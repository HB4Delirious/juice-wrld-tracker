import AppKit
import SwiftUI

// Hunt (a missing song a day, and suggestions), Playlists (with M3U export), and Organize (the file organizer, the
// inbox folder and Fill a drive).

// MARK: - Shared bits

/// Plays these songs next, in order, from your own files.
@MainActor func playInOrder(_ songs: [Int]) {
    let library = EngineLibrary.shared, catalog = EngineState.shared.catalog, p = AmbientPlayer.shared
    let items = songs.compactMap { i in library.playableURL(i).map { ($0, catalog[i].name) } }
    guard !items.isEmpty else { return }
    EngineAmbient.on = true
    let wasPlaying = p.title != nil
    p.clearUpNext()
    for (url, name) in items { p.queueNext(url, title: name) }
    if wasPlaying { p.skip() }
}

/// An M3U playlist of the songs you have (absolute paths, so Music, VLC and Plex on this Mac can open it).
@MainActor func m3u(_ songs: [Int]) -> String {
    let library = EngineLibrary.shared, catalog = EngineState.shared.catalog
    return Engine.m3u(songs.compactMap { i in library.playableURL(i).map { ($0.path, catalog[i].name, Engine.lengthSeconds(catalog[i].length)) } })
}

@MainActor func saveM3U(_ songs: [Int], name: String) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "\(Engine.safeName(name)).m3u"
    panel.allowedContentTypes = [.init(filenameExtension: "m3u") ?? .plainText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try? m3u(songs).write(to: url, atomically: true, encoding: .utf8)
}

/// How many times each song played in the app.
@MainActor func playCounts() -> [Int: Int] {
    let library = EngineLibrary.shared
    var byPath: [String: Int] = [:]
    for e in AmbientPlayer.playLog { byPath[e.path, default: 0] += 1 }
    var out: [Int: Int] = [:]
    for (i, paths) in library.match.owned {
        out[i] = paths.compactMap { library.url(of: $0)?.path }.reduce(0) { $0 + (byPath[$1] ?? 0) }
    }
    return out
}

/// "Add to playlist" for a song row or card.
struct AddToPlaylistMenu: View {
    let ids: [String]
    var body: some View {
        Menu("Add to playlist") {
            ForEach(EngineState.shared.playlists) { p in Button(p.name) { EngineState.shared.addToPlaylist(p.id, ids) } }
            Divider()
            Button("New playlist") {
                EngineState.shared.setPlaylists(EngineState.shared.playlists + [.init(id: UUID().uuidString, name: "New playlist", songs: ids)])
                NativeStore.shared.openSong = nil
                NativeStore.shared.page = .playlists
            }
        }
    }
}

// MARK: - Hunt

struct HuntScreen: View {
    @ObservedObject private var store = NativeStore.shared
    @State private var skip = 0
    @State private var d: SongDetails?

    /// Today's song: the same all day, a different one tomorrow; "Another one" moves along.
    private var pick: Song? {
        let missing = store.songs.filter { !$0.o }
        guard !missing.isEmpty else { return nil }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        return missing[(day &* 7919 &+ skip &* 104_729) % missing.count]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(text: "Hunt")
                Text("One song you don't have, picked for you each day: its story, and where it might turn up.").foregroundColor(JT.muted)
                if let s = pick {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 16) {
                            Image(eraSticker(s.e, fallback: s.i)).resizable().frame(width: 70, height: 70).rotationEffect(.degrees(-8))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(skip == 0 ? "Today's song" : "Another one").font(.caption.bold()).foregroundColor(JT.lavender)
                                Text(s.n).font(JT.marker(40))
                                HStack { Text("\(s.c) · \(s.e) era").foregroundColor(JT.muted); RarityChip(song: s) }
                            }
                        }
                        if let d {
                            ForEach(story(d), id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                            Text("Where it might turn up").font(.headline).padding(.top, 4)
                            Text(where_(s, d)).foregroundColor(JT.muted).fixedSize(horizontal: false, vertical: true)
                        } else { Spinner999(size: 24) }
                        HStack {
                            if s.f { Button { EngineDownloads.shared.add([s.s.id]) } label: { Label("Download it", systemImage: "arrow.down.circle") }.controlSize(.large) }
                            Button { EngineState.shared.toggleWish(s.s.id) } label: { Label(s.w ? "On your wishlist" : "Add to wishlist", systemImage: s.w ? "star.fill" : "star") }
                            Button("Open song card") { store.openSong = s }
                            Spacer()
                            Button("Another one") { skip += 1 }
                        }
                    }
                    .padding(20).doodled(16)
                    .task(id: s.i) { d = nil; d = await store.details(s.i) }
                } else {
                    Label("You have every song in the catalog.", systemImage: "crown").foregroundColor(JT.have)
                }
                SuggestionsSection()
            }
            .padding(.horizontal, JT.compact ? 18 : 34).padding(.top, JT.compact ? 20 : 40).padding(.bottom, 60)
            .frame(maxWidth: 1080, alignment: .leading)
        }
    }

    private func story(_ d: SongDetails) -> [String] {
        var out: [String] = []
        // The catalog's text often starts with its own "Recorded" and ends with a period.
        let when = d.recordDates.replacingOccurrences(of: #"^\s*recorded\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let at = d.locations.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let by = d.producers.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if !when.isEmpty { out.append("Recorded \(when)\(at.isEmpty ? "" : " at \(at)")\(by.isEmpty ? "" : ", produced by \(by)").") }
        if !d.sessions.isEmpty { out.append("Sessions: \(d.sessions).") }
        if !d.previewDate.isEmpty { out.append("Previewed \(d.previewDate).") }
        if !d.leakDate.isEmpty { out.append("Surfaced \(d.leakDate)\(d.leakType.isEmpty ? "" : " (\(d.leakType))").") }
        if !d.notes.isEmpty { out.append(d.notes) }
        return out.isEmpty ? ["The catalog has no story for this one yet."] : out
    }

    private func where_(_ s: Song, _ d: SongDetails) -> String {
        if s.f { return "juicewrldapi.com has a file for it: Download it puts it straight into the right era folder." }
        if s.s.rel { return "It's released, so it's on the streaming services and stores; buy or rip your own copy and drop it in your inbox folder (Organize)." }
        if !d.leakDate.isEmpty || !d.previewDate.isEmpty {
            return "No file on the site yet. Songs that were previewed or snippeted often surface later in leaks or group buys. Put it on your wishlist and the daily check tells you the moment a file appears."
        }
        return "Nothing has surfaced yet. Wishlist it: the daily check watches for a file and alerts you with a Download button."
    }
}

/// "You rated these highly, so try…": songs you don't have that share a name, producer or era with your 4–5 heart songs.
private struct SuggestionsSection: View {
    @ObservedObject private var store = NativeStore.shared

    private var picks: [(Song, String)] {
        let ratings = EngineState.shared.ratings, songs = store.songs
        let loved = songs.filter { (ratings[$0.s.id] ?? 0) >= 4 }
        guard !loved.isEmpty else { return [] }
        var score: [Int: (Int, String)] = [:]
        func bump(_ s: Song, _ n: Int, _ why: String) { if !s.o, (score[s.i]?.0 ?? 0) < n { score[s.i] = (n, why) } }
        for l in loved {
            let key = Engine.normalize(l.n), producers = Set(l.s.pr)
            for s in songs where s.i != l.i && !s.o {
                if Engine.normalize(s.n) == key { bump(s, 3, "another version of “\(l.n)”") }
                else if let p = s.s.pr.first(where: producers.contains) { bump(s, 2, "produced by \(p), like “\(l.n)”") }
                else if s.e == l.e && s.f { bump(s, 1, "from the \(l.e) era, like “\(l.n)”") }
            }
        }
        return score.sorted { $0.value.0 != $1.value.0 ? $0.value.0 > $1.value.0 : $0.key < $1.key }.prefix(12).map { (songs[$0.key], $0.value.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You rated these highly, so try…").font(.title3.bold())
            let list = picks
            if list.isEmpty { Text("Rate songs 4 or 5 hearts on their cards, and suggestions show up here.").foregroundColor(JT.muted) }
            ForEach(list, id: \.0.i) { s, why in
                HStack {
                    Button(s.n) { store.openSong = s }.buttonStyle(.link)
                    Text(why).font(.caption).foregroundColor(JT.muted)
                    Spacer()
                    if s.f { Button("Download") { EngineDownloads.shared.add([s.s.id]) } }
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).doodled(14)
    }
}

// MARK: - Playlists

struct PlaylistsScreen: View {
    @ObservedObject private var store = NativeStore.shared
    @State private var picked: String?

    var body: some View {
        let lists = EngineState.shared.playlists
        VStack(alignment: .leading, spacing: 16) {
            ScreenTitle(text: "Playlists")
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lists) { p in
                        Button { picked = p.id } label: {
                            HStack { Text(p.name).lineLimit(1); Spacer(); Text("\(p.songs.count)").foregroundColor(JT.muted) }
                                .padding(.vertical, 6).padding(.horizontal, 10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(picked == p.id ? JT.raise : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                    Button { let p = EngineState.Playlist(id: UUID().uuidString, name: "New playlist", songs: []); EngineState.shared.setPlaylists(lists + [p]); picked = p.id } label: {
                        Label("New playlist", systemImage: "plus")
                    }
                    .buttonStyle(.borderless).padding(.top, 6)
                    Divider().padding(.vertical, 8)
                    SmartExports()
                }
                .frame(width: 240)
                if let p = lists.first(where: { $0.id == picked }) ?? lists.first { PlaylistDetail(playlist: p) } else {
                    Text("Make a playlist here, then add songs from a song's card or a row's right-click menu.").foregroundColor(JT.muted)
                }
            }
        }
        .padding(.horizontal, JT.compact ? 18 : 34).padding(.top, JT.compact ? 20 : 40).padding(.bottom, 30)
        .frame(maxWidth: 1080, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PlaylistDetail: View {
    let playlist: EngineState.Playlist
    @ObservedObject private var store = NativeStore.shared
    @State private var name = ""
    @State private var askDownload = false

    var body: some View {
        let byId = Dictionary(store.songs.map { ($0.s.id, $0) }, uniquingKeysWith: { a, _ in a })
        let songs = playlist.songs.compactMap { byId[$0] }
        let missing = songs.filter { !$0.o && $0.f }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).font(.title3).frame(maxWidth: 320)
                Spacer()
                Button { playInOrder(songs.filter(\.o).map(\.i)) } label: { Label("Play", systemImage: "play.fill") }.disabled(!songs.contains(where: \.o))
                Button("Export M3U…") { saveM3U(songs.map(\.i), name: playlist.name) }.disabled(!songs.contains(where: \.o))
                if !missing.isEmpty { Button("Download \(missing.count) missing") { askDownload = true } }
                Button(role: .destructive) { EngineState.shared.setPlaylists(EngineState.shared.playlists.filter { $0.id != playlist.id }) } label: { Image(systemName: "trash") }
                    .help("Delete this playlist").accessibilityLabel("Delete this playlist")
            }
            Text("Drag to reorder. Songs you don't have yet stay on the list but are skipped when playing and exporting.").font(.caption).foregroundColor(JT.muted)
            List {
                ForEach(songs, id: \.s.id) { s in
                    HStack {
                        Text(s.n).foregroundColor(s.o ? JT.mist : JT.muted)
                        Spacer()
                        Text(s.e).foregroundColor(JT.muted).font(.caption)
                        Button { update { $0.songs.removeAll { $0 == s.s.id } } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Remove \(s.n)")
                    }
                }
                .onMove { from, to in update { p in var ids = songs.map(\.s.id); ids.move(fromOffsets: from, toOffset: to); p.songs = ids } }
            }
            .frame(minHeight: 300)
            .clearListBackground()
        }
        .onAppear { name = playlist.name }
        .onChange(of: playlist.id) { _ in name = playlist.name }
        .alert("Download \(missing.count) songs into your music folder?", isPresented: $askDownload) {
            Button("Download") { EngineDownloads.shared.add(missing.map(\.s.id)) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The songs in this playlist you don't have yet, one at a time, into the folders the tracker picks for each era.") }
        .onChange(of: name) { typed in // saved on every keystroke, so switching playlists right away keeps it
            guard typed != playlist.name, !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            update { $0.name = typed }
        }
    }

    private func update(_ change: (inout EngineState.Playlist) -> Void) {
        var lists = EngineState.shared.playlists
        guard let n = lists.firstIndex(where: { $0.id == playlist.id }) else { return }
        change(&lists[n])
        EngineState.shared.setPlaylists(lists)
    }
}

/// One-click M3U files: an era, your wishlist, top rated, or never played.
private struct SmartExports: View {
    @ObservedObject private var store = NativeStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Smart M3U").font(.caption.bold()).foregroundColor(JT.muted)
            Menu("Export an era…") {
                ForEach(Array(Set(store.songs.filter(\.o).map(\.e))).sorted(), id: \.self) { e in
                    Button(e) { saveM3U(store.songs.filter { $0.o && $0.e == e }.sorted { ($0.s.m ?? 0) < ($1.s.m ?? 0) }.map(\.i), name: e) }
                }
            }
            Button("Top rated") {
                let r = EngineState.shared.ratings
                saveM3U(store.songs.filter { $0.o && (r[$0.s.id] ?? 0) > 0 }.sorted { (r[$0.s.id] ?? 0) > (r[$1.s.id] ?? 0) }.map(\.i), name: "Top rated")
            }
            Button("Wishlist (the ones you have)") { saveM3U(store.songs.filter { $0.o && $0.w }.map(\.i), name: "Wishlist") }
            Button("Never played") { let plays = playCounts(); saveM3U(store.songs.filter { $0.o && (plays[$0.i] ?? 0) == 0 }.map(\.i), name: "Never played") }
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Organize

struct OrganizeScreen: View {
    @ObservedObject private var store = NativeStore.shared
    @ObservedObject private var library = EngineLibrary.shared
    @AppStorage("organizePattern") private var pattern = "{era}/{song}"
    @State private var plan: [(from: String, to: String)] = []
    @State private var pending: Pending?
    @State private var result: (String, Bool)?
    @State private var inbox = EngineLibrary.inbox?.path ?? ""
    @State private var previewed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(text: "Organize")
                if let result { Banner(text: result.0, error: result.1) }

                VStack(alignment: .leading, spacing: 10) {
                    Text("File organizer").font(.title3.bold())
                    Text("Renames and moves matched files into a pattern inside your music folder. Use {era}, {song}, {category} and {year}; slashes make folders. Nothing moves until you confirm, a file never replaces another, and Undo puts everything back.")
                        .font(.caption).foregroundColor(JT.muted).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("{era}/{song}", text: $pattern).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                        Button("Preview") { previewed = true; plan = Engine.organizePlan(files: library.files, match: library.match, catalog: EngineState.shared.catalog, pattern: pattern) }
                        if !plan.isEmpty {
                            Button("Move \(EngineTools.plural(plan.count, "file", "files"))") {
                                let p = plan
                                pending = Pending(title: "Move \(EngineTools.plural(p.count, "file", "files"))?", message: "They move inside your music folder; nothing is replaced or deleted. Plex sees the new places on its next scan, and Undo puts them back.",
                                                  button: "Move files", run: { let r = await EngineLibrary.shared.organize(p); plan = []; return r })
                            }
                        }
                        if !library.lastOrganize.isEmpty {
                            Button("Undo last organize") { Task { result = (await EngineLibrary.shared.undoOrganize(), false) } }
                        }
                    }
                    if !plan.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(plan.prefix(200).enumerated()), id: \.offset) { _, m in
                                Text("\(m.from)  →  \(m.to)").font(.caption.monospaced()).foregroundColor(JT.muted).lineLimit(1).truncationMode(.middle)
                            }
                            if plan.count > 200 { Text("and \(plan.count - 200) more").font(.caption).foregroundColor(JT.muted) }
                        }
                    } else if previewed {
                        Text("Every file already fits that pattern (or can't be placed for sure, like a title shared by different songs).").font(.caption).foregroundColor(JT.muted)
                    } else if library.root != nil {
                        Text("Preview shows each move before anything happens.").font(.caption).foregroundColor(JT.muted)
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).doodled(14)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Inbox folder").font(.title3.bold())
                    Text("Drop songs into this folder (outside your music folder). Each one the tracker recognizes moves into its era's folder and gets the catalog's tags, once it has finished copying. Anything else stays in the inbox for you to look at, with a note saying why.")
                        .font(.caption).foregroundColor(JT.muted).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(inbox.isEmpty ? "Choose an inbox folder…" : "Change…") { pickInbox() }
                        if !inbox.isEmpty {
                            Text(inbox).font(.caption.monospaced()).foregroundColor(JT.muted).lineLimit(1).truncationMode(.middle)
                            Button("Stop using it") { EngineLibrary.inbox = nil; inbox = ""; EngineLibrary.shared.watchInbox() }
                        }
                    }
                    if !EngineLibrary.inboxNote.isEmpty { Text(EngineLibrary.inboxNote).font(.caption) }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).doodled(14)

                FillDriveCard()
            }
            .padding(.horizontal, JT.compact ? 18 : 34).padding(.top, JT.compact ? 20 : 40).padding(.bottom, 60)
            .frame(maxWidth: 1080, alignment: .leading)
        }
        .confirming($pending, result: $result)
    }

    private func pickInbox() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Use as inbox"
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL else { return }
        if let root = library.root?.standardizedFileURL, url.path == root.path || url.path.hasPrefix(root.path + "/") || root.path.hasPrefix(url.path + "/") {
            result = ("Pick a folder outside your music folder, so the inbox and the library don't overlap.", true); return
        }
        EngineLibrary.inbox = url; inbox = url.path
        EngineLibrary.shared.watchInbox()
    }
}

/// Copies your best songs onto a phone, USB stick or other drive, up to a size: best rated first, then the rarest,
/// then the most played. Copies only; nothing in your library changes, and files already there are skipped.
private struct FillDriveCard: View {
    @ObservedObject private var store = NativeStore.shared
    @State private var target: URL?
    @State private var gb = 32.0
    @State private var status = ""
    @State private var copying = false

    private var picks: [(path: String, size: Int)] {
        let library = EngineLibrary.shared, catalog = EngineState.shared.catalog, ratings = EngineState.shared.ratings, plays = playCounts()
        func rank(_ i: Int) -> (Int, Int, Int) {
            let r = Engine.rarity(catalog[i], owned: true)
            return (ratings[catalog[i].id] ?? 0, r == "Grail" ? 2 : r == "Rare" ? 1 : 0, plays[i] ?? 0)
        }
        let ordered = library.match.owned.keys.sorted { rank($0) != rank($1) ? rank($0) > rank($1) : $0 < $1 }
        let sizes = Dictionary(library.files.map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a })
        var out: [(String, Int)] = [], total = 0, seen = Set<String>()
        let budget = Int(gb * 1_000_000_000)
        for i in ordered {
            guard let path = library.match.owned[i]?.first, !seen.contains(path) else { continue }
            let size = sizes[path] ?? 0
            if total + size > budget { continue }
            seen.insert(path); total += size; out.append((path, size))
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fill a drive").font(.title3.bold())
            Text("Copies your best songs to a phone, USB stick or other drive, up to the size you pick: highest rated first, then the rarest, then the most played. Nothing in your library changes.")
                .font(.caption).foregroundColor(JT.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Up to")
                TextField("", value: $gb, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                Text("GB")
                Button(target.map { "To “\($0.lastPathComponent)”" } ?? "Choose where to copy…") { pick() }
                let list = picks
                if let target, !list.isEmpty {
                    Button(copying ? "Copying…" : "Copy \(list.count) songs (\(ByteCountFormatter.string(fromByteCount: Int64(list.reduce(0) { $0 + $1.size }), countStyle: .file)))") {
                        copy(list, to: target)
                    }
                    .disabled(copying)
                }
            }
            if !status.isEmpty { Text(status).font(.caption) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).doodled(14)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Copy here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let root = EngineLibrary.shared.root, url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) {
            status = "Pick a place outside your music folder."; return
        }
        target = url
    }

    private func copy(_ list: [(path: String, size: Int)], to target: URL) {
        copying = true
        let library = EngineLibrary.shared
        let jobs = list.compactMap { f in library.url(of: f.path).map { ($0, target.appendingPathComponent(f.path.split(separator: "/").dropFirst().joined(separator: "/"), isDirectory: false)) } }
        Task {
            var done = 0, skipped = 0, failed = 0
            for (n, (src, dst)) in jobs.enumerated() {
                status = "Copying \(n + 1) of \(jobs.count)…"
                let r = await Task.detached { () -> Int in
                    let fm = FileManager.default
                    if fm.fileExists(atPath: dst.path) { return 1 }
                    do { try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true); try fm.copyItem(at: src, to: dst); return 0 }
                    catch { return 2 }
                }.value
                if r == 0 { done += 1 } else if r == 1 { skipped += 1 } else { failed += 1 }
            }
            status = "Copied \(done) songs.\(skipped > 0 ? " \(skipped) were there already." : "")\(failed > 0 ? " \(failed) couldn't be copied (is the drive full?)." : "")"
            copying = false
        }
    }
}

// MARK: - Wishlist ranking

/// Drag your wishlist into order; "Download wishlist" and wishlist alerts download the top songs first.
struct WishRankSheet: View {
    let close: () -> Void
    @ObservedObject private var store = NativeStore.shared
    @State private var ids: [String] = EngineState.shared.wishRanked

    var body: some View {
        let byId = Dictionary(store.songs.map { ($0.s.id, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 12) {
            Text("Rank your wishlist").font(JT.marker(28))
            Text("Drag the songs you want most to the top. Wishlist downloads go in this order.").foregroundColor(JT.muted)
            List {
                ForEach(Array(ids.enumerated()), id: \.element) { n, id in
                    HStack {
                        Text("\(n + 1)").monospacedDigit().foregroundColor(JT.muted).frame(width: 28, alignment: .trailing)
                        Text(byId[id]?.n ?? "Song \(id)")
                        Spacer()
                        Text(byId[id].map { $0.o ? "In library" : $0.f ? "On the site" : "No file yet" } ?? "").font(.caption).foregroundColor(JT.muted)
                    }
                }
                .onMove { ids.move(fromOffsets: $0, toOffset: $1); EngineState.shared.setWishOrder(ids) }
            }
            .frame(minHeight: 360)
            .clearListBackground()
            HStack {
                Button("Download wishlist") { _ = EngineDownloads.shared.downloadWishlist() }
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 560, height: 560)
        .background(Color(red: 20 / 255, green: 10 / 255, blue: 44 / 255)).preferredColorScheme(.dark)
    }
}

extension View {
    /// Lists over the sky: no gray box (macOS 13 and later; macOS 12 keeps the standard look).
    @ViewBuilder func clearListBackground() -> some View {
        if #available(macOS 13, *) { scrollContentBackground(.hidden).background(Color.white.opacity(0.03)).cornerRadius(10) } else { self }
    }
}
