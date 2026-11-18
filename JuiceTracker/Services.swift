import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Settings keys (UserDefaults)

enum Pref {
    static let dailyCheck = "dailyCheck"     // check juicewrldapi.com for new songs every day (default on)
    static let keepRunning = "keepRunning"   // stay open after the window closes, so checks keep running (default off)
    static let autoUpdate = "autoUpdate"     // check GitHub for app updates (default on)
    static let plexServer = "plexServer"     // e.g. http://192.168.1.20:32400
    static let menuBar = "menuBar"           // butterfly mini player in the menu bar (default on)
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
        var add = match
        add[kSecValueData as String] = Data(value.utf8)
        let saved = !value.isEmpty && SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        // Lets the app know a token exists without touching the Keychain: an unsigned app gets a new identity with
        // every update, so each Keychain read can bring up an "allow access" prompt.
        UserDefaults.standard.set(saved, forKey: "keychain.\(account).saved")
    }
}

// MARK: - Plex

enum Plex {
    struct Failure: LocalizedError { let errorDescription: String? }

    static var server: String {
        (UserDefaults.standard.string(forKey: Pref.plexServer) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    static var configured: Bool { !server.isEmpty && UserDefaults.standard.bool(forKey: "keychain.plex-token.saved") }

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

    private struct Track { let key: String; let plays: Int; let lastPlayed: Int }

    /// Every music track Plex has, as a lookup from a local file path. Plex sees the files under its own paths
    /// (often a different mount), so tracks are matched by "folder/file name", then by a unique file name.
    private static func trackFinder() async throws -> (String) -> Track? {
        var byTail: [String: Track] = [:], byName: [String: Track] = [:], ambiguous: Set<String> = []
        for section in try await musicSections() {
            let tracks = try await call("/library/sections/\(section.key)/all", query: [URLQueryItem(name: "type", value: "10")])
            for t in tracks["Metadata"] as? [[String: Any]] ?? [] {
                guard let key = t["ratingKey"] as? String else { continue }
                let track = Track(key: key, plays: (t["viewCount"] as? NSNumber)?.intValue ?? 0,
                                  lastPlayed: (t["lastViewedAt"] as? NSNumber)?.intValue ?? 0)
                for media in t["Media"] as? [[String: Any]] ?? [] {
                    for part in media["Part"] as? [[String: Any]] ?? [] {
                        guard let file = part["file"] as? String else { continue }
                        byTail[tail(file, 2)] = track
                        let name = tail(file, 1)
                        if let other = byName[name], other.key != key { ambiguous.insert(name) } else { byName[name] = track }
                    }
                }
            }
        }
        return { path in byTail[tail(path, 2)] ?? (ambiguous.contains(tail(path, 1)) ? nil : byName[tail(path, 1)]) }
    }

    /// Play counts for local files: [{ path, plays, last }] for the files Plex has, plus how many it doesn't.
    static func playCounts(paths: [String]) async throws -> (items: [[String: Any]], missing: Int) {
        let find = try await trackFinder()
        var items: [[String: Any]] = [], missing = 0
        for path in paths {
            guard let t = find(path) else { missing += 1; continue }
            items.append(["path": path, "plays": t.plays, "last": t.lastPlayed])
        }
        return (items, missing)
    }

    /// Makes (or replaces) an audio playlist from local file paths.
    static func playlist(title: String, paths: [String]) async throws -> (matched: Int, missing: Int) {
        let machine = try await call("/identity")["machineIdentifier"] as? String ?? ""
        let find = try await trackFinder()
        var keys: [String] = [], missing = 0
        for path in paths {
            guard let key = find(path)?.key else { missing += 1; continue }
            if !keys.contains(key) { keys.append(key) }
        }
        guard !keys.isEmpty else { throw Failure(errorDescription: "None of these songs are in Plex yet. Let Plex finish scanning, then try again.") }
        let existing = try await call("/playlists", query: [URLQueryItem(name: "playlistType", value: "audio")])["Metadata"] as? [[String: Any]] ?? []
        let uri = "server://\(machine)/com.plexapp.plugins.library/library/metadata/\(keys.joined(separator: ","))"
        _ = try await call("/playlists", method: "POST", query: [
            URLQueryItem(name: "type", value: "audio"), URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "smart", value: "0"), URLQueryItem(name: "uri", value: uri),
        ])
        // Only once the new one exists: if making it fails (Plex restarting, say), the old playlist is still there.
        for old in existing where old["title"] as? String == title {
            if let key = old["ratingKey"] as? String { _ = try await call("/playlists/\(key)", method: "DELETE") }
        }
        return (keys.count, missing)
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
        // The app's own catalog, freshly downloaded: one download, and the same rules for "released" and "has a file"
        // as everywhere else in the app.
        let before = await MainActor.run { EngineState.shared.fetchedAt }
        await EngineState.shared.reload()
        let (after, catalog) = await MainActor.run { (EngineState.shared.fetchedAt, EngineState.shared.catalog) }
        guard let after, after != before, !catalog.isEmpty else { return } // offline, or a download already running: next hour
        let songs = catalog.map { (id: $0.id, name: $0.name, released: Engine.isReleased($0), hasFile: !$0.filePath.isEmpty) }
        let defaults = UserDefaults.standard
        let known = Set(defaults.stringArray(forKey: "alertsKnownIds") ?? [])
        let wasReleased = Set(defaults.stringArray(forKey: "alertsReleasedIds") ?? [])
        // Older snapshots have no file list: treat every song as already having had one, so nothing alerts falsely.
        let hadFile = defaults.stringArray(forKey: "alertsFileIds").map(Set.init)
        let wished = Set(defaults.stringArray(forKey: "wishlistIds") ?? [])
        let wishNews = songs.filter { wished.contains($0.id) }.compactMap { s -> (id: String, name: String, what: String)? in
            if s.released && !wasReleased.contains(s.id) && known.contains(s.id) { return (s.id, s.name, "was just officially released") }
            if s.hasFile, let hadFile, !hadFile.contains(s.id) { return (s.id, s.name, "now has a file on juicewrldapi.com") }
            return nil
        }
        let added = songs.filter { !known.contains($0.id) }
        let nowReleased = songs.filter { $0.released && known.contains($0.id) && !wasReleased.contains($0.id) }
        defaults.set(songs.map(\.id), forKey: "alertsKnownIds")
        defaults.set(songs.filter(\.released).map(\.id), forKey: "alertsReleasedIds")
        defaults.set(songs.filter(\.hasFile).map(\.id), forKey: "alertsFileIds")
        defaults.set(Date(), forKey: "alertsLastCheck")
        defaults.set("\(songs.count) songs, \(known.isEmpty ? 0 : added.count) new, \(nowReleased.count) newly released", forKey: "alertsLastResult")
        if !known.isEmpty, !wishNews.isEmpty, !defaults.bool(forKey: "alertsDryRun") { notifyWishlist(wishNews) }
        let wishIds = Set(wishNews.map(\.id)) // already in their own alert
        let others = added.filter { !wishIds.contains($0.id) }, otherReleases = nowReleased.filter { !wishIds.contains($0.id) }
        guard !known.isEmpty, !added.isEmpty || !nowReleased.isEmpty else { return } // first run only takes a snapshot
        // For the menu bar's "New songs" line.
        defaults.set(added.map(\.name) + nowReleased.map { "\($0.name) (released)" }, forKey: "alertsLastNew")
        defaults.set(Date(), forKey: "alertsLastNewDate")
        if defaults.bool(forKey: "alertsDryRun") { return } // set only when testing, so no notification prompt appears
        guard !others.isEmpty || !otherReleases.isEmpty else { return }
        // New songs that already have a file (and older ones that just got one) can be downloaded from the alert.
        let fileNews = songs.filter { s in s.hasFile && !wishIds.contains(s.id) && (!known.contains(s.id) || (hadFile.map { !$0.contains(s.id) } ?? false)) }
        notify(added: others.map(\.name), released: otherReleases.map(\.name), downloadable: fileNews.map(\.id))
    }

    static let wishCategory = "wishlist"
    static let downloadAction = "download"

    /// Registers the "Download" button that wishlist alerts carry.
    static func registerActions() {
        let download = UNNotificationAction(identifier: downloadAction, title: "Download", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: wishCategory, actions: [download], intentIdentifiers: []),
        ])
    }

    /// Its own alert for wishlist songs, with a Download button (the song's id travels in userInfo).
    static func notifyWishlist(_ news: [(id: String, name: String, what: String)]) {
        let content = UNMutableNotificationContent()
        content.title = news.count == 1 ? "On your wishlist: \(news[0].name)" : "\(news.count) wishlist songs have news"
        content.body = news.prefix(4).map { "\($0.name) \($0.what)." }.joined(separator: " ")
        content.sound = .default
        content.categoryIdentifier = wishCategory
        content.userInfo = ["songIds": news.map(\.id)]
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            center.add(UNNotificationRequest(identifier: "wish-\(UUID().uuidString)", content: content, trigger: nil))
        }
    }

    static func notify(added: [String], released: [String], downloadable: [String] = []) {
        func list(_ names: [String]) -> String {
            names.count <= 3 ? names.joined(separator: ", ") : names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more"
        }
        var parts: [String] = []
        if !added.isEmpty { parts.append("\(added.count) new \(added.count == 1 ? "song" : "songs"): \(list(added)).") }
        if !released.isEmpty { parts.append("Just released: \(list(released)).") }
        let content = UNMutableNotificationContent()
        content.title = "Juice Tracker"
        if !downloadable.isEmpty { parts.append("\(downloadable.count) \(downloadable.count == 1 ? "has a file" : "have files") to download.") }
        content.body = parts.joined(separator: " ")
        content.sound = .default
        if !downloadable.isEmpty { content.categoryIdentifier = wishCategory; content.userInfo = ["songIds": downloadable] } // its Download button
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

// MARK: - Library snapshots

/// A dated CSV of the library (paths, tags, matched songs), saved weekly off the music drive, so a failed drive
/// still leaves a list of what was there. iCloud Drive when it's on, else Documents. The newest 12 are kept.
enum Snapshots {
    static var folder: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let base = FileManager.default.fileExists(atPath: icloud.path) ? icloud : home.appendingPathComponent("Documents")
        return base.appendingPathComponent("Juice Tracker Snapshots")
    }

    static func save(_ text: String) throws -> URL {
        let fm = FileManager.default, dir = folder
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let url = dir.appendingPathComponent("juice-wrld-library-\(f.string(from: Date())).csv")
        try Data(text.utf8).write(to: url, options: .atomic)
        let old = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for stale in old.filter({ $0.lastPathComponent.hasPrefix("juice-wrld-library-") }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(12) {
            try? fm.trashItem(at: stale, resultingItemURL: nil)
        }
        return url
    }
}

// MARK: - App updates from GitHub releases

enum Updater {
    struct Failure: LocalizedError { let errorDescription: String? }

    /// Shows the question as a sheet on the window, so downloads, scans and the music keep going while it's open
    /// (a modal alert stops the app's work until it's answered).
    @MainActor private static func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return alert.runModal() }
        return await withCheckedContinuation { cont in alert.beginSheetModal(for: window) { cont.resume(returning: $0) } }
    }

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
        // Always scheduled, so turning the setting on later works without a relaunch.
        let checkIfOn = { if Pref.bool(Pref.autoUpdate, default: true) { Task { await check(userInitiated: false) } } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: checkIfOn)
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in checkIfOn() }
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
            switch await present(ask) {
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
        // Detached explicitly before quitting below (a defer wouldn't run once NSApp.terminate ends the process).
        var mounted = true
        defer { if mounted { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) } }
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
        _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        mounted = false
        // Waits for this process to exit, moves the old copy to the Trash, puts the new one in its place (or the old
        // one back, if that fails), and opens it.
        let swap = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        old="$HOME/.Trash/JuiceTracker $(date +%Y-%m-%d-%H%M%S).app"
        mv "$2" "$old" && { mv "$3" "$2" || mv "$old" "$2"; }; open "$2"
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
    @AppStorage("crossfadeSeconds") private var crossfade = 4.0
    @AppStorage(Pref.keepRunning) private var keepRunning = false
    @AppStorage(Pref.autoUpdate) private var autoUpdate = true
    @AppStorage(Pref.menuBar) private var menuBar = true
    @AppStorage("eraTheme") private var eraTheme = "cosmic"
    @AppStorage("matchVolume") private var matchVolume = true
    @AppStorage("fadePause") private var fadePause = true
    @AppStorage("askQuitPlaying") private var askQuitPlaying = false
    @AppStorage("compactMode") private var compactMode = false
    @AppStorage("animatedDock") private var animatedDock = true
    @AppStorage("landedChime") private var landedChime = false
    @AppStorage("lyricStyle") private var lyricStyle = "line"
    @AppStorage("lyricBlur") private var lyricBlur = true
    @AppStorage("widget.edgeColor") private var edgeColor = ""
    @AppStorage("customAccent") private var customAccent = "ff6ad5"
    @AppStorage("customSky1") private var customSky1 = "d6308c"
    @AppStorage("customSky2") private var customSky2 = "5082ff"
    @AppStorage("discordOn") private var discordOn = false
    @AppStorage("discordAppId") private var discordAppId = ""

    private static var colorSave: DispatchWorkItem?
    /// A color picker's color, kept as hex in the settings.
    private func hex(_ value: Binding<String>) -> Binding<Color> {
        // Saved a moment after the color stops changing: each save redraws the whole window, and dragging in the color
        // wheel sends dozens of changes a second.
        Binding(get: { Color(EraTheme.color(value.wrappedValue) ?? .systemPink) }, set: { color in
            Self.colorSave?.cancel()
            let save = DispatchWorkItem { value.wrappedValue = EraTheme.hex(color) }
            Self.colorSave = save
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: save)
        })
    }
    @AppStorage(Pref.plexServer) private var plexServer = ""
    @State private var plexToken = "" // read when the window opens, never at app launch (see Keychain.write)
    @State private var plexStatus = ""
    @State private var openAtLogin = false
    @AppStorage(GoLive.serverKey) private var liveServer = ""
    @State private var liveKey = ""
    @State private var liveStatus = ""

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
                Toggle("Show the mini player in the menu bar", isOn: $menuBar)
                Text("Daily checks run while Juice Tracker is open. Keep it running, or open it at login, to get alerts without the window.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: { Text("New songs").bold() }
            Section {
                Picker("Crossfade between songs", selection: $crossfade) {
                    Text("Off").tag(0.0); Text("2 seconds").tag(2.0); Text("4 seconds").tag(4.0); Text("6 seconds").tag(6.0); Text("8 seconds").tag(8.0)
                }
                Toggle("Match the volume of quiet and loud files", isOn: $matchVolume)
                Text("Each file's level is measured when it starts and the player evens it out. Your files don't change.").font(.caption).foregroundColor(.secondary)
                Toggle("Fade the music when pausing and resuming", isOn: $fadePause)
                Toggle("Ask before quitting while a song plays", isOn: $askQuitPlaying)
            } header: { Text("Playback").bold() }

            Section {
                ShortcutsSettings()
            } header: { Text("Keyboard shortcuts").bold() }

            Section {
                Picker("Era theme", selection: $eraTheme) {
                    ForEach(EraTheme.all) { Text($0.name).tag($0.id) }
                    Text("Your colors").tag("custom")
                }
                if eraTheme == "custom" {
                    ColorPicker("Accent", selection: hex($customAccent), supportsOpacity: false)
                    ColorPicker("Sky glow", selection: hex($customSky1), supportsOpacity: false)
                    ColorPicker("Second sky glow", selection: hex($customSky2), supportsOpacity: false)
                }
                Toggle("Compact mode (denser, for smaller windows)", isOn: $compactMode)
                Toggle("Dock icon glows with the music and shows download progress", isOn: $animatedDock)
                Toggle("Play a chime when songs land", isOn: $landedChime)
                Text("Desktop widgets (drag to move, right-click to close)").font(.caption).foregroundColor(.secondary).padding(.top, 4)
                HStack {
                    ForEach(DesktopWidgets.kinds, id: \.key) { w in
                        Toggle(w.name, isOn: Binding(get: { UserDefaults.standard.bool(forKey: "widget.\(w.key)") },
                                                     set: { UserDefaults.standard.set($0, forKey: "widget.\(w.key)"); DesktopWidgets.apply() }))
                    }
                }
                HStack {
                    Toggle("Edge light in the cover's colors", isOn: Binding(get: { edgeColor.isEmpty }, set: { edgeColor = $0 ? "" : "ff6ad5" }))
                    if !edgeColor.isEmpty { ColorPicker("", selection: hex($edgeColor)).labelsHidden() }
                }
                .onChange(of: edgeColor) { _ in DesktopWidgets.apply() }
                Picker("Player lyrics", selection: $lyricStyle) {
                    Text("The line being sung, word by word").tag("line")
                    Text("The scrolling list").tag("list")
                }
                if lyricStyle == "list" { Toggle("Blur the lines not being sung", isOn: $lyricBlur) }
                Text("Recolors the app's accents and sky after an era's mood.").font(.caption).foregroundColor(.secondary)
            } header: { Text("Look").bold() }

            Section {
                Toggle("Show what's playing in my Discord status", isOn: $discordOn)
                TextField("Discord application ID", text: $discordAppId, prompt: Text("123456789012345678"))
                Text("Discord needs an application ID to show a status: make a free application at discord.com/developers/applications (name it Juice Tracker; the name is what Discord shows), then paste its Application ID here. The Discord app on this Mac must be open.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: { Text("Discord").bold() }

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
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: { Text("Plex").bold() }

            Section {
                TextField("Server URL", text: $liveServer, prompt: Text("rtmp://push-rtmp-….tiktokcdn.com/game/"))
                SecureField("Stream Key", text: $liveKey, prompt: Text("stream-…"))
                HStack {
                    Button("Save") {
                        Keychain.write(GoLive.keychainAccount, liveKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        liveStatus = GoLive.hasKey ? "Saved. Go live from the Player tab's broadcast button." : "Saved without a key."
                    }
                    if !liveStatus.isEmpty { Text(liveStatus).font(.caption) }
                }
                Text("Stream straight from Juice Tracker to TikTok LIVE: in TikTok, set up a LIVE on a computer (LIVE Center / LIVE Producer) and copy its Server URL and Stream Key here; TikTok gives new ones for each LIVE. The stream is the Player's stream window and the app's own sound, nothing else on your screen; macOS asks once for Screen Recording permission. Works with any RTMP service. The key is kept in your Keychain.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: { Text("Live").bold() }
        }
        .settingsLayout()
        .onAppear { plexToken = Keychain.read("plex-token") ?? ""; liveKey = GoLive.hasKey ? (Keychain.read(GoLive.keychainAccount) ?? "") : "" }
    }
}

// MARK: - Discord status

/// Shows "Listening to …" in your Discord profile while music plays, through the Discord app on this Mac (its local
/// connection; nothing goes over the network from here). Needs a Discord application ID (Settings > Discord).
final class DiscordStatus {
    static let shared = DiscordStatus()
    private let queue = DispatchQueue(label: "discord")
    private var fd: Int32 = -1
    private var connectedId = ""
    private var startedAt: Date?
    private var lastTitle: String?
    private var lastEra = ""
    private var lastId = ""          // the app ID last sent (main thread only; `connectedId` belongs to the queue)
    /// The playing song's era (NowPlaying finds the song a moment after it starts, then calls `refresh`).
    var era = ""
    func refresh() { update() }

    static var on: Bool { UserDefaults.standard.bool(forKey: "discordOn") }
    static var appId: String { (UserDefaults.standard.string(forKey: "discordAppId") ?? "").trimmingCharacters(in: .whitespaces) }

    func start() {
        for name in [AmbientPlayer.changed, UserDefaults.didChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.update() }
        }
    }

    private func update() {
        let p = AmbientPlayer.shared
        let id = Self.appId, title = Self.on && p.isPlaying ? p.title : nil
        if title != lastTitle { startedAt = title == nil ? nil : Date().addingTimeInterval(-p.currentTime) }
        let era = title == nil ? "" : self.era
        guard title != lastTitle || era != lastEra || lastId != id else { return }
        lastTitle = title; lastEra = era; lastId = id
        let started = startedAt
        queue.async { [weak self] in self?.send(id: id, title: title, era: era, started: started) }
    }

    private func send(id: String, title: String?, era: String, started: Date?) {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { close(); return }
        if fd < 0 || connectedId != id { close(); connect(id) }
        guard fd >= 0 else { retryLater(playing: title != nil); return } // Discord isn't open (yet)
        var activity: Any = NSNull()
        if let title {
            var a: [String: Any] = ["details": title, "state": era.isEmpty ? "Juice WRLD" : "Juice WRLD · \(era)", "assets": ["large_text": "Juice Tracker"]]
            if let started { a["timestamps"] = ["start": Int(started.timeIntervalSince1970)] }
            activity = a
        }
        let ok = frame(1, ["cmd": "SET_ACTIVITY", "args": ["pid": Int(getpid()), "activity": activity], "nonce": UUID().uuidString])
        if !ok { close(); retryLater(playing: title != nil) } // Discord quit
    }

    /// While music plays and Discord can't be reached, try again every 30 seconds, so opening Discord mid-song shows
    /// the status without waiting for the next song.
    private var retry: DispatchWorkItem? // only one waiting retry (this runs on `queue`)
    private func retryLater(playing: Bool) {
        retry?.cancel()
        guard playing else { return }
        let work = DispatchWorkItem { [weak self] in self?.lastId = ""; self?.update() }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// Discord listens on discord-ipc-0…9 in the temporary folder.
    private func connect(_ id: String) {
        let dir = (ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        for n in 0..<10 {
            let path = (dir as NSString).appendingPathComponent("discord-ipc-\(n)")
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            guard s >= 0 else { continue }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (k, b) in bytes.enumerated() { raw[k] = b } }
            let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            if r == 0 {
                var noSigPipe: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                var wait = timeval(tv_sec: 2, tv_usec: 0) // never hang waiting for Discord's answer
                setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
                fd = s; connectedId = id
                if frame(0, ["v": 1, "client_id": id]) { return } // frame read Discord's answer
                close(); return
            }
            Darwin.close(s)
        }
    }

    private func frame(_ op: UInt32, _ body: [String: Any]) -> Bool {
        guard fd >= 0, let json = try? JSONSerialization.data(withJSONObject: body) else { return false }
        var head = Data()
        var o = op.littleEndian, l = UInt32(json.count).littleEndian
        head.append(Data(bytes: &o, count: 4)); head.append(Data(bytes: &l, count: 4))
        let all = head + json
        let sent = all.withUnsafeBytes { write(fd, $0.baseAddress, all.count) }
        if sent == all.count { readReply(); return true }
        return false
    }

    /// Discord answers each message; read it so its buffer never fills (the content isn't needed).
    private func readReply() {
        var head = [UInt8](repeating: 0, count: 8)
        guard read(fd, &head, 8) == 8 else { return }
        var left = Int(UInt32(head[4]) | UInt32(head[5]) << 8 | UInt32(head[6]) << 16 | UInt32(head[7]) << 24)
        var buf = [UInt8](repeating: 0, count: 4096)
        while left > 0 { let n = read(fd, &buf, min(left, buf.count)); if n <= 0 { break }; left -= n }
    }

    private func close() { if fd >= 0 { Darwin.close(fd) }; fd = -1; connectedId = "" }
}

private extension View {
    /// Grouped sections that wrap and scroll (macOS 13 and later); macOS 12 keeps the column form, scrolling.
    @ViewBuilder func settingsLayout() -> some View {
        if #available(macOS 13, *) { formStyle(.grouped).frame(width: 600, height: 660) }
        else { ScrollView { padding(20) }.frame(width: 560, height: 660) }
    }
}

// MARK: - Keyboard shortcuts

/// Your own keys for the player: in the app, or (with Global on) from any app. Global shortcuts use the system's
/// hot keys, which need no accessibility permission.
@MainActor enum Shortcuts {
    static let actions: [(id: String, name: String)] = [("playPause", "Play / pause"), ("next", "Next song"), ("restart", "Start the song again"),
                                                         ("volUp", "Volume up"), ("volDown", "Volume down")]
    struct Key: Equatable { var code: UInt16; var mods: NSEvent.ModifierFlags; var label: String }
    static let changed = Notification.Name("ShortcutsChanged")
    static var global: Bool { UserDefaults.standard.bool(forKey: "shortcutsGlobal") }
    private static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    static func key(_ id: String) -> Key? {
        let parts = (UserDefaults.standard.string(forKey: "shortcut.\(id)") ?? "").split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3, let code = UInt16(parts[0]), let mods = UInt(parts[1]) else { return nil }
        return Key(code: code, mods: NSEvent.ModifierFlags(rawValue: mods), label: parts[2])
    }
    static func set(_ id: String, _ key: Key?) {
        UserDefaults.standard.set(key.map { "\($0.code)|\($0.mods.rawValue)|\($0.label)" }, forKey: "shortcut.\(id)")
        apply()
    }
    /// The key pressed, as a shortcut: it needs ⌘, ⌥ or ⌃ (or is a function key), so typing never sets one off.
    static func from(_ e: NSEvent) -> Key? {
        let mods = e.modifierFlags.intersection(relevant)
        let fn = (122...135).contains(Int(e.keyCode)) || [96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 118, 120].contains(Int(e.keyCode))
        guard fn || !mods.intersection([.command, .option, .control]).isEmpty else { return nil }
        var label = ""
        if mods.contains(.control) { label += "⌃" }; if mods.contains(.option) { label += "⌥" }
        if mods.contains(.shift) { label += "⇧" }; if mods.contains(.command) { label += "⌘" }
        let names: [UInt16: String] = [49: "Space", 36: "↩", 123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        label += names[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "?").uppercased()
        return Key(code: e.keyCode, mods: mods, label: label)
    }

    static func run(_ id: String) {
        let p = AmbientPlayer.shared
        switch id {
        case "playPause": if p.title == nil { EngineAmbient.setOn(true); p.resume() } else { p.togglePause() }
        case "next": p.skip()
        case "restart": p.seek(to: 0)
        case "volUp", "volDown":
            EngineAmbient.volume = max(0, min(100, EngineAmbient.volume + (id == "volUp" ? 5 : -5)))
            p.volume = Float(EngineAmbient.volume / 100)
        default: break
        }
    }

    private static var monitor: Any?
    private static var hotKeys: [EventHotKeyRef] = []
    private static var handler: EventHandlerRef?

    /// Listens for the shortcuts: in the app always; from other apps too while Global is on.
    static func apply() {
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                guard !global, !recording, let k = from(e), let hit = actions.first(where: { key($0.id).map { $0.code == k.code && $0.mods == k.mods } ?? false }) else { return e }
                run(hit.id); return nil
            }
        }
        hotKeys.forEach { UnregisterEventHotKey($0) }; hotKeys = []
        if global {
            if handler == nil {
                var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
                InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                    var hk = EventHotKeyID()
                    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                    let n = Int(hk.id)
                    DispatchQueue.main.async { MainActor.assumeIsolated { if Shortcuts.actions.indices.contains(n) { Shortcuts.run(Shortcuts.actions[n].id) } } }
                    return noErr
                }, 1, &spec, nil, &handler)
            }
            for (n, a) in actions.enumerated() {
                guard let k = key(a.id) else { continue }
                var carbon: UInt32 = 0
                if k.mods.contains(.command) { carbon |= UInt32(cmdKey) }; if k.mods.contains(.option) { carbon |= UInt32(optionKey) }
                if k.mods.contains(.control) { carbon |= UInt32(controlKey) }; if k.mods.contains(.shift) { carbon |= UInt32(shiftKey) }
                var ref: EventHotKeyRef?
                if RegisterEventHotKey(UInt32(k.code), carbon, EventHotKeyID(signature: OSType(0x4A54524B), id: UInt32(n)), GetApplicationEventTarget(), 0, &ref) == noErr, let ref { hotKeys.append(ref) }
            }
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }
    /// While a shortcut is being recorded in Settings, keys go to the recorder.
    static var recording = false
}

private struct ShortcutsSettings: View {
    @AppStorage("shortcutsGlobal") private var global = false
    @State private var recording: String?
    @State private var monitor: Any?
    @State private var version = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Shortcuts.actions, id: \.id) { a in
                HStack {
                    Text(a.name).frame(width: 170, alignment: .leading)
                    Button(recording == a.id ? "Press the keys…" : Shortcuts.key(a.id)?.label ?? "Not set") { record(a.id) }.frame(minWidth: 120)
                    if Shortcuts.key(a.id) != nil, recording != a.id { Button("Clear") { Shortcuts.set(a.id, nil); version += 1 }.buttonStyle(.link) }
                }
            }
            .id(version)
            Toggle("Also when Juice Tracker is in the background (global)", isOn: $global).onChange(of: global) { _ in Shortcuts.apply() }
            Text("Click a shortcut, then press the keys: they need ⌘, ⌥ or ⌃, or a function key. Esc cancels, Delete clears.").font(.caption).foregroundColor(.secondary)
        }
        .onDisappear(perform: stop)
    }
    private func record(_ id: String) {
        stop(); recording = id; Shortcuts.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }                                            // Esc
            if e.keyCode == 51 || e.keyCode == 117 { Shortcuts.set(id, nil); stop(); return nil } // Delete
            guard let k = Shortcuts.from(e) else { return nil }
            Shortcuts.set(id, k); stop()
            return nil
        }
    }
    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recording = nil; Shortcuts.recording = false; version += 1
    }
}
