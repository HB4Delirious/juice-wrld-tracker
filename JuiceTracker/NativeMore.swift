import AppIntents
import AppKit
import CoreSpotlight
import SwiftUI

// More native features: lyrics (synced while playing), era artwork, instrumentals, the mini player, the visualizer,
// listening stats (Plex and the app's own play history), Spotlight and Shortcuts.

// MARK: - Song extras from juicewrldapi.com (lyrics, artwork, instrumentals, snippets)

struct SongExtras {
    var lyrics = ""
    var synced: [(at: Double, line: String)] = []
    var image: URL?
    var instrumentals = ""
    var snippets: [String] = []

    /// The index of the synced line being sung at `time`, or nil before the first.
    func line(at time: Double) -> Int? { synced.lastIndex { $0.at <= time + 0.15 } }
}

@MainActor final class Extras: ObservableObject {
    static let shared = Extras()
    private var cache: [String: SongExtras] = [:]
    private var images: [URL: NSImage] = [:]

    func extras(for id: String) async -> SongExtras? {
        if let hit = cache[id] { return hit }
        guard let url = URL(string: "https://juicewrldapi.com/juicewrld/songs/\(id)/"),
              let (data, response) = try? await URLSession.shared.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var x = SongExtras()
        x.lyrics = (json["lyrics"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        x.synced = Self.parseSynced(json["synced_lyrics"] as? String ?? "")
        if let path = json["image_url"] as? String, !path.isEmpty { x.image = URL(string: path, relativeTo: URL(string: "https://juicewrldapi.com"))?.absoluteURL }
        x.instrumentals = [json["instrumentals"] as? String ?? "", json["instrumental_names"] as? String ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && $0 != "N/A" }.joined(separator: "\n")
        x.snippets = (json["snippets"] as? [Any] ?? []).map { "\($0)" }
        cache[id] = x
        return x
    }

    func image(_ url: URL) async -> NSImage? {
        if let hit = images[url] { return hit }
        guard let (data, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: data) else { return nil }
        images[url] = img
        return img
    }

    /// "[1:23.45] line" → (83.45, "line"); lines without a time are skipped.
    static func parseSynced(_ text: String) -> [(at: Double, line: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
            let stamp = line[line.index(after: line.startIndex)..<close].split(separator: ":")
            guard stamp.count == 2, let m = Double(stamp[0]), let s = Double(stamp[1]) else { return nil }
            return (m * 60 + s, line[line.index(after: close)...].trimmingCharacters(in: .whitespaces))
        }
    }
}

// MARK: - What's playing (song, lyrics line, loudness)

@MainActor final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()
    @Published var song: Song?
    @Published var extras: SongExtras?
    @Published var lineIndex: Int?
    @Published var level: Float = 0
    private var timer: Timer?
    private var path: String?

    private init() {
        NotificationCenter.default.addObserver(forName: AmbientPlayer.changed, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.tickWhenNeeded() } }
        }
    }

    /// Finds the catalog song for the file playing, and its lyrics and artwork.
    func refresh() async {
        let p = AmbientPlayer.shared
        defer { WidgetFeed.update() }
        if p.currentPath != path {
            path = p.currentPath
            song = nil; extras = nil; lineIndex = nil
            if let path {
                let raw = await NativeStore.shared.act("songForPath", -1, ["path": path])
                if let i = Int(raw), NativeStore.shared.songs.indices.contains(i) {
                    let s = NativeStore.shared.songs[i]
                    song = s
                    DiscordStatus.shared.era = s.e; DiscordStatus.shared.refresh()
                    extras = await Extras.shared.extras(for: s.s.id)
                    if let url = extras?.image, let img = await Extras.shared.image(url) { p.setFallbackArtwork(img, for: path) }
                }
            }
        }
        let row = p.isPlaying ? song?.i : nil
        if PlayingRow.shared.index != row { PlayingRow.shared.index = row }
        tickWhenNeeded()
    }

    /// Ticks (lyrics line, loudness) only while music plays and the app is in front: nothing to see otherwise.
    private func tickWhenNeeded() {
        let needed = AmbientPlayer.shared.isPlaying && NSApp.isActive
        if needed, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        } else if !needed {
            timer?.invalidate(); timer = nil; level = 0
            SkyNSView.current?.setGlow(0)
        }
    }

    private func tick() {
        let p = AmbientPlayer.shared
        level = p.level()
        SkyNSView.current?.setGlow(level)
        if let x = extras, !x.synced.isEmpty {
            let n = x.line(at: p.currentTime)
            if n != lineIndex { lineIndex = n }
        }
    }

    var currentLine: String? {
        guard let x = extras, let n = lineIndex, x.synced.indices.contains(n) else { return nil }
        return x.synced[n].line
    }
}

/// Five bars that move with the music (the sidebar player and the mini player).
struct Visualizer: View {
    @ObservedObject private var now = NowPlaying.shared
    var height: CGFloat = 16
    private let weights: [CGFloat] = [0.55, 0.9, 1, 0.75, 0.6]
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { n in
                Capsule().fill(JT.lavender)
                    .frame(width: 3, height: max(3, height * min(1, CGFloat(now.level) * weights[n] * 1.25 + (now.level > 0 ? 0.08 * CGFloat((n * 7 + Int(now.level * 40)) % 3) : 0))))
            }
        }
        .frame(height: height, alignment: .bottom)
        .animation(.easeOut(duration: 0.12), value: now.level)
    }
}

// MARK: - Song card extras

struct SongExtrasView: View {
    let song: Song
    @ObservedObject private var now = NowPlaying.shared
    @State private var x: SongExtras?
    @State private var art: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let art {
                HStack(spacing: 12) {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill).frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
                    Text("Era artwork from juicewrldapi.com").font(.caption).foregroundColor(JT.muted)
                }
            }
            if let x, !x.instrumentals.isEmpty {
                Text("Instrumentals").font(.headline).padding(.top, 6)
                Text(x.instrumentals).foregroundColor(JT.muted).textSelection(.enabled)
            }
            if let x, !x.snippets.isEmpty {
                Text("Snippets").font(.headline).padding(.top, 6)
                ForEach(x.snippets, id: \.self) { Text($0).font(.caption).foregroundColor(JT.muted) }
            }
            if let x, !x.synced.isEmpty || !x.lyrics.isEmpty {
                let playing = now.song?.i == song.i
                HStack { Text("Lyrics").font(.headline); if playing && !x.synced.isEmpty { Label("in time with the music", systemImage: "waveform").font(.caption).foregroundColor(JT.lavender) } }
                    .padding(.top, 6)
                if !x.synced.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(x.synced.enumerated()), id: \.offset) { n, l in
                                    Text(l.line.isEmpty ? " " : l.line)
                                        .font(JT.body(playing && now.lineIndex == n ? 17 : 15, playing && now.lineIndex == n ? .semibold : .regular))
                                        .foregroundColor(playing && now.lineIndex == n ? JT.mist : JT.muted.opacity(playing ? 0.7 : 1)).id(n)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 220)
                        .onChange(of: now.lineIndex) { n in if playing, let n { withAnimation { proxy.scrollTo(n, anchor: .center) } } }
                    }
                } else {
                    Text(x.lyrics).foregroundColor(JT.muted).textSelection(.enabled)
                }
            }
        }
        .task(id: song.i) {
            x = await Extras.shared.extras(for: song.s.id)
            if let url = x?.image { art = await Extras.shared.image(url) }
        }
    }
}

// MARK: - Mini player (a small window that stays on top)

struct MiniPlayerView: View {
    @ObservedObject private var now = NowPlaying.shared
    @State private var title: String?
    @State private var paused = false
    @State private var art: NSImage?
    private let changed = NotificationCenter.default.publisher(for: AmbientPlayer.changed)

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let art { Image(nsImage: art).resizable().aspectRatio(contentMode: .fill) } else { Image("jt-logo").resizable() }
            }
            .frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title ?? "Not playing").font(JT.body(14, .semibold)).lineLimit(1)
                    Visualizer(height: 12)
                }
                Text(now.currentLine ?? (now.song?.e ?? "Juice WRLD")).font(JT.body(12)).foregroundColor(JT.muted).lineLimit(1)
                HStack(spacing: 14) {
                    Button { AmbientPlayer.shared.togglePause() } label: { Image(systemName: paused || title == nil ? "play.fill" : "pause.fill") }
                    Button { AmbientPlayer.shared.skip() } label: { Image(systemName: "forward.fill") }
                    Button { AppDelegate.shared?.showMainWindow() } label: { Image(systemName: "macwindow") }.help("Open Juice Tracker")
                    SeekBar()
                }
                .buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 320, height: 84)
        .background(LinearGradient(colors: [JT.night, Color(red: 42 / 255, green: 12 / 255, blue: 62 / 255)], startPoint: .top, endPoint: .bottom))
        .foregroundColor(JT.mist)
        .preferredColorScheme(.dark)
        .onReceive(changed) { _ in read() }
        .onAppear { read() }
        .task(id: now.extras?.image) { if let url = now.extras?.image { art = await Extras.shared.image(url) } else { art = nil } }
    }

    private func read() { title = AmbientPlayer.shared.title; paused = AmbientPlayer.shared.isPaused }
}

enum MiniPlayer {
    private static var panel: NSPanel?
    static func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 84), styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
            p.title = "Juice Tracker"
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.isFloatingPanel = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            p.isMovableByWindowBackground = true
            p.contentView = NSHostingView(rootView: MiniPlayerView())
            if !p.setFrameUsingName("MiniPlayer") { p.center() }
            p.setFrameAutosaveName("MiniPlayer")
            panel = p
        }
        panel?.orderFront(nil)
    }
}

// MARK: - Listening (Stats)

private struct PlexListening: Decodable { struct Top: Decodable, Hashable { let i: Int; let plays: Int }; struct EraPlays: Decodable, Hashable { let name: String; let plays: Int }
    let total: Int; let top: [Top]; let never: [Int]; let eras: [EraPlays]; let missing: Int }

struct ListeningSection: View {
    @ObservedObject private var store = NativeStore.shared
    @State private var plex: PlexListening?
    @State private var plexError = ""
    @State private var loadingPlex = false
    @State private var week: [(Song, Int)] = []
    @State private var allTime: [(Song, Int)] = []
    @State private var never: [Song] = []
    @State private var plays = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your listening in Juice Tracker").font(.headline)
            if plays == 0 {
                Text("Songs the app plays (background music, the player, trivia clips aside) are counted here.").font(.caption).foregroundColor(JT.muted)
            } else {
                Text("\(plays) plays so far.").foregroundColor(JT.muted)
                HStack(alignment: .top, spacing: 18) {
                    list("This week", week)
                    list("All time", allTime)
                }
                if !never.isEmpty {
                    Text("Owned but never played here (\(never.count))").font(.subheadline.bold())
                    Text(never.prefix(24).map(\.n).joined(separator: " · ") + (never.count > 24 ? " and \(never.count - 24) more" : ""))
                        .font(.caption).foregroundColor(JT.muted)
                }
            }

            Divider().overlay(JT.line)
            HStack {
                Text("Your listening in Plex").font(.headline)
                Spacer()
                Button(loadingPlex ? "Loading…" : plex == nil ? "Load play counts" : "Refresh") { Task { await loadPlex() } }.disabled(loadingPlex)
            }
            if !plexError.isEmpty { Text(plexError).font(.caption).foregroundColor(JT.missing) }
            if let p = plex {
                Text("\(p.total) plays in Plex. \(p.never.count) songs you own have never been played there.\(p.missing > 0 ? " \(p.missing) files aren't in Plex yet." : "")")
                    .foregroundColor(JT.muted)
                HStack(alignment: .top, spacing: 18) {
                    list("Most played", p.top.compactMap { t in store.songs.indices.contains(t.i) ? (store.songs[t.i], t.plays) : nil })
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Top eras by plays").font(.subheadline.bold())
                        ForEach(p.eras, id: \.self) { e in HStack { Text(e.name); Spacer(); Text("\(e.plays)").foregroundColor(JT.muted) }.font(.callout) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Play counts for your songs from your Plex server (set up in Settings, ⌘,).").font(.caption).foregroundColor(JT.muted)
            }
        }
        .padding(16).doodled(14)
        .task(id: store.version) { await loadOwn() }
    }

    private func list(_ title: String, _ items: [(Song, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.bold())
            if items.isEmpty { Text("Nothing yet.").font(.caption).foregroundColor(JT.muted) }
            ForEach(Array(items.prefix(10).enumerated()), id: \.offset) { n, item in
                Button { store.openSong = item.0 } label: {
                    HStack { Text("\(n + 1).").foregroundColor(JT.muted).frame(width: 22, alignment: .trailing); Text(item.0.n).lineLimit(1); Spacer(); Text("\(item.1)").foregroundColor(JT.muted) }
                        .font(.callout).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadOwn() async {
        let log = AmbientPlayer.playLog
        plays = log.count
        guard !log.isEmpty else { return }
        let paths = Array(Set(log.map(\.path)))
        let raw = await store.act("songsForPaths", -1, ["paths": paths])
        let idx = (try? JSONDecoder().decode([Int].self, from: Data(raw.utf8))) ?? []
        var songFor: [String: Int] = [:]
        for (n, p) in paths.enumerated() where n < idx.count && idx[n] >= 0 { songFor[p] = idx[n] }
        func ranked(_ entries: [(path: String, at: Date)]) -> [(Song, Int)] {
            var counts: [Int: Int] = [:]
            for e in entries { if let i = songFor[e.path] { counts[i, default: 0] += 1 } }
            return counts.sorted { $0.value > $1.value }.compactMap { store.songs.indices.contains($0.key) ? (store.songs[$0.key], $0.value) : nil }
        }
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        week = ranked(log.filter { $0.at > weekAgo })
        allTime = ranked(log)
        let neverRaw = await store.act("neverPlayed", -1, ["paths": paths])
        never = ((try? JSONDecoder().decode([Int].self, from: Data(neverRaw.utf8))) ?? []).compactMap { store.songs.indices.contains($0) ? store.songs[$0] : nil }
    }

    private func loadPlex() async {
        loadingPlex = true; plexError = ""
        do { plex = try JSONDecoder().decode(PlexListening.self, from: Data(try await store.tryAct("listening").utf8)) }
        catch { plexError = "Couldn't load play counts: \(error.localizedDescription)" }
        loadingPlex = false
    }
}

// MARK: - Spotlight: your songs show up in ⌘Space search

enum SpotlightIndex {
    private static var indexed: Set<String>? // song ids in the index; nil until the first update this launch
    static let prefix = "jt-song-"

    /// Indexes the songs you have (title, other titles, era): everything once per launch, then only what changed.
    static func update(_ songs: [Song]) {
        let owned = songs.filter(\.o), ids = Set(owned.map(\.s.id))
        guard ids != indexed else { return }
        let index = CSSearchableIndex.default()
        let old = indexed
        indexed = ids
        let items = owned.filter { old?.contains($0.s.id) != true }.map { s -> CSSearchableItem in
            let a = CSSearchableItemAttributeSet(contentType: .audio)
            a.title = s.n
            a.contentDescription = "Juice WRLD · \(s.e) · \(s.c)"
            a.keywords = ["Juice WRLD", s.e] + s.s.a
            a.artist = "Juice WRLD"
            return CSSearchableItem(uniqueIdentifier: prefix + s.s.id, domainIdentifier: "songs", attributeSet: a)
        }
        if let old {
            let gone = old.subtracting(ids).map { prefix + $0 }
            if !gone.isEmpty { index.deleteSearchableItems(withIdentifiers: gone, completionHandler: nil) }
            if !items.isEmpty { index.indexSearchableItems(items, completionHandler: nil) }
        } else { // first update: clear what an earlier launch left, then add everything
            index.deleteSearchableItems(withDomainIdentifiers: ["songs"]) { _ in index.indexSearchableItems(items, completionHandler: nil) }
        }
    }

    /// Opens the song a Spotlight result points to.
    @MainActor static func open(_ identifier: String) {
        guard identifier.hasPrefix(prefix) else { return }
        let id = String(identifier.dropFirst(prefix.count))
        AppDelegate.shared?.showMainWindow()
        if let s = NativeStore.shared.songs.first(where: { $0.s.id == id }) { NativeStore.shared.openSong = s }
        else { pending = id } // launched from Spotlight: the songs aren't loaded yet
    }
    static var pending: String?
}

// MARK: - Shortcuts and Siri

@available(macOS 13.0, *)
struct PlayEraIntent: AppIntent {
    static var title: LocalizedStringResource = "Play an Era"
    static var description = IntentDescription("Plays songs you have from one era in Juice Tracker (or every era).")
    static var openAppWhenRun = true
    @Parameter(title: "Era", description: "Leave empty for all eras") var era: String?
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = NativeStore.shared
        guard await store.ready() else { return .result(dialog: IntentDialog(stringLiteral: "Juice Tracker isn't ready yet. Try again in a moment.")) }
        let eras = EngineAmbient.eras
        guard !eras.isEmpty else { return .result(dialog: IntentDialog(stringLiteral: "There are no songs to play yet.")) }
        let spoken = (era ?? "").trimmingCharacters(in: .whitespaces)
        let fits = spoken.isEmpty ? [""] : EngineAmbient.erasNamed(spoken)
        guard fits.count == 1 else {
            let text = fits.isEmpty
                ? "There's no era called \(spoken) in your library. You have \(eras.prefix(8).joined(separator: ", "))\(eras.count > 8 ? ", and more" : "")."
                : "Which one: \(fits.prefix(6).joined(separator: ", "))?"
            return .result(dialog: IntentDialog(stringLiteral: text))
        }
        let picked = fits[0]
        EngineAmbient.setEra(picked)
        return .result(dialog: IntentDialog(stringLiteral: picked.isEmpty ? "Playing your songs." : "Playing songs from \(picked)."))
    }
}

@available(macOS 13.0, *)
struct WhatsPlayingIntent: AppIntent {
    static var title: LocalizedStringResource = "What's Playing in Juice Tracker"
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let p = AmbientPlayer.shared, title = p.title
        // Built as plain text first: older Xcode versions don't accept a computed string as a dialog.
        let text = title.map { p.isPlaying ? "\($0) by Juice WRLD." : "\($0) by Juice WRLD is paused." } ?? "Nothing is playing."
        return .result(value: title ?? "", dialog: IntentDialog(stringLiteral: text))
    }
}

@available(macOS 13.0, *)
struct PlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Play or Pause Juice Tracker"
    @MainActor func perform() async throws -> some IntentResult { AmbientPlayer.shared.togglePause(); return .result() }
}

@available(macOS 13.0, *)
struct NextSongIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Song in Juice Tracker"
    @MainActor func perform() async throws -> some IntentResult { AmbientPlayer.shared.skip(); return .result() }
}

@available(macOS 13.0, *)
struct DownloadWishlistIntent: AppIntent {
    static var title: LocalizedStringResource = "Download My Wishlist"
    static var description = IntentDescription("Downloads the songs on your wishlist that you don't have yet and that have a file on the site.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = NativeStore.shared
        guard await store.ready(), EngineLibrary.shared.root != nil else {
            return .result(dialog: IntentDialog(stringLiteral: "Juice Tracker isn't ready yet. Try again in a moment."))
        }
        let n = EngineDownloads.shared.downloadWishlist()
        let text = n > 0 ? "Downloading \(n) wishlist \(n == 1 ? "song" : "songs")." : "Nothing on your wishlist to download right now."
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

@available(macOS 13.0, *)
struct JuiceTrackerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayEraIntent(), phrases: ["Play music in \(.applicationName)", "Play an era in \(.applicationName)"])
        AppShortcut(intent: WhatsPlayingIntent(), phrases: ["What's playing in \(.applicationName)"])
        AppShortcut(intent: PlayPauseIntent(), phrases: ["Pause \(.applicationName)", "Resume \(.applicationName)"])
        AppShortcut(intent: NextSongIntent(), phrases: ["Next song in \(.applicationName)"])
        AppShortcut(intent: DownloadWishlistIntent(), phrases: ["Download my wishlist in \(.applicationName)"])
    }
}

// MARK: - Desktop widget feed

import WidgetKit

/// Writes the small summary the desktop widget shows (collection count, what's playing, "On this day"), and asks
/// macOS to refresh the widget, at most every 20 seconds (macOS limits how often widgets reload).
@MainActor enum WidgetFeed {
    private struct Summary: Codable { var have: Int; var total: Int; var playing: String?; var today: String? }
    private static var last: Summary?
    private static var lastReload = Date.distantPast

    static func update() {
        guard let s = NativeStore.shared.state else { return }
        let today = s.today.first.flatMap { row -> String? in
            let names = row.songs.prefix(2).compactMap { NativeStore.shared.songs.indices.contains($0) ? NativeStore.shared.songs[$0].n : nil }
            return names.isEmpty ? nil : "\(row.head) \(names.joined(separator: ", "))"
        }
        let p = AmbientPlayer.shared
        let summary = Summary(have: s.have, total: s.total, playing: p.isPlaying ? p.title : nil, today: today)
        guard summary.have != last?.have || summary.playing != last?.playing || summary.today != last?.today || summary.total != last?.total else { return }
        last = summary
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/JuiceTracker/\(Bundle.main.bundleIdentifier ?? "com.hb4delirious.JuiceTracker")")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(summary).write(to: dir.appendingPathComponent("widget.json"), options: .atomic)
        let wait = 20 - Date().timeIntervalSince(lastReload)
        if wait <= 0 { reload() } else { DispatchQueue.main.asyncAfter(deadline: .now() + wait) { reload() } }
    }

    private static func reload() {
        guard Date().timeIntervalSince(lastReload) >= 19 else { return }
        lastReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - Player tab

/// The Player tab, made to sit and watch: a ringed black hole in deep space whose glow takes its colors from the
/// cover art, the time above it, the lyrics lighting up word by word, the cover on a tilted card, the queue floating
/// at the left and a control bar at the bottom. Your songs open from the search button. All drawn in code.
struct PlayerScreen: View {
    let songs: [Song]
    @State private var version = 0 // bumps when the player or the song changes; the small parts redraw from it
    @State private var browsing = false
    @State private var query = ""
    @State private var era = ""
    @State private var palette = CoverPalette.fallback
    @State private var paletteFor: ObjectIdentifier?
    private let changed = NotificationCenter.default.publisher(for: AmbientPlayer.changed)

    var body: some View {
        let library = EngineLibrary.shared
        let mine = songs.filter { $0.o && library.playableURL($0.i) != nil }
        let eras = mine.reduce(into: [String]()) { if !$0.contains($1.e) { $0.append($1.e) } }
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let hole = max(160, min(w * 0.34, h * 0.4, 360))
            let cx = w / 2, cy = h * 0.44
            ZStack {
                BlackHole(palette: palette, size: hole).position(x: cx, y: cy)
                PlayerClock(size: hole * 0.34).position(x: cx, y: cy - hole * 0.62)
                let words = min(w * 0.42, 460) // starts just right of the cover card
                KaraokeLine().frame(width: words).position(x: cx - hole * 0.08 + words / 2, y: cy + hole * 0.24)
                CoverCard(version: version).frame(width: hole * 0.44).position(x: cx - hole * 0.36, y: cy + hole * 0.36)
                QueuePanel(version: version).frame(width: 230).position(x: max(135, cx - hole * 1.3), y: cy)
                VStack(alignment: .trailing, spacing: 10) {
                    Button { browsing.toggle() } label: {
                        Image(systemName: browsing ? "xmark" : "magnifyingglass").frame(width: 30, height: 30)
                            .background(Circle().fill(Color.white.opacity(0.1))).overlay(Circle().stroke(Color.white.opacity(0.2)))
                    }
                    .buttonStyle(.plain).help(browsing ? "Close your songs" : "Your songs").accessibilityLabel(browsing ? "Close your songs" : "Your songs")
                    ControlBar(eras: eras, version: version)
                }
                .frame(width: min(w - 40, 760)).position(x: cx, y: h - 58)
                if mine.isEmpty {
                    Text("Songs you have that this Mac can play show up here.").foregroundColor(JT.muted).position(x: cx, y: cy)
                } else if browsing {
                    SongPicker(songs: mine, eras: eras, query: $query, era: $era)
                        .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.88)))
                        .frame(width: min(460, w - 40), height: max(240, h - 170))
                        .position(x: w - min(460, w - 40) / 2 - 20, y: (h - 170) / 2 + 20)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.25), value: browsing)
        }
        .background(SpaceField(palette: palette).ignoresSafeArea())
        .onReceive(changed) { _ in version += 1; updatePalette() }
        .onReceive(NowPlaying.shared.$song) { _ in version += 1 }
        .onAppear { updatePalette() }
    }

    private func updatePalette() {
        let img = AmbientPlayer.shared.coverImage
        let id = img.map(ObjectIdentifier.init)
        guard id != paletteFor else { return }
        paletteFor = id
        let next = img.map(CoverPalette.init(image:)) ?? .fallback
        withAnimation(.easeInOut(duration: 1.2)) { palette = next }
    }
}

/// Three glowing colors from the cover art: the most colorful hues, brightened so they glow on black.
struct CoverPalette: Equatable {
    var a: Color, b: Color, c: Color
    static let fallback = CoverPalette(a: JT.lavender, b: Color(red: 0.31, green: 0.51, blue: 1), c: Color(red: 0.55, green: 0.16, blue: 0.75))
    init(a: Color, b: Color, c: Color) { self.a = a; self.b = b; self.c = c }
    init(image: NSImage) {
        let colors = Self.hues(image)
        let f = Self.fallback
        self.init(a: colors.count > 0 ? colors[0] : f.a, b: colors.count > 1 ? colors[1] : colors.first ?? f.b, c: colors.count > 2 ? colors[2] : f.c)
    }
    /// Up to three colors: pixels binned by hue, each weighted by how colorful and bright it is.
    static func hues(_ image: NSImage) -> [Color] {
        let n = 24
        var rect = NSRect(x: 0, y: 0, width: n, height: n)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return [] }
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return [] }
        var bins = [(w: Double, r: Double, g: Double, b: Double)](repeating: (0, 0, 0, 0), count: 12)
        for k in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[k]) / 255, g = Double(px[k + 1]) / 255, b = Double(px[k + 2]) / 255
            let mx = max(r, g, b), mn = min(r, g, b), s = mx == 0 ? 0 : (mx - mn) / mx
            guard mx > 0.15, s > 0.25 else { continue } // greys and near-black say nothing about the color
            let d = mx - mn
            var hue = mx == r ? (g - b) / d : mx == g ? 2 + (b - r) / d : 4 + (r - g) / d
            hue = (hue / 6).truncatingRemainder(dividingBy: 1); if hue < 0 { hue += 1 }
            let bin = min(11, Int(hue * 12)), wt = s * mx
            bins[bin].w += wt; bins[bin].r += r * wt; bins[bin].g += g * wt; bins[bin].b += b * wt
        }
        return bins.filter { $0.w > 0.5 }.sorted { $0.w > $1.w }.prefix(3).map { bin in
            let c = NSColor(red: bin.r / bin.w, green: bin.g / bin.w, blue: bin.b / bin.w, alpha: 1)
            return Color(nsColor: NSColor(hue: c.hueComponent, saturation: max(c.saturationComponent, 0.55), brightness: max(c.brightnessComponent, 0.9), alpha: 1))
        }
    }
}

/// Deep space: black, faint glows in the song's colors, and stars (the same ones every time).
private struct SpaceField: View {
    let palette: CoverPalette
    var body: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [palette.b.opacity(0.16), .clear], center: UnitPoint(x: 0.82, y: 0.12), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [palette.a.opacity(0.12), .clear], center: UnitPoint(x: 0.12, y: 0.88), startRadius: 0, endRadius: 520)
            Canvas { ctx, size in
                var seed: UInt64 = 999
                func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(UInt64(1) << 53) }
                for _ in 0..<320 {
                    let x = next() * size.width, y = next() * size.height, r = 0.4 + next() * 1.2
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(0.25 + next() * 0.6)))
                }
            }
        }
    }
}

/// The ringed black hole: a glowing disc in the song's colors, slowly turning, passing behind the hole at the top
/// and in front of it at the bottom.
private struct BlackHole: View {
    let palette: CoverPalette
    let size: CGFloat
    @State private var spin = 0.0

    var body: some View {
        let span = size * 2.5
        ZStack {
            disc(span).mask(VStack(spacing: 0) { Rectangle(); Color.clear })
            Circle().stroke(AngularGradient(colors: [palette.a, palette.b, palette.c, palette.a], center: .center), lineWidth: size * 0.05)
                .blur(radius: size * 0.06).opacity(0.75).frame(width: size * 1.1, height: size * 1.1)
            Circle().fill(Color.black).frame(width: size, height: size)
                .overlay(Circle().stroke(Color.white.opacity(0.95), lineWidth: 3))
                .shadow(color: .white.opacity(0.7), radius: 8)
                .shadow(color: palette.b.opacity(0.6), radius: 30)
            disc(span).mask(VStack(spacing: 0) { Color.clear; Rectangle() })
        }
        .frame(width: span, height: span)
        .allowsHitTesting(false)
        .onAppear { withAnimation(.linear(duration: 90).repeatForever(autoreverses: false)) { spin = 360 } }
    }

    private func disc(_ span: CGFloat) -> some View {
        ZStack {
            Circle().stroke(AngularGradient(colors: [palette.a, palette.b.opacity(0.35), palette.c, palette.a.opacity(0.3), palette.b, palette.a], center: .center), lineWidth: size * 0.2)
                .blur(radius: size * 0.07).opacity(0.9).frame(width: size * 1.95, height: size * 1.95)
            Circle().stroke(AngularGradient(colors: [.white.opacity(0.8), palette.a.opacity(0.2), .white.opacity(0.55), palette.b.opacity(0.2), .white.opacity(0.8)], center: .center), lineWidth: size * 0.04)
                .blur(radius: size * 0.02).frame(width: size * 1.55, height: size * 1.55)
            Circle().stroke(palette.c.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [1.5, 12])).frame(width: size * 2.35, height: size * 2.35)
        }
        .frame(width: span, height: span)
        .rotationEffect(.degrees(spin))
        .scaleEffect(x: 1, y: 0.24)
        .rotationEffect(.degrees(-8))
    }
}

/// The date, then the time big and condensed, fading toward the hole.
private struct PlayerClock: View {
    let size: CGFloat
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        f.dateFormat = f.dateFormat.replacingOccurrences(of: "a", with: "").trimmingCharacters(in: .whitespaces)
        return f
    }()
    var body: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(spacing: 0) {
                Text(ctx.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())).font(JT.body(13, .semibold)).foregroundColor(JT.mist.opacity(0.85))
                Text(Self.time.string(from: ctx.date))
                    .font(.custom("HelveticaNeue-CondensedBold", size: size))
                    .foregroundStyle(LinearGradient(colors: [.white.opacity(0.92), .white.opacity(0.12)], startPoint: .top, endPoint: .bottom))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The line being sung, its words lighting up as the song gets to them. Shown live from the site, never saved.
private struct KaraokeLine: View {
    @ObservedObject private var now = NowPlaying.shared
    var body: some View {
        let p = AmbientPlayer.shared
        Group {
            if let x = now.extras, !x.synced.isEmpty, let n = now.lineIndex, x.synced.indices.contains(n) {
                let start = x.synced[n].at, end = n + 1 < x.synced.count ? x.synced[n + 1].at : start + 4
                let words = x.synced[n].line.split(separator: " ").map(String.init)
                let progress = min(1, max(0, (p.currentTime - start) / max(0.5, (end - start) * 0.85)))
                let lit = Int((Double(words.count) * progress).rounded(.up))
                (words.isEmpty ? Text("♪") : words.enumerated().reduce(Text("")) { line, w in
                    line + Text((w.offset == 0 ? "" : " ") + w.element).foregroundColor(w.offset < lit ? .white : .white.opacity(0.28))
                })
                .id(n).transition(.opacity)
            } else if p.title == nil {
                Text("Press play").foregroundColor(.white.opacity(0.5))
            }
        }
        .font(JT.body(30, .heavy))
        .lineLimit(3)
        .shadow(color: .black.opacity(0.7), radius: 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.3), value: now.lineIndex)
        .allowsHitTesting(false)
    }
}

/// A small cover thumbnail, or a note on a tile when there's no art.
private func thumb(_ image: NSImage?, _ side: CGFloat) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: side * 0.18).fill(Color.white.opacity(0.12))
        if let image { Image(nsImage: image).resizable().scaledToFill() } else { Image(systemName: "music.note").foregroundColor(JT.muted) }
    }
    .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: side * 0.18))
}

/// The cover on a glassy card, tilted toward the hole. Click opens the song's card.
private struct CoverCard: View {
    let version: Int
    var body: some View {
        let p = AmbientPlayer.shared
        VStack(spacing: 5) {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay(Group {
                    if let img = p.coverImage { Image(nsImage: img).resizable().scaledToFill() } else { Image("jt-logo").resizable().scaledToFit().padding(24).opacity(0.85) }
                })
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(p.title ?? "Nothing playing").font(JT.body(14, .semibold)).lineLimit(1)
            Text(NowPlaying.shared.song?.e ?? "Juice WRLD").font(JT.body(11.5)).foregroundColor(JT.mist.opacity(0.7)).lineLimit(1)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [Color.white.opacity(0.24), Color.white.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.3)))
        .rotation3DEffect(.degrees(16), axis: (x: 0.15, y: 1, z: 0), perspective: 0.6)
        .shadow(color: .black.opacity(0.6), radius: 18, y: 10)
        .onTapGesture { if let s = NowPlaying.shared.song { NativeStore.shared.openSong = s } }
        .help("Open the song card")
    }
}

/// The song playing, then Up next, on a panel turned toward the middle. Click plays one now; right-click to move it
/// or take it out.
private struct QueuePanel: View {
    let version: Int
    var body: some View {
        let p = AmbientPlayer.shared, list = p.upNext
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                thumb(p.coverImage, 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Queue").font(JT.body(14, .bold))
                    Text(list.isEmpty ? (EngineAmbient.era.isEmpty ? "Shuffle after this" : "\(EngineAmbient.era) after this") : "\(list.count) up next").font(JT.body(11)).foregroundColor(JT.muted)
                }
            }
            .padding(.bottom, 4)
            if let t = p.title {
                row(p.coverImage, t, NowPlaying.shared.song?.e ?? "Playing")
                    .padding(6).background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.14)))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.6), lineWidth: 1.5))
            }
            ForEach(Array(list.prefix(8).enumerated()), id: \.offset) { k, item in
                row(nil, item.title, "Up next").padding(.horizontal, 6).padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onTapGesture { p.removeUpNext(at: k); p.playNow(item.url, title: item.title) }
                    .contextMenu {
                        Button("Play now") { p.removeUpNext(at: k); p.playNow(item.url, title: item.title) }
                        if k > 0 { Button("Move up") { p.moveUpNext(from: [k], to: k - 1) } }
                        if k < list.count - 1 { Button("Move down") { p.moveUpNext(from: [k], to: k + 2) } }
                        Divider()
                        Button("Remove from queue") { p.removeUpNext(at: k) }
                    }
            }
            if list.count > 8 { Text("+\(list.count - 8) more").font(JT.body(11)).foregroundColor(JT.muted).padding(.leading, 6) }
            if !list.isEmpty { Button("Clear") { p.clearUpNext() }.buttonStyle(.borderless).font(JT.body(11)).padding(.leading, 6) }
        }
        .padding(12)
        .rotation3DEffect(.degrees(24), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
    }

    private func row(_ image: NSImage?, _ title: String, _ sub: String) -> some View {
        HStack(spacing: 8) {
            thumb(image, 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(JT.body(12, .semibold)).lineLimit(1)
                Text(sub).font(JT.body(10)).foregroundColor(JT.muted).lineLimit(1)
            }
        }
    }
}

/// The pill at the bottom: shuffle, restart, play/pause, next, era radio, the song with its progress, heart, sleep,
/// lyrics, mini player and volume.
private struct ControlBar: View {
    let eras: [String]
    let version: Int
    @ObservedObject private var store = NativeStore.shared // the heart follows ratings
    @State private var volume = EngineAmbient.volume

    var body: some View {
        let p = AmbientPlayer.shared
        let id = NowPlaying.shared.song.flatMap { s in EngineState.shared.catalog.indices.contains(s.i) ? EngineState.shared.catalog[s.i].id : nil }
        let loved = id.map { (EngineState.shared.ratings[$0] ?? 0) > 0 } ?? false
        HStack(spacing: 14) {
            Menu {
                Button("All eras") { EngineAmbient.setEra("") }
                Divider()
                ForEach(eras, id: \.self) { e in Button(e) { EngineAmbient.setEra(e) } }
            } label: { Image(systemName: "shuffle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(EngineAmbient.era.isEmpty ? "Shuffling all eras" : "Shuffling \(EngineAmbient.era)").accessibilityLabel("Which era to shuffle")
            Button { p.seek(to: 0) } label: { Image(systemName: "backward.fill") }.help("Start this song again").accessibilityLabel("Start this song again")
            Button { if p.title == nil { EngineAmbient.setOn(true); p.resume() } else { p.togglePause() } } label: {
                Image(systemName: p.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 20)).frame(width: 24)
            }
            .help(p.isPlaying ? "Pause" : "Play").accessibilityLabel(p.isPlaying ? "Pause" : "Play")
            Button { p.skip() } label: { Image(systemName: "forward.fill") }.help("Next song").accessibilityLabel("Next song")
            Button { EngineAmbient.setInOrder(!EngineAmbient.inOrder) } label: { Image(systemName: "repeat").foregroundColor(EngineAmbient.inOrder ? JT.lavender : JT.mist) }
                .help("Era radio: play the era in the order it was recorded").accessibilityLabel("Era radio")
            HStack(spacing: 8) {
                thumb(p.coverImage, 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title ?? "Nothing playing").font(JT.body(12, .semibold)).lineLimit(1)
                    Text(NowPlaying.shared.song?.e ?? "Juice WRLD").font(JT.body(10)).foregroundColor(JT.muted).lineLimit(1)
                    ProgressLine()
                }
            }
            .frame(maxWidth: .infinity)
            Button { if let id { EngineState.shared.setRating(id, loved ? 0 : 5) } } label: { Image(systemName: loved ? "heart.fill" : "heart").foregroundColor(loved ? JT.missing : JT.mist) }
                .disabled(id == nil).help(loved ? "Clear the rating" : "Rate 5 hearts").accessibilityLabel(loved ? "Clear the rating" : "Rate 5 hearts")
            SleepMenu()
            Button { LyricsWindow.show() } label: { Image(systemName: "quote.bubble") }.help("Big lyrics window").accessibilityLabel("Lyrics window")
            Button { MiniPlayer.show() } label: { Image(systemName: "pip.enter") }.help("Mini player (⌘3)").accessibilityLabel("Mini player")
            Image(systemName: "speaker.wave.2").foregroundColor(JT.muted)
            Slider(value: $volume, in: 0...100) { editing in if !editing { p.volume = Float(volume / 100); EngineAmbient.volume = volume } }
                .controlSize(.mini).frame(width: 70).accessibilityLabel("Volume")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(Capsule().fill(Color(white: 0.11).opacity(0.9)))
        .overlay(Capsule().stroke(Color.white.opacity(0.18)))
        .onAppear { volume = Double(p.volume * 100) }
    }
}

/// A thin progress line; click or drag on it to move in the song.
private struct ProgressLine: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let p = AmbientPlayer.shared, f = p.duration > 0 ? min(1, p.currentTime / p.duration) : 0
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15)).frame(height: 3)
                    Capsule().fill(Color.white.opacity(0.85)).frame(width: g.size.width * f, height: 3)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { v in if p.duration > 0 { p.seek(to: max(0, min(1, v.location.x / g.size.width)) * p.duration) } })
            }
            .frame(height: 10)
            .accessibilityLabel("Position in the song")
        }
    }
}

/// Plays a song now; the mix (shuffle or era radio) carries on after it.
@MainActor private func playNow(_ s: Song) {
    guard let url = EngineLibrary.shared.playableURL(s.i) else { return }
    if !EngineAmbient.on { EngineAmbient.setOn(true) } // hands the player the mix to carry on with
    AmbientPlayer.shared.playNow(url, title: s.n)
}

/// Your playable songs, by era, with search.
private struct SongPicker: View {
    let songs: [Song]
    let eras: [String]
    @Binding var query: String
    @Binding var era: String
    @ObservedObject private var playing = PlayingRow.shared

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = songs.filter { (era.isEmpty || $0.e == era) && (q.isEmpty || $0.n.lowercased().contains(q)) }
        let catalog = EngineState.shared.catalog
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Your songs").font(JT.body(15, .semibold))
                Text("\(shown.count)").foregroundColor(JT.muted)
                Spacer()
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(width: 180)
                Picker("", selection: $era) {
                    Text("All eras").tag("")
                    ForEach(eras, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            if !era.isEmpty {
                HStack(spacing: 10) {
                    Button { playInOrder(shown.sorted { (Engine.recordMonth(catalog[$0.i].recordDates) ?? Int.max, $0.n) < (Engine.recordMonth(catalog[$1.i].recordDates) ?? Int.max, $1.n) }.map(\.i)) } label: {
                        Label("Play \(era) in order", systemImage: "play.fill")
                    }
                    Button { EngineAmbient.setEra(era) } label: { Label("Shuffle \(era)", systemImage: "shuffle") }
                }
                .controlSize(.small)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { s in
                        HStack(spacing: 10) {
                            if playing.index == s.i { Visualizer(height: 14).frame(width: 20) } else { Image(systemName: "music.note").foregroundColor(JT.muted).frame(width: 20) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.n).lineLimit(1).foregroundColor(playing.index == s.i ? JT.lavender : JT.mist)
                                if era.isEmpty { Text(s.e).font(JT.body(12)).foregroundColor(JT.muted).lineLimit(1) }
                            }
                            Spacer()
                            Button { playNow(s) } label: { Image(systemName: "play.fill") }
                                .buttonStyle(.borderless).help("Play now").accessibilityLabel("Play \(s.n)")
                            Button { if let url = EngineLibrary.shared.playableURL(s.i) { AmbientPlayer.shared.queueNext(url, title: s.n) } } label: { Image(systemName: "text.badge.plus") }
                                .buttonStyle(.borderless).help("Play next").accessibilityLabel("Play \(s.n) next")
                        }
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { playNow(s) }
                        Divider().opacity(0.3)
                    }
                }
            }
            .frame(minHeight: 300)
        }
        .padding(16).doodled(16, seed: 4)
    }
}
