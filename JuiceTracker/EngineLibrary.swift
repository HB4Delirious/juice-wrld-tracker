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
        let items = EngineFiles.read("items.json").flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
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

    private func use(_ url: URL) { root = url }

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

    /// Files moved to the Trash: out of the library.
    func removeFiles(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        let gone = Set(paths)
        files.removeAll { gone.contains($0.path) }
        let items = (EngineFiles.read("items.json").flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []).filter { !gone.contains($0) }
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
