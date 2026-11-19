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

// MARK: - Playback (with the equalizer on, through an engine with an EQ)

/// What plays a song: AVAudioPlayer, or with the equalizer on, an AVAudioEngine with an EQ on the way out.
protocol Playback: AnyObject {
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    var volume: Float { get set }
    var isPlaying: Bool { get }
    /// Called (on the main thread) when the song plays to its end, or a damaged file stops partway.
    var finished: (() -> Void)? { get set }
    @discardableResult func play() -> Bool
    func pause()
    func stop()
    func setVolume(_ volume: Float, fadeDuration: TimeInterval)
    /// Loudness right now, 0...1, for the visuals.
    func level() -> Float
}

/// AVAudioPlayer, wrapped (not subclassed: its init calls an init a Swift subclass doesn't have, and traps).
final class FilePlayback: NSObject, AVAudioPlayerDelegate, Playback {
    private let p: AVAudioPlayer
    var finished: (() -> Void)?
    init(contentsOf url: URL) throws {
        p = try AVAudioPlayer(contentsOf: url)
        super.init()
        p.delegate = self; p.isMeteringEnabled = true
        p.prepareToPlay() // reads the first buffers now, off the main thread (slow network drives)
    }
    var currentTime: TimeInterval { get { p.currentTime } set { p.currentTime = newValue } }
    var duration: TimeInterval { p.duration }
    var volume: Float { get { p.volume } set { p.volume = newValue } }
    var isPlaying: Bool { p.isPlaying }
    @discardableResult func play() -> Bool { p.play() }
    func pause() { p.pause() }
    func stop() { p.stop() }
    func setVolume(_ volume: Float, fadeDuration: TimeInterval) { p.setVolume(volume, fadeDuration: fadeDuration) }
    func level() -> Float {
        guard p.isPlaying else { return 0 }
        p.updateMeters()
        let db = (p.averagePower(forChannel: 0) + p.averagePower(forChannel: max(0, p.numberOfChannels - 1))) / 2
        return max(0, min(1, (db + 50) / 50))
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { finished?() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { finished?() }
}

/// Bass, mids and treble (Settings > Equalizer).
enum Equalizer {
    static let changed = Notification.Name("EqualizerChanged")
    static let keys = ["eq.bass", "eq.mid", "eq.treble"]
    static var on: Bool { UserDefaults.standard.bool(forKey: "eqOn") }
    static var bands: [Double] { keys.map { UserDefaults.standard.double(forKey: $0) } }
    /// Only then do songs go through the engine; otherwise they play as before.
    static var active: Bool { on && bands.contains { $0 != 0 } }
    static func configure(_ eq: AVAudioUnitEQ) {
        let b = bands, shape: [(AVAudioUnitEQFilterType, Float)] = [(.lowShelf, 120), (.parametric, 1000), (.highShelf, 6000)]
        for (k, band) in eq.bands.enumerated() where k < 3 {
            band.filterType = shape[k].0; band.frequency = shape[k].1; band.bandwidth = 1.5
            band.gain = Float(b[k]); band.bypass = !on
        }
        eq.globalGain = on ? Float(Engine.eqHeadroom(b)) : 0
    }
}

final class EQPlayback: NSObject, Playback {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 3)
    private let file: AVAudioFile
    private let rate: Double
    let duration: TimeInterval
    private var startFrame: AVAudioFramePosition = 0 // where the playing stretch began
    private var pausedAt: TimeInterval? = 0          // nil while playing
    private var stretch = 0                          // bumps each time playing (re)starts; an old stretch's end is ignored
    private var power: Float = -160                  // dB, from the audio on its way out (before the volume)
    private var fader: Timer?
    private var watch: NSObjectProtocol?
    var finished: (() -> Void)?

    init(contentsOf url: URL) throws {
        file = try AVAudioFile(forReading: url)
        rate = file.processingFormat.sampleRate
        duration = Double(file.length) / rate
        super.init()
        engine.attach(node); engine.attach(eq)
        engine.connect(node, to: eq, format: file.processingFormat)
        engine.connect(eq, to: engine.mainMixerNode, format: file.processingFormat)
        Equalizer.configure(eq)
        eq.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            guard let d = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength); var sum: Float = 0
            for k in 0..<n { sum += d[k] * d[k] }
            self?.power = 20 * log10(max((sum / Float(max(n, 1))).squareRoot(), 1e-6))
        }
        engine.prepare()
        watch = NotificationCenter.default.addObserver(forName: Equalizer.changed, object: nil, queue: .main) { [weak self] _ in
            if let eq = self?.eq { Equalizer.configure(eq) }
        }
    }
    deinit { if let watch { NotificationCenter.default.removeObserver(watch) }; fader?.invalidate(); engine.stop() }

    var isPlaying: Bool { pausedAt == nil }
    var currentTime: TimeInterval {
        get {
            if let pausedAt { return pausedAt }
            guard let t = node.lastRenderTime, let p = node.playerTime(forNodeTime: t) else { return Double(startFrame) / rate }
            return min(duration, Double(startFrame + p.sampleTime) / rate)
        }
        set {
            if pausedAt != nil { pausedAt = max(0, min(newValue, duration)) } else { begin(at: newValue) }
        }
    }
    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { fader?.invalidate(); engine.mainMixerNode.outputVolume = newValue }
    }

    @discardableResult func play() -> Bool {
        guard let at = pausedAt else { return true }
        do { if !engine.isRunning { try engine.start() } } catch { return false }
        begin(at: at)
        return true
    }
    func pause() {
        guard pausedAt == nil else { return }
        pausedAt = currentTime
        stretch += 1; node.stop(); engine.pause()
    }
    func stop() {
        pausedAt = 0; stretch += 1; fader?.invalidate()
        node.stop(); engine.stop()
    }
    /// Plays from `t` to the end of the file.
    private func begin(at t: TimeInterval) {
        node.stop()
        stretch += 1
        let mine = stretch
        startFrame = AVAudioFramePosition(max(0, min(t, duration)) * rate)
        let count = AVAudioFrameCount(max(0, file.length - startFrame))
        pausedAt = nil
        guard count > 0 else { DispatchQueue.main.async { [weak self] in self?.finished?() }; return }
        node.scheduleSegment(file, startingFrame: startFrame, frameCount: count, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { guard let self, self.stretch == mine, self.pausedAt == nil else { return }; self.pausedAt = self.duration; self.finished?() }
        }
        node.play()
    }
    func setVolume(_ target: Float, fadeDuration: TimeInterval) {
        fader?.invalidate()
        guard fadeDuration > 0 else { engine.mainMixerNode.outputVolume = target; return }
        let from = engine.mainMixerNode.outputVolume, start = Date()
        fader = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let p = min(1, Date().timeIntervalSince(start) / fadeDuration)
            self.engine.mainMixerNode.outputVolume = from + (target - from) * Float(p)
            if p >= 1 { t.invalidate() }
        }
    }
    func level() -> Float { isPlaying ? max(0, min(1, (power + 50) / 50)) : 0 }
}

/// Plays the user's own matched songs, shuffled (quietly by default, as ambient music), with pause, skip,
/// volume, and "play this song now" for the sidebar player and the song card. Shows in Now Playing (Control Center)
/// and answers the keyboard's media keys and AirPods controls; the menu bar player uses it too.
final class AmbientPlayer: NSObject {
    static let shared = AmbientPlayer()
    static let changed = Notification.Name("AmbientPlayerChanged")

    var volume: Float = 0.06 { didSet { player?.volume = loud; publish() } }
    /// Volume matching (Settings > Playback): each file's measured level brings it to the same loudness.
    private var gain: Float = 1
    private var loud: Float { min(1, volume * gain) }
    static var matchVolume: Bool { UserDefaults.standard.object(forKey: "matchVolume") as? Bool ?? true }
    private static var levels: [String: Double] = [:] // measured once per file per launch
    private static let levelsLock = NSLock()            // songs load on background threads, sometimes two at once
    /// How much to scale a file to reach a typical level (-20 dBFS), at most 9 dB either way. `measure: false` only
    /// answers from what's known (nil when the file hasn't been measured yet).
    private static func gain(for url: URL, measure: Bool) -> Float? {
        guard matchVolume else { return 1 }
        levelsLock.lock(); var level = levels[url.path]; levelsLock.unlock()
        if level == nil, measure, let l = EngineHealth.loudness(url) {
            level = l
            levelsLock.lock(); levels[url.path] = l; levelsLock.unlock()
        }
        guard let l = level else { return measure ? 1 : nil }
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
    /// The playing song's cover (its own, else the era's art from the site), for the Player tab.
    private(set) var coverImage: NSImage?

    /// Loudness right now, 0...1, for the visualizer (0 when nothing plays).
    func level() -> Float { player?.level() ?? 0 }

    /// A file to play, through the equalizer when it's on. Off the main thread: opening reads the file.
    private static func open(_ url: URL) -> Playback? {
        Equalizer.active ? try? EQPlayback(contentsOf: url) : try? FilePlayback(contentsOf: url)
    }
    /// The equalizer changed: the song playing moves to (or off) the engine where it is, without a gap you'd notice.
    func equalizerChanged() {
        NotificationCenter.default.post(name: Equalizer.changed, object: nil)
        guard let old = player, let path = currentPath, (old is EQPlayback) != Equalizer.active else { return }
        let gen = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = Self.open(URL(fileURLWithPath: path))
            DispatchQueue.main.async { [weak self] in
                guard let self, let loaded, gen == self.generation, self.player === old else { return }
                loaded.finished = { [weak self, weak loaded] in if let self, let loaded { self.didFinish(loaded) } }
                loaded.currentTime = old.currentTime; loaded.volume = old.volume
                old.finished = nil; old.stop()
                self.player = loaded
                if !self.isPaused { loaded.play() }
            }
        }
    }

    /// Artwork for songs whose file has none (the era's art from juicewrldapi.com).
    func setFallbackArtwork(_ image: NSImage, for path: String) {
        guard path == currentPath, !hasOwnCover else { return }
        coverImage = image
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
    private var player: Playback?
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
    /// The Player tab's Up next list: drag to reorder, or take one out.
    func moveUpNext(from: IndexSet, to: Int) { upNext.move(fromOffsets: from, toOffset: to); publish() }
    func removeUpNext(at k: Int) { guard upNext.indices.contains(k) else { return }; upNext.remove(at: k); publish() }

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
        coverImage = nil
        publish()
    }

    /// Pausing and resuming fade over a moment (Settings > Playback), so the music doesn't cut off.
    static var fadePause: Bool { UserDefaults.standard.object(forKey: "fadePause") as? Bool ?? true }
    private static let pauseFade = 0.35
    func pause() {
        guard let p = player else { return }
        isPaused = true; publish()
        guard Self.fadePause else { p.pause(); return }
        p.setVolume(0, fadeDuration: Self.pauseFade)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pauseFade) { [weak self] in
            guard let self, self.isPaused, self.player === p else { return }
            p.pause(); p.volume = self.loud // ready for the next resume
        }
    }
    func resume() {
        isPaused = false
        guard let player else { next(); return }
        if Self.fadePause { player.volume = 0; player.play(); player.setVolume(loud, fadeDuration: Self.pauseFade) } else { player.play() }
        publish()
    }
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

    /// Every play (time and path, a line each), for "your listening" in Stats, in plays.tsv like the Windows app. All of
    /// them: the list in the app's settings this replaces kept only the newest 5,000, so the year's totals came out short.
    private static let playsFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/JuiceTracker/\(Bundle.main.bundleIdentifier ?? "com.hb4delirious.JuiceTracker")/plays.tsv")
    static func logPlay(_ path: String) {
        movePlaysToFile()
        appendPlays("\(Int(Date().timeIntervalSince1970))\t\(path)\n")
    }
    static var playLog: [(path: String, at: Date)] {
        movePlaysToFile()
        return Engine.parsePlays((try? String(contentsOf: playsFile, encoding: .utf8)) ?? "")
    }
    private static func appendPlays(_ text: String) {
        try? FileManager.default.createDirectory(at: playsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: playsFile) { h.seekToEndOfFile(); h.write(Data(text.utf8)); h.closeFile() }
        else { try? Data(text.utf8).write(to: playsFile) }
    }
    /// Plays logged before (in the app's settings) move to the file once, oldest first.
    private static func movePlaysToFile() {
        guard let old = UserDefaults.standard.array(forKey: "playLog") as? [[Any]] else { return }
        let lines = old.compactMap { e -> String? in
            guard e.count == 2, let p = e[0] as? String, let t = e[1] as? Double else { return nil }
            return "\(Int(t))\t\(p)\n"
        }
        let existing = (try? String(contentsOf: playsFile, encoding: .utf8)) ?? ""
        try? FileManager.default.createDirectory(at: playsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? Data((lines.joined() + existing).utf8).write(to: playsFile, options: .atomic)) != nil else { return } // kept in settings until it's safely in the file
        UserDefaults.standard.removeObject(forKey: "playLog")
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
            old.finished = nil // its end isn't "the song finished" any more
            old.setVolume(0, fadeDuration: fade)
            DispatchQueue.main.asyncAfter(deadline: .now() + fade) { old.stop() }
        } else { player?.stop() }
        generation += 1
        let gen = generation
        // Opening a file on a network drive can take seconds; keep it off the main thread.
        DispatchQueue.global(qos: .utility).async {
            let loaded = Self.open(item.url)
            let cover = loaded == nil ? nil : Self.cover(of: item.url)
            // Only a level measured earlier: measuring reads the file, and on a network drive that would hold up the start
            // (a crossfade would dip to silence). A new file is measured once it plays.
            let known = loaded == nil ? 1 : Self.gain(for: item.url, measure: false)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                guard let loaded else { self.next(failures: failures + 1); return }
                loaded.finished = { [weak self, weak loaded] in if let self, let loaded { self.didFinish(loaded) } }
                loaded.volume = 0
                loaded.play()
                self.gain = known ?? 1
                loaded.setVolume(self.loud, fadeDuration: fade > 0 ? fade : 3)
                self.player = loaded
                if known == nil { // measure now, then glide to the matched level
                    DispatchQueue.global(qos: .utility).async {
                        let g = Self.gain(for: item.url, measure: true) ?? 1
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.player === loaded, self.gain != g else { return }
                            self.gain = g
                            loaded.setVolume(self.loud, fadeDuration: max(1, fade))
                        }
                    }
                }
                self.crossfading = false
                self.title = item.title
                self.currentPath = item.url.path
                self.hasOwnCover = cover != nil
                self.coverImage = cover
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

    /// The song played to its end (or a damaged file stopped partway): the next one, rather than going quiet.
    private func didFinish(_ finished: Playback) {
        guard finished === player else { return }
        if sleepAtEnd { sleepAtEnd = false; isPaused = true; publish(); return } // paused; Play starts the song again
        player = nil
        if !items.isEmpty || !upNext.isEmpty { next() } else { title = nil; publish() }
    }

}
