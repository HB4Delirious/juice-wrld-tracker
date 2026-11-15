import AppKit

// Stage 4b of replacing the HTML engine: Swift owns the music folder and the library. It reopens the folder, shows the
// last scan right away from its tag cache, lists the folder in the background (a network drive can take minutes),
// matches files to songs, and hands the page the library (it still downloads, writes tags and checks files until
// 4c and 4d). The page tells Swift about every file it adds, retags or trashes, and about hand matches.

@MainActor final class EngineLibrary: ObservableObject {
    static let shared = EngineLibrary()
    static let folderId = "plex-music" // the page's picker id: the same saved folder and bookmark as before

    @Published private(set) var root: URL?
    @Published private(set) var files: [LibraryFile] = []
    @Published private(set) var status = ""      // shown under "Choose your music folder"
    @Published private(set) var scanning = false
    private(set) var match = Engine.Match()
    private(set) var layout = Engine.Layout()     // where a missing song is saved, learned from your folders
    @Published var drive: NState.Drive?           // the music drive status (stage 4c, EngineDownloads.swift)
    var driveBusy = false
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
        await EngineAmbient.migrate() // the page's player settings, before the first sync
        cache = EngineFiles.tagCache()
        if cache.isEmpty || EngineFiles.read("items.json") == nil { await migrateFromPage() }
        overrides = await pageOverrides() ?? overrides
        guard let url = await Self.restoreFolder() else { return }
        use(url)
        let items = EngineFiles.read("items.json").flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        if !items.isEmpty {
            files = items.compactMap { libraryFile($0, cache[$0]) }.sorted { $0.path.localizedCompare($1.path) == .orderedAscending }
            loaded = true
            rematch()
            await pushToPage(status: "\(files.count.formatted()) Juice WRLD files from your last scan. Checking the folder for changes…")
        }
        await checkDrive()
        watchDrive()
        await scan(reread: false)
        await EngineDownloads.shared.start() // carries on with what was queued
        EngineSnapshot.maybeSave()
    }

    /// The first launch with a Swift library: the page's tag cache and file list, so nothing is read twice.
    private func migrateFromPage() async {
        if cache.isEmpty, let json = try? await NativeStore.shared.tryAct("engineTagCache"),
           let raw = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: Any]] {
            for (path, v) in raw { cache[path] = Self.cached(v) }
            saveCache()
        }
        if let json = try? await NativeStore.shared.tryAct("engineItems"), let items = try? JSONDecoder().decode([String].self, from: Data(json.utf8)), !items.isEmpty {
            saveItems(items)
        }
    }

    private func pageOverrides() async -> [String: String]? {
        guard let json = try? await NativeStore.shared.tryAct("engineExport"),
              let ex = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        return ((ex["personal"] as? [String: Any])?["matchOverrides"] as? [String: Any])?.compactMapValues { $0 as? String }
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

    private func use(_ url: URL) {
        root = url
        WebViewStore.shared.allowFolder(url.path) // the page may read and write in it (downloads, tags, Trash)
    }

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
        await pushToPage(status: text)
        NSLog("Juice Tracker: scanned \(result.audioCount) files in \(String(format: "%.1f", took)) s")
    }

    // MARK: Matching and the page

    func rematch() {
        match = Engine.match(catalog: EngineState.shared.catalog, files: files, overrides: overrides)
        layout = Engine.layout(catalog: EngineState.shared.catalog, files: files, match: match)
        NativeStore.shared.rebuild()
        EngineAmbient.sync()
    }

    /// Gives the page the library (paths, tags and where each file is), so its tag fixer, duplicates, file health,
    /// downloads and music keep working. It matches the same way, so it agrees on what you own.
    func pushToPage(status text: String) async {
        status = text
        guard let root else { return }
        let base = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
        let list: [[String: Any]] = files.map { f in
            ["path": f.path, "abs": base + "/" + f.path.split(separator: "/", maxSplits: 1).dropFirst().joined(), "ext": f.ext, "tags": f.tags,
             "title": f.title, "key": f.key, "stem": f.stem, "fromTags": f.fromTags, "size": f.size]
        }
        let json = (try? JSONSerialization.data(withJSONObject: list)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        await NativeStore.shared.act("useLibrary", -1, ["root": base, "rootName": root.lastPathComponent, "files": json, "status": text])
    }

    /// What the page changed: tags it read or wrote ("put", path → size, date, tags), the files it still has after
    /// moving some to the Trash ("items"), and hand matches ("overrides").
    func pageChanged(_ change: [String: Any]) {
        var changed = false
        if let put = change["put"] as? [String: [String: Any]] {
            for (path, v) in put {
                let c = Self.cached(v)
                // A report older than what's here (the page scanned a download before Swift tagged it) is stale.
                if let have = cache[path], have.mtime > c.mtime { continue }
                cache[path] = c
                if let f = libraryFile(path, c) {
                    if let n = files.firstIndex(where: { $0.path == path }) { files[n] = f } else { files.append(f) }
                } else { files.removeAll { $0.path == path } } // not a Juice WRLD file
                changed = true
            }
            saveCache()
        }
        if let items = change["items"] as? [String] {
            let keep = Set(items)
            let before = files.count
            files.removeAll { !keep.contains($0.path) }
            changed = changed || files.count != before
            saveItems(items)
        }
        if let o = (change["overrides"] as? [String: Any])?.compactMapValues({ $0 as? String }), o != overrides {
            overrides = o
            changed = true
        }
        if changed {
            files.sort { $0.path.localizedCompare($1.path) == .orderedAscending }
            rematch()
        }
    }

    // MARK: Changes made here (stage 4d)

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
        if let f = libraryFile(path, c) {
            if let n = files.firstIndex(where: { $0.path == path }) { files[n] = f } else {
                files.append(f); files.sort { $0.path.localizedCompare($1.path) == .orderedAscending }
            }
        }
        rematch()
    }

    /// Files moved to the Trash: out of the library, here and in the page.
    func removeFiles(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        let gone = Set(paths)
        files.removeAll { gone.contains($0.path) }
        let items = (EngineFiles.read("items.json").flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []).filter { !gone.contains($0) }
        saveItems(items)
        rematch()
        await pushToPage(status: status)
    }

    /// A hand match ("none" for none of these), or nil to go back to automatic matching.
    func setOverride(_ path: String, _ id: String?) {
        overrides[path] = id
        rematch()
        Task { await pushToPage(status: status) }
    }
    func clearOverrides() {
        overrides = [:]
        rematch()
        Task { await pushToPage(status: status) }
    }

    // MARK: Helpers

    /// A library entry from cached tags, or nil when it isn't a Juice WRLD file (and only those count).
    private func libraryFile(_ path: String, _ c: Engine.CachedTags?) -> LibraryFile? {
        let tags = c?.tags ?? [:]
        guard !onlyJuice || Engine.hasArtist(path) || Engine.hasArtist("\(tags["artist"] ?? "") \(tags["albumartist"] ?? "")") else { return nil }
        let title = (tags["title"] ?? "").isEmpty ? Engine.titleFromFilename(path) : tags["title"]!
        return LibraryFile(path: path, ext: Engine.extOf(path), tags: tags, title: title, key: Engine.normalize(title), stem: Engine.stemOf(path),
                           fromTags: !(tags["title"] ?? "").isEmpty, size: c?.size ?? 0)
    }
    private static func cached(_ v: [String: Any]) -> Engine.CachedTags {
        Engine.CachedTags(size: (v["size"] as? NSNumber)?.intValue ?? 0, mtime: (v["mtime"] as? NSNumber)?.doubleValue ?? 0,
                          tags: (v["tags"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String })
    }
    private func saveCache() { if let data = try? JSONEncoder().encode(cache) { try? EngineFiles.write("tags.json", data) } }
    private func saveItems(_ items: [String]) { if let data = try? JSONEncoder().encode(items) { try? EngineFiles.write("items.json", data) } }
}
