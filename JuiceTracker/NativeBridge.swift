import AppKit
import AVFoundation
import WebKit

/// Gives the page the file access Chrome's File System Access API would: bridge.js builds
/// showDirectoryPicker() and folder/file handles on top of these messages.
/// Only folders the user picked in an open panel (and anything inside them) can be read or written.
final class NativeBridge: NSObject, WKScriptMessageHandlerWithReply {
    private struct BridgeError: Error { let message: String }
    private var roots: [String] = [] // touched on the main thread only
    private let ambient = AmbientPlayer()
    weak var webView: WKWebView?

    override init() {
        super.init()
        // Tell the page which song is playing (nil when stopped) so the sidebar can show it.
        ambient.onTrack = { [weak self] title in
            let json = (try? JSONSerialization.data(withJSONObject: [title.map { $0 as Any } ?? NSNull()])).flatMap { String(data: $0, encoding: .utf8) } ?? "[null]"
            self?.webView?.evaluateJavaScript("window.jwAmbientNow && window.jwAmbientNow(\(json)[0])")
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
            Self.download(url, to: dest, reply: replyHandler)
            return
        case "plex":
            // Plex lives in Settings (⌘,); the page only asks for a rescan, the status, or a playlist.
            switch body["action"] as? String {
            case "refresh":
                Plex.scheduleRefresh()
                replyHandler(true, nil)
            case "status":
                replyHandler(["configured": Plex.configured], nil)
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
        case "restoreFolder":
            replyHandler(restoreFolder(id: body["id"] as? String ?? ""), nil)
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
            reply(["path": path, "name": url.lastPathComponent], nil)
        }
    }

    /// Re-grants the folder last picked for this id, so the music folder survives relaunches. Only ever a folder
    /// the user chose in an open panel before. No disk access here: this runs on the main thread, and a slow network
    /// drive can take minutes to answer (the whole app would freeze). The page finds out when it lists the folder.
    private func restoreFolder(id: String) -> [String: String]? {
        guard let path = UserDefaults.standard.string(forKey: "lastFolder.\(id)") else { return nil }
        if !roots.contains(path) { roots.append(path) }
        return ["path": path, "name": URL(fileURLWithPath: path).lastPathComponent]
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
    private static func download(_ url: URL, to dest: URL, reply: @escaping (Any?, String?) -> Void) {
        let finish = { (result: Any?, failure: String?) in DispatchQueue.main.async { reply(result, failure) } }
        let fm = FileManager.default
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
/// volume, and "play this song now" for the sidebar player and the song card.
final class AmbientPlayer: NSObject, AVAudioPlayerDelegate {
    var volume: Float = 0.06 { didSet { player?.volume = volume } }
    var onTrack: ((String?) -> Void)?
    private var items: [(url: URL, title: String)] = []
    private var order: [Int] = []
    private var player: AVAudioPlayer?
    private var paused = false
    private var generation = 0 // bumps on every start/stop so a slow load can't start after the user turned it off

    func set(_ newItems: [(URL, String)]) {
        items = newItems.map { (url: $0.0, title: $0.1) }
        order = []
        if items.isEmpty { stop() }
    }

    /// Starts shuffling unless something is already playing, loading, or the user paused.
    func play() {
        if player?.isPlaying == true || paused || items.isEmpty { return }
        next()
    }

    func stop() {
        generation += 1
        paused = false
        player?.stop()
        player = nil
        onTrack?(nil)
    }

    func pause() { paused = true; player?.pause() }
    func resume() { paused = false; if let player { player.play() } else { next() } }
    func skip() { paused = false; next() }
    func playNow(_ url: URL, title: String) { paused = false; start((url: url, title: title)) }

    private func next(failures: Int = 0) {
        guard !items.isEmpty, failures < min(items.count, 5) else { stop(); return }
        if order.isEmpty { order = Array(items.indices).shuffled() }
        start(items[order.removeLast()], failures: failures)
    }

    private func start(_ item: (url: URL, title: String), failures: Int = 0) {
        player?.stop()
        generation += 1
        let gen = generation
        // Opening a file on a network drive can take seconds; keep it off the main thread.
        DispatchQueue.global(qos: .utility).async {
            let loaded = try? AVAudioPlayer(contentsOf: item.url)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                guard let loaded else { self.next(failures: failures + 1); return }
                loaded.delegate = self
                loaded.volume = 0
                loaded.play()
                loaded.setVolume(self.volume, fadeDuration: 3)
                self.player = loaded
                self.onTrack?(item.title)
            }
        }
    }

    func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        if finished === player { player = nil; if !items.isEmpty { next() } else { onTrack?(nil) } }
    }
}
