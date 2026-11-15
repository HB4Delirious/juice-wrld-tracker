import AppKit

// The music folder and the library: reopens the folder (from its bookmark), shows the last scan right away from the
// tag cache, lists the folder in the background (a network drive can take minutes), and matches files to songs.
// Downloads, tag writes and the Trash update it as they happen.

@MainActor final class EngineLibrary: ObservableObject {
    static let shared = EngineLibrary()
    static let folderId = "plex-music" // the saved folder and bookmark keep the name they always had

    @Published private(set) var root: URL?
    @Published private(set) var files: [LibraryFile] = []
    @Published private(set) var status = ""      // shown under "Choose your music folder"
    @Published private(set) var scanning = false
    private(set) var match = Engine.Match()
    private(set) var layout = Engine.Layout()     // where a missing song is saved, learned from your folders
    @Published var drive: NState.Drive?           // the music drive status (stage 4c, EngineDownloads.swift)
    var driveBusy = false
    var watcher: FSEventStreamRef?
    var pendingChanges = Set<String>()
    var applyingChanges = false
    private(set) var loaded = false               // a library (cached or scanned) is in place
    private var cache: [String: Engine.CachedTags] = [:]
    private var overrides: [String: String] = [:] { // hand matches (path → song id, or "none"); kept in personal.json
        didSet { if overrides != oldValue { EngineState.shared.setPersonal("matchOverrides", overrides) } }
    }
    var overrideCount: Int { overrides.count }
    private var started = false

    var onlyJuice: Bool {
        (EngineFiles.read("settings.json").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["onlyJuice"] as? Bool ?? true
    }
    var owned: Set<Int> { Set(match.owned.keys) }

    // MARK: Starting up

    /// After the catalog is in place: reopen the folder, show the last scan, then list the folder in the background.
    func start() async {
        guard !started else { return }
        started = true
        cache = EngineFiles.tagCache()
        overrides = (EngineState.shared.personalAny("matchOverrides") as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        guard let url = await Self.restoreFolder() else { return }
        use(url)
        let items = readItems()
        if !items.isEmpty {
            files = items.compactMap { libraryFile($0, cache[$0]) }.sorted { $0.path.localizedCompare($1.path) == .orderedAscending }
            loaded = true
            rematch()
            status = "\(files.count.formatted()) Juice WRLD files from your last scan. Checking the folder for changes…"
        }
        await checkDrive()
        watchDrive()
        await scan(reread: false)
        await EngineDownloads.shared.start() // carries on with what was queued
        EngineSnapshot.maybeSave()
    }

    // MARK: The folder

    /// The folder picked before, through its bookmark: that reconnects a network share that dropped and finds it
    /// when it comes back under another name. Off the main thread, since a sleeping drive can take a while.
    static func restoreFolder() async -> URL? {
        let defaults = UserDefaults.standard, pathKey = "lastFolder.\(folderId)", markKey = "lastFolderBookmark.\(folderId)"
        guard let saved = defaults.string(forKey: pathKey) else { return nil }
        let mark = defaults.data(forKey: markKey)
        let path = await Task.detached { () -> String in
            guard let mark else { return saved }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: mark, options: .withoutUI, bookmarkDataIsStale: &stale) else { return saved }
            if stale, let fresh = try? url.bookmarkData() { defaults.set(fresh, forKey: markKey) }
            return url.standardizedFileURL.path
        }.value
        if path != saved { defaults.set(path, forKey: pathKey) }
        return URL(fileURLWithPath: path)
    }

    /// Choose the music folder in an open panel, then scan it.
    func pick() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that holds your music."
        if let last = UserDefaults.standard.string(forKey: "lastFolder.\(Self.folderId)") { panel.directoryURL = URL(fileURLWithPath: last).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL else { return }
        UserDefaults.standard.set(url.path, forKey: "lastFolder.\(Self.folderId)")
        UserDefaults.standard.set(try? url.bookmarkData(), forKey: "lastFolderBookmark.\(Self.folderId)")
        if url != root { files = []; loaded = false }
        use(url)
        await scan(reread: false)
    }

    /// Rescan: lists the folder and re-reads every file's tags (catches files changed by other programs).
    func rescan() async { await scan(reread: true) }

    /// The drive came back (maybe under a new name): reopen the folder and look again.
    func reconnect() async {
        guard let url = await Self.restoreFolder() else { return }
        if url != root { use(url) }
        await scan(reread: false)
        await checkDrive()
    }

    private func use(_ url: URL) { root = url; watch(url); watchInbox() }

    private func scan(reread: Bool) async {
        guard let root, !scanning else { return }
        scanning = true
        defer { scanning = false }
        if files.isEmpty { status = "Reading your music folder…" }
        let started = Date()
        // Off the main thread: listing a network drive can take minutes.
        let result = await Task.detached { [cache, onlyJuice] in
            await Engine.scan(root: root, onlyJuice: onlyJuice, cache: cache, reread: reread) { done, total in
                Task { @MainActor in if EngineLibrary.shared.files.isEmpty || done % 200 == 0 { EngineLibrary.shared.status = "Reading song info: \(done.formatted()) of \(total.formatted())…" } }
            }
        }.value
        guard root == self.root else { return } // another folder was picked meanwhile
        if result.audioCount == 0 && !FileManager.default.fileExists(atPath: root.path) {
            status = files.isEmpty ? "Your music folder isn't available. Connect the drive, then Rescan." : "Your music folder isn't answering, so this is your last scan."
            return
        }
        for (path, t) in result.fresh { cache[path] = t }
        saveCache()
        saveItems(result.paths)
        files = result.files
        loaded = true
        rematch()
        let took = Date().timeIntervalSince(started)
        let text: String
        if result.audioCount == 0 { text = "No audio files found in that folder. Choose the folder that holds your music." }
        else if files.isEmpty { text = "Found \(result.audioCount.formatted()) audio files, but none look like Juice WRLD." }
        else { text = "\(files.count.formatted()) Juice WRLD files found\(onlyJuice ? " out of \(result.audioCount.formatted()) audio files" : "")." }
        status = text
        NSLog("Juice Tracker: scanned \(result.audioCount) files in \(String(format: "%.1f", took)) s")
    }

    // MARK: Matching

    func rematch() {
        match = Engine.match(catalog: EngineState.shared.catalog, files: files, overrides: overrides)
        layout = Engine.layout(catalog: EngineState.shared.catalog, files: files, match: match)
        NativeStore.shared.rebuild()
        EngineAmbient.sync()
    }

    // MARK: Changes made here (stage 4d)

    /// A file of this song the player can play, if you have one.
    func playableURL(_ i: Int) -> URL? {
        (match.owned[i] ?? []).first { EngineAmbient.playable.contains(Engine.extOf($0)) }.flatMap { url(of: $0) }
    }

    /// Where a library file is on disk.
    func url(of path: String) -> URL? {
        guard let root else { return nil }
        let url = path.split(separator: "/").dropFirst().reduce(root) { $0.appendingPathComponent(String($1)) }.standardizedFileURL
        return url.path.hasPrefix(root.standardizedFileURL.path + "/") ? url : nil
    }

    /// A file whose tags were just written (or that was just downloaded).
    func updateFile(_ path: String, tags: Tags, size: Int) {
        let c = Engine.CachedTags(size: size, mtime: Date().timeIntervalSince1970 * 1000, tags: tags)
        cache[path] = c
        saveCache()
        if !files.contains(where: { $0.path == path }) { // a new file (the folder watcher): keep it after a relaunch
            var items = readItems()
            if !items.contains(path) { items.append(path); saveItems(items) }
        }
        if let f = libraryFile(path, c) {
            if let n = files.firstIndex(where: { $0.path == path }) { files[n] = f } else {
                files.append(f); files.sort { $0.path.localizedCompare($1.path) == .orderedAscending }
            }
        }
        rematch()
    }

    /// Files moved to the Trash: out of the library.
    func removeFiles(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        let gone = Set(paths)
        files.removeAll { gone.contains($0.path) }
        let items = readItems().filter { !gone.contains($0) }
        saveItems(items)
        rematch()
    }

    /// A hand match ("none" for none of these), or nil to go back to automatic matching.
    func setOverride(_ path: String, _ id: String?) {
        overrides[path] = id
        rematch()
    }
    /// A backup's hand matches, for files that don't have one yet.
    func mergeOverrides(_ add: [String: String]) {
        for (path, id) in add where overrides[path] == nil { overrides[path] = id }
        rematch()
    }
    func clearOverrides() {
        overrides = [:]
        rematch()
    }

    // MARK: Helpers

    /// A library entry from cached tags, or nil when it isn't a Juice WRLD file (and only those count).
    private func libraryFile(_ path: String, _ c: Engine.CachedTags?) -> LibraryFile? {
        let tags = c?.tags ?? [:]
        guard !onlyJuice || Engine.countsAsJuice(path: path, tags: tags) else { return nil }
        let title = (tags["title"] ?? "").isEmpty ? Engine.titleFromFilename(path) : tags["title"]!
        return LibraryFile(path: path, ext: Engine.extOf(path), tags: tags, title: title, key: Engine.normalize(title), stem: Engine.stemOf(path),
                           fromTags: !(tags["title"] ?? "").isEmpty, size: c?.size ?? 0)
    }
    private static func cached(_ v: [String: Any]) -> Engine.CachedTags {
        Engine.CachedTags(size: (v["size"] as? NSNumber)?.intValue ?? 0, mtime: (v["mtime"] as? NSNumber)?.doubleValue ?? 0,
                          tags: (v["tags"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String })
    }
    private func saveCache() { if let data = try? JSONEncoder().encode(cache) { try? EngineFiles.write("tags.json", data) } }
    private func readItems() -> [String] { EngineFiles.read("items.json").flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [] }
    private func saveItems(_ items: [String]) { if let data = try? JSONEncoder().encode(items) { try? EngineFiles.write("items.json", data) } }
}

// MARK: - Watching the folder, and comparing with another drive

extension EngineLibrary {
    /// Notices files added, changed or removed in the music folder (by Finder or other apps on this Mac) and updates
    /// the library a moment later, without a rescan. Changes made on a network drive by another computer aren't
    /// reported by macOS; Rescan catches those.
    func watch(_ url: URL) {
        if let stream = watcher { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); watcher = nil }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let library = Unmanaged<EngineLibrary>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []).prefix(count)
            Task { @MainActor in library.noticed(Array(list)) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
        watcher = stream
    }

    private func noticed(_ paths: [String]) {
        guard let root else { return }
        let base = root.standardizedFileURL.path
        for p in paths where Engine.audioExts.contains(Engine.extOf(p)) && p.hasPrefix(base + "/") {
            let rel = root.lastPathComponent + "/" + String(p.dropFirst(base.count + 1))
            guard !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue } // hidden files, like a scan
            pendingChanges.insert(rel)
        }
        guard !pendingChanges.isEmpty, !applyingChanges else { return }
        applyingChanges = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000) // a copy in progress settles first
            await applyChanges()
        }
    }

    private func applyChanges() async {
        defer { applyingChanges = false }
        let rels = pendingChanges
        pendingChanges = []
        var gone: [String] = []
        for rel in rels {
            guard let url = url(of: rel) else { continue }
            let found = await Task.detached { () -> (Tags, Int)? in
                guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
                return (TagReader.read(url, ext: Engine.extOf(rel)), size)
            }.value
            if let (tags, size) = found { updateFile(rel, tags: tags, size: size) } else { gone.append(rel) }
        }
        await removeFiles(gone.filter { g in files.contains { $0.path == g } })
        if !pendingChanges.isEmpty { applyingChanges = true; await applyChanges() }
    }

    struct Comparison { var drive: String; var onlyHere: [Int]; var onlyThere: [Int]; var both: Int }

    /// Scans another folder (a backup drive, say) and compares songs: which you have only here, only there, or on
    /// both. Reads only; nothing on either drive changes.
    func compare(with other: URL, progress: @escaping (Int, Int) -> Void) async -> Comparison {
        let catalog = EngineState.shared.catalog
        let scan = await Task.detached { [onlyJuice] in
            await Engine.scan(root: other, onlyJuice: onlyJuice, cache: [:], reread: true) { d, t in Task { @MainActor in progress(d, t) } }
        }.value
        let there = Set(Engine.match(catalog: catalog, files: scan.files, overrides: [:]).owned.keys), here = owned
        return Comparison(drive: other.lastPathComponent, onlyHere: here.subtracting(there).sorted(), onlyThere: there.subtracting(here).sorted(),
                          both: here.intersection(there).count)
    }
}

// MARK: - Moving files: the organizer (with undo) and the inbox folder

extension EngineLibrary {
    /// Moves files inside the music folder. Never overwrites: a move whose place is taken on disk is skipped. Tag
    /// cache, hand matches and the file list follow each file. Returns the moves made and what was skipped.
    func move(_ moves: [(from: String, to: String)]) async -> (done: [(from: String, to: String)], failed: [String]) {
        var done: [(from: String, to: String)] = [], failed: [String] = []
        for m in moves {
            guard let src = url(of: m.from), let dst = url(of: m.to) else { failed.append("\(Engine.baseName(m.from)): outside the music folder"); continue }
            guard !onlyJuice || Engine.countsAsJuice(path: m.to, tags: cache[m.from]?.tags ?? [:]) else {
                failed.append("\(Engine.baseName(m.from)): it would no longer count as a Juice WRLD file there"); continue
            }
            let error = await Task.detached { () -> String? in
                let fm = FileManager.default
                guard fm.fileExists(atPath: src.path) else { return "isn't there any more" }
                guard !fm.fileExists(atPath: dst.path) else { return "a file is already at \(dst.lastPathComponent)" }
                do {
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: src, to: dst)
                    _ = rmdir(src.deletingLastPathComponent().path) // the folder it left, only if that's now empty
                    return nil
                } catch { return error.localizedDescription }
            }.value
            if let error { failed.append("\(Engine.baseName(m.from)): \(error)"); continue }
            done.append(m)
            cache[m.to] = cache.removeValue(forKey: m.from)
            if let o = overrides.removeValue(forKey: m.from) { overrides[m.to] = o }
            if let n = files.firstIndex(where: { $0.path == m.from }), let f = libraryFile(m.to, cache[m.to]) { files[n] = f }
        }
        guard !done.isEmpty else { return (done, failed) }
        files.sort { $0.path.localizedCompare($1.path) == .orderedAscending }
        let renamed = Dictionary(done.map { ($0.from, $0.to) }, uniquingKeysWith: { a, _ in a })
        let items = readItems().map { renamed[$0] ?? $0 }
        saveItems(items)
        saveCache()
        rematch()
        Plex.scheduleRefresh()
        return (done, failed)
    }

    /// The organizer's last run, kept so it can be undone (even after a relaunch).
    var lastOrganize: [(from: String, to: String)] {
        (EngineFiles.read("lastOrganize.json").flatMap { try? JSONDecoder().decode([[String]].self, from: $0) } ?? [])
            .compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    }
    func organize(_ plan: [(from: String, to: String)]) async -> String {
        let r = await move(plan)
        try? EngineFiles.write("lastOrganize.json", JSONEncoder().encode(r.done.map { [$0.from, $0.to] }))
        return "Moved \(EngineTools.plural(r.done.count, "file", "files")).\(r.failed.isEmpty ? "" : " Left \(r.failed.count) where they were: \(r.failed.prefix(3).joined(separator: "; ")).")"
    }
    func undoOrganize() async -> String {
        let r = await move(lastOrganize.reversed().map { ($0.to, $0.from) })
        try? EngineFiles.write("lastOrganize.json", Data("[]".utf8))
        return "Put \(EngineTools.plural(r.done.count, "file", "files")) back.\(r.failed.isEmpty ? "" : " Couldn't move \(r.failed.count): \(r.failed.prefix(3).joined(separator: "; ")).")"
    }

    // MARK: Inbox

    /// A folder outside the library: audio files dropped there are matched, moved into the folder the tracker picks
    /// for their era, and tagged with the catalog's details. Files it can't place stay in the inbox.
    static var inbox: URL? {
        get { UserDefaults.standard.string(forKey: "inboxFolder").map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: "inboxFolder") }
    }
    static var inboxNote = ""
    private static var inboxStream: FSEventStreamRef?
    private static var sorting = false, sortAgain = false // one run at a time; changes during a run start another
    private static var untaggable: Set<String> = []        // "name|size" put back once already; not tried again this launch

    func watchInbox() {
        if let s = Self.inboxStream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); Self.inboxStream = nil }
        guard let inbox = Self.inbox else { return }
        let callback: FSEventStreamCallback = { _, _, _, _, _, _ in
            Task { @MainActor in await EngineLibrary.shared.sortInbox() }
        }
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        guard let s = FSEventStreamCreate(nil, callback, &context, [inbox.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 3,
                                          UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
        Self.inboxStream = s
        Task { await sortInbox() } // what's there already
    }

    func sortInbox() async {
        guard let inbox = Self.inbox, root != nil, !EngineState.shared.catalog.isEmpty else { return }
        if Self.sorting { Self.sortAgain = true; return }
        Self.sorting = true
        defer {
            Self.sorting = false
            if Self.sortAgain { Self.sortAgain = false; Task { await sortInbox() } }
        }
        // Only files that have finished arriving: a copy from a USB stick or the network can take minutes, and moving a
        // half-copied file would put a cut-off song in the library.
        let (found, waiting) = await Task.detached { () -> ([(URL, Tags, Int)], Bool) in
            func look() -> [URL: (Int, Date)] {
                let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
                let urls = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
                var out: [URL: (Int, Date)] = [:]
                for u in urls where Engine.audioExts.contains(Engine.extOf(u.path)) {
                    let v = try? u.resourceValues(forKeys: Set(keys))
                    out[u] = (v?.fileSize ?? 0, v?.contentModificationDate ?? Date())
                }
                return out
            }
            let before = look()
            guard !before.isEmpty else { return ([], false) }
            Thread.sleep(forTimeInterval: 3)
            let now = look(), date = Date()
            let ready = now.filter { u, v in Engine.settled(sizeBefore: before[u]?.0 ?? -1, sizeNow: v.0, modified: v.1, now: date) }
            // Look again only for files still arriving; an empty file (a failed download, say) just stays in the inbox.
            let arriving = now.contains { u, v in ready[u] == nil && v.0 > 0 }
            return (ready.map { ($0.key, TagReader.read($0.key, ext: Engine.extOf($0.key.path)), $0.value.0) }, arriving)
        }.value
        if waiting { // look again once the rest has had time to finish
            Task { try? await Task.sleep(nanoseconds: 8_000_000_000); await sortInbox() }
        }
        guard !found.isEmpty else { return }
        let catalog = EngineState.shared.catalog
        var moved = 0, left: [String] = [], putBack: [String] = []
        for (u, tags, size) in found {
            let name = u.lastPathComponent, tmp = "inbox/\(name)"
            if Self.untaggable.contains("\(name)|\(size)") { putBack.append(name); continue }
            let title = (tags["title"] ?? "").isEmpty ? Engine.titleFromFilename(tmp) : tags["title"]!
            let lf = LibraryFile(path: tmp, ext: Engine.extOf(name), tags: tags, title: title, key: Engine.normalize(title), stem: Engine.stemOf(tmp),
                                 fromTags: !(tags["title"] ?? "").isEmpty, size: size)
            let m = Engine.match(catalog: catalog, files: [lf], overrides: [:])
            // Several versions can match one title; primarySong settles which one it is, or leaves it in the inbox.
            guard let songs = m.songsFor[tmp], m.how[tmp] != "close", let primary = Engine.primarySong(songs, catalog: catalog) else { left.append(name); continue }
            let rel = "\(Engine.saveFolder(catalog[primary], layout))/\(name)"
            // It must still count as a Juice WRLD file there: by its path or tags, or by the tags written below.
            guard let dst = url(of: rel), Engine.countsAsJuice(path: rel, tags: tags) || Engine.editableExts.contains(Engine.extOf(name)) else { left.append(name); continue }
            let ok = await Task.detached { () -> Bool in
                let fm = FileManager.default
                guard !fm.fileExists(atPath: dst.path) else { return false }
                do { try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true); try fm.moveItem(at: u, to: dst); return true }
                catch { return false }
            }.value
            guard ok else { left.append(name); continue }
            updateFile(rel, tags: tags, size: size)
            // The versions primarySong chose between share one name, so its tags are right for the title either way.
            _ = await EngineFixer.shared.autoTag(rel, song: primary, inbox: tags)
            // If its tags couldn't be written (an old ID3 version, say, or "only fill blank tags" kept another artist),
            // the library wouldn't list it there: back to the inbox, where you can see it.
            if onlyJuice, !Engine.countsAsJuice(path: rel, tags: cache[rel]?.tags ?? tags) {
                Self.untaggable.insert("\(name)|\(size)")
                let back = await Task.detached { () -> Bool in
                    guard !FileManager.default.fileExists(atPath: u.path) else { return false }
                    do { try FileManager.default.moveItem(at: dst, to: u); return true } catch { return false }
                }.value
                if back {
                    cache[rel] = nil; saveCache()
                    await removeFiles([rel])
                    putBack.append(name)
                    continue
                }
            }
            moved += 1
        }
        Self.inboxNote = "Inbox: moved \(EngineTools.plural(moved, "song", "songs")) into your library\(left.isEmpty ? "" : "; \(left.count) left in the inbox (not recognized, or already in the library)")"
            + (putBack.isEmpty ? "." : "; \(putBack.count) left because their tags can't be set to Juice WRLD (\(putBack.prefix(3).joined(separator: ", "))). Tag them as Juice WRLD, or put them in the music folder yourself.")
        if moved > 0 { Plex.scheduleRefresh() }
        NativeStore.shared.rebuild()
    }
}
