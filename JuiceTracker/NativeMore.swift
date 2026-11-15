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
        do {
            _ = try await store.tryAct("ambientSet", -1, ["on": true])
            _ = try await store.tryAct("ambientSet", -1, ["era": era ?? ""])
        } catch { return .result(dialog: IntentDialog(stringLiteral: "Couldn't start the music: \(error.localizedDescription)")) }
        return .result(dialog: IntentDialog(stringLiteral: "Playing \(era.map { "songs from \($0)" } ?? "your songs")."))
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
        guard await store.ready(), let raw = try? await store.tryAct("downloadWishlist"), let n = Int(raw) else {
            return .result(dialog: IntentDialog(stringLiteral: "Juice Tracker isn't ready yet. Try again in a moment."))
        }
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
