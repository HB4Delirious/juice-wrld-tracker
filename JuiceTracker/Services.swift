import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Settings keys (UserDefaults)

enum Pref {
    static let dailyCheck = "dailyCheck"     // check juicewrldapi.com for new songs every day (default on)
    static let keepRunning = "keepRunning"   // stay open after the window closes, so checks keep running (default off)
    static let autoUpdate = "autoUpdate"     // check GitHub for app updates (default on)
    static let plexServer = "plexServer"     // e.g. http://192.168.1.20:32400
    static func bool(_ key: String, default value: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? value }
}

// MARK: - Keychain (the Plex token never goes in UserDefaults or the web page)

enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "JuiceTracker"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let value = String(decoding: data, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    static func write(_ account: String, _ value: String) {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(match as CFDictionary)
        guard !value.isEmpty else { return }
        var add = match
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Plex

enum Plex {
    struct Failure: LocalizedError { let errorDescription: String? }

    static var server: String {
        (UserDefaults.standard.string(forKey: Pref.plexServer) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    static var configured: Bool { !server.isEmpty && Keychain.read("plex-token") != nil }

    /// One Plex API call; returns the JSON "MediaContainer".
    private static func call(_ path: String, method: String = "GET", query: [URLQueryItem] = []) async throws -> [String: Any] {
        guard let token = Keychain.read("plex-token"), var comps = URLComponents(string: server + path),
              comps.scheme == "http" || comps.scheme == "https" else {
            throw Failure(errorDescription: "Set up Plex in Settings (⌘,) first.")
        }
        if !query.isEmpty { comps.queryItems = (comps.queryItems ?? []) + query }
        guard let url = comps.url else { throw Failure(errorDescription: "The Plex server address isn't valid.") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Juice Tracker", forHTTPHeaderField: "X-Plex-Product")
        req.setValue(Bundle.main.bundleIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw Failure(errorDescription: "Plex didn't accept the token.") }
        guard (200..<300).contains(status) else { throw Failure(errorDescription: "Plex answered \(status).") }
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json["MediaContainer"] as? [String: Any] ?? [:]
    }

    /// The music libraries ("artist" sections).
    static func musicSections() async throws -> [(key: String, title: String)] {
        let dirs = try await call("/library/sections")["Directory"] as? [[String: Any]] ?? []
        return dirs.filter { $0["type"] as? String == "artist" }
            .compactMap { d in (d["key"] as? String).map { (key: $0, title: d["title"] as? String ?? "") } }
    }

    /// Rescans every music library. Returns how many.
    @discardableResult static func refresh() async throws -> Int {
        let sections = try await musicSections()
        for s in sections { _ = try await call("/library/sections/\(s.key)/refresh") }
        return sections.count
    }

    /// Downloads and tag edits come in bursts; one rescan a few seconds after the last change is enough.
    private static var pending: DispatchWorkItem?
    static func scheduleRefresh() {
        guard configured else { return }
        pending?.cancel()
        let work = DispatchWorkItem { Task { try? await refresh() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Makes (or replaces) an audio playlist from local file paths. Plex sees the files under its own paths
    /// (often a different mount), so tracks are matched by "folder/file name", then by a unique file name.
    static func playlist(title: String, paths: [String]) async throws -> (matched: Int, missing: Int) {
        let machine = try await call("/identity")["machineIdentifier"] as? String ?? ""
        var byTail: [String: String] = [:], byName: [String: String] = [:], ambiguous: Set<String> = []
        for section in try await musicSections() {
            let tracks = try await call("/library/sections/\(section.key)/all", query: [URLQueryItem(name: "type", value: "10")])
            for track in tracks["Metadata"] as? [[String: Any]] ?? [] {
                guard let key = track["ratingKey"] as? String else { continue }
                for media in track["Media"] as? [[String: Any]] ?? [] {
                    for part in media["Part"] as? [[String: Any]] ?? [] {
                        guard let file = part["file"] as? String else { continue }
                        byTail[tail(file, 2)] = key
                        let name = tail(file, 1)
                        if byName[name] != nil, byName[name] != key { ambiguous.insert(name) } else { byName[name] = key }
                    }
                }
            }
        }
        var keys: [String] = []
        for path in paths {
            let name = tail(path, 1)
            if let key = byTail[tail(path, 2)] ?? (ambiguous.contains(name) ? nil : byName[name]), !keys.contains(key) { keys.append(key) }
        }
        guard !keys.isEmpty else { throw Failure(errorDescription: "None of these songs are in Plex yet. Let Plex finish scanning, then try again.") }
        let existing = try await call("/playlists", query: [URLQueryItem(name: "playlistType", value: "audio")])["Metadata"] as? [[String: Any]] ?? []
        for old in existing where old["title"] as? String == title {
            if let key = old["ratingKey"] as? String { _ = try await call("/playlists/\(key)", method: "DELETE") }
        }
        let uri = "server://\(machine)/com.plexapp.plugins.library/library/metadata/\(keys.joined(separator: ","))"
        _ = try await call("/playlists", method: "POST", query: [
            URLQueryItem(name: "type", value: "audio"), URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "smart", value: "0"), URLQueryItem(name: "uri", value: uri),
        ])
        return (keys.count, paths.count - keys.count)
    }

    private static func tail(_ path: String, _ n: Int) -> String {
        path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").suffix(n).joined(separator: "/").lowercased()
    }
}

// MARK: - Daily new-song alerts

/// Checks juicewrldapi.com once a day (while the app is running) and posts a notification for songs that are new
/// since the last check, or that moved to released. Keeps its own snapshot, separate from the page's.
enum SongAlerts {
    private static var timer: Timer?

    static func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in checkIfDue() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { checkIfDue() }
    }

    static func checkIfDue() {
        guard Pref.bool(Pref.dailyCheck, default: true) else { return }
        let last = UserDefaults.standard.object(forKey: "alertsLastCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 23 * 3600 else { return }
        Task { await check() }
    }

    static func check() async {
        var next = URL(string: "https://juicewrldapi.com/juicewrld/songs/?page=1&page_size=100")
        var songs: [(id: String, name: String, released: Bool)] = []
        do {
            while let url = next, songs.count < 50_000 {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                for s in json["results"] as? [[String: Any]] ?? [] {
                    guard let id = s["id"].map({ "\($0)" }) else { continue }
                    // Same rule as the page's isReleased: category "released" or a release date.
                    let released = (s["category"] as? String)?.lowercased() == "released"
                        || !((s["release_date"] as? String) ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                    songs.append((id, s["name"] as? String ?? "", released))
                }
                next = (json["next"] as? String).flatMap(URL.init(string:))
            }
        } catch { return } // offline: try again next hour
        guard !songs.isEmpty else { return }
        let defaults = UserDefaults.standard
        let known = Set(defaults.stringArray(forKey: "alertsKnownIds") ?? [])
        let wasReleased = Set(defaults.stringArray(forKey: "alertsReleasedIds") ?? [])
        let added = songs.filter { !known.contains($0.id) }
        let nowReleased = songs.filter { $0.released && known.contains($0.id) && !wasReleased.contains($0.id) }
        defaults.set(songs.map(\.id), forKey: "alertsKnownIds")
        defaults.set(songs.filter(\.released).map(\.id), forKey: "alertsReleasedIds")
        defaults.set(Date(), forKey: "alertsLastCheck")
        defaults.set("\(songs.count) songs, \(known.isEmpty ? 0 : added.count) new, \(nowReleased.count) newly released", forKey: "alertsLastResult")
        guard !known.isEmpty, !added.isEmpty || !nowReleased.isEmpty else { return } // first run only takes a snapshot
        if defaults.bool(forKey: "alertsDryRun") { return } // set only when testing, so no notification prompt appears
        notify(added: added.map(\.name), released: nowReleased.map(\.name))
    }

    static func notify(added: [String], released: [String]) {
        func list(_ names: [String]) -> String {
            names.count <= 3 ? names.joined(separator: ", ") : names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more"
        }
        var parts: [String] = []
        if !added.isEmpty { parts.append("\(added.count) new \(added.count == 1 ? "song" : "songs"): \(list(added)).") }
        if !released.isEmpty { parts.append("Just released: \(list(released)).") }
        let content = UNMutableNotificationContent()
        content.title = "Juice Tracker"
        content.body = parts.joined(separator: " ")
        content.sound = .default
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

// MARK: - App updates from GitHub releases

enum Updater {
    struct Failure: LocalizedError { let errorDescription: String? }

    /// "updateFeed" is only set when testing the updater against a local server.
    private static var feed: URL {
        URL(string: UserDefaults.standard.string(forKey: "updateFeed") ?? "")
            ?? URL(string: "https://api.github.com/repos/HB4Delirious/juice-wrld-tracker/releases/latest")!
    }
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : 0) != (i < y.count ? y[i] : 0) {
            return (i < x.count ? x[i] : 0) > (i < y.count ? y[i] : 0)
        }
        return false
    }

    static func startDailyChecks() {
        guard Pref.bool(Pref.autoUpdate, default: true) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { Task { await check(userInitiated: false) } }
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            if Pref.bool(Pref.autoUpdate, default: true) { Task { await check(userInitiated: false) } }
        }
    }

    @MainActor static func check(userInitiated: Bool) async {
        do {
            let (data, response) = try await URLSession.shared.data(from: feed)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { throw Failure(errorDescription: "Couldn't read the latest release.") }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard isNewer(latest, than: current) else {
                if userInitiated { alert("You're up to date.", "Juice Tracker \(current) is the latest version.") }
                return
            }
            if !userInitiated, UserDefaults.standard.string(forKey: "skippedVersion") == latest { return }
            let assets = json["assets"] as? [[String: Any]] ?? []
            guard let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true })?["browser_download_url"] as? String,
                  let dmgURL = URL(string: dmg) else { throw Failure(errorDescription: "The \(tag) release has no DMG.") }
            let ask = NSAlert()
            ask.messageText = "Juice Tracker \(latest) is available"
            ask.informativeText = "You have \(current). Update now? The app will quit, update, and reopen."
            ask.addButton(withTitle: "Update")
            ask.addButton(withTitle: "Later")
            ask.addButton(withTitle: "Skip This Version")
            NSApp.activate(ignoringOtherApps: true)
            switch ask.runModal() {
            case .alertFirstButtonReturn: try await install(dmgURL, version: latest)
            case .alertThirdButtonReturn: UserDefaults.standard.set(latest, forKey: "skippedVersion")
            default: break
            }
        } catch {
            if userInitiated { alert("Couldn't check for updates", error.localizedDescription) }
        }
    }

    /// Downloads the DMG, checks the app inside is this app at the expected version with a valid signature,
    /// stages it next to the running copy, then quits; a helper swaps the copies and reopens the new one.
    @MainActor private static func install(_ dmg: URL, version: String) async throws {
        let (tmp, response) = try await URLSession.shared.download(from: dmg)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(errorDescription: "The download failed.") }
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appendingPathComponent("jt-update-\(UUID().uuidString)")
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, tmp.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let newApp = mount.appendingPathComponent("JuiceTracker.app")
        let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == version else {
            throw Failure(errorDescription: "The downloaded app isn't Juice Tracker \(version), so it wasn't installed.")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])
        let installed = Bundle.main.bundleURL
        let staged = installed.deletingLastPathComponent().appendingPathComponent(".JuiceTracker-\(version).app")
        try? fm.removeItem(at: staged)
        try run("/usr/bin/ditto", [newApp.path, staged.path])
        // Waits for this process to exit, moves the old copy to the Trash, puts the new one in its place, opens it.
        let swap = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        mv "$2" "$HOME/.Trash/JuiceTracker $(date +%Y-%m-%d-%H%M%S).app" && mv "$3" "$2" && open "$2"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", swap, "sh", String(ProcessInfo.processInfo.processIdentifier), installed.path, staged.path]
        try helper.run()
        NSApp.terminate(nil)
    }

    @discardableResult private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw Failure(errorDescription: "\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

// MARK: - Settings window (⌘,)

struct SettingsView: View {
    @AppStorage(Pref.dailyCheck) private var dailyCheck = true
    @AppStorage(Pref.keepRunning) private var keepRunning = false
    @AppStorage(Pref.autoUpdate) private var autoUpdate = true
    @AppStorage(Pref.plexServer) private var plexServer = ""
    @State private var plexToken = Keychain.read("plex-token") ?? ""
    @State private var plexStatus = ""
    @State private var openAtLogin = false

    var body: some View {
        Form {
            Section {
                Toggle("Check for new and newly released songs every day", isOn: $dailyCheck)
                Toggle("Keep running when the window is closed", isOn: $keepRunning)
                if #available(macOS 13, *) {
                    Toggle("Open Juice Tracker at login", isOn: $openAtLogin)
                        .onAppear { openAtLogin = SMAppService.mainApp.status == .enabled }
                        .onChange(of: openAtLogin) { on in
                            try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        }
                }
                Text("Daily checks run while Juice Tracker is open. Keep it running, or open it at login, to get alerts without the window.")
                    .font(.caption).foregroundColor(.secondary)
            } header: { Text("New songs").bold() }

            Section {
                Toggle("Check for app updates automatically", isOn: $autoUpdate)
                Button("Check Now") { Task { await Updater.check(userInitiated: true) } }
            } header: { Text("Updates").bold() }

            Section {
                TextField("Server address", text: $plexServer, prompt: Text("http://192.168.1.20:32400"))
                SecureField("Token", text: $plexToken, prompt: Text("X-Plex-Token"))
                HStack {
                    Button("Save and Test") {
                        Keychain.write("plex-token", plexToken.trimmingCharacters(in: .whitespacesAndNewlines))
                        plexStatus = "Connecting…"
                        Task {
                            do {
                                let sections = try await Plex.musicSections()
                                plexStatus = sections.isEmpty ? "Connected, but no music libraries were found."
                                    : "Connected: \(sections.map(\.title).joined(separator: ", "))."
                            } catch { plexStatus = error.localizedDescription }
                        }
                    }
                    Link("Finding your token", destination: URL(string: "https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/")!)
                }
                if !plexStatus.isEmpty { Text(plexStatus).font(.caption) }
                Text("When set up, Plex rescans after downloads and tag edits, and Export & backup can make Plex playlists. The token is kept in your Keychain.")
                    .font(.caption).foregroundColor(.secondary)
            } header: { Text("Plex").bold() }
        }
        .padding(20)
        .frame(width: 480)
    }
}
