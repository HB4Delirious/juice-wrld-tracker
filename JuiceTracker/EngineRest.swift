import AppKit

// The screens' requests (NativeStore.act): song details, playing a song, play history, trivia, Plex playlists and play
// counts, snapshots, and (through EngineTools) the tag fixer, duplicates and file health.

@MainActor enum EngineRouter {
    static func handle(_ op: String, _ i: Int, _ a: [String: Any]) async throws -> String {
        if let answer = try await EngineTools.handle(op, a) { return answer }
        let library = EngineLibrary.shared, catalog = EngineState.shared.catalog
        switch op {
        case "details": return await details(i)
        case "play": play(i); return ""
        case "playNext":
            if let path = (library.match.owned[i] ?? []).first(where: { EngineAmbient.playable.contains(Engine.extOf($0)) }), let url = library.url(of: path) {
                EngineAmbient.on = true
                AmbientPlayer.shared.queueNext(url, title: catalog[i].name)
            }
            return ""
        case "songForPath": return songsFor(paths: [a["path"] as? String ?? ""]).first.map { $0 >= 0 ? String($0) : "" } ?? ""
        case "songsForPaths": return EngineTools.json(songsFor(paths: a["paths"] as? [String] ?? []))
        case "neverPlayed": return EngineTools.json(neverPlayed(heard: Set(a["paths"] as? [String] ?? [])))
        case "ownedPaths": return EngineTools.json(library.match.owned.sorted { $0.key < $1.key }.map { [$0.key, $0.value] as [Any] })
        case "triviaInfo": return EngineTrivia.info()
        case "triviaRound": return EngineTrivia.round(type: a["type"] as? String ?? "mixed", pool: a["pool"] as? String ?? "all")
        case "triviaBest": EngineTrivia.best(a["key"] as? String ?? "", (a["score"] as? NSNumber)?.intValue ?? 0); return ""
        case "triviaClip":
            if let path = a["path"] as? String { AmbientPlayer.shared.playClip(URL(fileURLWithPath: path), from: Double(25 + Int.random(in: 0..<40)), seconds: 15) }
            return ""
        case "triviaStop": AmbientPlayer.shared.stopClip(); return ""
        case "plexSources": return await EnginePlex.sources()
        case "plexMake": return try await EnginePlex.make(a["id"] as? String ?? "")
        case "listening": return try await EnginePlex.listening()
        case "snapshotLost":
            let ids = try Engine.snapshotSongIds(a["text"] as? String ?? ""), owned = library.owned
            return EngineTools.json(catalog.indices.filter { ids.contains(catalog[$0].id) && !owned.contains($0) })
        default: return ""
        }
    }

    /// The song card's details, fetched from the site the first time a song with only basic info is opened.
    private static func details(_ i: Int) async -> String {
        let state = EngineState.shared, library = EngineLibrary.shared
        guard state.catalog.indices.contains(i) else { return "" }
        await state.fillDetails(i)
        let s = state.catalog[i]
        let show = { (v: String) in Engine.hasValue(v) ? v : "" }
        let files = library.match.owned[i] ?? []
        return EngineTools.json([
            "name": show(s.name), "era": show(s.era), "category": show(s.category), "length": show(s.length), "key": show(s.key),
            "recordDates": show(s.recordDates), "previewDate": show(s.previewDate), "release": show(s.release), "leakDate": show(s.leakDate),
            "leakType": show(s.leakType), "sessions": show(s.sessions), "artists": show(s.artists), "producers": show(s.producers),
            "engineers": show(s.engineers), "locations": show(s.locations), "notes": show(s.notes), "info": show(s.info),
            "alt": s.alt.joined(separator: ", "), "files": files, "playable": files.contains { EngineAmbient.playable.contains(Engine.extOf($0)) },
            "siteUrl": Engine.fileUrl(s), "note": state.notes[s.id] ?? "",
        ])
    }

    /// Plays a song you have now (its first playable file) and turns the music on.
    private static func play(_ i: Int) {
        let library = EngineLibrary.shared
        guard let path = (library.match.owned[i] ?? []).first(where: { EngineAmbient.playable.contains(Engine.extOf($0)) }), let url = library.url(of: path) else { return }
        EngineAmbient.on = true
        EngineAmbient.sync()
        AmbientPlayer.shared.playNow(url, title: EngineState.shared.catalog[i].name)
    }

    /// Which song each file on disk is (-1: none), for lyrics, artwork and the play history.
    static func songsFor(paths: [String]) -> [Int] {
        let library = EngineLibrary.shared
        var byDisk: [String: Int] = [:]
        for f in library.files { if let i = library.match.songsFor[f.path]?.first, let url = library.url(of: f.path) { byDisk[url.path] = i } }
        return paths.map { byDisk[URL(fileURLWithPath: $0).standardizedFileURL.path] ?? -1 }
    }

    /// Songs you have that never played here, counted once per file (versions matched by the same files once).
    private static func neverPlayed(heard: Set<String>) -> [Int] {
        let library = EngineLibrary.shared
        var seen = Set<String>(), out: [Int] = []
        for (i, paths) in library.match.owned.sorted(by: { $0.key < $1.key }) {
            let disk = paths.compactMap { library.url(of: $0)?.path }
            if disk.contains(where: heard.contains) || (!disk.isEmpty && disk.allSatisfy(seen.contains)) { continue }
            disk.forEach { seen.insert($0) }
            out.append(i)
        }
        return out
    }
}

// MARK: - Trivia

@MainActor enum EngineTrivia {
    static let length = 10
    static let types: [(String, String)] = [("mixed", "Mixed"), ("era", "Eras"), ("producer", "Producers"), ("year", "Recording years"),
                                            ("release", "Released or not"), ("listen", "Name that song (plays a clip)")]

    static func info() -> String {
        let best = (EngineState.shared.personalAny("trivia") as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
        return EngineTools.json(["types": types.map { ["key": $0.0, "label": $0.1] }, "best": best, "length": length])
    }

    static func best(_ key: String, _ score: Int) {
        var t = EngineState.shared.personalAny("trivia") as? [String: Any] ?? [:]
        t[key] = max((t[key] as? NSNumber)?.intValue ?? 0, score)
        EngineState.shared.setPersonal("trivia", t)
    }

    /// The same question types and rules as before: a round of 10, at most 2 yes/no questions in a mixed round.
    static func round(type: String, pool poolName: String) -> String {
        let catalog = EngineState.shared.catalog, library = EngineLibrary.shared, owned = library.match.owned
        let producersOf = catalog.map { Engine.splitNames($0.producers) }
        let yearsOf = catalog.map { Engine.yearsIn($0.recordDates) }
        let eraNames = Engine.eraStats(catalog, owned: [], eras: [:]).map(\.name).filter { $0 != Engine.noEra }
        // every producer, most credited first (the first spelling of each name)
        var counts: [String: (name: String, n: Int)] = [:]
        for list in producersOf { for n in list { counts[n.lowercased(), default: (n, 0)].n += 1 } }
        let producers = counts.values.sorted { $0.n != $1.n ? $0.n > $1.n : $0.name.localizedCompare($1.name) == .orderedAscending }.map(\.name)
        let allYears = Array(Set(yearsOf.flatMap { $0 })).sorted()
        let hasReleased = catalog.contains(where: Engine.isReleased), hasUnreleased = catalog.contains { !Engine.isReleased($0) }
        func playable(_ i: Int) -> URL? { (owned[i] ?? []).first { EngineAmbient.playable.contains(Engine.extOf($0)) }.flatMap(library.url(of:)) }
        func versionKey(_ name: String) -> String {
            Engine.normalize(name.replacingOccurrences(of: #"\s*[\(\[\{][^\)\]\}]*[\)\]\}]"#, with: " ", options: .regularExpression))
        }
        typealias Q = (prompt: String, answer: String, options: [String], clip: String)
        let builders: [String: (ok: (Int) -> Bool, make: (Int) -> Q)] = [
            "era": ({ Engine.hasValue(catalog[$0].era) && eraNames.count >= 4 }, { i in
                let s = catalog[i]
                return ("Which era is “\(s.name)” from?", s.era, ([s.era] + eraNames.filter { $0 != s.era }.shuffled().prefix(3)).shuffled(), "")
            }),
            "producer": ({ !producersOf[$0].isEmpty && producers.count >= 6 }, { i in
                let s = catalog[i], own = producersOf[i], ownKeys = Set(own.map { $0.lowercased() })
                let answer = own.randomElement()!, pool = producers.filter { !ownKeys.contains($0.lowercased()) }
                let likely = Array(pool.prefix(40).shuffled().prefix(3))
                let decoys = likely.count >= 3 ? likely : Array(pool.shuffled().prefix(3))
                return (own.count > 1 ? "Which of these producers worked on “\(s.name)”?" : "Who produced “\(s.name)”?", answer, ([answer] + decoys).shuffled(), "")
            }),
            "year": ({ yearsOf[$0].count == 1 && allYears.count >= 2 }, { i in
                let s = catalog[i], y = yearsOf[i][0]
                let near = [y - 2, y - 1, y + 1, y + 2].filter { $0 >= allYears.first! - 1 && $0 <= allYears.last! + 1 }
                return ("What year was “\(s.name)” recorded?", String(y), ([y] + near.shuffled().prefix(3)).shuffled().map(String.init), "")
            }),
            "listen": ({ owned.count >= 4 && playable($0) != nil }, { i in
                let s = catalog[i], key = versionKey(s.name)
                var decoys: [String] = []
                for j in owned.keys.shuffled() { let n = catalog[j].name; if versionKey(n) != key && !decoys.contains(n) { decoys.append(n) }; if decoys.count == 3 { break } }
                return ("Which song is playing?", s.name, ([s.name] + decoys).shuffled(), playable(i)!.path)
            }),
            "release": ({ _ in hasReleased && hasUnreleased }, { i in
                let yes = "Yes, it's officially released", no = "No, it hasn't been released"
                return ("Has “\(catalog[i].name)” been officially released?", Engine.isReleased(catalog[i]) ? yes : no, [yes, no], "")
            }),
        ]
        let pool = (poolName == "library" || type == "listen" ? Array(owned.keys) : Array(catalog.indices)).shuffled()
        let kinds = type == "mixed" ? ["era", "producer", "year", "release"] : [type]
        var questions: [[String: Any]] = [], used = Set<Int>(), yesNo = 0
        var attempt = 0
        while attempt < pool.count * 2 && questions.count < length {
            let i = pool[attempt % pool.count]; attempt += 1
            if used.contains(i) { continue }
            let available = kinds.filter { builders[$0]?.ok(i) == true }.shuffled()
            guard let t = available.first(where: { $0 != "release" || type != "mixed" || yesNo < 2 }) else { continue }
            let q = builders[t]!.make(i)
            if Set(q.options).count != q.options.count || q.options.count < 2 { continue }
            used.insert(i)
            if t == "release" { yesNo += 1 }
            questions.append(["prompt": q.prompt, "options": q.options, "answer": q.answer, "i": i, "clip": q.clip])
        }
        return EngineTools.json(questions)
    }
}

// MARK: - Plex (set up in Settings)

@MainActor enum EnginePlex {
    private static var counts: [String: Int]?   // plays per library path, loaded once (reading the token can prompt)
    private static var missing = 0

    private static func playable() -> [(path: String, disk: String)] {
        let library = EngineLibrary.shared
        return library.files.compactMap { f in library.match.songsFor[f.path]?.isEmpty == false ? library.url(of: f.path).map { (f.path, $0.path) } : nil }
    }
    private static func loadCounts() async throws {
        guard counts == nil else { return }
        let files = playable()
        guard !files.isEmpty else { throw EngineError("Open your music folder first") }
        let r = try await Plex.playCounts(paths: files.map(\.disk))
        var byDisk: [String: Int] = [:]
        for it in r.items { if let p = it["path"] as? String { byDisk[p] = (it["plays"] as? NSNumber)?.intValue ?? 0 } }
        counts = Dictionary(files.compactMap { f in byDisk[f.disk].map { (f.path, $0) } }, uniquingKeysWith: { a, _ in a })
        missing = r.missing
    }
    /// Most played (by song, top 50) and owned songs whose files Plex knows but never played.
    private static func lists() -> (most: [Int], never: [Int], plays: [Int: Int]) {
        let library = EngineLibrary.shared, c = counts ?? [:]
        var plays: [Int: Int] = [:]
        for f in library.files { if let n = c[f.path], n > 0, let i = library.match.songsFor[f.path]?.first { plays[i, default: 0] += n } }
        let never = library.match.owned.keys.sorted().filter { i in
            let fs = library.match.owned[i]!
            return fs.contains { c[$0] != nil } && fs.allSatisfy { (c[$0] ?? 0) == 0 }
        }
        return (plays.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(50).map(\.key), never, plays)
    }

    private struct Source { let id: String, label: String, title: String; let songs: [Int] }
    private static func all() -> [Source] {
        let library = EngineLibrary.shared, catalog = EngineState.shared.catalog, owned = library.owned
        let wish = EngineState.shared.wish
        let downloaded = EngineState.shared.personalAny("downloaded") as? [String: String] ?? [:]
        let monthAgo = Date().addingTimeInterval(-30 * 86400), iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let mine = catalog.indices.filter(owned.contains)
        var out = [
            Source(id: "wish", label: "Wishlist songs you have", title: "Juice WRLD: Wishlist", songs: mine.filter { wish[catalog[$0].id] != nil }),
            Source(id: "recent", label: "Downloaded in the last 30 days", title: "Juice WRLD: Recently downloaded",
                   songs: mine.filter { (downloaded[catalog[$0].id].flatMap(iso.date(from:)) ?? .distantPast) > monthAgo }),
        ]
        if counts != nil {
            let l = lists()
            out.append(Source(id: "most", label: "Your 50 most played (Plex)", title: "Juice WRLD: Most played", songs: l.most))
            out.append(Source(id: "never", label: "Songs you've never played (Plex)", title: "Juice WRLD: Never played", songs: l.never))
        }
        for e in Engine.eraStats(catalog, owned: owned, eras: [:]) where e.have > 0 {
            out.append(Source(id: "era:\(e.name)", label: "Era: \(e.name)", title: "Juice WRLD: \(e.name)", songs: mine.filter { Engine.eraName(catalog[$0]) == e.name }))
        }
        return out
    }

    static func sources() async -> String {
        guard Plex.configured else { return "[]" }
        try? await loadCounts() // no play counts: those lists just don't show
        return EngineTools.json(all().map { ["id": $0.id, "label": $0.label, "count": $0.songs.count] })
    }

    /// Makes (or replaces) a Plex playlist from one of the lists, each file once.
    static func make(_ id: String) async throws -> String {
        let library = EngineLibrary.shared
        guard let src = all().first(where: { $0.id == id }) else { throw EngineError("There are no songs you have in that list yet") }
        var seen = Set<String>(), paths: [String] = []
        for i in src.songs { for p in library.match.owned[i] ?? [] { if let u = library.url(of: p), seen.insert(u.path).inserted { paths.append(u.path) } } }
        guard !paths.isEmpty else { throw EngineError("There are no songs you have in that list yet") }
        let r = try await Plex.playlist(title: src.title, paths: paths)
        return "Made “\(src.title)” in Plex with \(EngineTools.plural(r.matched, "song", "songs")).\(r.missing > 0 ? " \(EngineTools.plural(r.missing, "file wasn't", "files weren't")) found in Plex yet; let Plex finish scanning and make it again." : "")"
    }

    /// Play counts for Stats: the total, the top 15, songs never played, and the most played eras.
    static func listening() async throws -> String {
        try await loadCounts()
        let catalog = EngineState.shared.catalog, l = lists()
        var eras: [String: Int] = [:]
        for (i, n) in l.plays { eras[Engine.eraName(catalog[i]), default: 0] += n }
        return EngineTools.json([
            "total": l.plays.values.reduce(0, +), "top": l.most.prefix(15).map { ["i": $0, "plays": l.plays[$0] ?? 0] }, "never": l.never,
            "eras": eras.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(8).map { ["name": $0.key, "plays": $0.value] },
            "missing": missing,
        ])
    }
}
