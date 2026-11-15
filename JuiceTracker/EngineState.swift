import Foundation

// Stage 2 of replacing the HTML engine: Swift owns the catalog (loading, the 12-hour cache, new and newly released
// songs), your wishlist and notes, and builds everything the screens show. The page still scans the folder, matches,
// downloads and plays; Swift hands it the same catalog, so a song's number means the same song on both sides, and
// takes from it only what you own, the file count, the drive status and the download queue.


@MainActor final class EngineState: ObservableObject {
    static let shared = EngineState()
    static let cacheHours = 12.0

    /// Saved between launches (catalog.json, saved.json, personal.json in EngineFiles.dir).
    struct CatalogFile: Codable { var fetchedAt: Date; var songs: [EngineSong]; var eras: [String: EraInfo] }
    struct Saved: Codable {
        var knownIds: [String]?
        var releaseSnap: [String: Int]?
        var newIds: [String] = []
        var releasedIds: [String] = []
        var prevCheck: Date?
        var lastCheck: Date?
        var firstCheck: Bool?
    }

    @Published private(set) var catalog: [EngineSong] = []
    @Published private(set) var status = ""       // shown under "Load the song catalog"
    @Published private(set) var loading = false
    private(set) var eras: [String: EraInfo] = [:]
    private(set) var saved = Saved()
    private(set) var fetchedAt: Date?
    private(set) var token = 0                    // goes up each time the page is handed the catalog
    private var personal: [String: Any] = [:]     // the page's personal data; Swift edits "wish" and "notes"
    private var started = false
    private var eraCache: (token: Int, order: [Engine.EraStat], names: [String])?
    private var todayCache: (token: Int, day: String, groups: [(key: String, songs: [Int])])?

    var wish: [String: String] { personal["wish"] as? [String: String] ?? [:] }
    var notes: [String: String] { personal["notes"] as? [String: String] ?? [:] }

    // MARK: Starting up

    /// Runs once the page has loaded: moves saved data over from the web view the first time, loads the cached
    /// catalog, hands it to the page, and refreshes it when it's older than 12 hours.
    func start() async {
        guard !started else { return }
        started = true
        if EngineFiles.read("catalog.json") == nil && EngineFiles.read("personal.json") == nil { await migrateFromPage() }
        saved = EngineFiles.read("saved.json").flatMap { try? Self.decoder.decode(Saved.self, from: $0) } ?? Saved()
        personal = EngineFiles.read("personal.json").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if let data = EngineFiles.read("catalog.json"), let file = try? Self.decoder.decode(CatalogFile.self, from: data) {
            catalog = file.songs; eras = file.eras; fetchedAt = file.fetchedAt
            status = "\(file.songs.count.formatted()) songs, loaded \(Self.ago(file.fetchedAt))."
        }
        await pushPersonal()
        if !catalog.isEmpty { await pushCatalog() }
        await EngineLibrary.shared.start() // the folder and your files (it needs the catalog to match against)
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) > Self.cacheHours * 3600 { await reload() }
    }

    /// The first launch with the Swift engine: copy the catalog, its history and your wishlist and notes out of the
    /// page's storage. Read only on the page's side.
    private func migrateFromPage() async {
        guard let json = try? await NativeStore.shared.tryAct("engineExport"),
              let ex = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        let store = ex["store"] as? [String: Any] ?? [:]
        if let personal = ex["personal"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: personal) { try? EngineFiles.write("personal.json", data) }
        try? EngineFiles.write("settings.json", (try? JSONSerialization.data(withJSONObject: ["onlyJuice": ex["onlyJuice"] ?? true, "root": ex["root"] ?? ""])) ?? Data())
        let date: (Any?) -> Date? = { ($0 as? String).flatMap { Self.iso.date(from: $0) } }
        var s = Saved()
        s.knownIds = store["knownIds"] as? [String]
        s.releaseSnap = (store["releaseSnap"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.intValue }
        s.newIds = store["newIds"] as? [String] ?? []
        s.releasedIds = store["releasedIds"] as? [String] ?? []
        s.prevCheck = date(store["prevCheck"]); s.lastCheck = date(store["lastCheck"])
        s.firstCheck = store["firstCheck"] as? Bool
        save(s)
        if let cat = store["catalog"] as? [String: Any], let songs = cat["songs"] as? [[String: Any]], !songs.isEmpty {
            var eras: [String: EraInfo] = [:]
            for (name, v) in cat["eras"] as? [String: [String: Any]] ?? [:] {
                eras[name] = EraInfo(id: (v["id"] as? NSNumber)?.intValue, description: v["description"] as? String ?? "", timeFrame: v["timeFrame"] as? String ?? "")
            }
            let file = CatalogFile(fetchedAt: date(cat["fetchedAt"]) ?? .distantPast, songs: songs.map(Engine.cleanSong), eras: eras)
            if let data = try? Self.encoder.encode(file) { try? EngineFiles.write("catalog.json", data) }
        }
    }

    // MARK: The catalog

    /// Downloads the catalog, notes which songs are new or newly released since the last time, saves it, and hands
    /// it to the page. Same rules as the page's "Reload catalog".
    func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        status = "Connecting to juicewrldapi.com…"
        do {
            let fetched = try await Engine.fetchCatalog { n, total in
                Task { @MainActor in self.status = total.map { "Loaded \(n.formatted()) of \($0.formatted()) songs…" } ?? "Loaded \(n.formatted()) songs…" }
            }
            let songs = fetched.songs, now = Date()
            var s = saved
            let ids = songs.map(\.id), snap = Dictionary(songs.map { ($0.id, Engine.isReleased($0) ? 1 : 0) }, uniquingKeysWith: { a, _ in a })
            if let known = s.knownIds.map(Set.init) {
                s.newIds = ids.filter { !known.contains($0) }
                s.prevCheck = s.lastCheck
                s.firstCheck = false
            } else { s.newIds = []; s.prevCheck = nil; s.firstCheck = true }
            s.releasedIds = s.releaseSnap.map { old in songs.filter { old[$0.id] == 0 && snap[$0.id] == 1 }.map(\.id) } ?? []
            s.releaseSnap = snap; s.knownIds = ids; s.lastCheck = now
            save(s)
            catalog = songs; eras = fetched.eras; fetchedAt = now
            if let data = try? Self.encoder.encode(CatalogFile(fetchedAt: now, songs: songs, eras: fetched.eras)) { try? EngineFiles.write("catalog.json", data) }
            status = "\(songs.count.formatted()) songs loaded."
            await pushCatalog()
            EngineLibrary.shared.rematch()
        } catch {
            status = "\(error.localizedDescription) Try again in a minute."
        }
    }

    /// Gives the page the catalog, so its song numbers are Swift's song numbers.
    private func pushCatalog() async {
        token += 1
        let songs = (try? Self.encoder.encode(catalog)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let eraDict = eras.mapValues { e -> [String: Any] in ["id": e.id.map { $0 as Any } ?? NSNull(), "description": e.description, "timeFrame": e.timeFrame] }
        await NativeStore.shared.act("useCatalog", -1, ["token": token, "songs": songs, "eras": eraDict])
    }

    /// Gives the page your wishlist, notes, hand matches and fixer settings (what it still does uses them).
    private func pushPersonal() async {
        var p: [String: Any] = ["wish": wish, "notes": notes]
        for k in ["matchOverrides", "fixGenre", "autoTag"] { if let v = personal[k] { p[k] = v } }
        await NativeStore.shared.act("setPersonal", -1, p)
    }

    func personalString(_ key: String) -> String { personal[key] as? String ?? "" }
    func personalBool(_ key: String, default d: Bool) -> Bool { personal[key] as? Bool ?? d }
    /// Changes one of your saved settings (hand matches, fixer genre, auto-tag) and saves it.
    func setPersonal(_ key: String, _ value: Any) {
        personal[key] = value
        savePersonal()
    }

    private func save(_ s: Saved) {
        saved = s
        if let data = try? Self.encoder.encode(s) { try? EngineFiles.write("saved.json", data) }
    }

    // MARK: Wishlist and notes

    func toggleWish(_ id: String) {
        var w = wish
        if w[id] != nil { w[id] = nil } else { w[id] = Self.iso.string(from: Date()) }
        personal["wish"] = w
        savePersonal()
    }

    func setNote(_ id: String, _ text: String) {
        var n = notes
        n[id] = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        personal["notes"] = n
        savePersonal()
    }

    /// Adds a backup's wishlist songs and notes that aren't here yet; returns how many of each were added.
    func mergeBackup(wishlist: [[String: Any]], notes added: [[String: Any]]) -> (wish: Int, notes: Int) {
        var w = wish, n = notes, aw = 0, an = 0
        for x in wishlist {
            guard let id = (x["id"] as? String) ?? (x["id"] as? NSNumber)?.stringValue, !id.isEmpty, w[id] == nil else { continue }
            w[id] = (x["added"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.iso.string(from: Date()); aw += 1
        }
        for x in added {
            guard let id = (x["id"] as? String) ?? (x["id"] as? NSNumber)?.stringValue, !id.isEmpty, let t = x["text"] as? String, !t.isEmpty, n[id] == nil else { continue }
            n[id] = t; an += 1
        }
        personal["wish"] = w; personal["notes"] = n
        savePersonal()
        return (aw, an)
    }

    private func savePersonal() {
        if let data = try? JSONSerialization.data(withJSONObject: personal) { try? EngineFiles.write("personal.json", data) }
        UserDefaults.standard.set(Array(wish.keys), forKey: "wishlistIds") // the daily check alerts these songs on their own
        NativeStore.shared.rebuild()
        Task { await pushPersonal() }
    }

    // MARK: What the screens show

    /// The screens' state: Swift's catalog and data, with what you own from the page.
    func build(includeCatalog: Bool) -> NState {
        let library = EngineLibrary.shared, owned = library.owned, wished = wish
        var catOrder: [String] = [], cats: [String: (have: Int, total: Int)] = [:]
        for (i, s) in catalog.enumerated() {
            if cats[s.category] == nil { catOrder.append(s.category); cats[s.category] = (0, 0) }
            cats[s.category]!.total += 1
            if owned.contains(i) { cats[s.category]!.have += 1 }
        }
        let catList = catOrder.enumerated().sorted { a, b in
            cats[a.element]!.total != cats[b.element]!.total ? cats[a.element]!.total > cats[b.element]!.total : a.offset < b.offset
        }.map { NState.Cat(name: Engine.capital($0.element), have: cats[$0.element]!.have, total: cats[$0.element]!.total) }
        // The era order and each song's era only change with the catalog; the counts change with what you own.
        if eraCache?.token != token {
            eraCache = (token, Engine.eraStats(catalog, owned: [], eras: eras), catalog.map(Engine.eraName))
        }
        var have: [String: Int] = [:]
        for i in owned where eraCache!.names.indices.contains(i) { have[eraCache!.names[i], default: 0] += 1 }
        let eraList = eraCache!.order.map {
            NState.Era(name: $0.name, have: have[$0.name] ?? 0, total: $0.total, time: Engine.hasValue($0.timeFrame) ? $0.timeFrame : "",
                       desc: Engine.hasValue($0.description) ? $0.description : "")
        }
        let newIds = Set(saved.newIds), releasedIds = Set(saved.releasedIds)
        return NState(
            total: catalog.count, have: owned.count, folder: library.root?.lastPathComponent ?? "", queue: EngineDownloads.shared.queueState, cats: catList, eras: eraList,
            owned: owned.sorted(),
            wished: catalog.indices.filter { wished[catalog[$0].id] != nil },
            fresh: catalog.indices.filter { newIds.contains(catalog[$0].id) },
            released: catalog.indices.filter { releasedIds.contains(catalog[$0].id) },
            files: library.files.count, drive: library.drive, notices: notices(), today: today(),
            catalog: includeCatalog ? catalog.enumerated().map { Self.catSong($0.offset, $0.element) } : nil)
    }

    private static func catSong(_ i: Int, _ s: EngineSong) -> NState.CatSong {
        let year: (String) -> Int? = { Int(Engine.yearOf($0)) }
        let rel = Engine.isReleased(s)
        return NState.CatSong(i: i, id: s.id, n: s.name, a: s.alt, rel: rel, e: Engine.eraName(s), c: Engine.capital(s.category), l: s.length,
                              f: !s.filePath.isEmpty, m: Engine.recordMonth(s.recordDates), ry: Engine.yearsIn(s.recordDates),
                              py: year(s.previewDate), sy: year(s.leakDate), rl: rel ? year(s.release) : nil,
                              pr: Engine.splitNames(s.producers), ar: Engine.splitNames(s.artists), en: Engine.splitNames(s.engineers),
                              st: Engine.splitStudios(s.locations))
    }

    /// The notes under the scoreboard: newly released songs, new songs, or that nothing changed.
    private func notices() -> [NState.Notice] {
        var out: [NState.Notice] = []
        let since = saved.prevCheck.map { " since your last check on \(Self.shortDate.string(from: $0))" } ?? ""
        let released = Set(saved.releasedIds), names = catalog.filter { released.contains($0.id) }.map(\.name)
        if !names.isEmpty {
            let shown = names.prefix(4).joined(separator: ", ") + (names.count > 4 ? ", and \((names.count - 4).formatted()) more" : "")
            out.append(.init(text: "Now officially released\(since): \(shown). The Now released tab has links to find them on Apple Music and Spotify.", released: true))
        }
        if !saved.newIds.isEmpty {
            out.append(.init(text: "\(saved.newIds.count.formatted()) \(saved.newIds.count == 1 ? "song was" : "songs were") added to the catalog\(since). See the New tab.", released: false))
        }
        if saved.firstCheck == true {
            out.append(.init(text: "This is your first check. Next time you load the catalog, newly added songs and songs that get officially released will be flagged here.", released: false))
        } else if saved.prevCheck != nil && saved.newIds.isEmpty && released.isEmpty {
            out.append(.init(text: "No new songs or releases\(since).", released: false))
        }
        return out
    }

    /// Songs recorded, previewed, surfaced or released on today's date in other years (up to 14 names).
    private func today(now: Date = Date()) -> [NState.TodayRow] {
        let cal = Calendar.current, m = cal.component(.month, from: now) - 1, d = cal.component(.day, from: now)
        let day = "\(m)-\(d)"
        if let c = todayCache, c.token == token, c.day == day { return Self.todayRows(c.groups) }
        let kinds: [(KeyPath<EngineSong, String>, String)] = [(\.recordDates, "Recorded"), (\.previewDate, "Previewed"), (\.leakDate, "Surfaced"), (\.release, "Released")]
        var groups: [String: [Int]] = [:]
        for (i, s) in catalog.enumerated() {
            for (k, label) in kinds { for x in Engine.datesIn(s[keyPath: k]) where x.m == m && x.d == d {
                let key = "\(x.y)|\(label)"
                if !(groups[key] ?? []).contains(i) { groups[key, default: []].append(i) }
            } }
        }
        let sorted = groups.keys.sorted().map { (key: $0, songs: groups[$0]!) }
        todayCache = (token, day, sorted)
        return Self.todayRows(sorted)
    }

    private static func todayRows(_ groups: [(key: String, songs: [Int])]) -> [NState.TodayRow] {
        var shown = 0, rows: [NState.TodayRow] = []
        for (key, set) in groups where shown < 14 {
            let parts = key.split(separator: "|")
            let list = Array(set.prefix(14 - shown))
            shown += list.count
            rows.append(.init(head: "\(parts[1]) in \(parts[0]):", songs: list, more: set.count - list.count))
        }
        return rows
    }

    // MARK: Helpers

    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let shortDate: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("yMd"); return f }()
    private static func ago(_ date: Date) -> String {
        let mins = Int((Date().timeIntervalSince(date) / 60).rounded())
        if mins < 60 { return "\(max(mins, 1)) min ago" }
        let hrs = Int((Double(mins) / 60).rounded())
        return hrs < 48 ? "\(hrs) hr ago" : "\(Int((Double(hrs) / 24).rounded())) days ago"
    }
}
