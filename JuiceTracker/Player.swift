import AppKit
import AVFoundation
import MediaPlayer

/// Song files from juicewrldapi.com, saved straight into the music folder.
enum Downloader {
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "alac", "flac", "wav", "aif", "aiff", "ogg", "opus", "wma"]

    /// Downloads to a temporary file and moves it into place only when complete, so a dropped connection never
    /// leaves half a song in the library. Never overwrites: an existing file is reported, not replaced. Returns whether
    /// the file was there already, and its size; throws with the reason (a missing music folder says "isn't available",
    /// which makes the queue wait for the drive).
    static func downloadFile(_ url: URL, to dest: URL, root: String) async throws -> (existed: Bool, size: Int) {
        // Only song files from the site, and only as audio files.
        guard url.scheme == "https", url.host == "juicewrldapi.com", url.path.hasPrefix("/juicewrld/files/download") else {
            throw EngineError("Only song files from juicewrldapi.com can be downloaded.")
        }
        guard audioExtensions.contains(dest.pathExtension.lowercased()) else { throw EngineError("Only audio files can be saved there.") }
        return try await withCheckedThrowingContinuation { cont in
            download(url, to: dest, root: root) { result, failure in
                if let failure {
                    cont.resume(throwing: EngineError(failure.replacingOccurrences(of: #"^\w+Error: "#, with: "", options: .regularExpression)))
                } else {
                    let r = result as? [String: Any] ?? [:]
                    cont.resume(returning: (r["existed"] as? Bool ?? false, (r["size"] as? NSNumber)?.intValue ?? 0))
                }
            }
        }
    }

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
}

/// Plays the user's own matched songs, shuffled (quietly by default, as ambient music), with pause, skip,
/// volume, and "play this song now" for the sidebar player and the song card. Shows in Now Playing (Control Center)
/// and answers the keyboard's media keys and AirPods controls; the menu bar player uses it too.
final class AmbientPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = AmbientPlayer()
    static let changed = Notification.Name("AmbientPlayerChanged")

    var volume: Float = 0.06 { didSet { player?.volume = loud; publish() } }
    /// Volume matching (Settings > Playback): each file's measured level brings it to the same loudness.
    private var gain: Float = 1
    private var loud: Float { min(1, volume * gain) }
    static var matchVolume: Bool { UserDefaults.standard.object(forKey: "matchVolume") as? Bool ?? true }
    private static var levels: [String: Double] = [:] // measured once per file per launch
    /// How much to scale a file to reach a typical level (-20 dBFS), at most 9 dB either way.
    private static func gain(for url: URL) -> Float {
        guard matchVolume else { return 1 }
        if levels[url.path] == nil, let l = EngineHealth.loudness(url) { levels[url.path] = l }
        guard let l = levels[url.path] else { return 1 }
        return Float(pow(10, max(-9, min(9, -20 - l)) / 20))
    }
    /// The song's length, and moving within it (the seek bars).
    var duration: TimeInterval { player?.duration ?? 0 }
    func seek(to t: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(t, player.duration - 0.5))
        publish()
    }
    /// Sleep timer: fades out and pauses at this time, or (`sleepAtEnd`) when the current song ends.
    private(set) var sleepAt: Date?
    private(set) var sleepAtEnd = false
    func sleep(minutes: Int?, atEnd: Bool = false) {
        sleepAt = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        sleepAtEnd = atEnd
        publish()
    }
    private func sleepIfDue() {
        guard let at = sleepAt, Date() >= at, let p = player, !isPaused else { return }
        sleepAt = nil
        p.setVolume(0, fadeDuration: 8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.player === p else { return }
            self.pause(); p.volume = self.loud
        }
        publish()
    }
    private(set) var title: String?
    private(set) var isPaused = false
    var hasSongs: Bool { !items.isEmpty }
    /// The file playing now (lyrics and artwork look up its song), and where in it.
    private(set) var currentPath: String?
    var currentTime: TimeInterval { player?.currentTime ?? 0 }
    private var hasOwnCover = false

    /// Loudness right now, 0...1, for the visualizer (0 when nothing plays).
    func level() -> Float {
        guard let player, player.isPlaying else { return 0 }
        player.updateMeters()
        let db = (player.averagePower(forChannel: 0) + player.averagePower(forChannel: max(0, player.numberOfChannels - 1))) / 2
        return max(0, min(1, (db + 50) / 50))
    }

    /// Artwork for songs whose file has none (the era's art from juicewrldapi.com).
    func setFallbackArtwork(_ image: NSImage, for path: String) {
        guard path == currentPath, !hasOwnCover else { return }
        artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        publish()
    }
    var isPlaying: Bool { player != nil && !isPaused }
    private var items: [(url: URL, title: String)] = []
    private var order: [Int] = []
    private var inOrder = false                          // era radio: the era's songs in recording order, not shuffled
    private(set) var upNext: [(url: URL, title: String)] = [] // songs you picked to play next, before the mix
    private var crossfading = false                      // the next song has started fading in over this one
    /// Seconds songs blend into each other (0: one after the other). Settings > Playback.
    static var crossfade: Double { UserDefaults.standard.object(forKey: "crossfadeSeconds") as? Double ?? 4 }
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
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime); return .success
        }
        // Crossfade: a few seconds before a song ends, start the next one fading in over it.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.crossfadeIfDue(); self?.sleepIfDue() }
    }

    /// The songs to play from. `inOrder` plays them as given (era radio) instead of shuffled.
    func set(_ newItems: [(URL, String)], inOrder: Bool = false) {
        let list = newItems.map { (url: $0.0, title: $0.1) }
        if list.map(\.url) != items.map(\.url) || inOrder != self.inOrder { order = [] }
        items = list
        self.inOrder = inOrder
        if items.isEmpty && upNext.isEmpty { stop() }
    }

    /// Plays this song after the current one (before the mix carries on).
    func queueNext(_ url: URL, title: String) {
        upNext.append((url, title))
        publish()
        if player == nil && !isPaused { next() }
    }
    func clearUpNext() { upNext = []; publish() }

    private func crossfadeIfDue() {
        let fade = Self.crossfade
        guard fade > 0, !crossfading, !sleepAtEnd, clip == nil, let p = player, p.isPlaying, p.duration > fade * 3, p.duration - p.currentTime <= fade else { return }
        crossfading = true
        next(fade: fade)
    }

    /// Starts shuffling unless something is already playing, loading, or the user paused.
    func play() {
        // While a trivia clip plays the music is paused for it; it comes back when the clip ends.
        if player?.isPlaying == true || isPaused || items.isEmpty || clip != nil { return }
        next()
    }

    func stop() {
        resumeAfterClip = false // a clip in progress (trivia) keeps playing; the music won't come back after it
        generation += 1
        isPaused = false
        player?.stop()
        player = nil
        title = nil
        currentPath = nil
        publish()
    }

    func pause() { guard player != nil else { return }; isPaused = true; player?.pause(); publish() }
    func resume() { isPaused = false; if let player { player.play(); publish() } else { next() } }
    func togglePause() { isPlaying ? pause() : resume() }
    func skip() { isPaused = false; next() }
    func playNow(_ url: URL, title: String) { isPaused = false; start((url: url, title: title)) }

    private func next(failures: Int = 0, fade: Double = 0) {
        if !upNext.isEmpty { start(upNext.removeFirst(), failures: failures, fade: fade); return }
        guard !items.isEmpty, failures < min(items.count, 5) else { stop(); return }
        if order.isEmpty {
            if inOrder { order = Array(items.indices.reversed()) } // taken from the end: first song first
            else {
                // Songs not heard yet today first; once all have played, everything shuffles again.
                let heard = Self.heardToday()
                let fresh = items.indices.filter { !heard.contains(items[$0].url.path) }
                order = (fresh.isEmpty ? Array(items.indices) : fresh).shuffled()
            }
        }
        start(items[order.removeLast()], failures: failures, fade: fade)
    }

    /// Every play (path and time), for "your listening" in Stats. The newest 5,000 are kept.
    static func logPlay(_ path: String) {
        var log = UserDefaults.standard.array(forKey: "playLog") as? [[Any]] ?? []
        log.append([path, Date().timeIntervalSince1970])
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
        UserDefaults.standard.set(log, forKey: "playLog")
    }
    static var playLog: [(path: String, at: Date)] {
        (UserDefaults.standard.array(forKey: "playLog") as? [[Any]] ?? []).compactMap { e in
            guard e.count == 2, let p = e[0] as? String, let t = e[1] as? Double else { return nil }
            return (p, Date(timeIntervalSince1970: t))
        }
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

    private func start(_ item: (url: URL, title: String), failures: Int = 0, fade: Double = 0) {
        if fade > 0, let old = player {
            old.delegate = nil // its end isn't "the song finished" any more
            old.setVolume(0, fadeDuration: fade)
            DispatchQueue.main.asyncAfter(deadline: .now() + fade) { old.stop() }
        } else { player?.stop() }
        generation += 1
        let gen = generation
        // Opening a file on a network drive can take seconds; keep it off the main thread.
        DispatchQueue.global(qos: .utility).async {
            let loaded = try? AVAudioPlayer(contentsOf: item.url)
            loaded?.prepareToPlay() // reads the first buffers here, not on the main thread (slow network drives)
            let cover = loaded == nil ? nil : Self.cover(of: item.url)
            let gain = loaded == nil ? 1 : Self.gain(for: item.url)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                guard let loaded else { self.next(failures: failures + 1); return }
                loaded.delegate = self
                loaded.isMeteringEnabled = true
                loaded.volume = 0
                loaded.play()
                self.gain = gain
                loaded.setVolume(self.loud, fadeDuration: fade > 0 ? fade : 3)
                self.player = loaded
                self.crossfading = false
                self.title = item.title
                self.currentPath = item.url.path
                self.hasOwnCover = cover != nil
                Self.markHeard(item.url.path)
                Self.logPlay(item.url.path)
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

    /// Updates Now Playing (Control Center, the menu bar's Now Playing) and tells the screens and menu bar.
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
        if sleepAtEnd { sleepAtEnd = false; isPaused = true; publish(); return } // paused; Play starts the song again
        player = nil
        if !items.isEmpty || !upNext.isEmpty { next() } else { title = nil; publish() }
    }

    // A damaged file stops partway with this instead of "finished"; move on rather than go quiet.
    func audioPlayerDecodeErrorDidOccur(_ failed: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(failed, successfully: false)
    }
}
