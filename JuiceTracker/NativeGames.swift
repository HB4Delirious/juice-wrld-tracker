import AppKit
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
                        LyricsCard(lines: chosen.isEmpty ? ["Pick a line"] : chosen, title: song?.n ?? "", era: song?.e ?? "", cover: AmbientPlayer.shared.coverImage)
                            .frame(width: 1080, height: 1350).scaleEffect(0.3).frame(width: 324, height: 405)
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
    private func render(_ lines: [String], _ song: Song?) -> Data? {
        let host = NSHostingView(rootView: LyricsCard(lines: lines, title: song?.n ?? "", era: song?.e ?? "", cover: AmbientPlayer.shared.coverImage))
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
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 7 / 255, green: 4 / 255, blue: 15 / 255), Color(red: 29 / 255, green: 11 / 255, blue: 64 / 255), Color(red: 74 / 255, green: 18 / 255, blue: 80 / 255)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // its own frame: a filled image is wider than the card, and would widen the text's room with it
            if let cover { Image(nsImage: cover).resizable().scaledToFill().frame(width: 1080, height: 1350).clipped().opacity(0.22) }
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 40) {
                Group {
                    if let cover { Image(nsImage: cover).resizable().scaledToFill() } else { Image("jt-logo").resizable().scaledToFit().padding(50) }
                }
                .frame(width: 360, height: 360).clipShape(RoundedRectangle(cornerRadius: 28)).shadow(color: .black.opacity(0.6), radius: 30, y: 12)
                VStack(spacing: 18) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(JT.body(54, .heavy)).foregroundColor(.white).multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 70).frame(width: 1080)
                VStack(spacing: 6) {
                    Text(title).font(JT.marker(42)).foregroundColor(JT.lavender).multilineTextAlignment(.center)
                    Text(era.isEmpty ? "Juice WRLD" : "Juice WRLD · \(era)").font(JT.body(26, .semibold)).foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(.vertical, 90)
            VStack { Spacer(); Text("Juice Tracker").font(JT.marker(22)).foregroundColor(.white.opacity(0.35)).padding(.bottom, 36) }
        }
        .frame(width: 1080, height: 1350).clipped()
    }
}
