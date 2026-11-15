import AppKit

// Stage 4c of replacing the HTML engine: the download queue, the music drive status, the background music and the
// weekly library snapshot, run by Swift. After each download the page still adds the file to the library and
// auto-tags it (tag writing moves in 4d).

@MainActor final class EngineDownloads: ObservableObject {
    static let shared = EngineDownloads()
    struct Item: Codable { var id: String; var tries = 0 }
    struct Job { var done = 0, total = 0, saved = 0; var failed: [String] = []; var current = "", waiting = "" }

    @Published private(set) var job: Job?
    private var queue: [Item] = []
    private var stopping = false
    private var loaded = false

    /// The queue (queue.json), carried over from the page the first time. It survives quitting and dropped drives.
    private func load() async {
        guard !loaded else { return }
        loaded = true
        queue = EngineFiles.read("queue.json").flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
        if let json = try? await NativeStore.shared.tryAct("engineQueue"),
           let old = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] {
            for o in old { if let id = o["id"].map({ "\($0)" }), !queue.contains(where: { $0.id == id }) { queue.append(Item(id: id, tries: (o["tries"] as? NSNumber)?.intValue ?? 0)) } }
            save()
        }
    }
    private func save() { if let data = try? JSONEncoder().encode(queue) { try? EngineFiles.write("queue.json", data) } }

    /// After the library is in place: carries on with what was queued, and takes a wishlist alert's Download.
    func start() async {
        await load()
        takePending()
        run()
    }

    /// Songs from a wishlist alert's Download button (kept by the app until now: the alert can start it).
    func takePending() {
        let ids = UserDefaults.standard.stringArray(forKey: "pendingDownloads") ?? []
        guard !ids.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: "pendingDownloads")
        add(ids)
    }

    /// Queues songs (once each) and starts the queue. Returns how many were added.
    @discardableResult func add(_ ids: [String]) -> Int {
        var added = 0
        for id in ids where !queue.contains(where: { $0.id == id }) { queue.append(Item(id: id)); added += 1 }
        save()
        if job != nil { job!.total += added; NativeStore.shared.rebuild() }
        run()
        return added
    }

    func stop() { if job != nil { stopping = true } }

    /// The songs on your wishlist that you don't have and that have a file on the site. Returns how many.
    func downloadWishlist() -> Int {
        let engine = EngineState.shared, owned = EngineLibrary.shared.owned, wish = engine.wish
        let ids = engine.catalog.enumerated().filter { wish[$0.element.id] != nil && !owned.contains($0.offset) && !$0.element.filePath.isEmpty }.map(\.element.id)
        return add(ids)
    }

    private func run() {
        guard job == nil, EngineLibrary.shared.root != nil, !EngineState.shared.catalog.isEmpty, !queue.isEmpty else { return }
        Task { await runQueue() }
    }

    /// One song at a time. A failed song goes to the back of the line (3 tries); a dropped drive pauses the queue
    /// until it's back.
    private func runQueue() async {
        stopping = false
        job = Job(total: queue.count)
        NativeStore.shared.rebuild()
        while !stopping, let item = queue.first {
            let catalog = EngineState.shared.catalog
            guard let i = catalog.firstIndex(where: { $0.id == item.id }), !catalog[i].filePath.isEmpty else {
                queue.removeFirst(); save(); job!.done += 1; continue
            }
            job!.current = catalog[i].name
            NativeStore.shared.rebuild()
            do {
                let r = try await downloadSong(i)
                if !r.existed { job!.saved += 1 }
                if !r.note.isEmpty { job!.failed.append("\(catalog[i].name) (\(r.note))") }
                queue.removeAll { $0.id == item.id }; save()
                job!.done += 1
            } catch {
                let message = error.localizedDescription
                if message.contains("isn't available") { await waitForDrive(message); continue } // the same song again
                var it = item
                it.tries += 1
                queue.removeAll { $0.id == item.id }
                if it.tries >= 3 { job!.failed.append("\(catalog[i].name) (\(message))"); job!.done += 1 }
                else { queue.append(it) } // back of the line
                save()
                if it.tries < 3 { try? await Task.sleep(nanoseconds: UInt64(4 * it.tries) * 1_000_000_000) }
            }
            NativeStore.shared.rebuild()
        }
        if stopping { queue = []; save() }
        let saved = job?.saved ?? 0
        job = nil
        NativeStore.shared.rebuild()
        if saved > 0 { Plex.scheduleRefresh() }
    }

    /// Downloads one song now, outside the queue (File health's Replace). Returns where it went.
    func downloadNow(_ i: Int) async throws -> (existed: Bool, note: String, where: String) {
        let r = try await downloadSong(i)
        let library = EngineLibrary.shared, song = EngineState.shared.catalog[i]
        let folder = Engine.saveFolder(song, library.layout)
        let inner = folder.split(separator: "/").dropFirst().joined(separator: "/")
        return (r.existed, r.note, inner.isEmpty ? (library.root?.lastPathComponent ?? "") : inner)
    }

    /// Saves one song into the folder its era's songs live in; the page adds it to the library, then Swift tags it.
    private func downloadSong(_ i: Int) async throws -> (existed: Bool, note: String) {
        let library = EngineLibrary.shared, song = EngineState.shared.catalog[i]
        guard let root = library.root, let url = URL(string: Engine.fileUrl(song)) else { throw EngineError("Choose your music folder first") }
        let rel = "\(Engine.saveFolder(song, library.layout))/\(Engine.saveFileName(song))"
        let inner = rel.split(separator: "/").dropFirst().map(String.init)
        let dest = inner.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL
        // never outside the music folder, whatever a song's name says
        guard dest.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw EngineError("can't be saved there") }
        let r = try await NativeBridge.downloadFile(url, to: dest, root: root.path)
        var note = ""
        if let json = try? await NativeStore.shared.tryAct("afterDownload", i, ["rel": rel, "existed": r.existed, "noTag": true]),
           let out = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
            note = out["note"] as? String ?? ""
        }
        if !r.existed {
            // Into Swift's library straight away (the page's report of it can arrive later), then auto-tag it.
            let tags = await Task.detached { TagReader.read(dest, ext: Engine.extOf(rel)) }.value
            EngineLibrary.shared.updateFile(rel, tags: tags, size: r.size)
            let tagNote = await EngineFixer.shared.autoTag(rel, song: i)
            if !tagNote.isEmpty { note = tagNote }
        }
        return (r.existed, note)
    }

    /// The music drive dropped: try to reconnect every 30 seconds until it answers (or the queue is stopped).
    private func waitForDrive(_ message: String) async {
        job?.waiting = message
        NativeStore.shared.rebuild()
        while !stopping {
            for _ in 0..<30 where !stopping { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            if stopping { break }
            await EngineLibrary.shared.reconnect()
            if let root = EngineLibrary.shared.root, await DriveCheck.answers(root, within: 10) != nil { break }
        }
        job?.waiting = ""
        await EngineLibrary.shared.checkDrive()
        NativeStore.shared.rebuild()
    }

    /// For the sidebar: done, total, the song downloading now, and whether it's waiting for the drive.
    var queueState: NState.Queue? {
        job.map { NState.Queue(done: $0.done, total: $0.total, current: $0.current, waiting: !$0.waiting.isEmpty) }
    }
}

// MARK: - The music drive

enum DriveCheck {
    /// How long the folder took to answer, or nil if it's gone or didn't answer in time.
    static func answers(_ url: URL, within seconds: Double) async -> Double? {
        await withTaskGroup(of: Double?.self) { group in
            group.addTask {
                let started = Date()
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? Date().timeIntervalSince(started) : -1
            }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first.flatMap { $0 < 0 ? nil : $0 }
        }
    }
}

extension EngineLibrary {
    /// Is the music folder answering, slowly, or not at all? (the dot under the sidebar)
    func checkDrive() async {
        guard let root, !driveBusy else { return }
        driveBusy = true
        defer { driveBusy = false }
        let started = Date()
        let took = await withTaskGroup(of: (Bool, Double)?.self) { group -> (Bool, Double)? in
            group.addTask {
                var isDir: ObjCBool = false
                let ok = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
                return (ok, Date().timeIntervalSince(started))
            }
            group.addTask { try? await Task.sleep(nanoseconds: 8_000_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let took {
            drive = !took.0 ? NState.Drive(kind: "off", text: "Music drive disconnected. Click to reconnect")
                : took.1 < 0.8 ? NState.Drive(kind: "ok", text: "Music drive connected")
                : NState.Drive(kind: "slow", text: "Music drive is slow (\(String(format: "%.1f", took.1)) s to answer)")
        } else {
            drive = NState.Drive(kind: "slow", text: "Music drive isn't answering")
        }
        NativeStore.shared.rebuild()
    }

    /// The sidebar's drive button: a fresh check, or a reconnect when the drive is down.
    func driveClicked() async {
        if drive?.kind != "ok" {
            drive = NState.Drive(kind: drive?.kind ?? "slow", text: "Reconnecting…")
            NativeStore.shared.rebuild()
            await reconnect()
        }
        await checkDrive()
    }

    /// Checks the drive every minute while the app is in front.
    func watchDrive() {
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in if NSApp.isActive { await EngineLibrary.shared.checkDrive() } }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await EngineLibrary.shared.checkDrive() }
        }
    }
}

// MARK: - Background music

/// Your matched songs, shuffled, very quietly (or one era's). The settings carry over from the page the first time.
@MainActor enum EngineAmbient {
    static let playable: Set<String> = ["mp3", "m4a", "m4b", "aac", "alac", "flac", "wav", "aif", "aiff"] // what AVAudioPlayer opens

    static var on: Bool {
        get { UserDefaults.standard.object(forKey: "ambientOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ambientOn") }
    }
    static var era: String {
        get { UserDefaults.standard.string(forKey: "ambientEra") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "ambientEra") }
    }
    static var volume: Double {
        get { UserDefaults.standard.object(forKey: "ambientVolume") as? Double ?? 6 }
        set { UserDefaults.standard.set(newValue, forKey: "ambientVolume") }
    }

    /// The page's player settings, once.
    static func migrate() async {
        guard UserDefaults.standard.object(forKey: "ambientMigrated") == nil,
              let json = try? await NativeStore.shared.tryAct("engineSettings"),
              let s = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        UserDefaults.standard.set(true, forKey: "ambientMigrated")
        if let a = s["ambient"] as? String { on = a != "off" }
        if let e = s["era"] as? String { era = e }
        if let v = (s["volume"] as? String).flatMap(Double.init) { volume = v }
        if let t = (s["lastSnapshot"] as? String).flatMap(Double.init), t > 0 { UserDefaults.standard.set(t / 1000, forKey: "lastSnapshot") }
    }

    /// Each playable file you have, with its song: (file, title, era).
    private static func playableFiles() -> [(url: URL, title: String, era: String)] {
        let library = EngineLibrary.shared, catalog = EngineState.shared.catalog
        guard let root = library.root else { return [] }
        return library.files.compactMap { f in
            guard playable.contains(f.ext), let i = library.match.songsFor[f.path]?.first, catalog.indices.contains(i) else { return nil }
            let url = f.path.split(separator: "/").dropFirst().reduce(root) { $0.appendingPathComponent(String($1)) }
            return (url, catalog[i].name, Engine.eraName(catalog[i]))
        }
    }
    /// The eras you can pick (ones you have playable songs from).
    static var eras: [String] { Array(Set(playableFiles().map(\.era))).sorted() }

    /// Hands the player the songs (one era's, or all when that era has none) and starts or stops it.
    static func sync() {
        let all = playableFiles()
        let picked = era.isEmpty ? [] : all.filter { $0.era == era }
        let items = (picked.isEmpty ? all : picked).map { ($0.url, $0.title) }
        guard !items.isEmpty else { return }
        let player = AmbientPlayer.shared
        player.set(items)
        player.volume = Float(volume / 100)
        on ? player.play() : player.stop()
    }

    static func setOn(_ value: Bool) { on = value; sync() }
    static func setEra(_ name: String) { era = name; on = true; sync() }
}

// MARK: - The weekly library snapshot

@MainActor enum EngineSnapshot {
    static var last: Date? { (UserDefaults.standard.object(forKey: "lastSnapshot") as? Double).map(Date.init(timeIntervalSince1970:)) }

    /// Every file: its path, tags, size and the songs it matched (a CSV kept off the music drive).
    static func csv() -> String {
        let library = EngineLibrary.shared
        return Engine.snapshotCSV(files: library.files, match: library.match, catalog: EngineState.shared.catalog)
    }

    /// Saves one now. Returns what to tell you.
    @discardableResult static func save() async -> String {
        let library = EngineLibrary.shared
        guard !library.files.isEmpty else { return "There's no library to snapshot yet." }
        let text = csv()
        do {
            let url = try await Task.detached { try Snapshots.save(text) }.value
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastSnapshot")
            return "Saved a snapshot of \(library.files.count.formatted()) \(library.files.count == 1 ? "file" : "files") to \(url.deletingLastPathComponent().path)."
        } catch {
            return "Couldn't save the snapshot: \(error.localizedDescription)"
        }
    }

    /// Once a week, a minute after launch settles.
    static func maybeSave() {
        guard Date().timeIntervalSince(last ?? .distantPast) >= 7 * 86400 else { return }
        Task { try? await Task.sleep(nanoseconds: 60_000_000_000); await save() }
    }
}
