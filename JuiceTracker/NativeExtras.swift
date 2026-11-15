import AppKit
import SwiftUI
import UniformTypeIdentifiers

// SwiftUI stage 5: Trivia, Export & backup, the setup screen, the sidebar player and the song card's note.

// MARK: - Saving and opening files

@MainActor enum Files {
    /// Asks where to save, then writes the text (or data) there.
    static func save(_ data: Data, name: String, type: UTType) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    static func openText(types: [UTType]) -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

private struct Note: View {
    let text: String
    let error: Bool
    var body: some View {
        Label(text, systemImage: error ? "xmark.octagon" : "sparkles")
            .padding(.vertical, 9).padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 12).fill((error ? JT.missing : JT.lavender).opacity(0.18)))
    }
}

// MARK: - Setup (no catalog or folder yet)


struct SetupView: View {
    @ObservedObject private var store = NativeStore.shared
    @ObservedObject private var engine = EngineState.shared
    @ObservedObject private var library = EngineLibrary.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ScreenTitle(text: "Welcome")
            Text("Two steps and your collection shows up here: load the song catalog from juicewrldapi.com, and choose your music folder. Your files stay on this Mac.")
                .foregroundColor(JT.muted).frame(maxWidth: 620, alignment: .leading)
            HStack(alignment: .top, spacing: 16) {
                step(1, "Load the song catalog", done: !engine.catalog.isEmpty, status: engine.status,
                     button: engine.loading ? "Loading…" : engine.catalog.isEmpty ? "Load catalog" : "Reload catalog") { await engine.reload() }
                step(2, "Choose your music folder", done: library.root != nil && library.loaded, status: library.status,
                     button: library.root == nil ? "Choose folder" : "Choose another folder",
                     rescan: library.root == nil ? nil : { await library.rescan() }) { await library.pick() }
            }
            Text("Loading the catalog takes about a minute the first time. After that it's saved and loads instantly.")
                .font(.caption).foregroundColor(JT.muted)
        }
        .padding(.horizontal, JT.compact ? 18 : 34).padding(.top, JT.compact ? 20 : 40)
        .frame(maxWidth: 1080, maxHeight: .infinity, alignment: .topLeading)
    }

    private func step(_ n: Int, _ title: String, done: Bool, status: String, button: String, rescan: (() async -> Void)? = nil,
                      run: @escaping () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle").foregroundColor(done ? JT.have : JT.lavender).font(.title2)
                Text(title).font(.headline)
            }
            if !status.isEmpty { Text(status).font(.callout).foregroundColor(JT.muted).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(button) { Task { await run() } }.controlSize(.large)
                if let rescan { Button(library.scanning ? "Scanning…" : "Rescan folder") { Task { await rescan() } }.controlSize(.large).disabled(library.scanning) }
            }
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading).doodled(14)
    }
}

// MARK: - Sidebar player

private struct AmbientInfo: Decodable { let on: Bool; let era: String; let eras: [String]; let songs: Int }

struct PlayerPanel: View {
    @ObservedObject private var store = NativeStore.shared
    @ObservedObject private var now = NowPlaying.shared
    @State private var title: String?
    @State private var paused = false
    @State private var volume: Double = 6
    @State private var info: AmbientInfo?
    private let changed = NotificationCenter.default.publisher(for: AmbientPlayer.changed)

    var body: some View {
        // A VStack, not a Group: with nothing to show yet, a Group is empty and its .task would never run.
        VStack(spacing: 0) {
            if let info, info.songs > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if info.on && !paused && title != nil { Visualizer(height: 16).frame(width: 22) } else { Image(systemName: "music.note").foregroundColor(JT.lavender) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Ambient music").font(.caption.bold())
                            Text(info.on ? (title ?? "Starting…") : "Off").font(.caption2).foregroundColor(JT.muted).lineLimit(1)
                            if info.on, let line = now.currentLine, !line.isEmpty {
                                Text(line).font(.caption2.italic()).foregroundColor(JT.lavenderHi).lineLimit(1).transition(.opacity).id(line)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { info.on }, set: { on in EngineAmbient.setOn(on); load() }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                    }
                    if info.on {
                        HStack(spacing: 8) {
                            Button { AmbientPlayer.shared.togglePause() } label: { Image(systemName: paused ? "play.fill" : "pause.fill") }
                                .buttonStyle(.borderless).help(paused ? "Play" : "Pause")
                            Button { AmbientPlayer.shared.skip() } label: { Image(systemName: "forward.fill") }.buttonStyle(.borderless).help("Next song")
                            Slider(value: $volume, in: 0...100) { editing in if !editing { AmbientPlayer.shared.volume = Float(volume / 100); EngineAmbient.volume = volume } }
                                .controlSize(.mini)
                            Button { LyricsWindow.show() } label: { Image(systemName: "quote.bubble") }.buttonStyle(.borderless).help("Lyrics").accessibilityLabel("Lyrics")
                            Button { MiniPlayer.show() } label: { Image(systemName: "pip.enter") }.buttonStyle(.borderless).help("Mini player (⌘3)").accessibilityLabel("Mini player")
                            SleepMenu()
                        }
                        if title != nil { SeekBar() }
                        // An era with no playable songs plays everything (the page falls back), so say "All eras" then.
                        Menu(info.eras.contains(info.era) ? info.era : "All eras") {
                            Button("All eras") { setEra("") }
                            Divider()
                            ForEach(info.eras, id: \.self) { e in Button(e) { setEra(e) } }
                            Divider()
                            Toggle("Play an era in recording order", isOn: Binding(get: { EngineAmbient.inOrder }, set: { EngineAmbient.setInOrder($0); load() }))
                        }
                        .controlSize(.small)
                        .help("Which era the background music plays from")
                        if !AmbientPlayer.shared.upNext.isEmpty {
                            HStack {
                                Text("Up next: \(AmbientPlayer.shared.upNext.map(\.title).prefix(2).joined(separator: ", "))\(AmbientPlayer.shared.upNext.count > 2 ? " +\(AmbientPlayer.shared.upNext.count - 2)" : "")")
                                    .font(.caption2).foregroundColor(JT.muted).lineLimit(1)
                                Spacer()
                                Button { AmbientPlayer.shared.clearUpNext() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("Clear up next")
                            }
                        }
                    }
                }
                .padding(10).doodled(10)
                .overlay(alignment: .top) {
                    if info.on && !paused && title != nil { NoteDrift().frame(height: 110).offset(y: -110).allowsHitTesting(false) }
                }
            }
        }
        .task(id: store.version) { load() }
        .onReceive(changed) { _ in read() }
        .onAppear { read() }
    }

    private func setEra(_ era: String) { EngineAmbient.setEra(era); load() }

    private func read() {
        let p = AmbientPlayer.shared
        title = p.title
        paused = p.isPaused
        volume = Double(p.volume * 100)
    }

    private func load() {
        let eras = EngineAmbient.eras
        info = AmbientInfo(on: EngineAmbient.on, era: EngineAmbient.era, eras: eras, songs: eras.isEmpty ? 0 : 1)
    }
}

// MARK: - Trivia

private struct TriviaType: Decodable, Hashable { let key: String; let label: String }
private struct TriviaInfo: Decodable { let types: [TriviaType]; let best: [String: Int]; let length: Int }
private struct Question: Decodable, Hashable { let prompt: String; let options: [String]; let answer: String; let i: Int; let clip: String }

struct TriviaScreen: View {
    @ObservedObject private var store = NativeStore.shared
    @State private var info: TriviaInfo?
    @State private var type = "mixed"
    @State private var pool = "all"
    @State private var round: [Question] = []
    @State private var n = 0
    @State private var score = 0
    @State private var picked: String?
    @State private var error = ""

    private var key: String { "\(type):\(pool)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(text: "Trivia")
                if round.isEmpty { setup } else if n >= round.count { finished } else { question(round[n]) }
            }
            .padding(.horizontal, JT.compact ? 18 : 34).padding(.top, JT.compact ? 20 : 40).padding(.bottom, 60)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .task { info = try? JSONDecoder().decode(TriviaInfo.self, from: Data(await store.act("triviaInfo").utf8)) }
        .onDisappear { Task { await store.act("triviaStop") } }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Picker("Question type", selection: $type) { ForEach(info?.types ?? [], id: \.self) { Text($0.label).tag($0.key) } }.frame(maxWidth: 320)
                Picker("Songs", selection: $pool) { Text("Whole catalog").tag("all"); Text("Only songs in my library").tag("library") }.frame(maxWidth: 300)
            }
            Button { Task { await start() } } label: { Label("Start a round", systemImage: "play.fill") }.controlSize(.large).keyboardShortcut(.defaultAction)
            if let best = info?.best[key] { Text("Your best for this setup is \(best) of \(info?.length ?? 10).").foregroundColor(JT.muted) }
            if !error.isEmpty { Text(error).foregroundColor(JT.missing) }
            Text("\(info?.length ?? 10) questions per round. Press 1 to 4 to answer.").font(.caption).foregroundColor(JT.muted)
        }
        .padding(18).doodled(14)
    }

    private func question(_ q: Question) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Question \(n + 1) of \(round.count). Score \(score).").font(.caption).foregroundColor(JT.muted)
            Text(q.prompt).font(JT.marker(28))
            if !q.clip.isEmpty { Button { clip(q) } label: { Label("Play the clip again", systemImage: "speaker.wave.2") }.buttonStyle(.borderless) }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(Array(q.options.enumerated()), id: \.offset) { k, o in
                    Button { answer(o, q) } label: {
                        HStack {
                            Text("\(k + 1)").font(.caption.bold()).frame(width: 22, height: 22).background(Circle().fill(Color.white.opacity(0.1)))
                            Text(o).multilineTextAlignment(.leading)
                            Spacer()
                            if picked != nil, o == q.answer { Image(systemName: "checkmark.circle.fill").foregroundColor(JT.have) }
                            if picked == o, o != q.answer { Image(systemName: "xmark.circle.fill").foregroundColor(JT.missing) }
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(picked == nil ? Color.white.opacity(0.06)
                            : o == q.answer ? JT.have.opacity(0.18) : picked == o ? JT.missing.opacity(0.18) : Color.white.opacity(0.03)))
                    }
                    .buttonStyle(.plain)
                    .disabled(picked != nil)
                    .keyboardShortcut(KeyEquivalent(Character("\(k + 1)")), modifiers: [])
                }
            }
            if let picked {
                HStack {
                    Text(picked == q.answer ? "Correct." : "Not quite. The answer is \(q.answer).").foregroundColor(picked == q.answer ? JT.have : JT.missing)
                    Button("Open the song card") { if store.songs.indices.contains(q.i) { store.openSong = store.songs[q.i] } }.buttonStyle(.borderless)
                    Spacer()
                    Button(n + 1 < round.count ? "Next question" : "See your score") { next() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18).doodled(14)
        .onAppear { clip(q) }
        .id(n)
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Round complete").font(.caption).foregroundColor(JT.muted)
            Text("You got \(score) of \(round.count).").font(JT.marker(34))
            if let best = info?.best[key] { Text(score >= best ? "That's your best score for this setup." : "Your best for this setup is \(best).").foregroundColor(JT.muted) }
            HStack {
                Button("Play again") { Task { await start() } }.keyboardShortcut(.defaultAction)
                Button("Change settings") { round = [] }
            }
        }
        .padding(18).doodled(14)
    }

    private func start() async {
        error = ""
        let qs = (try? JSONDecoder().decode([Question].self, from: Data(await store.act("triviaRound", -1, ["type": type, "pool": pool]).utf8))) ?? []
        guard qs.count >= 3 else {
            error = pool == "library" || type == "listen"
                ? "There aren't enough matched songs in your library with that kind of info. Try the whole catalog or another question type."
                : "The catalog doesn't have enough of that info for a round. Try another question type."
            return
        }
        round = qs; n = 0; score = 0; picked = nil
    }

    private func answer(_ o: String, _ q: Question) {
        picked = o
        if o == q.answer { score += 1 }
    }

    private func next() {
        picked = nil
        n += 1
        if n >= round.count {
            Task {
                await store.act("triviaStop")
                if round.count == info?.length { await store.act("triviaBest", -1, ["key": key, "score": score]) }
                info = try? JSONDecoder().decode(TriviaInfo.self, from: Data(await store.act("triviaInfo").utf8))
            }
        }
    }

    private func clip(_ q: Question) { if !q.clip.isEmpty { Task { await store.act("triviaClip", -1, ["path": q.clip]) } } }
}

// MARK: - Export & backup

private struct PlexSource: Decodable, Hashable { let id: String; let label: String; let count: Int }
private struct SnapInfo: Decodable { let available: Bool; let last: Double }

struct ExportScreen: View {
    @ObservedObject private var store = NativeStore.shared
    @State private var card: NSImage?
    @State private var snap: SnapInfo?
    @State private var plex: [PlexSource] = []
    @State private var plexPick = ""
    @State private var message: (String, Bool)?
    @State private var lost: [Int] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(text: "Export & backup")
                if let message { Note(text: message.0, error: message.1) }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], alignment: .leading, spacing: 14) {
                    item("Collection card", "A picture of your collection to post or keep.") {
                        if let card { Image(nsImage: card).resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 10)) }
                        Button("Save collection card…") { saveCard() }.disabled(card == nil)
                    }
                    item("Full catalog spreadsheet", "Every song with all credits, dates and notes, plus your library, wishlist and notes.") {
                        Button("Export full catalog…") { Task { await exportCatalog() } }
                    }
                    DriveCompareCard()
                    item("Wishlist and notes backup", "Your wishlist, notes, trivia scores and hand matches, in one file you can keep or move to another Mac.") {
                        HStack { Button("Save a backup…") { Task { await backup() } }; Button("Restore…") { Task { await restore() } } }
                    }
                    if snap?.available == true {
                        item("Library snapshot", "Every week the app saves a list of your files, tags and matched songs to iCloud Drive (or Documents), away from your music drive.") {
                            Text(snap.map { $0.last > 0 ? "Last snapshot: \(Date(timeIntervalSince1970: $0.last / 1000).formatted(date: .abbreviated, time: .omitted))." : "No snapshot yet." } ?? "")
                                .font(.caption).foregroundColor(JT.muted)
                            HStack {
                                Button("Save a snapshot now") { Task { message = (await EngineSnapshot.save(), false); loadSnap() } }
                                Button("Show snapshots") { try? FileManager.default.createDirectory(at: Snapshots.folder, withIntermediateDirectories: true); NSWorkspace.shared.open(Snapshots.folder) }
                            }
                            Button("Download from a snapshot…") { Task { await fromSnapshot() } }
                            if !lost.isEmpty {
                                let withFile = lost.filter { store.songs.indices.contains($0) && store.songs[$0].f }
                                Text("\(lost.count) songs from that snapshot aren't in your library now; \(withFile.count) have a file on the site.").font(.caption)
                                Button("Download \(withFile.count) songs") { EngineDownloads.shared.add(withFile.compactMap { store.songs.indices.contains($0) ? store.songs[$0].s.id : nil }); lost = [] }
                                    .disabled(withFile.isEmpty)
                            }
                        }
                    }
                    if !plex.isEmpty {
                        item("Plex playlists", "Makes a playlist in Plex from songs you have. Making the same one again replaces it.") {
                            Picker("Songs", selection: $plexPick) { ForEach(plex, id: \.self) { Text("\($0.label) (\($0.count))").tag($0.id) } }
                            Button("Make playlist") { Task { await makePlaylist() } }.disabled(plexPick.isEmpty)
                        }
                    }
                }
            }
            .padding(.horizontal, JT.compact ? 18 : 34).padding(.top, JT.compact ? 20 : 40).padding(.bottom, 60)
            .frame(maxWidth: 1080, alignment: .leading)
        }
        .task {
            loadSnap()
            card = EngineState.shared.collectionCard()
            plex = (try? JSONDecoder().decode([PlexSource].self, from: Data(await store.act("plexSources").utf8))) ?? []
            if plexPick.isEmpty { plexPick = plex.first?.id ?? "" }
        }
    }

    private func item<Content: View>(_ title: String, _ hint: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(hint).font(.caption).foregroundColor(JT.muted).fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading).doodled(14)
    }

    private func loadSnap() { snap = SnapInfo(available: true, last: (EngineSnapshot.last?.timeIntervalSince1970 ?? 0) * 1000) }

    private func saveCard() {
        guard let card, let tiff = card.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        if Files.save(png, name: "juice-wrld-collection-\(Files.today).png", type: .png) { message = ("Saved your collection card.", false) }
    }

    private func exportCatalog() async {
        let csv = await EngineState.shared.catalogCSV()
        if Files.save(Data(csv.utf8), name: "juice-wrld-full-catalog-\(Files.today).csv", type: .commaSeparatedText) { message = ("Exported the full catalog.", false) }
    }

    private func backup() async {
        let json = await EngineState.shared.backupJSON()
        if Files.save(Data(json.utf8), name: "juice-wrld-tracker-backup-\(Files.today).json", type: .json) { message = ("Saved your backup.", false) }
    }

    private func restore() async {
        guard let text = Files.openText(types: [.json]) else { return }
        do { message = (try await EngineState.shared.restore(text), false) }
        catch { message = ("That file isn't a backup from this tracker.", true) }
    }

    private func fromSnapshot() async {
        guard let text = Files.openText(types: [.commaSeparatedText]) else { return }
        do {
            let json = try await store.tryAct("snapshotLost", -1, ["text": text]) // throws when it isn't a snapshot
            lost = (try? JSONDecoder().decode([Int].self, from: Data(json.utf8))) ?? []
            message = lost.isEmpty ? ("You still have every song in that snapshot.", false) : nil
        } catch { message = (error.localizedDescription, true) }
    }

    private func makePlaylist() async {
        do { message = (try await store.tryAct("plexMake", -1, ["id": plexPick]), false) }
        catch { message = ("Couldn't make the playlist: \(error.localizedDescription)", true) }
    }
}
