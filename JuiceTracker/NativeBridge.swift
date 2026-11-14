import AppKit
import AVFoundation
import MediaPlayer
import WebKit

/// Gives the page the file access Chrome's File System Access API would: bridge.js builds
/// showDirectoryPicker() and folder/file handles on top of these messages.
/// Only folders the user picked in an open panel (and anything inside them) can be read or written.
final class NativeBridge: NSObject, WKScriptMessageHandlerWithReply {
    private struct BridgeError: Error { let message: String }
    private var roots: [String] = [] // touched on the main thread only
    private let ambient = AmbientPlayer.shared
    weak var webView: WKWebView?

    override init() {
        super.init()
        // Tell the page what's playing, whether it's paused, and the volume, however it changed
        // (the page's own controls, media keys, Control Center, or the menu bar).
        NotificationCenter.default.addObserver(forName: AmbientPlayer.changed, object: nil, queue: .main) { [weak self] _ in
            let p = AmbientPlayer.shared
            let args: [Any] = [p.title ?? NSNull(), p.isPaused, Int((p.volume * 100).rounded())]
            guard let data = try? JSONSerialization.data(withJSONObject: args), let json = String(data: data, encoding: .utf8) else { return }
            self?.webView?.evaluateJavaScript("window.jwAmbientNow && window.jwAmbientNow(...\(json))")
        }
    }

    func stopAmbient() { ambient.stop() }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "TypeError: Bad request")
            return
        }
        switch op {
        case "pickFolder":
            pickFolder(id: body["id"] as? String ?? "", reply: replyHandler)
            return
        case "ambient":
            // Background music from the user's matched files. Paths go through the same folder check as every file op.
            if let list = body["items"] as? [[String: Any]] {
                ambient.set(list.compactMap { item -> (URL, String)? in
                    guard let path = item["path"] as? String, let url = allowedURL(path) else { return nil }
                    return (url, item["title"] as? String ?? url.deletingPathExtension().lastPathComponent)
                })
            }
            if let volume = body["volume"] as? NSNumber { ambient.volume = max(0, min(1, volume.floatValue)) }
            switch body["cmd"] as? String {
            case "pause": ambient.pause()
            case "resume": ambient.resume()
            case "skip": ambient.skip()
            default: break
            }
            if let path = body["clipPath"] as? String {
                // Trivia "name that song": a short clip, louder than the background music, which pauses meanwhile.
                guard let url = allowedURL(path) else {
                    replyHandler(nil, "NotAllowedError: That location isn't inside a folder you chose.")
                    return
                }
                ambient.playClip(url, from: (body["start"] as? NSNumber)?.doubleValue ?? 30, seconds: (body["seconds"] as? NSNumber)?.doubleValue ?? 15)
            }
            if body["stopClip"] as? Bool == true { ambient.stopClip() }
            if let path = body["playPath"] as? String {
                guard let url = allowedURL(path) else {
                    replyHandler(nil, "NotAllowedError: That location isn't inside a folder you chose.")
                    return
                }
                ambient.playNow(url, title: body["title"] as? String ?? url.deletingPathExtension().lastPathComponent)
            }
            if let play = body["play"] as? Bool { play ? ambient.play() : ambient.stop() }
            replyHandler(true, nil)
            return
        case "download":
            // A song file from juicewrldapi.com, saved straight into the picked music folder.
            guard let path = body["path"] as? String, let dest = allowedURL(path) else {
                replyHandler(nil, "NotAllowedError: That location isn't inside a folder you chose.")
                return
            }
            guard let raw = body["url"] as? String, let url = URL(string: raw), url.scheme == "https",
                  url.host == "juicewrldapi.com", url.path.hasPrefix("/juicewrld/files/download") else {
                replyHandler(nil, "NotAllowedError: Only song files from juicewrldapi.com can be downloaded.")
                return
            }
            guard Self.audioExtensions.contains(dest.pathExtension.lowercased()) else {
                replyHandler(nil, "NotAllowedError: Only audio files can be saved there.")
                return
            }
            let root = roots.first { dest.path == $0 || dest.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } ?? dest.path
            Self.download(url, to: dest, root: root, reply: replyHandler)
            return
        case "plex":
            // Plex lives in Settings (⌘,); the page only asks for a rescan, the status, or a playlist.
            switch body["action"] as? String {
            case "refresh":
                Plex.scheduleRefresh()
                replyHandler(true, nil)
            case "status":
                replyHandler(["configured": Plex.configured], nil)
            case "stats":
                // Play counts for the library's files (the Plex account of the token in Settings).
                let paths = body["paths"] as? [String] ?? []
                Task {
                    do {
                        let r = try await Plex.playCounts(paths: paths)
                        await MainActor.run { replyHandler(["items": r.items, "missing": r.missing], nil) }
                    } catch {
                        await MainActor.run { replyHandler(nil, "PlexError: \(error.localizedDescription)") }
                    }
                }
            case "playlist":
                let title = (body["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let paths = body["paths"] as? [String] ?? []
                guard !title.isEmpty, !paths.isEmpty else { replyHandler(nil, "TypeError: A playlist needs a title and songs."); return }
                Task {
                    do {
                        let r = try await Plex.playlist(title: title, paths: paths)
                        await MainActor.run { replyHandler(["matched": r.matched, "missing": r.missing], nil) }
                    } catch {
                        await MainActor.run { replyHandler(nil, "PlexError: \(error.localizedDescription)") }
                    }
                }
            default:
                replyHandler(nil, "TypeError: Unknown Plex action.")
            }
            return
        case "wishlist":
            // The page's wishlist (catalog ids), so the daily check can give those songs their own alert.
            UserDefaults.standard.set((body["ids"] as? [Any] ?? []).map { "\($0)" }, forKey: "wishlistIds")
            replyHandler(true, nil)
            return
        case "snapshot":
            // A weekly copy of the library list, kept off the music drive (iCloud Drive when it's on).
            let text = body["text"] as? String ?? ""
            DispatchQueue.global(qos: .utility).async {
                do {
                    let url = try Snapshots.save(text)
                    DispatchQueue.main.async { replyHandler(["path": url.path, "folder": url.deletingLastPathComponent().path], nil) }
                } catch {
                    DispatchQueue.main.async { replyHandler(nil, "UnknownError: \(error.localizedDescription)") }
                }
            }
            return
        case "snapshotFolder":
            let folder = Snapshots.folder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
            replyHandler(folder.path, nil)
            return
        case "restoreFolder":
            restoreFolder(id: body["id"] as? String ?? "", reply: replyHandler)
            return
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body["text"] as? String ?? "", forType: .string)
            replyHandler(true, nil)
            return
        default:
            break
        }
        guard let path = body["path"] as? String, let url = allowedURL(path) else {
            replyHandler(nil, "NotAllowedError: That location isn't inside a folder you chose.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Any?
            let failure: String?
            do {
                result = try Self.perform(op, url: url, body: body)
                failure = nil
            } catch let e as BridgeError {
                result = nil; failure = e.message
            } catch {
                result = nil; failure = "UnknownError: \(error.localizedDescription)"
            }
            DispatchQueue.main.async { replyHandler(result, failure) }
        }
    }

    // MARK: Folder picking

    private func pickFolder(id: String, reply: @escaping (Any?, String?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        let key = "lastFolder.\(id)"
        if let last = UserDefaults.standard.string(forKey: key) {
            panel.directoryURL = URL(fileURLWithPath: last).deletingLastPathComponent()
        }
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else {
                reply(nil, "AbortError: The user aborted a request.")
                return
            }
            let path = url.standardizedFileURL.path
            if !(self?.roots.contains(path) ?? true) { self?.roots.append(path) }
            UserDefaults.standard.set(path, forKey: key)
            UserDefaults.standard.set(try? url.bookmarkData(), forKey: "lastFolderBookmark.\(id)")
            reply(["path": path, "name": url.lastPathComponent], nil)
        }
    }

    /// Re-grants the folder last picked for this id, so the music folder survives relaunches. Only ever a folder
    /// the user chose in an open panel before. Its bookmark reconnects a network share that dropped, and finds it
    /// when it comes back under another name (/Volumes/PlexMedia-1). That can be slow, so it runs off the main thread,
    /// and after 3 seconds the page gets the saved path anyway (a later answer is still saved for next time).
    private func restoreFolder(id: String, reply: @escaping (Any?, String?) -> Void) {
        let defaults = UserDefaults.standard, pathKey = "lastFolder.\(id)", markKey = "lastFolderBookmark.\(id)"
        guard let saved = defaults.string(forKey: pathKey) else { reply(nil, nil); return }
        var replied = false
        let answer = { [weak self] (path: String) in
            if let self, !self.roots.contains(path) { self.roots.append(path) }
            if path != saved { defaults.set(path, forKey: pathKey) }
            guard !replied else { return }
            replied = true
            reply(["path": path, "name": URL(fileURLWithPath: path).lastPathComponent], nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { answer(saved) }
        let mark = defaults.data(forKey: markKey)
        DispatchQueue.global(qos: .userInitiated).async {
            var path = saved
            if let mark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: mark, options: .withoutUI, bookmarkDataIsStale: &stale) {
                    path = url.standardizedFileURL.path
                    if stale, let fresh = try? url.bookmarkData() { defaults.set(fresh, forKey: markKey) }
                }
            } else if let fresh = try? URL(fileURLWithPath: saved).bookmarkData() {
                defaults.set(fresh, forKey: markKey) // folders picked before bookmarks were saved
            }
            DispatchQueue.main.async { answer(path) }
        }
    }

    private func allowedURL(_ path: String) -> URL? {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        for root in roots where p == root || p.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    // MARK: Downloads

    private static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "alac", "flac", "wav", "aif", "aiff", "ogg", "opus", "wma"]

    /// Downloads to a temporary file and moves it into place only when complete, so a dropped connection
    /// never leaves half a song in the library. Never overwrites: an existing file is reported, not replaced.
    private static func download(_ url: URL, to dest: URL, root: String, reply: @escaping (Any?, String?) -> Void) {
        let finish = { (result: Any?, failure: String?) in DispatchQueue.main.async { reply(result, failure) } }
        let fm = FileManager.default
        // Off the main thread: on a struggling network drive even this existence check can take minutes,
        // and on the main thread it froze the whole window for every download.
        DispatchQueue.global(qos: .userInitiated).async {
            // A network drive that dropped leaves its path missing; creating folders there fails with a confusing
            // permission error (or, worse, would write to the local disk), so say what's actually wrong.
            guard fm.fileExists(atPath: root) else {
                finish(nil, "NotFoundError: Your music folder (\(root)) isn't available. If it's on a network drive, reconnect it and try again."); return
            }
            if fm.fileExists(atPath: dest.path) { finish(["path": dest.path, "existed": true], nil); return }
            URLSession.shared.downloadTask(with: url) { temp, response, error in
                if let error { finish(nil, "NetworkError: \(error.localizedDescription)"); return }
                let http = response as? HTTPURLResponse
                guard let temp, let http, http.statusCode == 200 else {
                    finish(nil, "NetworkError: juicewrldapi.com answered \(http?.statusCode ?? 0)."); return
                }
                // An error page served as 200 must not land in the library as a song.
                let type = (http.mimeType ?? "").lowercased()
                guard type.hasPrefix("audio/") || type == "application/octet-stream" else {
                    finish(nil, "NetworkError: juicewrldapi.com didn't send an audio file."); return
                }
                do {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dest.path) { finish(["path": dest.path, "existed": true], nil); return }
                    try fm.moveItem(at: temp, to: dest) // the temp file is deleted when this handler returns
                    // Download temp files are private (600); make it readable like the rest of the library, so Plex can index it.
                    try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dest.path)
                    let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.intValue ?? 0
                    finish(["path": dest.path, "size": size], nil)
                } catch {
                    finish(nil, "UnknownError: \(error.localizedDescription)")
                }
            }.resume()
        }
    }

    // MARK: File operations (run off the main thread)

    private static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

    private static func kind(of url: URL) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        return isDir.boolValue ? "directory" : "file"
    }

    private static func perform(_ op: String, url: URL, body: [String: Any]) throws -> Any {
        let fm = FileManager.default
        switch op {
        case "list":
            guard kind(of: url) == "directory" else { throw BridgeError(message: "NotFoundError: Folder not found.") }
            // Names and types straight from the directory listing: asking for each file's details costs a round
            // trip per file on a network drive (about 0.1 s each on the user's NAS). Only links and unknowns get a stat.
            guard let dir = opendir(url.path) else { throw BridgeError(message: "NotFoundError: Folder not found.") }
            defer { closedir(dir) }
            var entries: [[String: String]] = []
            while let entry = readdir(dir) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                if name == "." || name == ".." { continue }
                switch Int32(entry.pointee.d_type) {
                case DT_DIR: entries.append(["name": name, "kind": "directory"])
                case DT_REG: entries.append(["name": name, "kind": "file"])
                default: if let k = kind(of: url.appendingPathComponent(name)) { entries.append(["name": name, "kind": k]) }
                }
            }
            return entries
        case "stat", "exists":
            guard let k = kind(of: url) else {
                if op == "exists" { return ["exists": false] }
                throw BridgeError(message: "NotFoundError: File not found.")
            }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            let mtime = ((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000
            return ["exists": true, "kind": k, "size": size, "mtime": mtime]
        case "read":
            guard let start = int(body["start"]), let end = int(body["end"]), start >= 0, end >= start else {
                throw BridgeError(message: "TypeError: Bad range.")
            }
            guard let handle = FileHandle(forReadingAtPath: url.path) else {
                throw BridgeError(message: "NotFoundError: File not found.")
            }
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(start))
            let data = try handle.read(upToCount: end - start) ?? Data()
            return data.base64EncodedString()
        case "write":
            guard let b64 = body["data"] as? String, let data = Data(base64Encoded: b64) else {
                throw BridgeError(message: "TypeError: Bad data.")
            }
            try data.write(to: url, options: .atomic)
            return true
        case "mkdir":
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        case "probe":
            // File health check: does the audio open, and how long is it? AVFoundation estimates the length from the
            // header and file size, so a cut-off file reads as short without reading the whole song over the network.
            guard kind(of: url) == "file" else { throw BridgeError(message: "NotFoundError: File not found.") }
            let asset = AVURLAsset(url: url)
            let seconds = CMTimeGetSeconds(asset.duration)
            let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
            return ["ok": asset.isPlayable && !asset.tracks(withMediaType: .audio).isEmpty, "seconds": seconds.isFinite ? seconds : 0, "size": size]
        case "reveal":
            guard kind(of: url) != nil else { throw BridgeError(message: "NotFoundError: File not found.") }
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            return true
        case "trash":
            // Duplicate cleanup: always the Trash, never a permanent delete. Some network drives have no Trash;
            // then this fails and the file stays.
            guard kind(of: url) == "file" else { throw BridgeError(message: "NotFoundError: File not found.") }
            try fm.trashItem(at: url, resultingItemURL: nil)
            return true
        default:
            throw BridgeError(message: "TypeError: Unknown operation \(op).")
        }
    }
}

/// Plays the user's own matched songs, shuffled (quietly by default, as ambient music), with pause, skip,
/// volume, and "play this song now" for the sidebar player and the song card. Shows in Now Playing (Control Center)
/// and answers the keyboard's media keys and AirPods controls; the menu bar player uses it too.
final class AmbientPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = AmbientPlayer()
    static let changed = Notification.Name("AmbientPlayerChanged")

    var volume: Float = 0.06 { didSet { player?.volume = volume; publish() } }
    private(set) var title: String?
    private(set) var isPaused = false
    var hasSongs: Bool { !items.isEmpty }
    var isPlaying: Bool { player != nil && !isPaused }
    private var items: [(url: URL, title: String)] = []
    private var order: [Int] = []
    private var player: AVAudioPlayer?
    private var artwork: MPMediaItemArtwork?
    private var generation = 0 // bumps on every start/stop so a slow load can't start after the user turned it off
    private var clip: AVAudioPlayer?
    private var clipGeneration = 0
    private var resumeAfterClip = false

    private override init() {
        super.init()
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePause(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.skip(); return .success }
        c.previousTrackCommand.isEnabled = false
    }

    func set(_ newItems: [(URL, String)]) {
        items = newItems.map { (url: $0.0, title: $0.1) }
        order = []
        if items.isEmpty { stop() }
    }

    /// Starts shuffling unless something is already playing, loading, or the user paused.
    func play() {
        if player?.isPlaying == true || isPaused || items.isEmpty { return }
        next()
    }

    func stop() {
        generation += 1
        isPaused = false
        player?.stop()
        player = nil
        title = nil
        publish()
    }

    func pause() { guard player != nil else { return }; isPaused = true; player?.pause(); publish() }
    func resume() { isPaused = false; if let player { player.play(); publish() } else { next() } }
    func togglePause() { isPlaying ? pause() : resume() }
    func skip() { isPaused = false; next() }
    func playNow(_ url: URL, title: String) { isPaused = false; start((url: url, title: title)) }

    private func next(failures: Int = 0) {
        guard !items.isEmpty, failures < min(items.count, 5) else { stop(); return }
        if order.isEmpty {
            // Songs not heard yet today first; once all have played, everything shuffles again.
            let heard = Self.heardToday()
            let fresh = items.indices.filter { !heard.contains(items[$0].url.path) }
            order = (fresh.isEmpty ? Array(items.indices) : fresh).shuffled()
        }
        start(items[order.removeLast()], failures: failures)
    }

    /// Paths played today, kept across launches.
    private static func heardToday() -> Set<String> {
        let saved = UserDefaults.standard.dictionary(forKey: "ambientHeard") ?? [:]
        guard saved["day"] as? String == today() else { return [] }
        return Set(saved["paths"] as? [String] ?? [])
    }
    private static func markHeard(_ path: String) {
        var paths = heardToday()
        paths.insert(path)
        UserDefaults.standard.set(["day": today(), "paths": Array(paths)], forKey: "ambientHeard")
    }
    private static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Plays part of a song for trivia, then goes back to the background music if it was playing.
    func playClip(_ url: URL, from start: Double, seconds: Double) {
        clipGeneration += 1
        let gen = clipGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = try? AVAudioPlayer(contentsOf: url)
            loaded?.prepareToPlay()
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.clipGeneration, let loaded else { return }
                self.clip?.stop()
                if self.clip == nil { self.resumeAfterClip = self.player?.isPlaying == true }
                self.player?.pause()
                loaded.currentTime = max(0, min(start, loaded.duration - seconds))
                loaded.volume = 0.7
                loaded.play()
                self.clip = loaded
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    if gen == self?.clipGeneration { self?.stopClip() }
                }
            }
        }
    }

    func stopClip() {
        clipGeneration += 1
        guard let clip else { return }
        clip.stop()
        self.clip = nil
        if resumeAfterClip, !isPaused { player?.play() }
    }

    private func start(_ item: (url: URL, title: String), failures: Int = 0) {
        player?.stop()
        generation += 1
        let gen = generation
        // Opening a file on a network drive can take seconds; keep it off the main thread.
        DispatchQueue.global(qos: .utility).async {
            let loaded = try? AVAudioPlayer(contentsOf: item.url)
            loaded?.prepareToPlay() // reads the first buffers here, not on the main thread (slow network drives)
            let cover = loaded == nil ? nil : Self.cover(of: item.url)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                guard let loaded else { self.next(failures: failures + 1); return }
                loaded.delegate = self
                loaded.volume = 0
                loaded.play()
                loaded.setVolume(self.volume, fadeDuration: 3)
                self.player = loaded
                self.title = item.title
                Self.markHeard(item.url.path)
                let image = cover ?? NSApp.applicationIconImage ?? NSImage()
                self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.publish()
            }
        }
    }

    /// The song's embedded cover art, if it has any.
    private static func cover(of url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let art = AVMetadataItem.metadataItems(from: asset.commonMetadata, filteredByIdentifier: .commonIdentifierArtwork).first
        return art?.dataValue.flatMap(NSImage.init(data:))
    }

    /// Updates Now Playing (Control Center, the menu bar's Now Playing) and tells the page and menu bar.
    private func publish() {
        let center = MPNowPlayingInfoCenter.default()
        if let player, let title {
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: "Juice WRLD",
                MPMediaItemPropertyPlaybackDuration: player.duration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
                MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0,
            ]
            if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
            center.nowPlayingInfo = info
            center.playbackState = isPaused ? .paused : .playing
        } else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        guard finished === player else { return }
        player = nil
        if !items.isEmpty { next() } else { title = nil; publish() }
    }

    // A damaged file stops partway with this instead of "finished"; move on rather than go quiet.
    func audioPlayerDecodeErrorDidOccur(_ failed: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(failed, successfully: false)
    }
}
