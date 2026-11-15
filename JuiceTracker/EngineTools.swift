import AppKit
import AVFoundation

// The tag fixer (with auto-tagging after downloads), duplicate cleanup and the file health check. Files are only ever
// rewritten after TagWriter's safety check passes, backed up first when a backup folder is set, and removed only by
// moving them to the Trash.

@MainActor enum EngineTools {
    static let ops: Set<String> = ["fixer", "fixSet", "fixGenre", "fixSel", "fixAll", "fixNone", "fixMatch", "fixUndoMatches", "fixBackup", "fixWrite",
                                   "dups", "trashDups", "health", "healthRun", "healthStop", "healthFix"]

    /// A screen's request, answered in Swift (nil: not one of these).
    static func handle(_ op: String, _ a: [String: Any]) async throws -> String? {
        guard ops.contains(op) else { return nil }
        switch op {
        case "dups": return EngineDups.json()
        case "trashDups": return try await EngineDups.trash(path: a["path"] as? String)
        case "health": return EngineHealth.shared.json()
        case "healthRun": EngineHealth.shared.run(); return ""
        case "healthStop": EngineHealth.shared.stopping = true; return ""
        case "healthFix": return try await EngineHealth.shared.fix(a["fix"] as? String ?? "", path: a["path"] as? String ?? "")
        default: return try await EngineFixer.shared.handle(op, a)
        }
    }

    static func json(_ v: Any) -> String { (try? JSONSerialization.data(withJSONObject: v)).map { String(decoding: $0, as: UTF8.self) } ?? "{}" }
    static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n.formatted()) \(n == 1 ? one : many)" }

    /// Moves a file in the music folder to the Trash (never a permanent delete; a drive with no Trash says so).
    static func trash(_ path: String) async throws {
        guard let url = EngineLibrary.shared.url(of: path) else { throw EngineError("That file isn't in your music folder") }
        try await Task.detached { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }.value
    }
}

// MARK: - The tag fixer

@MainActor final class EngineFixer {
    static let shared = EngineFixer()
    static let fieldLabels: [(String, String)] = [("title", "Title"), ("artist", "Artist, with features"), ("albumartist", "Album artist"), ("album", "Album, set to the era"),
                                                  ("year", "Year"), ("producer", "Producers"), ("genre", "Genre"), ("comment", "Comment, with category and recording date")]

    private var selection: [String: Bool] = [:]   // ticks you changed; by default a file is ticked unless it matched by a close title
    private var backupDir: URL?
    private var backupStatus = ""
    private(set) var writing = false
    private var status = ""

    var fields: [String] {
        get { UserDefaults.standard.stringArray(forKey: "fixFields") ?? ["title", "artist", "albumartist", "album", "year", "producer"] }
        set { UserDefaults.standard.set(Self.fieldLabels.map(\.0).filter(newValue.contains), forKey: "fixFields") }
    }
    var onlyBlanks: Bool {
        get { UserDefaults.standard.bool(forKey: "fixBlanks") }
        set { UserDefaults.standard.set(newValue, forKey: "fixBlanks") }
    }
    var genre: String {
        let g = EngineState.shared.personalString("fixGenre").trimmingCharacters(in: .whitespacesAndNewlines)
        return g.isEmpty ? Engine.defaultGenre : g
    }
    var autoTag: Bool { EngineState.shared.personalBool("autoTag", default: true) }

    private func plan() -> (changes: [Engine.FixItem], skipped: [(path: String, reason: String)], same: Int) {
        let library = EngineLibrary.shared
        return Engine.buildPlan(files: library.files, match: library.match, catalog: EngineState.shared.catalog, fields: fields, onlyBlanks: onlyBlanks, genre: genre)
    }
    private func isSelected(_ path: String) -> Bool { selection[path] ?? (EngineLibrary.shared.match.how[path] != "close") }

    func handle(_ op: String, _ a: [String: Any]) async throws -> String {
        let library = EngineLibrary.shared, state = EngineState.shared
        switch op {
        case "fixer": return json()
        case "fixSet":
            let key = a["key"] as? String ?? "", on = a["on"] as? Bool ?? false
            if key == "blanks" { onlyBlanks = on }
            else if key == "autoTag" { state.setPersonal("autoTag", on) }
            else if key.hasPrefix("field:") { let f = String(key.dropFirst(6)); fields = on ? fields + [f] : fields.filter { $0 != f } }
        case "fixGenre": state.setPersonal("fixGenre", (a["value"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        case "fixSel": selection[a["path"] as? String ?? ""] = a["on"] as? Bool ?? false
        case "fixAll", "fixNone": for it in plan().changes { selection[it.path] = op == "fixAll" }
        case "fixMatch":
            let path = a["path"] as? String ?? ""
            var value = a["value"] as? String ?? ""
            if value == "confirm" {
                guard let it = plan().changes.first(where: { $0.path == path }) else { return "" }
                value = state.catalog[it.song].id
            }
            if !value.isEmpty && value != "none" { selection[path] = true }
            library.setOverride(path, value.isEmpty ? nil : value)
        case "fixUndoMatches": library.clearOverrides()
        case "fixBackup": pickBackup()
        case "fixWrite": Task { await writeSelected() }
        default: break
        }
        return ""
    }

    /// The fixer's screen.
    private func json() -> String {
        let library = EngineLibrary.shared, catalog = EngineState.shared.catalog, p = plan()
        let on = Set(fields)
        let choose = library.files.filter { (library.match.songsFor[$0.path]?.count ?? 0) > 1 }.prefix(200).map { f -> [String: Any] in
            ["path": f.path, "file": Engine.baseName(f.path), "folder": Engine.parentOf(f.path),
             "options": library.match.songsFor[f.path]!.map { i -> [String: Any] in
                let s = catalog[i]; return ["id": s.id, "label": "\(s.name) (\(Engine.eraName(s)), \(Engine.capital(s.category)))"] }]
        }
        let labels = Dictionary(uniqueKeysWithValues: Self.fieldLabels.map { ($0.0, $0.1) })
        return EngineTools.json([
            "support": library.root == nil ? "To edit tags, choose your music folder first." : "",
            "fields": Self.fieldLabels.map { ["key": $0.0, "label": $0.1, "on": on.contains($0.0)] },
            "blanks": onlyBlanks, "autoTag": autoTag, "autoTagShown": library.root != nil,
            "genre": EngineState.shared.personalString("fixGenre"), "genrePlaceholder": Engine.defaultGenre,
            "backup": backupStatus, "backupSet": backupDir != nil, "canPickBackup": true,
            "writing": writing, "status": status, "same": p.same, "total": p.changes.count, "selected": p.changes.filter { isSelected($0.path) }.count,
            "changes": p.changes.prefix(400).map { it -> [String: Any] in
                let how = library.match.how[it.path] ?? ""
                return ["path": it.path, "file": Engine.baseName(it.path), "song": catalog[it.song].name, "fuzzy": how == "close", "selected": isSelected(it.path),
                        "how": how == "file" ? "matched by file name" : how == "manual" ? "matched by you" : "",
                        "changes": it.changes.map { ["label": labels[$0.key] ?? $0.key, "from": $0.from, "to": $0.to] }]
            },
            "skipped": p.skipped.prefix(200).map { ["file": Engine.baseName($0.path), "reason": $0.reason] },
            "choose": Array(choose), "manual": library.overrideCount,
        ])
    }

    /// A folder outside the music folder, where each original is copied once before its first edit.
    private func pickBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Use for backups"
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL else { return }
        if let root = EngineLibrary.shared.root?.standardizedFileURL, url.path == root.path || url.path.hasPrefix(root.path + "/") {
            backupStatus = "That folder is inside your music folder, so Plex would pick up the backups as duplicates. Choose a folder somewhere else."
            return
        }
        backupDir = url
        backupStatus = "Backups go to “\(url.lastPathComponent)”. Each original file is copied there once, before its first edit."
    }

    /// Writes the ticked changes (the screen asked you first).
    private func writeSelected() async {
        guard !writing else { return }
        let items = plan().changes.filter { isSelected($0.path) }
        guard !items.isEmpty, EngineLibrary.shared.root != nil else { return }
        writing = true
        var ok = 0, failed: [String] = []
        for (n, it) in items.enumerated() {
            status = "Writing \((n + 1).formatted()) of \(items.count.formatted()): \(Engine.baseName(it.path))"
            do { try await write(it.path, it.desired); selection[it.path] = nil; ok += 1 }
            catch {
                let m = error.localizedDescription
                failed.append("\(Engine.baseName(it.path)) \(m.range(of: #"^(has|uses|isn't|is |would|failed)"#, options: .regularExpression) != nil ? m : "couldn't be saved (\(m))")")
            }
        }
        status = "Updated \(EngineTools.plural(ok, "file", "files")).\(failed.isEmpty ? "" : " \(EngineTools.plural(failed.count, "file", "files")) were left unchanged: \(failed.prefix(5).joined(separator: "; "))\(failed.count > 5 ? "; and more" : "").") In Plex, refresh the library's metadata to see the new tags."
        writing = false // after the message, so the screen's last refresh shows it
        if ok > 0 { Plex.scheduleRefresh() }
    }

    /// Rewrites one file's tags: build the new file in memory, run the safety check, back up the original, save,
    /// read the tags back.
    func write(_ path: String, _ desired: Tags) async throws {
        guard let url = EngineLibrary.shared.url(of: path) else { throw EngineError("isn't in your music folder") }
        let backup = backupDir.map { dir in path.split(separator: "/").dropFirst().reduce(dir) { $0.appendingPathComponent(String($1)) } }
        let ext = Engine.extOf(path)
        let (tags, size) = try await Task.detached { () -> (Tags, Int) in
            let orig = [UInt8](try Data(contentsOf: url))
            let out = try TagWriter.write(orig, ext: ext, tags: desired)
            if let backup { try Self.backUp(Data(orig), to: backup) }
            try Data(out).write(to: url, options: .atomic)
            return (TagReader.read(url, ext: ext), out.count)
        }.value
        EngineLibrary.shared.updateFile(path, tags: tags, size: size)
    }

    /// Adds cover art to a file that has none, with the same safety check, backup and atomic save as a tag write.
    func addArt(_ path: String, jpeg: [UInt8], width: Int, height: Int) async throws {
        guard let url = EngineLibrary.shared.url(of: path) else { throw EngineError("isn't in your music folder") }
        let backup = backupDir.map { dir in path.split(separator: "/").dropFirst().reduce(dir) { $0.appendingPathComponent(String($1)) } }
        let ext = Engine.extOf(path)
        let (tags, size) = try await Task.detached { () -> (Tags, Int) in
            let orig = [UInt8](try Data(contentsOf: url))
            let out = try TagWriter.addArt(orig, ext: ext, jpeg: jpeg, width: width, height: height)
            if let backup { try Self.backUp(Data(orig), to: backup) }
            try Data(out).write(to: url, options: .atomic)
            return (TagReader.read(url, ext: ext), out.count)
        }.value
        EngineLibrary.shared.updateFile(path, tags: tags, size: size)
    }

    /// Keeps the first backup forever, but not an empty one (a failed earlier attempt could have left it).
    nonisolated static func backUp(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > 0 { return }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// After a download: tag it with the fixer's settings (when auto-tagging is on). Returns a note if it failed.
    func autoTag(_ path: String, song: Int, always: Bool = false) async -> String {
        guard autoTag || always, Engine.editableExts.contains(Engine.extOf(path)), let file = EngineLibrary.shared.files.first(where: { $0.path == path }) else { return "" }
        let it = Engine.fixFor(tags: file.tags, song: EngineState.shared.catalog[song], fields: fields, onlyBlanks: onlyBlanks, genre: genre)
        guard !it.changes.isEmpty else { return "" }
        do { try await write(path, it.desired); return "" } catch { return "Its tags weren't updated: \(error.localizedDescription)." }
    }
}

// MARK: - Duplicates

@MainActor enum EngineDups {
    private static func groups() -> [Engine.DupGroup] {
        let library = EngineLibrary.shared
        return Engine.duplicateGroups(files: library.files, match: library.match, catalog: EngineState.shared.catalog)
    }

    static func json() -> String {
        let all = groups(), canTrash = EngineLibrary.shared.root != nil
        return EngineTools.json([
            "canTrash": canTrash, "exactExtra": canTrash ? Engine.extraCopies(all.filter(Engine.isExactDuplicate)).count : 0,
            "groups": all.map { g -> [String: Any] in
                let keep = Engine.bestCopy(g.files).path
                return ["title": g.title, "i": g.song.map { $0 as Any } ?? NSNull(), "exact": Engine.isExactDuplicate(g), "extra": g.extra,
                        "files": g.files.map { ["path": $0.path, "ext": $0.ext, "size": $0.size, "title": $0.title, "keep": $0.path == keep, "onDisk": true] }]
            },
        ])
    }

    /// Keeps the best copy and moves the rest to the Trash: one song's group (by one of its files) or every group
    /// whose files all have exactly the same title. The screen asked you first.
    static func trash(path: String?) async throws -> String {
        let all = groups()
        let picked = (path.map { p in all.filter { $0.files.contains { $0.path == p } } } ?? all).filter(Engine.isExactDuplicate)
        let victims = Engine.extraCopies(picked)
        guard !victims.isEmpty else { return "" }
        var moved: [String] = [], failed: [String] = []
        for f in victims {
            do { try await EngineTools.trash(f.path); moved.append(f.path) }
            catch { failed.append("\(Engine.baseName(f.path)) (\(error.localizedDescription))") }
        }
        await EngineLibrary.shared.removeFiles(moved)
        return "Moved \(EngineTools.plural(moved.count, "file", "files")) to the Trash.\(failed.isEmpty ? "" : " Couldn't move \(failed.prefix(3).joined(separator: "; "))\(failed.count > 3 ? "; and more" : "").")"
    }
}

// MARK: - File health

@MainActor final class EngineHealth {
    static let shared = EngineHealth()
    static let playable: Set<String> = ["mp3", "m4a", "m4b", "aac", "alac", "flac", "wav", "aif", "aiff"]
    private var probes: [String: Engine.Probe] = [:]
    private var running = false, done = false
    var stopping = false
    private var status = ""

    func json() -> String {
        let library = EngineLibrary.shared, catalog = EngineState.shared.catalog
        let issues = Engine.healthIssues(files: library.files, match: library.match, catalog: catalog, probes: probes)
        let titles = ["damaged": ("May be damaged or cut off", "Replace it with the site's copy, or move it to the Trash."),
                      "upgrade": ("Better copies on the site", "Upgrade downloads the site's higher-quality file; yours goes to the Trash."),
                      "tags": ("Tags to fix", "The Tag fixer writes the catalog's tags to matched files. Unmatched files can be matched by hand there."),
                      "loudness": ("Much quieter or louder", "Compared with the middle of your library. A very different level can mean a bad rip or a different source."),
                      "art": ("No cover art", "Add artwork puts the song's picture from the site into the file. Tags and audio stay as they are; the Tag fixer's backup folder is used when set.")]
        let groups = ["damaged", "upgrade", "tags", "loudness", "art"].compactMap { k -> [String: Any]? in
            let items = issues.filter { $0.group == k }
            guard !items.isEmpty else { return nil }
            return ["key": k, "title": titles[k]!.0, "help": titles[k]!.1, "items": items.prefix(500).map { x -> [String: Any] in
                let songs = library.match.songsFor[x.path] ?? [], song = songs.count == 1 ? catalog[songs[0]] : nil
                return ["path": x.path, "text": x.text, "reveal": true, "trash": library.root != nil && x.group != "art",
                        "replace": library.root != nil && x.group != "art" && !(song?.filePath.isEmpty ?? true),
                        "art": x.group == "art" && library.root != nil && !songs.isEmpty]
            }]
        }
        return EngineTools.json(["running": running, "done": done, "status": status, "probeable": true, "groups": groups])
    }

    /// Opens every playable file, two at a time (gentle on a network drive): does it play, and for how long?
    func run() {
        guard !running else { return }
        let library = EngineLibrary.shared
        let files = library.files.filter { Self.playable.contains($0.ext) }.compactMap { f in library.url(of: f.path).map { (f.path, $0) } }
        running = true; stopping = false; probes = [:]
        Task {
            var next = 0, count = 0
            while next < files.count && !stopping {
                let batch = Array(files[next..<min(next + 2, files.count)])
                next += batch.count
                let results = await withTaskGroup(of: (String, Engine.Probe?).self) { group -> [(String, Engine.Probe?)] in
                    for (path, url) in batch { group.addTask { (path, await Self.probe(url)) } }
                    var out: [(String, Engine.Probe?)] = []
                    for await r in group { out.append(r) }
                    return out
                }
                for (path, p) in results { if let p { probes[path] = p } }
                count += batch.count
                if count % 10 == 0 { status = "Checked \(count.formatted()) of \(EngineTools.plural(files.count, "file", "files"))…" }
            }
            running = false
            done = !stopping
            status = stopping ? "Stopped after \(EngineTools.plural(count, "file", "files"))." : "Checked \(EngineTools.plural(files.count, "file", "files"))."
        }
    }

    /// AVFoundation estimates the length from the header and file size, so a cut-off file reads as short without
    /// reading the whole song over the network. A file gone since the scan gives nothing.
    nonisolated static func probe(_ url: URL) async -> Engine.Probe? {
        await Task.detached { () -> Engine.Probe? in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let asset = AVURLAsset(url: url)
            let seconds = CMTimeGetSeconds(asset.duration)
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
            let ok = asset.isPlayable && !asset.tracks(withMediaType: .audio).isEmpty, ext = Engine.extOf(url.path)
            return Engine.Probe(ok: ok, seconds: seconds.isFinite ? seconds : 0, size: size, loudness: ok ? loudness(url) : nil,
                                art: Engine.editableExts.contains(ext) ? TagReader.hasArt(url, ext: ext) : nil)
        }.value
    }

    /// The average level (RMS, in dBFS) of three 3-second samples at a quarter, half and three quarters of the way in.
    /// Reads under 1 MB of audio, so it stays quick on a network drive. Silence or an unreadable file gives nothing.
    nonisolated static func loudness(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate * 3)) else { return nil }
        var sum = 0.0, count = 0
        for at in [0.25, 0.5, 0.75] {
            file.framePosition = AVAudioFramePosition(Double(file.length) * at)
            guard (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData else { continue }
            for c in 0..<Int(buf.format.channelCount) {
                for n in 0..<Int(buf.frameLength) { let v = Double(ch[c][n]); sum += v * v }
                count += Int(buf.frameLength)
            }
        }
        guard count > 0, sum > 0 else { return nil }
        return 10 * log10(sum / Double(count))
    }

    /// The song's picture from the site as a JPEG, at most 600 px across.
    private static func artwork(for song: EngineSong) async throws -> (jpeg: [UInt8], width: Int, height: Int) {
        guard let x = await Extras.shared.extras(for: String(song.id)), let link = x.image, let img = await Extras.shared.image(link),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw EngineError("The site has no picture for “\(song.name)”") }
        let scale = min(1, 600 / Double(max(cg.width, cg.height)))
        let w = max(1, Int(Double(cg.width) * scale)), h = max(1, Int(Double(cg.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw EngineError("Couldn't resize the picture") }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage(), let data = NSBitmapImageRep(cgImage: small).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { throw EngineError("Couldn't make a JPEG of the picture") }
        return ([UInt8](data), w, h)
    }

    private func addArt(_ path: String) async throws {
        guard let i = EngineLibrary.shared.match.songsFor[path]?.first else { throw EngineError("That file isn't matched to a song") }
        let a = try await Self.artwork(for: EngineState.shared.catalog[i])
        try await EngineFixer.shared.addArt(path, jpeg: a.jpeg, width: a.width, height: a.height)
        probes[path]?.art = true
    }

    /// Show in Finder, move to the Trash, or replace with the site's copy (the screen asked you first).
    func fix(_ op: String, path: String) async throws -> String {
        let library = EngineLibrary.shared
        if op == "artAll" {
            let paths = probes.filter { $0.value.art == false && library.match.songsFor[$0.key]?.first != nil }.keys.sorted()
            var ok = 0, failed: [String] = []
            for p in paths {
                do { try await addArt(p); ok += 1 } catch { failed.append("\(Engine.baseName(p)): \(error.localizedDescription)") }
            }
            if ok > 0 { Plex.scheduleRefresh() }
            return "Added cover art to \(EngineTools.plural(ok, "file", "files")).\(failed.isEmpty ? "" : " Skipped \(failed.prefix(3).joined(separator: "; "))\(failed.count > 3 ? "; and more" : "").")"
        }
        guard library.files.contains(where: { $0.path == path }), let url = library.url(of: path) else { throw EngineError("That file isn't in your library anymore") }
        switch op {
        case "reveal":
            NSWorkspace.shared.activateFileViewerSelecting([url]); return ""
        case "trash":
            try await EngineTools.trash(path)
            probes[path] = nil
            await library.removeFiles([path])
            return "Moved “\(Engine.baseName(path))” to the Trash."
        case "art":
            try await addArt(path)
            Plex.scheduleRefresh()
            return "Added cover art to “\(Engine.baseName(path))”."
        case "replace":
            guard let i = library.match.songsFor[path]?.first else { throw EngineError("That file isn't matched to a song") }
            let song = EngineState.shared.catalog[i]
            // Same name: the old file must go first (downloads never overwrite). Otherwise download first, so a failed
            // download leaves your copy where it was.
            let samePath = "\(Engine.saveFolder(song, library.layout))/\(Engine.saveFileName(song))" == path
            let retire = { [self] in try await EngineTools.trash(path); probes[path] = nil; await library.removeFiles([path]) }
            if samePath { try await retire() }
            let r: (existed: Bool, note: String, where: String)
            do { r = try await EngineDownloads.shared.downloadNow(i) }
            catch { throw EngineError(samePath ? "\(error.localizedDescription) Your old copy is in the Trash." : error.localizedDescription) }
            if !samePath { try await retire() }
            if !r.existed { Plex.scheduleRefresh() }
            return r.existed ? "“\(song.name)” was already in \(r.where)." : "Saved “\(song.name)” to \(r.where).\(r.note.isEmpty ? "" : " \(r.note)")"
        default: return ""
        }
    }
}
