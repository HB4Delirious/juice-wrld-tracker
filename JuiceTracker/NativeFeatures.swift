import AppKit
import AVFoundation
import SwiftUI

// Ratings, rarity, the year in review, the lyrics window and the drive comparison.

// MARK: - Ratings

/// 1–5 hearts for a song (click the same heart again to clear).
struct RatingHearts: View {
    let id: String
    @ObservedObject private var store = NativeStore.shared // redraws when a rating changes
    var size: CGFloat = 16

    var body: some View {
        let rating = EngineState.shared.ratings[id] ?? 0
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { n in
                Button { EngineState.shared.setRating(id, n == rating ? 0 : n) } label: {
                    Image(systemName: n <= rating ? "heart.fill" : "heart").font(.system(size: size))
                        .foregroundColor(n <= rating ? JT.missing : JT.muted.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(n == rating ? "Clear the rating" : "\(n) \(n == 1 ? "heart" : "hearts")")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue(rating == 0 ? "Not rated" : "\(rating) of 5 hearts")
        .accessibilityAdjustableAction { d in
            if d == .increment { EngineState.shared.setRating(id, min(5, rating + 1)) }
            if d == .decrement { EngineState.shared.setRating(id, max(0, rating - 1)) }
        }
    }
}

// MARK: - Rarity

/// "Grail" or "Rare" (unreleased with no file on the site), or nothing.
struct RarityChip: View {
    let song: Song
    var body: some View {
        let state = EngineState.shared
        if state.catalog.indices.contains(song.i), let r = Engine.rarity(state.catalog[song.i], owned: song.o) {
            Text(r.uppercased()).font(JT.body(11, .bold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .foregroundColor(r == "Grail" ? JT.night : JT.mist)
                .background(Capsule().fill(r == "Grail" ? JT.yellowGold : JT.raise))
                .help(r == "Grail" ? "Unreleased, no file on the site, and you have it" : "Unreleased, and the site has no file for it")
        }
    }
}
extension JT { static let yellowGold = Color(red: 1, green: 0.85, blue: 0.3) }

// MARK: - Year in review

/// Your year so far from the app's play history: plays, time listened, top songs and eras, and the busiest month.
struct YearInReviewSection: View {
    @ObservedObject private var store = NativeStore.shared
    @State private var r: Review?

    struct Review { var plays = 0, minutes = 0; var top: [(String, Int)] = [], eras: [(String, Int)] = []; var month = "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your \(String(Calendar.current.component(.year, from: Date()))) so far").font(.headline)
                Spacer()
                if let r, r.plays > 0 {
                    Menu("Wrapped picture") {
                        Button("Save picture…") { if let png = wrapped(r) { _ = Files.save(png, name: "Juice WRLD \(year) wrapped.png", type: .png) } }
                        Button("Copy picture") { if let png = wrapped(r), let img = NSImage(data: png) { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([img]) } }
                    }
                    .fixedSize()
                }
            }
            if let r, r.plays > 0 {
                Text(summary(r))
                HStack(alignment: .top, spacing: 30) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Top songs").font(.subheadline.bold())
                        ForEach(Array(r.top.enumerated()), id: \.offset) { n, t in row(n, t.0, t.1) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Top eras").font(.subheadline.bold())
                        ForEach(Array(r.eras.enumerated()), id: \.offset) { n, t in row(n, t.0, t.1) }
                    }
                }
                .font(.callout)
            } else {
                Text("Nothing played in the app this year yet.").foregroundColor(JT.muted)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).doodled(14)
        .task(id: store.version) { r = review(await Task.detached { AmbientPlayer.playLog }.value) } // read off the main thread
    }

    private var year: String { String(Calendar.current.component(.year, from: Date())) }
    /// Your year as a picture (1080 × 1350) to share.
    private func wrapped(_ r: Review) -> Data? {
        let host = NSHostingView(rootView: WrappedCard(year: year, r: r, time: time(r)))
        host.frame = NSRect(x: 0, y: 0, width: 1080, height: 1350)
        return snapshot(host)
    }
    private func time(_ r: Review) -> String { r.minutes >= 120 ? "\((r.minutes / 60).formatted()) hours" : "\(r.minutes) minutes" }

    private func row(_ n: Int, _ name: String, _ plays: Int) -> some View {
        HStack(spacing: 8) { Text("\(n + 1). \(name)").lineLimit(1); Text("\(plays)").foregroundColor(JT.muted) }
    }

    private func summary(_ r: Review) -> String {
        let month = r.month.isEmpty ? "" : " Your busiest month was \(r.month)."
        return "\(r.plays.formatted()) plays, about \(time(r)) of Juice WRLD.\(month)"
    }

    private func review(_ all: [(path: String, at: Date)]) -> Review {
        let cal = Calendar.current, year = cal.component(.year, from: Date())
        let log = all.filter { cal.component(.year, from: $0.at) == year }
        guard !log.isEmpty else { return Review() }
        let catalog = EngineState.shared.catalog
        let paths = Array(Set(log.map(\.path))), songs = EngineRouter.songsFor(paths: paths)
        let songFor = Dictionary(uniqueKeysWithValues: zip(paths, songs))
        var out = Review(plays: log.count)
        var bySong: [Int: Int] = [:], byEra: [String: Int] = [:], byMonth: [Int: Int] = [:], seconds = 0.0
        for e in log {
            byMonth[cal.component(.month, from: e.at), default: 0] += 1
            guard let i = songFor[e.path], i >= 0, catalog.indices.contains(i) else { seconds += 180; continue } // unknown: a typical song
            bySong[i, default: 0] += 1
            byEra[Engine.eraName(catalog[i]), default: 0] += 1
            seconds += Engine.lengthSeconds(catalog[i].length) ?? 180
        }
        out.minutes = Int(seconds / 60)
        out.top = bySong.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5).map { (catalog[$0.key].name, $0.value) }
        out.eras = byEra.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3).map { ($0.key, $0.value) }
        if let m = byMonth.max(by: { $0.value < $1.value })?.key, byMonth.count > 1 { out.month = cal.monthSymbols[m - 1] }
        return out
    }
}

private struct WrappedCard: View {
    let year: String
    let r: YearInReviewSection.Review
    let time: String
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 7 / 255, green: 4 / 255, blue: 15 / 255), Color(red: 29 / 255, green: 11 / 255, blue: 64 / 255), Color(red: 74 / 255, green: 18 / 255, blue: 80 / 255)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 34) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("My \(year) in").font(JT.body(34, .semibold)).foregroundColor(.white.opacity(0.7))
                    Text("Juice WRLD").font(JT.marker(96)).foregroundColor(JT.lavender)
                }
                HStack(spacing: 60) {
                    stat("\(r.plays.formatted())", "plays")
                    stat(time, "listened")
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Top songs").font(JT.body(30, .bold)).foregroundColor(.white.opacity(0.6))
                    ForEach(Array(r.top.enumerated()), id: \.offset) { n, t in
                        Text("\(n + 1). \(t.0)").font(JT.body(40, .heavy)).foregroundColor(.white).lineLimit(1)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Top eras").font(JT.body(30, .bold)).foregroundColor(.white.opacity(0.6))
                    Text(r.eras.map(\.0).joined(separator: " · ")).font(JT.body(38, .heavy)).foregroundColor(JT.lavender).lineLimit(2)
                }
                if !r.month.isEmpty { Text("Busiest month: \(r.month)").font(JT.body(30, .semibold)).foregroundColor(.white.opacity(0.75)) }
            }
            .padding(.horizontal, 90).frame(width: 1080, alignment: .leading)
            VStack { Spacer(); Text("Juice Tracker").font(JT.marker(22)).foregroundColor(.white.opacity(0.35)).padding(.bottom, 36) }
        }
        .frame(width: 1080, height: 1350).clipped()
    }
    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(JT.body(64, .heavy)).foregroundColor(.white)
            Text(label).font(JT.body(28, .semibold)).foregroundColor(.white.opacity(0.6))
        }
    }
}

// MARK: - Lyrics

/// A big window with the words of the song playing: the line being sung large, the ones around it dimmed (or the
/// plain lyrics when the site has no timing). Shown live from juicewrldapi.com, never saved.
enum LyricsWindow {
    private static var window: NSWindow?
    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Lyrics"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: LyricsView())
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct LyricsView: View {
    @ObservedObject private var now = NowPlaying.shared

    var body: some View {
        ZStack {
            SkyBackground().ignoresSafeArea()
            if let x = now.extras, !x.synced.isEmpty {
                let n = now.lineIndex ?? -1
                VStack(spacing: 18) {
                    ForEach(max(0, n - 2)...min(x.synced.count - 1, max(n, 0) + 3), id: \.self) { k in
                        Text(x.synced[k].line.isEmpty ? "♪" : x.synced[k].line)
                            .font(k == n ? JT.marker(40) : JT.body(22))
                            .foregroundColor(k == n ? JT.mist : JT.muted.opacity(k < n ? 0.35 : 0.6))
                            .multilineTextAlignment(.center)
                            .shadow(color: k == n ? JT.lavender.opacity(0.6) : .clear, radius: 12)
                    }
                }
                .padding(40)
                .animation(.easeOut(duration: 0.3), value: n)
            } else if let x = now.extras, !x.lyrics.isEmpty {
                ScrollView { Text(x.lyrics).font(JT.body(20)).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(40) }
            } else {
                Text(now.song == nil ? "Play a song to see its lyrics." : "The site has no lyrics for this song.").font(JT.body(18)).foregroundColor(JT.muted)
            }
        }
        .overlay(alignment: .top) {
            if let s = now.song { Text(s.n).font(JT.marker(20)).foregroundColor(JT.lavender).padding(.top, 34) }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 480, minHeight: 360)
    }
}

// MARK: - Compare with another drive

/// Scans a second folder (a backup drive) and shows which songs are only on one of them.
struct DriveCompareCard: View {
    @ObservedObject private var store = NativeStore.shared
    @State private var result: EngineLibrary.Comparison?
    @State private var running = false
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compare with another drive").font(.headline)
            Text("Scans another folder, like a backup drive, and shows the songs that are only on one of them. Nothing on either drive changes.")
                .font(.caption).foregroundColor(JT.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(running ? "Scanning…" : "Choose a folder to compare…") { pick() }.disabled(running || EngineLibrary.shared.root == nil)
                if !status.isEmpty { Text(status).font(.caption).foregroundColor(JT.muted) }
            }
            if let r = result {
                Text("\(r.both.formatted()) songs on both. \(r.onlyHere.count.formatted()) only here, \(r.onlyThere.count.formatted()) only on “\(r.drive)”.").font(.callout)
                list("Only here (not backed up)", r.onlyHere)
                list("Only on “\(r.drive)”", r.onlyThere)
                let fetchable = r.onlyThere.filter { store.songs.indices.contains($0) && store.songs[$0].f }
                if !fetchable.isEmpty {
                    Button("Download the \(fetchable.count) missing here from the site") { EngineDownloads.shared.add(fetchable.map { store.songs[$0].s.id }) }
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading).doodled(14)
    }

    @ViewBuilder private func list(_ title: String, _ songs: [Int]) -> some View {
        if !songs.isEmpty {
            Text(title).font(.caption.bold()).padding(.top, 4)
            Text(songs.prefix(12).compactMap { store.songs.indices.contains($0) ? store.songs[$0].n : nil }.joined(separator: ", ") + (songs.count > 12 ? ", and \(songs.count - 12) more" : ""))
                .font(.caption).foregroundColor(JT.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Compare"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        running = true; result = nil
        Task {
            let r = await EngineLibrary.shared.compare(with: url) { done, total in status = "Reading \(done.formatted()) of \(total.formatted())…" }
            result = r; running = false; status = ""
        }
    }
}

// MARK: - Seek bar and sleep timer

/// Where the playing song is, with a slider to move in it (sidebar and mini player).
struct SeekBar: View {
    @State private var dragging: Double?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let p = AmbientPlayer.shared, length = max(p.duration, 1)
            HStack(spacing: 6) {
                Text(Engine.fmtTime(dragging ?? p.currentTime)).monospacedDigit()
                Slider(value: Binding(get: { dragging ?? p.currentTime }, set: { dragging = $0 }), in: 0...length) { editing in
                    if !editing, let t = dragging { p.seek(to: t); dragging = nil }
                }
                .controlSize(.mini)
                .accessibilityLabel("Position in the song")
                Text(Engine.fmtTime(p.duration)).monospacedDigit()
            }
            .font(.caption2).foregroundColor(JT.muted)
            .disabled(p.duration == 0)
        }
    }
}

/// Stop the music after a while, or when this song ends (it fades out over 8 seconds).
struct SleepMenu: View {
    var body: some View {
        let p = AmbientPlayer.shared
        Menu {
            ForEach([15, 30, 60], id: \.self) { m in Button("In \(m) minutes") { p.sleep(minutes: m) } }
            Button("At the end of this song") { p.sleep(minutes: nil, atEnd: true) }
            if p.sleepAt != nil || p.sleepAtEnd { Divider(); Button("Turn off the sleep timer") { p.sleep(minutes: nil) } }
        } label: {
            Image(systemName: p.sleepAt != nil || p.sleepAtEnd ? "moon.zzz.fill" : "moon.zzz")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(p.sleepAt.map { "Sleep timer: stops at \($0.formatted(date: .omitted, time: .shortened))" } ?? (p.sleepAtEnd ? "Sleep timer: stops after this song" : "Sleep timer"))
        .accessibilityLabel("Sleep timer")
    }
}

// MARK: - Versions and A/B compare

/// The other versions of a song (same name once version marks and brackets are dropped), side by side, with
/// whether you have each, and a button to compare two you have.
struct VersionsList: View {
    let song: Song
    @ObservedObject private var store = NativeStore.shared

    var body: some View {
        let key = Engine.normalize(song.n)
        let others = store.songs.filter { $0.i != song.i && Engine.normalize($0.n) == key }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Other versions (\(others.count))").font(.headline)
                    Spacer()
                    let owned = ([song] + others).filter(\.o)
                    if owned.count >= 2 { Button("Compare A/B") { ABWindow.show(owned, start: song.o ? song : owned[0]) } }
                    let missing = others.filter { !$0.o && $0.f }
                    if !missing.isEmpty { Button("Download \(missing.count) missing") { EngineDownloads.shared.add(missing.map(\.s.id)) } }
                }
                ForEach(others) { v in
                    HStack {
                        Button(v.n) { store.openSong = v }.buttonStyle(.link)
                        Text(v.c).foregroundColor(JT.muted)
                        Spacer()
                        Text(v.o ? "In library" : v.f ? "On the site" : "No file").foregroundColor(v.o ? JT.have : JT.muted)
                    }
                    .font(.callout)
                }
            }
            .padding(.top, 6)
        }
    }
}

/// Plays two versions together, in step, and switches between them instantly. The background music pauses meanwhile.
final class ABCompare: ObservableObject {
    @Published var a: Song
    @Published var b: Song
    @Published private(set) var onB = false
    @Published private(set) var playing = false
    private var pa: AVAudioPlayer?, pb: AVAudioPlayer?
    private var musicWasPlaying = false

    init(a: Song, b: Song) { self.a = a; self.b = b }

    var position: TimeInterval { (onB ? pb : pa)?.currentTime ?? 0 }
    var length: TimeInterval { max(pa?.duration ?? 0, pb?.duration ?? 0) }

    @MainActor func load() {
        stop()
        let library = EngineLibrary.shared
        pa = library.playableURL(a.i).flatMap { try? AVAudioPlayer(contentsOf: $0) }
        pb = library.playableURL(b.i).flatMap { try? AVAudioPlayer(contentsOf: $0) }
        pa?.prepareToPlay(); pb?.prepareToPlay()
        apply()
    }
    func toggle() {
        guard let pa, let pb else { return }
        if playing { pa.pause(); pb.pause(); playing = false; return }
        if !musicWasPlaying && AmbientPlayer.shared.isPlaying { musicWasPlaying = true; AmbientPlayer.shared.pause() }
        let t = pa.deviceCurrentTime + 0.05 // start both on the same audio clock tick, so they stay in step
        pa.play(atTime: t); pb.play(atTime: t)
        playing = true
    }
    func flip() { onB.toggle(); apply() }
    func seek(_ t: TimeInterval) {
        pa?.currentTime = min(t, pa?.duration ?? 0); pb?.currentTime = min(t, pb?.duration ?? 0)
        if playing { playing = false; toggle() }
    }
    private func apply() { pa?.volume = onB ? 0 : 0.8; pb?.volume = onB ? 0.8 : 0 }
    func stop() {
        pa?.stop(); pb?.stop(); playing = false
        if musicWasPlaying { musicWasPlaying = false; AmbientPlayer.shared.resume() }
    }
}

enum ABWindow {
    private static var window: NSWindow?
    private static var closing: NSObjectProtocol?
    @MainActor static func show(_ versions: [Song], start: Song) {
        window?.close()
        if let closing { NotificationCenter.default.removeObserver(closing) }
        let other = versions.first { $0.i != start.i } ?? start
        let ab = ABCompare(a: start, b: other)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Compare versions"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: ABView(versions: versions, ab: ab))
        // A closed window stays in memory, so SwiftUI's onDisappear never runs: stop the players when it closes.
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in ab.stop() }
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}

private struct ABView: View {
    let versions: [Song]
    @StateObject var ab: ABCompare

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                side("A", $ab.a, on: !ab.onB)
                side("B", $ab.b, on: ab.onB)
            }
            Button { ab.flip() } label: {
                Text("Switch to \(ab.onB ? "A" : "B")").frame(maxWidth: .infinity)
            }
            .controlSize(.large).keyboardShortcut(.tab, modifiers: [])
            HStack {
                Button { ab.toggle() } label: { Image(systemName: ab.playing ? "pause.fill" : "play.fill").frame(width: 24) }
                    .keyboardShortcut(.space, modifiers: []).accessibilityLabel(ab.playing ? "Pause" : "Play")
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Slider(value: Binding(get: { ab.position }, set: { ab.seek($0) }), in: 0...max(ab.length, 1))
                        .accessibilityLabel("Position")
                }
            }
            Text("Space plays and pauses; Tab switches. Both play together from the same point, so you hear the difference right away.")
                .font(.caption).foregroundColor(JT.muted)
        }
        .padding(20)
        .frame(width: 520)
        .preferredColorScheme(.dark)
        .task { ab.load() }
        .onChange(of: ab.a) { _ in ab.load() }
        .onChange(of: ab.b) { _ in ab.load() }
    }

    private func side(_ label: String, _ pick: Binding<Song>, on: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(JT.marker(28)).foregroundColor(on ? JT.lavender : JT.muted)
            Picker("", selection: pick) { ForEach(versions) { Text($0.n).tag($0) } }.labelsHidden()
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).stroke(on ? JT.lavender : JT.line, lineWidth: on ? 2 : 1))
    }
}

/// Names as links, a few to a line (the song card's credits).
struct FlowNames: View {
    let names: [String]
    let open: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(stride(from: 0, to: names.count, by: 3)), id: \.self) { start in
                HStack(spacing: 10) {
                    ForEach(names[start..<min(start + 3, names.count)], id: \.self) { n in Button(n) { open(n) }.buttonStyle(.link).help("See all of \(n)'s songs") }
                }
            }
        }
    }
}

// MARK: - Listening calendar and collection gaps

/// Plays per day over the last year, GitHub style, with your current and longest streaks.
struct ListeningCalendar: View {
    @ObservedObject private var store = NativeStore.shared

    var body: some View {
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        var perDay: [Date: Int] = [:]
        for e in AmbientPlayer.playLog { perDay[cal.startOfDay(for: e.at), default: 0] += 1 }
        // 53 weeks, ending with this week; columns are weeks, rows Sunday to Saturday
        let weekday = cal.component(.weekday, from: today) - 1
        let start = cal.date(byAdding: .day, value: -(52 * 7 + weekday), to: today)!
        let top = max(perDay.values.max() ?? 1, 1)
        let (current, longest) = streaks(perDay, today: today)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Listening calendar").font(.headline)
                Spacer()
                Text("Streak: \(current) \(current == 1 ? "day" : "days") · longest \(longest)").font(.caption).foregroundColor(JT.muted)
            }
            HStack(alignment: .top, spacing: 3) {
                ForEach(0..<53, id: \.self) { w in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { d in
                            let day = cal.date(byAdding: .day, value: w * 7 + d, to: start)!
                            let n = perDay[day] ?? 0
                            RoundedRectangle(cornerRadius: 2)
                                .fill(day > today ? Color.clear : n == 0 ? JT.raise.opacity(0.6) : JT.lavender.opacity(0.25 + 0.75 * Double(n) / Double(top)))
                                .frame(width: 11, height: 11)
                                .help("\(day.formatted(date: .abbreviated, time: .omitted)): \(n) \(n == 1 ? "play" : "plays")")
                        }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Listening calendar: \(perDay.count) days with plays in the last year, current streak \(current) days")
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).doodled(14)
    }

    private func streaks(_ days: [Date: Int], today: Date) -> (Int, Int) {
        let cal = Calendar.current, sorted = days.keys.sorted()
        var longest = 0, run = 0, prev: Date?
        for d in sorted {
            run = prev.flatMap { cal.dateComponents([.day], from: $0, to: d).day } == 1 ? run + 1 : 1
            longest = max(longest, run); prev = d
        }
        var current = 0, d = days[today] != nil ? today : cal.date(byAdding: .day, value: -1, to: today)! // today can still come
        while days[d] != nil { current += 1; d = cal.date(byAdding: .day, value: -1, to: d)! }
        return (current, longest)
    }
}

/// Every month from 2014 to 2024: how much of what was recorded then you have. Pale cells are where to dig.
struct GapsHeatmap: View {
    let songs: [Song]
    @State private var picked: Int?

    var body: some View {
        var total: [Int: Int] = [:], have: [Int: Int] = [:]
        for s in songs { if let m = s.s.m { total[m, default: 0] += 1; if s.o { have[m, default: 0] += 1 } } }
        let months = Calendar.current.shortMonthSymbols
        return VStack(alignment: .leading, spacing: 8) {
            Text("Gaps by month recorded").font(.headline)
            Text("Each square is a month; the brighter it is, the more of that month's recordings you have. Click one to see its songs.").font(.caption).foregroundColor(JT.muted)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Text("").frame(width: 38)
                    ForEach(months, id: \.self) { Text($0).font(.system(size: 9)).foregroundColor(JT.muted).frame(width: 30) }
                }
                ForEach(2014...2024, id: \.self) { y in
                    HStack(spacing: 3) {
                        Text(String(y)).font(.caption.monospacedDigit()).foregroundColor(JT.muted).frame(width: 38, alignment: .leading)
                        ForEach(0..<12, id: \.self) { m in
                            let key = y * 12 + m, t = total[key] ?? 0, h = have[key] ?? 0
                            Button { picked = picked == key ? nil : key } label: {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(t == 0 ? Color.clear : h == 0 ? JT.missing.opacity(0.35) : JT.have.opacity(0.2 + 0.8 * Double(h) / Double(t)))
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(picked == key ? JT.mist : JT.line, lineWidth: picked == key ? 2 : t == 0 ? 0.5 : 0))
                                    .frame(width: 30, height: 16)
                            }
                            .buttonStyle(.plain).disabled(t == 0)
                            .help(t == 0 ? "\(months[m]) \(y): nothing recorded" : "\(months[m]) \(y): \(h) of \(t)")
                            .accessibilityLabel(t == 0 ? "\(months[m]) \(y), nothing recorded" : "\(months[m]) \(y), \(h) of \(t)")
                        }
                    }
                }
            }
            if let picked {
                let list = songs.filter { $0.s.m == picked }.sorted { $0.o == $1.o ? $0.n < $1.n : !$0.o }
                Text("\(months[picked % 12]) \(picked / 12): \(list.filter(\.o).count) of \(list.count)").font(.subheadline.bold()).padding(.top, 6)
                LazyVStack(spacing: 0) { ForEach(list) { s in SongRow(song: s, open: { NativeStore.shared.openSong = s }, compact: true) } }.doodled(12)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).doodled(14)
    }
}
