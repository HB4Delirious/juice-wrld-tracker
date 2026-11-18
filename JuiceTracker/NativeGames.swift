import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// Wordle (guess a song title letter by letter), Tier list (rank your songs in S–D rows, export a picture) and the
// Lyrics card (a line being sung as a picture to share). All Juice Tracker's own: the rules are in Engine.swift.

// MARK: - Wordle

private let tileGreen = Color(red: 0.36, green: 0.72, blue: 0.36), tileYellow = Color(red: 0.86, green: 0.70, blue: 0.20), tileGrey = Color.white.opacity(0.14)

struct WordleScreen: View {
    @ObservedObject private var store = NativeStore.shared
    @AppStorage("wordleDaily") private var daily = true
    @AppStorage("wordleEra") private var era = ""
    @AppStorage("wordleSaved") private var saved = ""     // today's daily round: "date|era|GUESS,GUESS"
    @AppStorage("wordleStats") private var stats = "0,0,0,0" // daily rounds: played, won, streak, best
    @AppStorage("wordleCounted") private var counted = ""  // the last daily round counted in the stats
    @State private var unlimitedPick = Int.random(in: 0..<10_000)
    @State private var unlimitedGuesses: [String] = []
    @State private var typed = ""
    @State private var note = ""
    @FocusState private var typing: Bool

    /// Every title that makes a puzzle (4 to 14 letters), one song per title, in a fixed order.
    private var pool: [(word: String, song: Song)] {
        var seen = Set<String>(), out: [(String, Song)] = []
        for s in store.songs where era.isEmpty || s.e == era {
            if let w = Engine.wordleWord(s.n), seen.insert(w).inserted { out.append((w, s)) }
        }
        return out.sorted { $0.0 < $1.0 }
    }
    private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    private var today: String { Self.day.string(from: Date()) }
    private var dayNumber: Int { Int(Date().timeIntervalSince1970 / 86400) }

    var body: some View {
        let pool = self.pool
        VStack(alignment: .leading, spacing: 16) {
            ScreenTitle(text: "Wordle")
            Text("Guess a Juice WRLD song title letter by letter. Green is the right letter in the right place, yellow is in the title somewhere else. Six tries.")
                .foregroundColor(JT.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Picker("", selection: $daily) { Text("Daily").tag(true); Text("Unlimited").tag(false) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Menu(era.isEmpty ? "All eras" : era) {
                    Button("All eras") { era = ""; restart() }
                    Divider()
                    ForEach(eras, id: \.self) { e in Button(e) { era = e; restart() } }
                }
                .fixedSize()
                Spacer()
                let st = stats.split(separator: ",").map { Int($0) ?? 0 } + [0, 0, 0, 0]
                Text("Daily: played \(st[0]) · won \(st[1]) · streak \(st[2]) · best \(st[3])").font(JT.body(13)).foregroundColor(JT.muted)
            }
            if pool.isEmpty {
                Text("No titles to play in this era.").foregroundColor(JT.muted)
            } else {
                let answer = daily ? pool[(dayNumber * 7919) % pool.count] : pool[unlimitedPick % pool.count]
                game(answer.word, song: answer.song)
            }
        }
        .padding(.horizontal, JT.compact ? 18 : 34).padding(.top, JT.compact ? 20 : 40).padding(.bottom, 30)
        .frame(maxWidth: 1080, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: daily) { _ in typed = ""; note = "" }
    }

    private var eras: [String] { store.songs.reduce(into: [String]()) { if !$0.contains($1.e) { $0.append($1.e) } } }

    private var guesses: [String] {
        guard daily else { return unlimitedGuesses }
        let parts = saved.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == today, parts[1] == era else { return [] }
        return parts[2].split(separator: ",").map(String.init)
    }
    private func setGuesses(_ list: [String]) {
        if daily { saved = "\(today)|\(era)|\(list.joined(separator: ","))" } else { unlimitedGuesses = list }
    }
    private func restart() { unlimitedGuesses = []; typed = ""; note = "" }

    @ViewBuilder private func game(_ answer: String, song: Song) -> some View {
        let letters = answer.filter { $0 != " " }, list = guesses
        let won = list.last == letters, done = won || list.count >= 6
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<6, id: \.self) { r in
                    let text = r < list.count ? list[r] : (r == list.count && !done ? Self.clean(typed) : "")
                    row(answer, text, scored: r < list.count)
                }
            }
            if done {
                VStack(alignment: .leading, spacing: 8) {
                    Text(won ? "Got it in \(list.count)!" : "Out of tries. It was:").font(JT.body(18, .bold))
                    Text(song.n).font(JT.marker(28)).foregroundColor(JT.lavender)
                    Text(song.e).foregroundColor(JT.muted)
                    HStack {
                        Button("Open the song card") { store.openSong = song }
                        if daily { Text("A new title tomorrow.").foregroundColor(JT.muted) }
                        else { Button("Next title") { unlimitedPick = Int.random(in: 0..<10_000); restart() } }
                    }
                }
                .onAppear { count(won: won) }
            } else {
                HStack(spacing: 10) {
                    TextField("Type a title (\(letters.count) letters)", text: $typed)
                        .textFieldStyle(.roundedBorder).frame(width: 320).focused($typing)
                        .onSubmit { guess(answer) }
                    Button("Guess") { guess(answer) }.keyboardShortcut(.defaultAction)
                    if !note.isEmpty { Text(note).font(JT.body(13)).foregroundColor(JT.missing) }
                }
                .onAppear { typing = true }
                keyboard(answer, list)
            }
        }
    }

    /// Letters and digits only, upper-cased: what a guess is made of.
    private static func clean(_ s: String) -> String { String(s.uppercased().folding(options: .diacriticInsensitive, locale: nil).filter { ($0.isLetter || $0.isNumber) && $0.isASCII }) }

    private func guess(_ answer: String) {
        let letters = answer.filter { $0 != " " }, g = Self.clean(typed)
        guard g.count == letters.count else { note = "That's \(g.count) letters; the title has \(letters.count)."; return }
        note = ""; typed = ""
        setGuesses(guesses + [g])
    }

    /// One row of tiles: the answer's shape (gaps between words), filled with a guess.
    private func row(_ answer: String, _ text: String, scored: Bool) -> some View {
        let score = scored ? Engine.wordleScore(text, answer) : []
        let chars = Array(text)
        var next = 0 // each tile's place among the letters (spaces are gaps, not tiles)
        let cells: [Int] = answer.map { c in if c == " " { return -1 }; defer { next += 1 }; return next }
        return HStack(spacing: 5) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, n in
                if n < 0 { Color.clear.frame(width: 14, height: 46) } else {
                    let letter = n < chars.count ? String(chars[n]) : ""
                    Text(letter).font(JT.body(22, .heavy)).foregroundColor(.white).frame(width: 46, height: 46)
                        .background(RoundedRectangle(cornerRadius: 8).fill(scored ? [tileGrey, tileYellow, tileGreen][score[n]] : Color.white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(scored ? 0 : letter.isEmpty ? 0.15 : 0.5)))
                }
            }
        }
    }

    /// The letters seen so far, coloured by the best they've done; click one to type it.
    private func keyboard(_ answer: String, _ list: [String]) -> some View {
        var best: [Character: Int] = [:]
        for g in list { for (c, s) in zip(g, Engine.wordleScore(g, answer)) { best[c] = max(best[c] ?? -1, s) } }
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM", "0123456789"], id: \.self) { keys in
                HStack(spacing: 4) {
                    ForEach(Array(keys), id: \.self) { c in
                        Button { typed += String(c); typing = true } label: {
                            Text(String(c)).font(JT.body(13, .bold)).frame(width: 30, height: 34)
                                .background(RoundedRectangle(cornerRadius: 6).fill(best[c].map { [Color.black.opacity(0.5), tileYellow, tileGreen][$0] } ?? Color.white.opacity(0.1)))
                        }
                        .buttonStyle(.plain).foregroundColor(best[c] == 0 ? JT.muted : .white)
                    }
                }
            }
        }
    }

    /// Daily stats, once per round.
    private func count(won: Bool) {
        guard daily, counted != today else { return }
        var st = stats.split(separator: ",").map { Int($0) ?? 0 } + [0, 0, 0, 0]
        let yesterday = Self.day.string(from: Date().addingTimeInterval(-86400))
        st[0] += 1
        if won { st[1] += 1; st[2] = counted == yesterday ? st[2] + 1 : 1; st[3] = max(st[3], st[2]) } else { st[2] = 0 }
        stats = st.prefix(4).map(String.init).joined(separator: ",")
        counted = today
    }
}

// MARK: - Tier list

struct TierList: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name = "My tier list"
    var era = ""                                     // "" means all eras
    var rows: [[String]] = Array(repeating: [], count: 5) // song ids, S to D
}

private let tierNames = ["S", "A", "B", "C", "D"]
private let tierColors: [Color] = [Color(red: 1, green: 0.42, blue: 0.45), Color(red: 1, green: 0.66, blue: 0.36), Color(red: 1, green: 0.86, blue: 0.38),
                                    Color(red: 0.55, green: 0.86, blue: 0.45), Color(red: 0.42, green: 0.66, blue: 1)]

struct TierListScreen: View {
    @ObservedObject private var store = NativeStore.shared
    @AppStorage("tierLists") private var raw = ""
    @AppStorage("tierListPick") private var pickId = ""
    @State private var query = ""
    @State private var note = ""

    private var lists: [TierList] {
        let decoded = (try? JSONDecoder().decode([TierList].self, from: Data(raw.utf8))) ?? []
        return decoded.isEmpty ? [TierList()] : decoded
    }
    private func save(_ lists: [TierList]) { raw = (try? String(decoding: JSONEncoder().encode(lists), as: UTF8.self)) ?? "" }
    private func update(_ change: (inout TierList) -> Void) {
        var all = lists
        let k = all.firstIndex { $0.id == pickId } ?? 0
        change(&all[k]); save(all)
    }

    var body: some View {
        let all = lists, list = all.first { $0.id == pickId } ?? all[0]
        let byId = Dictionary(store.songs.map { ($0.s.id, $0) }, uniquingKeysWith: { a, _ in a })
        let placed = Set(list.rows.joined())
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let pool = store.songs.filter { $0.o && (list.era.isEmpty || $0.e == list.era) && !placed.contains($0.s.id) && (q.isEmpty || $0.n.lowercased().contains(q)) }
        VStack(alignment: .leading, spacing: 14) {
            ScreenTitle(text: "Tier list")
            Text("Rank your songs: drag one into a row (or right-click it), drag it back down to take it out. Save the list as a picture to share.")
                .foregroundColor(JT.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Menu(list.name) {
                    ForEach(all) { l in Button(l.name) { pickId = l.id } }
                    Divider()
                    Button("New tier list") { let n = TierList(name: "Tier list \(all.count + 1)"); save(all + [n]); pickId = n.id }
                    if all.count > 1 { Button("Delete “\(list.name)”") { save(all.filter { $0.id != list.id }); pickId = "" } }
                }
                .fixedSize()
                TextField("Name", text: Binding(get: { list.name }, set: { v in update { $0.name = v } })).textFieldStyle(.roundedBorder).frame(width: 200)
                Menu(list.era.isEmpty ? "All eras" : list.era) {
                    Button("All eras") { update { $0.era = "" } }
                    Divider()
                    ForEach(store.songs.reduce(into: [String]()) { if !$0.contains($1.e) { $0.append($1.e) } }, id: \.self) { e in Button(e) { update { $0.era = e } } }
                }
                .fixedSize()
                Spacer()
                Button("Save as picture…") { export(list, byId) }
                if !note.isEmpty { Text(note).font(JT.body(12)).foregroundColor(JT.muted) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<5, id: \.self) { r in
                        HStack(alignment: .top, spacing: 8) {
                            Text(tierNames[r]).font(JT.marker(30)).foregroundColor(.black).frame(width: 64).frame(minHeight: 58)
                                .background(RoundedRectangle(cornerRadius: 10).fill(tierColors[r]))
                            chips(list.rows[r].compactMap { byId[$0] }, row: r)
                                .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
                                .padding(6).background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                                .onDrop(of: [.plainText], isTargeted: nil) { drop($0, to: r) }
                        }
                    }
                    HStack {
                        Text("Your songs").font(JT.body(15, .semibold))
                        Text("\(pool.count)").foregroundColor(JT.muted)
                        Spacer()
                        TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
                    }
                    .padding(.top, 10)
                    chips(Array(pool.prefix(300)), row: -1)
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                        .padding(6).background(RoundedRectangle(cornerRadius: 10).stroke(JT.line))
                        .onDrop(of: [.plainText], isTargeted: nil) { drop($0, to: -1) }
                    if pool.count > 300 { Text("Showing 300 of \(pool.count); search to find the rest.").font(JT.body(12)).foregroundColor(JT.muted) }
                }
            }
        }
        .padding(.horizontal, JT.compact ? 18 : 34).padding(.top, JT.compact ? 20 : 40).padding(.bottom, 30)
        .frame(maxWidth: 1180, maxHeight: .infinity, alignment: .topLeading)
    }

    private func chips(_ songs: [Song], row: Int) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(songs) { s in
                Text(s.n).font(JT.body(12, .semibold)).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(row >= 0 ? tierColors[row].opacity(0.22) : JT.raise))
                    .help("\(s.n) · \(s.e)")
                    .onDrag { NSItemProvider(object: s.s.id as NSString) }
                    .contextMenu {
                        ForEach(0..<5, id: \.self) { r in Button("Move to \(tierNames[r])") { move(s.s.id, to: r) } }
                        if row >= 0 { Divider(); Button("Take out") { move(s.s.id, to: -1) } }
                        Divider(); Button("Open the song card") { store.openSong = s }
                    }
            }
        }
    }

    private func drop(_ providers: [NSItemProvider], to row: Int) -> Bool {
        guard let p = providers.first else { return false }
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            if let id = obj as? String { DispatchQueue.main.async { move(id, to: row) } }
        }
        return true
    }
    /// Takes a song out of every row, then (row 0-4) adds it to the end of that row.
    private func move(_ id: String, to row: Int) {
        update { list in
            for k in list.rows.indices { list.rows[k].removeAll { $0 == id } }
            if (0..<5).contains(row) { list.rows[row].append(id) }
        }
    }

    private func export(_ list: TierList, _ byId: [String: Song]) {
        let host = NSHostingView(rootView: TierCard(list: list, rows: list.rows.map { $0.compactMap { byId[$0]?.n } }))
        host.frame = NSRect(origin: .zero, size: NSSize(width: 1200, height: 100))
        host.frame.size = host.fittingSize
        guard let png = snapshot(host) else { return }
        if Files.save(png, name: "\(Engine.safeName(list.name)).png", type: .png) { note = "Saved." }
    }
}

/// The tier list as a picture: the five rows with song names, the list's name, a small credit.
private struct TierCard: View {
    let list: TierList
    let rows: [[String]]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(list.name).font(JT.marker(54)).foregroundColor(.white)
                Spacer()
                Text(list.era.isEmpty ? "Juice WRLD" : "Juice WRLD · \(list.era)").font(JT.body(24, .semibold)).foregroundColor(JT.lavender)
            }
            ForEach(0..<5, id: \.self) { r in
                HStack(alignment: .top, spacing: 12) {
                    Text(tierNames[r]).font(JT.marker(48)).foregroundColor(.black).frame(width: 96).frame(minHeight: 96)
                        .background(RoundedRectangle(cornerRadius: 14).fill(tierColors[r]))
                    Text(rows[r].isEmpty ? "—" : rows[r].joined(separator: "  ·  ")).font(JT.body(26, .semibold)).foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 96, alignment: .leading).padding(.horizontal, 16)
                        .background(RoundedRectangle(cornerRadius: 14).fill(tierColors[r].opacity(0.16)))
                }
            }
            Text("Made with Juice Tracker").font(JT.marker(20)).foregroundColor(.white.opacity(0.4)).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(48).frame(width: 1200)
        .background(LinearGradient(colors: [Color(red: 7 / 255, green: 4 / 255, blue: 15 / 255), Color(red: 29 / 255, green: 11 / 255, blue: 64 / 255)], startPoint: .top, endPoint: .bottom))
    }
}

/// A view drawn into a PNG (the same way the badge and collection cards are made).
@MainActor private func snapshot(_ host: NSView) -> Data? {
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Lyrics card

/// Pick up to four lines of the song playing and save them as a picture (1080 × 1350) with the cover and the title.
/// The lyrics come live from the site and aren't kept; the picture is only made when you save it.
struct LyricsCardSheet: View {
    let close: () -> Void
    @State private var picked: Set<Int> = []
    @State private var note = ""
    @State private var picture: NSImage?
    @State private var tint = JT.lavender
    @State private var showInfo = true

    private var lines: [String] {
        guard let x = NowPlaying.shared.extras else { return [] }
        let source = x.synced.isEmpty ? x.lyrics.components(separatedBy: .newlines) : x.synced.map(\.line)
        return source.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        let lines = self.lines, song = NowPlaying.shared.song
        let chosen = picked.sorted().compactMap { lines.indices.contains($0) ? lines[$0] : nil }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lyrics card").font(JT.marker(26))
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
            if lines.isEmpty {
                Text(song == nil ? "Play a song first; its lyrics show up here." : "The site has no lyrics for this song.").foregroundColor(JT.muted)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pick up to four lines").font(JT.body(13, .semibold)).foregroundColor(JT.muted)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { k, line in
                                    Button { toggle(k) } label: {
                                        Text(line).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 5)
                                            .background(RoundedRectangle(cornerRadius: 6).fill(picked.contains(k) ? JT.lavender.opacity(0.3) : .clear))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(width: 360)
                    VStack(spacing: 10) {
                        card(chosen.isEmpty ? ["Pick a line"] : chosen, song)
                            .frame(width: 1080, height: 1350).scaleEffect(0.3).frame(width: 324, height: 405)
                        HStack(spacing: 8) {
                            Button(picture == nil ? "Choose picture…" : "Use the cover") { picture = picture == nil ? choosePicture() : nil }
                            ColorPicker("", selection: $tint).labelsHidden().help("The card's color")
                            Toggle("Song info", isOn: $showInfo)
                        }
                        HStack {
                            Button("Save image…") { save(chosen, song) }.disabled(chosen.isEmpty)
                            Button("Copy") { copy(chosen, song) }.disabled(chosen.isEmpty)
                        }
                        if !note.isEmpty { Text(note).font(JT.body(12)).foregroundColor(JT.muted) }
                    }
                }
            }
        }
        .padding(22).frame(width: 760, height: 560)
        .onAppear { if let n = NowPlaying.shared.lineIndex, NowPlaying.shared.extras?.synced.isEmpty == false { picked = [n] } }
    }

    private func toggle(_ k: Int) {
        if picked.contains(k) { picked.remove(k) } else if picked.count < 4 { picked.insert(k) }
    }
    private func card(_ lines: [String], _ song: Song?) -> LyricsCard {
        LyricsCard(lines: lines, title: song?.n ?? "", era: song?.e ?? "", cover: picture ?? AmbientPlayer.shared.coverImage, tint: tint, showInfo: showInfo)
    }
    private func choosePicture() -> NSImage? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        return panel.runModal() == .OK ? panel.url.flatMap(NSImage.init(contentsOf:)) : nil
    }
    private func render(_ lines: [String], _ song: Song?) -> Data? {
        let host = NSHostingView(rootView: card(lines, song))
        host.frame = NSRect(x: 0, y: 0, width: 1080, height: 1350)
        return snapshot(host)
    }
    private func save(_ lines: [String], _ song: Song?) {
        guard let png = render(lines, song) else { return }
        if Files.save(png, name: "\(Engine.safeName(song?.n ?? "lyrics")) lyrics.png", type: .png) { note = "Saved." }
    }
    private func copy(_ lines: [String], _ song: Song?) {
        guard let png = render(lines, song), let image = NSImage(data: png) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]); note = "Copied: paste it anywhere."
    }
}

private struct LyricsCard: View {
    let lines: [String]
    let title: String
    let era: String
    let cover: NSImage?
    var tint = JT.lavender
    var showInfo = true
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 7 / 255, green: 4 / 255, blue: 15 / 255), Color(red: 29 / 255, green: 11 / 255, blue: 64 / 255), Color(red: 74 / 255, green: 18 / 255, blue: 80 / 255)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // its own frame: a filled image is wider than the card, and would widen the text's room with it
            if let cover { Image(nsImage: cover).resizable().scaledToFill().frame(width: 1080, height: 1350).clipped().opacity(showInfo ? 0.22 : 0.4) }
            LinearGradient(colors: [tint.opacity(0.35), .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 40) {
                if showInfo {
                Group {
                    if let cover { Image(nsImage: cover).resizable().scaledToFill() } else { Image("jt-logo").resizable().scaledToFit().padding(50) }
                }
                .frame(width: 360, height: 360).clipShape(RoundedRectangle(cornerRadius: 28)).shadow(color: .black.opacity(0.6), radius: 30, y: 12)
                }
                VStack(spacing: 18) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(JT.body(54, .heavy)).foregroundColor(.white).multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 70).frame(width: 1080)
                if showInfo {
                    VStack(spacing: 6) {
                        Text(title).font(JT.marker(42)).foregroundColor(tint).multilineTextAlignment(.center)
                        Text(era.isEmpty ? "Juice WRLD" : "Juice WRLD · \(era)").font(JT.body(26, .semibold)).foregroundColor(.white.opacity(0.7))
                    }
                }
            }
            .padding(.vertical, 90)
            VStack { Spacer(); Text("Juice Tracker").font(JT.marker(22)).foregroundColor(.white.opacity(0.35)).padding(.bottom, 36) }
        }
        .frame(width: 1080, height: 1350).clipped()
    }
}

// MARK: - Heardle

/// Name the song from a clip of your own files: one second, then more with each wrong guess or skip (1, 2, 4, 7, 11,
/// 16 seconds). Daily (the same song all day, with stats) or unlimited; from the intro or a spot inside the song.
struct HeardleScreen: View {
    @ObservedObject private var store = NativeStore.shared
    @AppStorage("heardleDaily") private var daily = true
    @AppStorage("heardleEra") private var era = ""
    @AppStorage("heardleIntro") private var fromIntro = true
    @AppStorage("heardleSaved") private var saved = ""      // today's daily round: "date|era|intro|id,id,-" (- is a skip)
    @AppStorage("heardleStats") private var stats = "0,0,0,0" // daily rounds: played, won, streak, best
    @AppStorage("heardleCounted") private var counted = ""
    @State private var unlimitedPick = Int.random(in: 0..<10_000)
    @State private var unlimitedGuesses: [String] = []
    @State private var query = ""
    static let steps: [Double] = [1, 2, 4, 7, 11, 16]

    /// Songs you have that can play, one per title (versions count as the same song), in a fixed order.
    private var pool: [Song] {
        var seen = Set<String>()
        return store.songs.filter { $0.o && (era.isEmpty || $0.e == era) && EngineLibrary.shared.playableURL($0.i) != nil }
            .filter { seen.insert(Engine.normalize($0.n)).inserted }
            .sorted { Engine.normalize($0.n) < Engine.normalize($1.n) }
    }
    private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    private var today: String { Self.day.string(from: Date()) }
    private var key: String { "\(today)|\(era)|\(fromIntro)" }

    var body: some View {
        let pool = self.pool
        VStack(alignment: .leading, spacing: 16) {
            ScreenTitle(text: "Heardle")
            Text("Name the song from a clip of your own files. You hear one second; each wrong guess or skip plays more. Six tries.")
                .foregroundColor(JT.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Picker("", selection: $daily) { Text("Daily").tag(true); Text("Unlimited").tag(false) }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Picker("", selection: $fromIntro) { Text("From the intro").tag(true); Text("From inside").tag(false) }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Menu(era.isEmpty ? "All eras" : era) {
                    Button("All eras") { era = ""; restart() }
                    Divider()
                    ForEach(store.songs.filter(\.o).reduce(into: [String]()) { if !$0.contains($1.e) { $0.append($1.e) } }, id: \.self) { e in Button(e) { era = e; restart() } }
                }
                .fixedSize()
                Spacer()
                let st = stats.split(separator: ",").map { Int($0) ?? 0 } + [0, 0, 0, 0]
                Text("Daily: played \(st[0]) · won \(st[1]) · streak \(st[2]) · best \(st[3])").font(JT.body(13)).foregroundColor(JT.muted)
            }
            if pool.isEmpty {
                Text("No songs you have to play in this era.").foregroundColor(JT.muted)
            } else {
                let day = Int(Date().timeIntervalSince1970 / 86400)
                game(daily ? pool[(day * 7919) % pool.count] : pool[unlimitedPick % pool.count], seed: daily ? day : unlimitedPick)
            }
        }
        .padding(.horizontal, JT.compact ? 18 : 34).padding(.top, JT.compact ? 20 : 40).padding(.bottom, 30)
        .frame(maxWidth: 1080, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear { AmbientPlayer.shared.stopClip() }
        .onChange(of: daily) { _ in query = "" }
    }

    private var guesses: [String] {
        guard daily else { return unlimitedGuesses }
        let parts = saved.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts.prefix(3).joined(separator: "|") == key else { return [] }
        return parts[3].split(separator: ",").map(String.init)
    }
    private func add(_ guess: String) {
        let list = guesses + [guess]
        if daily { saved = "\(key)|\(list.joined(separator: ","))" } else { unlimitedGuesses = list }
        query = ""
    }
    private func restart() { unlimitedGuesses = []; query = ""; AmbientPlayer.shared.stopClip() }

    /// Where the clip starts: the intro, or a spot 20–70% into the song picked by the round.
    private func start(_ song: Song, seed: Int) -> Double {
        guard !fromIntro else { return 0 }
        let length = Engine.lengthSeconds(song.l) ?? 180
        return length * (0.2 + 0.5 * Double((seed &* 2654435761) % 1000) / 1000)
    }

    @ViewBuilder private func game(_ answer: Song, seed: Int) -> some View {
        let list = guesses, target = Engine.normalize(answer.n)
        let won = list.last.flatMap { id in store.songs.first { $0.s.id == id } }.map { Engine.normalize($0.n) == target } ?? false
        let done = won || list.count >= 6
        let seconds = done ? 16 : Self.steps[min(list.count, 5)]
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button {
                    if let url = EngineLibrary.shared.playableURL(answer.i) { AmbientPlayer.shared.playClip(url, from: start(answer, seed: seed), seconds: seconds) }
                } label: { Label("Play \(Int(seconds)) second\(seconds == 1 ? "" : "s")", systemImage: "play.fill").font(JT.body(15, .semibold)) }
                .keyboardShortcut(.space, modifiers: [])
                // how much is unlocked
                HStack(spacing: 3) {
                    ForEach(0..<6, id: \.self) { k in
                        Capsule().fill(k <= min(list.count, 5) || done ? JT.lavender : Color.white.opacity(0.15)).frame(width: CGFloat(Self.steps[k] * 6 + 8), height: 6)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<6, id: \.self) { r in
                    let id = r < list.count ? list[r] : nil
                    let s = id.flatMap { id in store.songs.first { $0.s.id == id } }
                    HStack(spacing: 8) {
                        if id == "-" { Image(systemName: "forward.fill").foregroundColor(JT.muted); Text("Skipped").foregroundColor(JT.muted) }
                        else if let s {
                            let right = Engine.normalize(s.n) == target
                            Image(systemName: right ? "checkmark.circle.fill" : "xmark.circle").foregroundColor(right ? JT.have : JT.missing)
                            Text(s.n).lineLimit(1)
                            if !right && s.e == answer.e { Text("right era").font(JT.body(11, .bold)).foregroundColor(.black).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(tileYellow)) }
                        } else { Text(" ") }
                    }
                    .font(JT.body(14)).padding(.horizontal, 10).frame(maxWidth: 520, minHeight: 32, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(r < list.count ? 0.08 : 0.04)))
                }
            }
            if done {
                VStack(alignment: .leading, spacing: 8) {
                    Text(won ? "Got it with \(Int(Self.steps[list.count - 1])) second\(list.count == 1 ? "" : "s")!" : "Out of tries. It was:").font(JT.body(18, .bold))
                    Text(answer.n).font(JT.marker(28)).foregroundColor(JT.lavender)
                    Text(answer.e).foregroundColor(JT.muted)
                    HStack {
                        Button("Open the song card") { store.openSong = answer }
                        if daily { Text("A new song tomorrow.").foregroundColor(JT.muted) }
                        else { Button("Next song") { unlimitedPick = Int.random(in: 0..<10_000); restart() } }
                    }
                }
                .onAppear { count(won: won) }
            } else {
                HStack(spacing: 10) {
                    TextField("Search for the song", text: $query).textFieldStyle(.roundedBorder).frame(width: 360)
                    Button("Skip (+\(Int(Self.steps[min(list.count + 1, 5)] - Self.steps[min(list.count, 5)]))s)") { add("-") }
                }
                let q = Engine.normalize(query)
                if q.count >= 2 {
                    var seen = Set<String>()
                    let matches = store.songs.filter { Engine.normalize($0.n).contains(q) && seen.insert(Engine.normalize($0.n)).inserted }.prefix(8)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(matches), id: \.i) { s in
                            Button { add(s.s.id) } label: {
                                HStack { Text(s.n); Spacer(); Text(s.e).foregroundColor(JT.muted) }.padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: 360).background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.4)))
                }
            }
        }
    }

    private func count(won: Bool) {
        guard daily, counted != today else { return }
        var st = stats.split(separator: ",").map { Int($0) ?? 0 } + [0, 0, 0, 0]
        st[0] += 1
        if won { st[1] += 1; st[2] = counted == Self.day.string(from: Date().addingTimeInterval(-86400)) ? st[2] + 1 : 1; st[3] = max(st[3], st[2]) } else { st[2] = 0 }
        stats = st.prefix(4).map(String.init).joined(separator: ","); counted = today
    }
}

// MARK: - Desktop widgets

/// Small floating widgets: a clock, what's playing (play/pause, next), up next, and an edge light that makes the
/// screen's edges glow with the music. Each is on or off in Settings > Look; drag one to move it (right-click to
/// close it). They stay where you put them.
@MainActor enum DesktopWidgets {
    static let changed = Notification.Name("DesktopWidgetsChanged")
    static let kinds: [(key: String, name: String)] = [("clock", "Clock"), ("playing", "What's playing"), ("upnext", "Up next"), ("playlist", "Playlist"), ("edge", "Edge light")]
    private static var windows: [String: NSWindow] = [:]
    static func isOn(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: "widget.\(key)") }
    /// The edge light follows the music's loudness, so the meter keeps ticking while the app is in the background.
    static var wantsLevel: Bool { windows["edge"] != nil }

    /// The edge light's windows on the other screens (the main screen's is windows["edge"]).
    private static var edgeOthers: [NSWindow] = []
    private static var screensWatch: NSObjectProtocol?

    static func apply() {
        for (key, _) in kinds {
            if isOn(key), windows[key] == nil { open(key) }
            if !isOn(key), let w = windows.removeValue(forKey: key) { w.close(); if key == "edge" { edgeOthers.forEach { $0.close() }; edgeOthers = [] } }
        }
        // a screen plugged in or out (or "every screen" turned on or off): the edge light goes round the screens there are now
        if screensWatch == nil {
            screensWatch = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { reopenEdge() }
            }
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static func close(_ key: String) { UserDefaults.standard.set(false, forKey: "widget.\(key)"); apply() }
    static func isLocked(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: "widget.locked.\(key)") }
    /// A locked widget stays put when dragged.
    static func setLocked(_ key: String, _ locked: Bool) {
        UserDefaults.standard.set(locked, forKey: "widget.locked.\(key)")
        windows[key]?.isMovableByWindowBackground = !locked
    }

    private static func open(_ key: String) {
        if key == "edge" { openEdge(); return }
        let view: AnyView
        let size: NSSize
        switch key {
        case "clock": view = AnyView(ClockWidget()); size = NSSize(width: 260, height: 130)
        case "playing": view = AnyView(PlayingWidget()); size = NSSize(width: 340, height: 96)
        case "playlist": view = AnyView(PlaylistWidget()); size = NSSize(width: 290, height: 300)
        default: view = AnyView(UpNextWidget()); size = NSSize(width: 280, height: 220)
        }
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true; p.level = .floating
        p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = false
        p.isMovableByWindowBackground = !isLocked(key)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: view.contextMenu { WidgetMenu(key: key) })
        if !p.setFrameUsingName("widget.\(key)") {
            let v = NSScreen.main?.visibleFrame ?? .zero, k = CGFloat(kinds.firstIndex { $0.key == key } ?? 0)
            p.setFrameOrigin(NSPoint(x: v.maxX - size.width - 30, y: max(v.minY + 20, v.maxY - size.height - 30 - k * 150)))
        }
        p.setFrameAutosaveName("widget.\(key)")
        p.orderFrontRegardless()
        windows[key] = p
    }

    /// Settings > Look: the edge light on every screen, or only the main one.
    static var edgeEverywhere: Bool { Pref.bool("widget.edgeAll", default: true) }
    static func reopenEdge() {
        guard let w = windows.removeValue(forKey: "edge") else { return }
        w.close(); edgeOthers.forEach { $0.close() }; edgeOthers = []
        openEdge()
    }

    private static func openEdge() {
        guard let main = NSScreen.main else { return }
        let screens = [main] + (edgeEverywhere ? NSScreen.screens.filter { $0 != main } : [])
        let all = screens.map { screen -> NSWindow in
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            w.level = .floating; w.backgroundColor = .clear; w.isOpaque = false; w.hasShadow = false
            w.ignoresMouseEvents = true // clicks go through to whatever is underneath
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.isReleasedWhenClosed = false
            w.contentView = EdgeLightView(frame: NSRect(origin: .zero, size: screen.frame.size))
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            return w
        }
        windows["edge"] = all[0]; edgeOthers = Array(all.dropFirst())
    }
}

private struct WidgetMenu: View {
    let key: String
    @AppStorage private var locked: Bool
    init(key: String) { self.key = key; _locked = AppStorage(wrappedValue: false, "widget.locked.\(key)") }
    var body: some View {
        Button(locked ? "Unlock position" : "Lock position") { DesktopWidgets.setLocked(key, !locked) }
        Button("Close this widget") { DesktopWidgets.close(key) }
    }
}

private struct WidgetBox<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color(red: 0.06, green: 0.03, blue: 0.13).opacity(0.78)))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.14)))
            .foregroundColor(JT.mist).font(JT.body(13)).preferredColorScheme(.dark)
    }
}

private struct ClockWidget: View {
    private static let time: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("jmm")
        f.dateFormat = f.dateFormat.replacingOccurrences(of: "a", with: "").trimmingCharacters(in: .whitespaces); return f
    }()
    /// Takes the cover's color while a song plays.
    @State private var glow = JT.lavender
    private let changed = NotificationCenter.default.publisher(for: AmbientPlayer.changed)
    var body: some View {
        WidgetBox {
            TimelineView(.everyMinute) { ctx in
                VStack(alignment: .leading, spacing: 0) {
                    Text(ctx.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(JT.body(13, .semibold)).foregroundColor(glow)
                    Text(Self.time.string(from: ctx.date)).font(.custom("HelveticaNeue-CondensedBold", size: 64)).shadow(color: glow.opacity(0.6), radius: 14)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 18).fill(glow.opacity(0.1)).allowsHitTesting(false))
        .animation(.easeInOut(duration: 1.2), value: glow)
        .onAppear(perform: tint).onReceive(changed) { _ in tint() }
    }
    private func tint() {
        let p = AmbientPlayer.shared
        glow = p.isPlaying ? (p.coverImage.map(CoverPalette.init(image:)) ?? .fallback).a : JT.lavender
    }
}

private struct PlayingWidget: View {
    @State private var version = 0
    private let changed = NotificationCenter.default.publisher(for: AmbientPlayer.changed)
    var body: some View {
        let p = AmbientPlayer.shared
        WidgetBox {
            HStack(spacing: 12) {
                Group { if let img = p.coverImage { Image(nsImage: img).resizable().scaledToFill() } else { Image("jt-logo").resizable().scaledToFit().padding(8) } }
                    .frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.title ?? "Nothing playing").font(JT.body(14, .bold)).lineLimit(1)
                    Text(NowPlaying.shared.song?.e ?? "Juice Tracker").foregroundColor(JT.muted).lineLimit(1)
                    HStack(spacing: 14) {
                        Button { if p.title == nil { EngineAmbient.setOn(true); p.resume() } else { p.togglePause() } } label: { Image(systemName: p.isPlaying ? "pause.fill" : "play.fill") }
                        Button { p.skip() } label: { Image(systemName: "forward.fill") }
                    }
                    .buttonStyle(.plain).font(.system(size: 15)).padding(.top, 2)
                }
            }
        }
        .onReceive(changed) { _ in version += 1 }
        .id(version)
    }
}

private struct UpNextWidget: View {
    @State private var version = 0
    private let changed = NotificationCenter.default.publisher(for: AmbientPlayer.changed)
    var body: some View {
        let p = AmbientPlayer.shared
        WidgetBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Up next").font(JT.marker(18)).foregroundColor(JT.lavender)
                if let t = p.title { Text("♪ \(t)").font(JT.body(13, .bold)).lineLimit(1) }
                if p.upNext.isEmpty { Text(EngineAmbient.era.isEmpty ? "Shuffle after this" : "\(EngineAmbient.era) after this").foregroundColor(JT.muted) }
                ForEach(Array(p.upNext.prefix(6).enumerated()), id: \.offset) { k, item in
                    Text("\(k + 1). \(item.title)").lineLimit(1).foregroundColor(JT.mist.opacity(0.85))
                }
            }
        }
        .onReceive(changed) { _ in version += 1 }
        .id(version)
    }
}

/// A playlist (or the songs you rated 4 or 5 hearts) on the desktop; click a song to play from it.
private struct PlaylistWidget: View {
    @AppStorage("widget.playlistPick") private var pick = "" // a playlist id, or "" for liked songs
    @ObservedObject private var store = NativeStore.shared
    var body: some View {
        let lists = EngineState.shared.playlists
        let list = lists.first { $0.id == pick }
        let ids = list?.songs ?? store.songs.filter { (EngineState.shared.ratings[$0.s.id] ?? 0) >= 4 }.map(\.s.id)
        let byId = Dictionary(store.songs.map { ($0.s.id, $0) }, uniquingKeysWith: { a, _ in a })
        let songs = ids.compactMap { byId[$0] }.filter(\.o)
        WidgetBox {
            VStack(alignment: .leading, spacing: 5) {
                Menu {
                    Button("Liked songs") { pick = "" }
                    ForEach(lists) { p in Button(p.name) { pick = p.id } }
                } label: { Text(list?.name ?? "Liked songs").font(JT.marker(18)).foregroundColor(JT.lavender) }
                .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
                if songs.isEmpty { Text(list == nil ? "Rate songs 4 or 5 hearts to see them here." : "No songs you have in this playlist.").foregroundColor(JT.muted) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(songs.enumerated()), id: \.offset) { k, s in
                            Button { playInOrder(songs[k...].map(\.i)) } label: {
                                Text("\(k + 1). \(s.n)").lineLimit(1).foregroundColor(AmbientPlayer.shared.title == s.n ? JT.lavender : JT.mist.opacity(0.85))
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

/// A glow around the screen's edges in the song's colours, brighter on the beat. Core Animation; clicks pass through.
final class EdgeLightView: NSView {
    private let glow = CAShapeLayer()
    private var meter: AnyCancellable?
    private var tokens: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glow.fillColor = nil; glow.lineWidth = 6
        glow.shadowRadius = 34; glow.shadowOpacity = 1; glow.shadowOffset = .zero
        glow.opacity = AmbientPlayer.shared.isPlaying ? 0.25 : 0
        layer?.addSublayer(glow)
        recolor()
        for name in [AmbientPlayer.changed, DesktopWidgets.changed] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.recolor() } })
        }
        // brighter on the beat; fades out when the music stops
        meter = LevelMeter.shared.$level.sink { [weak self] level in
            MainActor.assumeIsolated {
                let on = AmbientPlayer.shared.isPlaying
                CATransaction.begin(); CATransaction.setAnimationDuration(on ? 0.12 : 1.2)
                self?.glow.opacity = on ? Float(0.25 + CGFloat(level) * 0.75) : 0
                CATransaction.commit()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    override func layout() { super.layout(); glow.frame = bounds; glow.path = CGPath(rect: bounds.insetBy(dx: 2, dy: 2), transform: nil) }
    /// The cover's two strongest colors, or your own color (Settings > Look).
    private func recolor() {
        if let own = EraTheme.color(UserDefaults.standard.string(forKey: "widget.edgeColor")) {
            glow.strokeColor = own.cgColor; glow.shadowColor = own.cgColor; return
        }
        let palette = AmbientPlayer.shared.coverImage.map(CoverPalette.init(image:)) ?? .fallback
        CATransaction.begin(); CATransaction.setAnimationDuration(1.2)
        glow.strokeColor = NSColor(palette.a).cgColor; glow.shadowColor = NSColor(palette.b).cgColor
        CATransaction.commit()
    }
}

// MARK: - Song share picture

/// A song as a picture (1080 × 1350): the era's art, the title, the era and dates, and whether you have it.
@MainActor func songSharePicture(_ song: Song, details d: SongDetails?) async -> Data? {
    var art: NSImage?
    if let url = await Extras.shared.extras(for: song.s.id)?.image { art = await Extras.shared.image(url) }
    let facts: [(String, String)] = [("Recorded", d?.recordDates ?? ""), ("Released", d?.release ?? ""), ("Surfaced", d?.leakDate ?? ""), ("Length", d?.length ?? ""),
                                     ("Produced by", d?.producers ?? "")].filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }
    let host = NSHostingView(rootView: SongPicture(song: song, art: art, facts: facts))
    host.frame = NSRect(x: 0, y: 0, width: 1080, height: 1350)
    return snapshot(host)
}

private struct SongPicture: View {
    let song: Song
    let art: NSImage?
    let facts: [(String, String)]
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 7 / 255, green: 4 / 255, blue: 15 / 255), Color(red: 29 / 255, green: 11 / 255, blue: 64 / 255), Color(red: 74 / 255, green: 18 / 255, blue: 80 / 255)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let art { Image(nsImage: art).resizable().scaledToFill().frame(width: 1080, height: 1350).clipped().opacity(0.18) }
            VStack(spacing: 30) {
                Group { if let art { Image(nsImage: art).resizable().scaledToFill() } else { Image(eraSticker(song.e, fallback: song.i)).resizable().scaledToFit().padding(40) } }
                    .frame(width: 420, height: 420).clipShape(RoundedRectangle(cornerRadius: 30)).shadow(color: .black.opacity(0.6), radius: 30, y: 12)
                Text(song.n).font(JT.marker(64)).foregroundColor(.white).multilineTextAlignment(.center)
                Text("Juice WRLD · \(song.e) · \(song.c)").font(JT.body(28, .semibold)).foregroundColor(JT.lavender)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(facts, id: \.0) { k, v in
                        HStack(alignment: .top) { Text(k).foregroundColor(.white.opacity(0.55)).frame(width: 220, alignment: .leading); Text(v).foregroundColor(.white).lineLimit(2) }
                    }
                }
                .font(JT.body(26)).frame(width: 820)
                Text(song.o ? "✓ In my library" : "Still hunting for this one").font(JT.body(28, .bold)).foregroundColor(song.o ? JT.have : JT.new)
                    .padding(.horizontal, 26).padding(.vertical, 12).background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .padding(.horizontal, 80).frame(width: 1080)
            VStack { Spacer(); Text("Juice Tracker").font(JT.marker(22)).foregroundColor(.white.opacity(0.35)).padding(.bottom, 36) }
        }
        .frame(width: 1080, height: 1350).clipped()
    }
}

// MARK: - Time the lyrics

/// Make synced lyrics for the song playing: play it, and press Space as each line starts (or each word, word by
/// word). The Player then sings your timing. Saved on this Mac; export it as an .lrc file.
struct LyricsMakerSheet: View {
    let close: () -> Void
    @ObservedObject private var now = NowPlaying.shared
    @AppStorage("lyricsMakerWords") private var byWord = false
    @State private var song: Song?
    @State private var lines: [String] = []
    @State private var marks: [[Double]] = []
    @State private var note = ""

    /// The line waiting for its next tap (nil when every line is timed).
    private var cursor: Int? { marks.indices.first { marks[$0].count < need($0) } }
    private func need(_ k: Int) -> Int { byWord ? max(1, lines[k].split(separator: " ").count) : 1 }
    private var sameSong: Bool { song != nil && now.song?.s.id == song?.s.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Time the lyrics").font(JT.marker(26))
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
            if let song, !lines.isEmpty {
                Text("“\(song.n)”: press Space as each \(byWord ? "word" : "line") starts. Delete takes the last tap back and plays from just before it.")
                    .foregroundColor(JT.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Picker("", selection: $byWord) { Text("By line").tag(false); Text("Word by word").tag(true) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 220).disabled(marks.contains { !$0.isEmpty })
                    Button("Start from the top") { restart() }
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        Text(Engine.lrcStamp(AmbientPlayer.shared.currentTime)).font(.system(.body, design: .monospaced)).foregroundColor(JT.muted)
                    }
                    Spacer()
                    if song.o, MyLyrics.lrc(song.s.id) != nil { Button("Remove my timing") { MyLyrics.set(song.s.id, nil); note = "Removed: the site's timing is back." } }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { k, line in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(marks[k].first.map(Engine.lrcStamp) ?? "--:--.--").font(.system(size: 12, design: .monospaced)).foregroundColor(JT.muted).frame(width: 66, alignment: .leading)
                                    let words = line.split(separator: " ").map(String.init)
                                    words.enumerated().reduce(Text("")) { t, w in
                                        t + Text((w.offset == 0 ? "" : " ") + w.element).foregroundColor(w.offset < (byWord ? marks[k].count : marks[k].isEmpty ? 0 : words.count) ? .white : JT.muted)
                                    }
                                }
                                .font(JT.body(15, k == cursor ? .bold : .regular))
                                .padding(.horizontal, 8).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6).fill(k == cursor ? JT.lavender.opacity(0.25) : .clear)).id(k)
                            }
                        }
                    }
                    .onChange(of: cursor) { k in if let k { withAnimation { proxy.scrollTo(k, anchor: .center) } } }
                }
                HStack(spacing: 10) {
                    Button(cursor == nil ? "All timed" : "Tap (Space)") { tap() }.keyboardShortcut(.space, modifiers: []).disabled(cursor == nil || !sameSong)
                    Button("Take back (Delete)") { undo() }.keyboardShortcut(.delete, modifiers: []).disabled(!marks.contains { !$0.isEmpty })
                    Spacer()
                    if !note.isEmpty { Text(note).font(JT.body(12)).foregroundColor(JT.muted) }
                    Button("Export .lrc…") { if let lrc = timed() { _ = Files.save(Data(lrc.utf8), name: "\(Engine.safeName(song.n)).lrc", type: UTType(filenameExtension: "lrc") ?? .plainText) } }.disabled(timed() == nil)
                    Button("Save") { if let lrc = timed() { MyLyrics.set(song.s.id, lrc); note = "Saved: the Player sings your timing." } }.keyboardShortcut(.defaultAction).disabled(timed() == nil)
                }
                if !sameSong { Text("The song changed: play “\(song.n)” again to keep timing it.").font(JT.body(12)).foregroundColor(JT.missing) }
            } else {
                Text(now.song == nil ? "Play a song first; its lyrics show up here." : "The site has no lyrics for this song to time.").foregroundColor(JT.muted)
            }
        }
        .padding(22).frame(width: 760, height: 600, alignment: .topLeading)
        .onAppear(perform: load)
        .onChange(of: byWord) { _ in marks = lines.map { _ in [] } }
    }

    private func load() {
        song = now.song
        guard let x = now.extras else { return }
        let source = x.lyrics.isEmpty ? x.synced.map(\.line) : x.lyrics.components(separatedBy: .newlines)
        lines = source.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        marks = lines.map { _ in [] }
    }
    private func restart() {
        marks = lines.map { _ in [] }; note = ""
        AmbientPlayer.shared.seek(to: 0)
        if !AmbientPlayer.shared.isPlaying { AmbientPlayer.shared.togglePause() }
    }
    private func tap() {
        guard let k = cursor, sameSong else { return }
        marks[k].append(AmbientPlayer.shared.currentTime)
    }
    private func undo() {
        guard let k = marks.lastIndex(where: { !$0.isEmpty }), let t = marks[k].popLast() else { return }
        AmbientPlayer.shared.seek(to: max(0, t - 3))
    }
    /// The lines timed so far as LRC, or nil before the first tap.
    private func timed() -> String? {
        let done = lines.indices.filter { marks[$0].count == need($0) }
        guard !done.isEmpty else { return nil }
        return Engine.formatLrc(done.map { Engine.LrcLine(at: marks[$0][0], line: lines[$0], words: byWord ? marks[$0] : []) })
    }
}
