import AppKit

// The download queue, the music drive status, the background music and the weekly library snapshot.

@MainActor final class EngineDownloads: ObservableObject {
    static let shared = EngineDownloads()
    struct Item: Codable { var id: String; var tries = 0 }
    struct Job { var done = 0, total = 0, saved = 0; var failed: [String] = []; var current = "", waiting = "" }

    @Published private(set) var job: Job?
    private var queue: [Item] = []
    private var stopping = false
    private var loaded = false

    /// The queue (queue.json). It survives quitting and dropped drives.
    private func load() async {
        guard !loaded else { return }
        loaded = true
        queue = EngineFiles.read("queue.json").flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
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

    /// Bytes free on the music drive, or nil when it can't be told (or there's no music folder). Asks the drive, so
    /// off the main thread where it can be slow (a network drive waking up).
    nonisolated static func freeSpace(_ root: URL?) -> Int64? {
        guard let root,
              let v = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) else { return nil }
        if let important = v.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return v.volumeAvailableCapacity.map(Int64.init)
    }

    /// Settings > Downloads: new songs with a file download on their own when the daily check finds them, as many as
    /// fit while keeping 2 GB free (each song's size from the site's bitrate and length). `free` is asked by the caller
    /// off the main thread: a network drive that's asleep can take minutes to answer. Returns how many were queued.
    @discardableResult func autoDownload(_ ids: [String], free: Int64?) -> Int {
        let engine = EngineState.shared, owned = EngineLibrary.shared.owned
        let wanted = ids.filter { id in engine.catalog.firstIndex { $0.id == id }.map { !owned.contains($0) && !engine.catalog[$0].filePath.isEmpty } ?? false }
        guard !wanted.isEmpty else { return 0 }
        let sizes = wanted.map { id in engine.catalog.first { $0.id == id }.map(Engine.estimatedBytes) ?? 12_000_000 }
        let fits = Array(wanted.prefix(Engine.downloadsThatFit(sizes, free: free)))
        if fits.count < wanted.count { Inbox.add("Not everything fits on the music drive", "\(wanted.count - fits.count) new song\(wanted.count - fits.count == 1 ? "" : "s") weren't downloaded, to keep 2 GB free.") }
        guard !fits.isEmpty else { return 0 }
        let names = fits.compactMap { id in engine.catalog.first { $0.id == id }?.name }
        Inbox.add("Downloading \(fits.count) new song\(fits.count == 1 ? "" : "s")", names.prefix(6).joined(separator: ", ") + (names.count > 6 ? " and \(names.count - 6) more" : ""), ids: fits)
        return add(fits)
    }

    /// The songs on your wishlist that you don't have and that have a file on the site. Returns how many.
    func downloadWishlist() -> Int {
        let engine = EngineState.shared, owned = EngineLibrary.shared.owned, wish = engine.wish
        let wanted = Set(engine.catalog.enumerated().filter { wish[$0.element.id] != nil && !owned.contains($0.offset) && !$0.element.filePath.isEmpty }.map(\.element.id))
        return add(engine.wishRanked.filter { wanted.contains($0) }) // most wanted first
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
            // never fill the drive: stop with 1 GB left, and say so in the notifications
            let root = EngineLibrary.shared.root
            if let free = await Task.detached(operation: { Self.freeSpace(root) }).value, free < 1_000_000_000 {
                Inbox.add("Downloads stopped: the music drive is almost full", "\(queue.count) song\(queue.count == 1 ? "" : "s") still to download. Free up some space, then download them again.")
                stopping = true; break
            }
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

    /// Saves one song into the folder its era's songs live in, adds it to the library and auto-tags it.
    private func downloadSong(_ i: Int) async throws -> (existed: Bool, note: String) {
        let library = EngineLibrary.shared, song = EngineState.shared.catalog[i]
        guard let root = library.root, let url = URL(string: Engine.fileUrl(song)) else { throw EngineError("Choose your music folder first") }
        let rel = "\(Engine.saveFolder(song, library.layout))/\(Engine.saveFileName(song))"
        let inner = rel.split(separator: "/").dropFirst().map(String.init)
        let dest = root.appendingPathComponent(inner.joined(separator: "/"), isDirectory: false).standardizedFileURL
        // never outside the music folder, whatever a song's name says
        guard dest.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw EngineError("can't be saved there") }
        let r = try await Downloader.downloadFile(url, to: dest, root: root.path)
        var note = ""
        let state = EngineState.shared, now = EngineState.isoString(Date())
        var opened = state.personalAny("opened") as? [String: Any] ?? [:]
        opened[song.id] = now
        state.setPersonal("opened", opened)
        if !r.existed {
            var downloaded = state.personalAny("downloaded") as? [String: Any] ?? [:]
            downloaded[song.id] = now
            state.setPersonal("downloaded", downloaded)
            // We know exactly which song this file is, even when its title also matches other versions: a hand match,
            // so it counts once and can be tagged. Then into the library, and auto-tagged.
            EngineLibrary.shared.setOverride(rel, song.id)
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

/// Your matched songs, shuffled, very quietly (or one era's).
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
    /// Era radio: an era's songs in recording order instead of shuffled.
    static var inOrder: Bool {
        get { UserDefaults.standard.bool(forKey: "ambientInOrder") }
        set { UserDefaults.standard.set(newValue, forKey: "ambientInOrder") }
    }
    static var volume: Double {
        get { UserDefaults.standard.object(forKey: "ambientVolume") as? Double ?? 6 }
        set { UserDefaults.standard.set(newValue, forKey: "ambientVolume") }
    }

    /// Each playable file you have, with its song: (file, title, era).
    private static func playableFiles() -> [(url: URL, title: String, era: String, when: Int)] {
        let library = EngineLibrary.shared, catalog = EngineState.shared.catalog
        guard library.root != nil else { return [] }
        return library.files.compactMap { f in
            guard playable.contains(f.ext), let i = library.match.songsFor[f.path]?.first, catalog.indices.contains(i), let url = library.url(of: f.path) else { return nil }
            return (url, catalog[i].name, Engine.eraName(catalog[i]), Engine.recordMonth(catalog[i].recordDates) ?? Int.max)
        }
    }
    /// The eras you can pick (ones you have playable songs from).
    static var eras: [String] { Array(Set(playableFiles().map(\.era))).sorted() }

    /// Hands the player the songs (one era's, or all when that era has none) and starts or stops it.
    static func sync() {
        let all = playableFiles()
        let picked = era.isEmpty ? [] : all.filter { $0.era == era }
        let radio = inOrder && !picked.isEmpty // in order only makes sense within an era
        let list = radio ? picked.sorted { ($0.when, $0.title) < ($1.when, $1.title) } : (picked.isEmpty ? all : picked)
        let items = list.map { ($0.url, $0.title) }
        guard !items.isEmpty else { return }
        let player = AmbientPlayer.shared
        player.set(items, inOrder: radio)
        player.volume = Float(volume / 100)
        on ? player.play() : player.stop()
    }

    /// Your eras a spoken name fits (by short or full name, see `Engine.erasNamed`).
    static func erasNamed(_ spoken: String) -> [String] {
        let info = EngineState.shared.eras
        return Engine.erasNamed(spoken, eras: eras.map { (name: $0, full: info[$0]?.description ?? "") })
    }
    static func setOn(_ value: Bool) { on = value; sync() }
    static func setEra(_ name: String) { era = name; on = true; sync(); AmbientPlayer.shared.skip() } // the new mix starts now
    static func setInOrder(_ value: Bool) { inOrder = value; sync(); if !era.isEmpty { AmbientPlayer.shared.skip() } }
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
