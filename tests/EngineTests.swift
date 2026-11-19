// Checks the Swift engine (JuiceTracker/Engine.swift) against the page's own answers in fixtures.json, frozen when the
// HTML page was retired (they can't be made again). Run: scripts/test-engine.sh
import Foundation

@main struct EngineTests {
    static var failures = 0, checks = 0
    static func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
        checks += 1
        if !ok { failures += 1; print("FAIL: \(what())") }
    }

    static func main() throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let fx = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("fixtures.json"))) as! [String: Any]

        // text helpers
        let text = fx["text"] as! [String: [[Any]]]
        for c in text["normalize"]! { expect(Engine.normalize(c[0] as? String) == c[1] as! String, "normalize(\(c[0])) = \(Engine.normalize(c[0] as? String)), page says \(c[1])") }
        for c in text["hasValue"]! { expect(Engine.hasValue(c[0] as! String) == c[1] as! Bool, "hasValue(\(c[0]))") }
        for c in text["yearOf"]! { expect(Engine.yearOf(c[0] as! String) == c[1] as! String, "yearOf(\(c[0])) = \(Engine.yearOf(c[0] as! String))") }
        for c in text["hasArtist"]! { expect(Engine.hasArtist(c[0] as! String) == c[1] as! Bool, "hasArtist(\(c[0]))") }
        for c in text["extOf"]! { expect(Engine.extOf(c[0] as! String) == c[1] as! String, "extOf(\(c[0])) = \(Engine.extOf(c[0] as! String))") }
        for c in text["stemOf"]! { expect(Engine.stemOf(c[0] as! String) == c[1] as! String, "stemOf(\(c[0])) = \(Engine.stemOf(c[0] as! String))") }
        for c in text["titleFromFilename"]! { expect(Engine.titleFromFilename(c[0] as! String) == c[1] as! String, "titleFromFilename(\(c[0])) = \(Engine.titleFromFilename(c[0] as! String))") }
        for c in text["similarity"]! {
            let got = Engine.similarity(Array((c[0] as! String).utf8), Array((c[1] as! String).utf8))
            expect(abs(got - (c[2] as! Double)) < 1e-12, "similarity(\(c[0]), \(c[1])) = \(got), page says \(c[2])")
        }

        // catalog cleaning: compared as JSON, field by field
        let catalog = fx["catalog"] as! [String: Any]
        let raw = catalog["raw"] as! [[String: Any]]
        func asDict(_ s: EngineSong) -> [String: Any] { try! JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any] }
        func same(_ a: Any?, _ b: Any?) -> Bool {
            guard let a, let b else { return a == nil && b == nil }
            return (try? JSONSerialization.data(withJSONObject: [a], options: .sortedKeys)) == (try? JSONSerialization.data(withJSONObject: [b], options: .sortedKeys))
        }
        for (n, page) in (catalog["cleaned"] as! [[String: Any]]).enumerated() {
            let mine = asDict(Engine.cleanSong(raw[n]))
            for k in Set(page.keys).union(mine.keys) { expect(same(mine[k], page[k]), "cleanSong #\(n) \(k): \(mine[k] ?? "nil") vs page \(page[k] ?? "nil")") }
        }
        let merged = Engine.mergeSongs([raw]).map(\.id), pageMerged = (catalog["merged"] as! [[String: Any]]).map { $0["id"] as! String }
        expect(merged == pageMerged, "mergeSongs ids \(merged) vs page \(pageMerged)")
        let eras = Engine.collectEras(raw), pageEras = catalog["eras"] as! [String: [String: Any]]
        expect(Set(eras.keys) == Set(pageEras.keys), "collectEras names \(eras.keys.sorted()) vs page \(pageEras.keys.sorted())")
        for (name, e) in pageEras {
            expect(eras[name]?.description == e["description"] as? String && eras[name]?.timeFrame == e["timeFrame"] as? String, "collectEras \(name)")
        }

        // tag reading, on files the page's own writers made and hand-built ones
        for f in fx["files"] as! [[String: Any]] {
            let name = f["name"] as! String, page = f["tags"] as! [String: String]
            let mine = TagReader.read(dir.appendingPathComponent("files/\(name)"), ext: f["ext"] as! String)
            expect(mine == page, "tags of \(name): \(mine) vs page \(page)")
        }

        // matching
        let m = fx["matching"] as! [String: Any]
        let songs = try JSONDecoder().decode([EngineSong].self, from: JSONSerialization.data(withJSONObject: m["catalog"]!))
        let files = (m["files"] as! [[String: String]]).map {
            LibraryFile(path: $0["path"]!, ext: Engine.extOf($0["path"]!), tags: [:], title: $0["title"]!, key: $0["key"]!, stem: $0["stem"]!, fromTags: false, size: 0)
        }
        let got = Engine.match(catalog: songs, files: files, overrides: m["overrides"] as! [String: String])
        let pageOwned = (m["owned"] as! [String: [String]]).reduce(into: [Int: [String]]()) { $0[Int($1.key)!] = $1.value }
        expect(got.owned == pageOwned, "owned \(got.owned) vs page \(pageOwned)")
        expect(got.unmatched == m["unmatched"] as! [String], "unmatched \(got.unmatched) vs page \(m["unmatched"]!)")
        expect(got.how == m["how"] as! [String: String], "matched by \(got.how) vs page \(m["how"]!)")

        // what the screens show (stage 2)
        let d = fx["derived"] as! [String: [[Any]]]
        func ints(_ v: Any) -> [Int] { (v as? [NSNumber] ?? []).map(\.intValue) }
        for c in d["splitNames"]! { let t = c[0] as! String; expect(Engine.splitNames(t) == c[1] as! [String], "splitNames(\(t)) = \(Engine.splitNames(t)), page \(c[1])") }
        for c in d["splitStudios"]! { let t = c[0] as! String; expect(Engine.splitStudios(t) == c[1] as! [String], "splitStudios(\(t)) = \(Engine.splitStudios(t)), page \(c[1])") }
        for c in d["yearsIn"]! { let t = c[0] as! String; expect(Engine.yearsIn(t) == ints(c[1]), "yearsIn(\(t)) = \(Engine.yearsIn(t)), page \(c[1])") }
        for c in d["recordMonth"]! { let t = c[0] as! String; expect(Engine.recordMonth(t) == (c[1] as? NSNumber)?.intValue, "recordMonth(\(t)) = \(String(describing: Engine.recordMonth(t))), page \(c[1])") }
        for c in d["timeKey"]! { let t = c[0] as! String; expect(Engine.timeKey(t) == (c[1] as? NSNumber)?.intValue, "timeKey(\(t)) = \(String(describing: Engine.timeKey(t))), page \(c[1])") }
        for c in d["datesIn"]! {
            let t = c[0] as! String, page = (c[1] as! [[String: Int]]).map { [$0["y"]!, $0["m"]!, $0["d"]!] }
            expect(Engine.datesIn(t).map { [$0.y, $0.m, $0.d] } == page, "datesIn(\(t)) = \(Engine.datesIn(t)), page \(page)")
        }
        for c in d["capital"]! { expect(Engine.capital(c[0] as! String) == c[1] as! String, "capital(\(c[0]))") }
        let e = fx["eras"] as! [String: Any]
        let eraSongs = try JSONDecoder().decode([EngineSong].self, from: JSONSerialization.data(withJSONObject: e["catalog"]!))
        let info = try JSONDecoder().decode([String: EraInfo].self, from: JSONSerialization.data(withJSONObject: e["info"]!))
        let stats = Engine.eraStats(eraSongs, owned: Set(ints(e["owned"]!)), eras: info)
        let pageStats = (e["stats"] as! [[String: Any]]).map { Engine.EraStat(name: $0["name"] as! String, have: $0["have"] as! Int, total: $0["total"] as! Int,
                                                                               timeFrame: $0["timeFrame"] as! String, description: $0["description"] as! String) }
        expect(stats == pageStats, "eraStats \(stats.map(\.name)) vs page \(pageStats.map(\.name))")

        // export helpers (stage 3)
        let ex = fx["exportCases"] as! [String: Any]
        for c in ex["uri"] as! [[String]] { expect(Engine.encodeURIComponent(c[0]) == c[1], "encodeURIComponent(\(c[0])) = \(Engine.encodeURIComponent(c[0])), page \(c[1])") }
        for c in ex["fileUrl"] as! [[String]] {
            let song = EngineSong(id: "1", publicId: "", name: "x", alt: [], era: "", category: "", length: "", release: "", artists: "", producers: "", recordDates: "",
                                  engineers: "", locations: "", key: "", info: "", notes: "", previewDate: "", leakDate: "", leakType: "", sessions: "", dates: "", bitrate: "",
                                  filePath: c[0], hasDetails: false)
            expect(Engine.fileUrl(song) == c[1], "fileUrl(\(c[0])) = \(Engine.fileUrl(song)), page \(c[1])")
        }
        let csv = Engine.csvText([["id", "name", "note"], ["1", "He said \"hi\"", "line\nbreak, comma"], ["2", "", "Ünïcode"]])
        expect(csv.hasPrefix("\u{FEFF}") == ex["csvBom"] as! Bool, "csvText byte order mark")
        expect(String(csv.unicodeScalars.dropFirst()) == ex["csv"] as! String, "csvText: \(csv.debugDescription) vs page \((ex["csv"] as! String).debugDescription)")

        // writing tags (stage 4): the same bytes, or the same error, as the page's writers
        for c in fx["writes"] as! [[String: Any]] {
            let name = c["name"] as! String, ext = c["ext"] as! String
            let input = [UInt8](Data(base64Encoded: c["input"] as! String)!), desired = c["desired"] as! [String: String]
            let write: ([UInt8], Tags) throws -> TagWriter.Written = ext == "mp3" ? { try TagWriter.writeMp3($0, $1) } : ext == "flac" ? { try TagWriter.writeFlac($0, $1) } : { try TagWriter.writeM4a($0, $1) }
            let verify: ([UInt8], TagWriter.Written, Tags) throws -> Void = ext == "mp3" ? TagWriter.verifyMp3 : ext == "flac" ? TagWriter.verifyFlac : TagWriter.verifyM4a
            do {
                let r = try write(input, desired)
                if let pageError = c["error"] as? String { expect(false, "\(name): Swift wrote it, the page refused (\(pageError))"); continue }
                expect(r.out == [UInt8](Data(base64Encoded: c["out"] as! String)!), "\(name): different bytes (\(r.out.count) vs page \(Data(base64Encoded: c["out"] as! String)!.count))")
                var verifyError: String?
                do { try verify(input, r, desired) } catch { verifyError = error.localizedDescription }
                expect(verifyError == c["verify"] as? String, "\(name): safety check \(verifyError ?? "passed"), page \(c["verify"] as? String ?? "passed")")
            } catch {
                expect(error.localizedDescription == c["error"] as? String, "\(name): \(error.localizedDescription), page \(c["error"] as? String ?? "wrote it")")
            }
        }

        // where missing songs are saved (stage 4c)
        let layoutSongs = try JSONDecoder().decode([EngineSong].self, from: JSONSerialization.data(withJSONObject: fx["layoutSongs"]!))
        for l in fx["layouts"] as! [[String: Any]] {
            let name = l["name"] as! String
            let files = (l["files"] as! [[String: Any]]).map {
                LibraryFile(path: $0["path"] as! String, ext: Engine.extOf($0["path"] as! String), tags: $0["tags"] as! [String: String], title: $0["title"] as! String,
                            key: $0["key"] as! String, stem: $0["stem"] as! String, fromTags: false, size: $0["size"] as! Int)
            }
            let m = Engine.match(catalog: layoutSongs, files: files, overrides: [:])
            let layout = Engine.layout(catalog: layoutSongs, files: files, match: m)
            let snap = String(Engine.snapshotCSV(files: files, match: m, catalog: layoutSongs).unicodeScalars.dropFirst())
            expect(snap == l["snapshot"] as! String, "\(name): snapshot CSV differs:\n\(snap.debugDescription)\nvs page\n\((l["snapshot"] as! String).debugDescription)")
            for (n, s) in layoutSongs.enumerated() {
                let want = (l["folders"] as! [String])[n], got = Engine.saveFolder(s, layout)
                expect(got == want, "\(name): save folder for \(s.name) (\(s.era)) = \(got), page \(want)")
                expect(Engine.saveFileName(s) == (l["fileNames"] as! [String])[n], "\(name): file name for \(s.name) = \(Engine.saveFileName(s))")
            }
        }

        // the tag fixer, duplicates and file health (stage 4d)
        let t = fx["tools"] as! [String: Any]
        let toolSongs = try JSONDecoder().decode([EngineSong].self, from: JSONSerialization.data(withJSONObject: t["songs"]!))
        let toolLib = (t["lib"] as! [[String: Any]]).map {
            LibraryFile(path: $0["path"] as! String, ext: $0["ext"] as! String, tags: $0["tags"] as! [String: String], title: $0["title"] as! String,
                        key: $0["key"] as! String, stem: $0["stem"] as! String, fromTags: $0["fromTags"] as! Bool, size: $0["size"] as! Int)
        }
        let tm = Engine.match(catalog: toolSongs, files: toolLib, overrides: t["overrides"] as! [String: String])
        for (n, want) in (t["planned"] as! [[String: String]]).enumerated() {
            let got = Engine.plannedTags(toolSongs[n]).filter { !$0.value.isEmpty }, page = want.filter { !$0.value.isEmpty }
            expect(got == page, "plannedTags(\(toolSongs[n].name)) = \(got), page \(page)")
        }
        for p in t["plans"] as! [[String: Any]] {
            let plan = Engine.buildPlan(files: toolLib, match: tm, catalog: toolSongs, fields: p["fields"] as! [String], onlyBlanks: p["blanks"] as! Bool, genre: p["genre"] as! String)
            let label = "plan \(p["fields"]!) blanks=\(p["blanks"]!)"
            expect(plan.same == p["same"] as! Int, "\(label): \(plan.same) the same, page \(p["same"]!)")
            expect(plan.skipped.map { [$0.path, $0.reason] } == p["skipped"] as! [[String]], "\(label): skipped \(plan.skipped)")
            let pageChanges = (p["changes"] as! [[String: Any]]).map { c in "\(c["path"]!) #\(c["song"]!) " + (c["changes"] as! [[String]]).map { $0.joined(separator: "→") }.joined(separator: "; ") }
            let mine = plan.changes.map { c in "\(c.path) #\(c.song) " + c.changes.map { [$0.key, $0.from, $0.to].joined(separator: "→") }.joined(separator: "; ") }
            expect(mine == pageChanges, "\(label): changes\n\(mine)\nvs page\n\(pageChanges)")
        }
        let groups = Engine.duplicateGroups(files: toolLib, match: tm, catalog: toolSongs)
        expect(Engine.distinctGroups(groups + groups).count == Engine.distinctGroups(groups).count, "duplicates: the same files are shown once")
        let pageGroups = t["dupGroups"] as! [[String: Any]]
        expect(groups.count == pageGroups.count, "duplicate groups: \(groups.count), page \(pageGroups.count)")
        for (gr, pg) in zip(groups, pageGroups) {
            expect(gr.song == pg["song"] as? Int && gr.title == pg["title"] as! String && gr.files.map(\.path) == pg["files"] as! [String] && gr.extra == pg["extra"] as! Int,
                   "duplicate group \(gr.title) \(gr.files.map(\.path)) extra \(gr.extra) vs page \(pg)")
            expect(Engine.isExactDuplicate(gr) == pg["exact"] as! Bool && Engine.bestCopy(gr.files).path == pg["keep"] as! String, "duplicate group \(gr.title): exact/keep")
        }
        let probes = try JSONDecoder().decode([String: Engine.Probe].self, from: JSONSerialization.data(withJSONObject: t["probes"]!))
        let issues = Engine.healthIssues(files: toolLib, match: tm, catalog: toolSongs, probes: probes).map { [$0.path, $0.group, $0.text] }
        expect(issues == t["health"] as! [[String]], "health issues\n\(issues)\nvs page\n\(t["health"]!)")
        for c in t["sizes"] as! [[Any]] { let n = (c[0] as! NSNumber).intValue; expect(Engine.formatSize(n) == c[1] as! String, "formatSize(\(n)) = \(Engine.formatSize(n)), page \(c[1])") }
        for c in t["times"] as! [[Any]] { let n = (c[0] as! NSNumber).doubleValue; expect(Engine.fmtTime(n) == c[1] as! String, "fmtTime(\(n)) = \(Engine.fmtTime(n)), page \(c[1])") }
        for c in t["kbps"] as! [[Any]] { expect(Engine.siteKbps(c[0] as! String, c[1] as! String) == (c[2] as! NSNumber).intValue, "siteKbps(\(c[0]))") }
        for c in t["lengths"] as! [[Any]] { expect(Engine.lengthSeconds(c[0] as! String) == (c[1] as? NSNumber)?.doubleValue, "lengthSeconds(\(c[0]))") }
        for c in t["keys"] as! [[String]] { expect(Engine.cmdkKey(c[0]) == c[1], "cmdkKey(\(c[0])) = \(Engine.cmdkKey(c[0])), page \(c[1])") }

        // Beyond the page: text frames after big cover art are read (the page missed them once the title was found).
        do {
            func frame(_ id: String, _ body: [UInt8]) -> [UInt8] { Array(id.utf8) + TagWriter.u32be(body.count) + [0, 0] + body }
            let art = [UInt8](repeating: 0x55, count: 300 * 1024)
            let frames = frame("TIT2", [0] + Array("Big Art".utf8)) + frame("APIC", [0] + Array("image/jpeg".utf8) + [0, 3, 0] + art)
                + frame("TALB", [0] + Array("Mainstream".utf8)) + frame("TYER", [0] + Array("2019".utf8))
            let n = frames.count
            let tag = Array("ID3".utf8) + [3, 0, 0, UInt8(n >> 21 & 0x7f), UInt8(n >> 14 & 0x7f), UInt8(n >> 7 & 0x7f), UInt8(n & 0x7f)] + frames
            let url = dir.appendingPathComponent("big-art.mp3")
            try Data(tag + [0xff, 0xfb] + [UInt8](repeating: 1, count: 1000)).write(to: url)
            let got = TagReader.read(url, ext: "mp3")
            checks += 1
            if got != ["title": "Big Art", "album": "Mainstream", "year": "2019"] { failures += 1; print("FAIL: tags after big cover art: \(got)") }
        }

        // reading snapshots back (stage 5)
        for c in fx["csvCases"] as! [[Any]] { let t = c[0] as! String; expect(Engine.parseCsv(t) == c[1] as! [[String]], "parseCsv(\(t.debugDescription)) = \(Engine.parseCsv(t))") }

        // File organizer (beyond the page)
        do {
            func song(_ id: String, _ name: String, _ era: String) -> EngineSong {
                EngineSong(id: id, publicId: id, name: name, alt: [], era: era, category: "Unreleased", length: "", release: "", artists: "", producers: "",
                           recordDates: "2018", engineers: "", locations: "", key: "", info: "", notes: "", previewDate: "", leakDate: "", leakType: "",
                           sessions: "", dates: "", bitrate: "", filePath: "", hasDetails: false)
            }
            func file(_ path: String) -> LibraryFile {
                LibraryFile(path: path, ext: Engine.extOf(path), tags: ["artist": "Juice WRLD"], title: "", key: "", stem: "", fromTags: false, size: 1)
            }
            let cat = [song("1", "Lucid Dreams", "GB&GR"), song("2", "What?/Why", "DRFL")]
            let files = [file("M/a.mp3"), file("M/b.flac"), file("M/c.mp3"), file("M/GB&GR/Lucid Dreams.mp3")]
            var m = Engine.Match()
            m.songsFor = ["M/a.mp3": [0], "M/b.flac": [1], "M/c.mp3": [0, 1], "M/GB&GR/Lucid Dreams.mp3": [0]]
            m.how = ["M/a.mp3": "title", "M/b.flac": "close", "M/c.mp3": "title", "M/GB&GR/Lucid Dreams.mp3": "title"]
            let plan = Engine.organizePlan(files: files, match: m, catalog: cat, pattern: "{era}/{song}")
            expect(plan.isEmpty, "organizer: a file already in place is never overwritten, close and unsettled matches stay (\(plan))")
            expect(Engine.primarySong([0, 1], catalog: cat) == nil, "primary song: different names stay unsettled")
            let versions = [song("3", "Lean Wit' Me", "GB&GR"), song("4", "Lean Wit' Me", "GB&GR"), song("5", "Lean Wit' Me (Live)", "WOD"), song("6", "Lean Wit' Me", "Mainstream")]
            expect(Engine.primarySong([0, 1, 2, 3], catalog: versions) == 0, "primary song: the era most plain-named versions share")
            expect(Engine.primarySong([0, 3], catalog: versions) == nil, "primary song: a tie stays unsettled")
            m.how["M/b.flac"] = "title"
            let p2 = Engine.organizePlan(files: files, match: m, catalog: cat, pattern: "{year}/{song} ({era})")
            expect(p2.map(\.to) == ["M/2018/Lucid Dreams (GB&GR).mp3", "M/2018/WhatWhy (DRFL).flac"], "organizer: pattern fields and safe names (\(p2))")
            expect(Set(p2.map(\.to)).count == p2.count, "organizer: no two files go to the same place")
            var untagged = files[0]; untagged.path = "M/Juice WRLD/a.mp3"; untagged.tags = [:]
            m.songsFor[untagged.path] = [0]; m.how[untagged.path] = "title"
            expect(Engine.organizePlan(files: [untagged], match: m, catalog: cat, pattern: "{era}/{song}").isEmpty,
                   "organizer: a file counted only by its Juice WRLD folder stays put")
            expect(Engine.organizePlan(files: [untagged], match: m, catalog: cat, pattern: "Juice WRLD/{era}/{song}").map(\.to) == ["M/Juice WRLD/GB&GR/Lucid Dreams.mp3"],
                   "organizer: it can move inside a Juice WRLD folder")
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            expect(!Engine.settled(sizeBefore: 100, sizeNow: 200, modified: t0, now: t0 + 60), "inbox: a growing file isn't settled")
            expect(!Engine.settled(sizeBefore: 200, sizeNow: 200, modified: t0, now: t0 + 3), "inbox: a file written seconds ago isn't settled")
            expect(Engine.settled(sizeBefore: 200, sizeNow: 200, modified: t0, now: t0 + 30), "inbox: a finished file is settled")
            expect(!Engine.settled(sizeBefore: 0, sizeNow: 0, modified: t0, now: t0 + 30), "inbox: an empty file isn't settled")
            expect(Engine.settled(sizeBefore: 200, sizeNow: 200, modified: t0 + 3600, now: t0), "inbox: a file dated in the future is settled by its size")
            let eras = [("DRFL", "Death Race For Love"), ("DRFL (TV)", "Death Race For Love TV mixes"), ("TPNE", "The Party Never Ends"),
                        ("TPNE 2.0", "The Party Never Ends 2.0"), ("GB&GR", "Goodbye & Good Riddance")].map { (name: $0.0, full: $0.1) }
            expect(Engine.erasNamed("drfl", eras: eras) == ["DRFL"], "era names: the short name, any case")
            expect(Engine.erasNamed("death race for love", eras: eras) == ["DRFL"], "era names: the full name beats the TV mixes")
            expect(Engine.erasNamed("goodbye and good riddance", eras: eras) == ["GB&GR"], "era names: & and and are the same")
            expect(Engine.erasNamed("party never ends", eras: eras) == ["TPNE", "TPNE 2.0"], "era names: several fits are all returned")
            expect(Engine.erasNamed("fighting demons", eras: eras).isEmpty, "era names: no fit, nothing")
            expect(Engine.wordleWord("Lucid Dreams (Forget Me)") == "LUCID DREAMS", "wordle: brackets dropped, words kept")
            expect(Engine.wordleWord("Bandit [v1]") == "BANDIT", "wordle: version marks dropped")
            expect(Engine.wordleWord("Can't Die") == "CANT DIE", "wordle: apostrophes dropped")
            expect(Engine.wordleWord("All Girls Are The Same") == nil && Engine.wordleWord("Hey") == nil, "wordle: too long or too short is skipped")
            expect(Engine.wordleScore("CRANE", "CREAK") == [2, 2, 1, 0, 1], "wordle: green, yellow and grey")
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
            func day(_ d: Int, _ h: Int) -> Date { utc.date(from: DateComponents(year: 2026, month: 3, day: d, hour: h))! }
            let plays = [day(10, 9), day(9, 23), day(2, 12), day(1, 0), day(11, 8)]
            expect(Engine.playTimeline(plays, buckets: 7, bucketDays: 1, now: day(10, 12), calendar: utc) == [0, 0, 0, 0, 0, 1, 1], "timeline: plays by day, today last, older and future plays left out")
            expect(Engine.playTimeline(plays, buckets: 2, bucketDays: 7, now: day(10, 12), calendar: utc) == [2, 2], "timeline: plays by week, the week ending today last")
            expect(Engine.m3u([("/m/a.mp3", "Lucid Dreams", 239.6), ("/m/b.flac", "Two\nLines", nil)]) == "#EXTM3U\n#EXTINF:239,Juice WRLD - Lucid Dreams\n/m/a.mp3\n#EXTINF:-1,Juice WRLD - Two Lines\n/m/b.flac\n", "m3u: length, title on one line, path")
            expect(Engine.boosted(0.2, peak: 0.25) == (0.8, 0.25) && Engine.boosted(0.05, peak: 0) == (0.2, 0.25), "boost: a quiet song is lifted, near-silence only so far")
            expect(Engine.boosted(0.9, peak: 0.4) == (1, 0.9) && Engine.boosted(0.45, peak: 0.9).level == 0.45 / (0.9 * 0.995), "boost: a loud song sets the peak, which falls back slowly")
            let cuts = ["3:00", "4:10", ""].enumerated().map { k, l -> EngineSong in var s = song("\(k)", "Same", "DRFL"); s.length = l; return s }
            expect(Engine.closestByLength([0, 1, 2], catalog: cuts, seconds: 245) == 1 && Engine.closestByLength([0, 1, 2], catalog: cuts, seconds: nil) == 0
                   && Engine.closestByLength([2], catalog: cuts, seconds: 10) == 2, "identify: of the versions, the one closest in length")
            expect(Engine.dateSentence("First Teased\nMarch 23, 2018.", fallback: "Previewed") == "First teased March 23, 2018."
                   && Engine.dateSentence("Surfaced\r\nJune 24, 2018.", fallback: "Surfaced", extra: "Throwaway Track\n(Complete)") == "Surfaced June 24, 2018 (Throwaway Track (Complete))."
                   && Engine.dateSentence("December 25, 2025", fallback: "Surfaced") == "Surfaced December 25, 2025."
                   && Engine.dateSentence("First Teased August 16, 2019", fallback: "Previewed") == "First teased August 16, 2019."
                   && Engine.dateSentence("Surfaced\n", fallback: "Surfaced") == "", "story: the site's own date label leads, once, on one line")
            let plays2 = Engine.parsePlays("1700000000\tMusic/A.mp3\nbroken line\n1700000060\tMusic/B\twith tab.mp3\n")
            expect(plays2.map(\.path) == ["Music/A.mp3", "Music/B\twith tab.mp3"] && plays2[1].at.timeIntervalSince1970 == 1_700_000_060, "plays: a line each, broken lines skipped, tabs in paths kept")
            let ny = TimeZone(identifier: "America/New_York")!
            func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
            expect(Engine.localDay(at("2026-03-11T00:30:00Z"), ny) == Engine.localDay(at("2026-03-10T15:00:00Z"), ny)
                   && Engine.localDay(at("2026-03-11T04:30:00Z"), ny) == Engine.localDay(at("2026-03-10T15:00:00Z"), ny) + 1, "daily games: the day turns over at local midnight, not UTC's")
            var wav = song("w", "W", "DRFL"); wav.bitrate = "1411kbps (.wav)"; wav.length = "3:00"
            var mp3 = wav; mp3.bitrate = "1411kbps (.wav), 320kbps (.mp3)"; mp3.filePath = "Juice WRLD/W.mp3"
            expect(Engine.estimatedBytes(wav) == 31_747_500 && Engine.estimatedBytes(song("x", "X", "DRFL")) == 12_000_000
                   && Engine.estimatedBytes(mp3) == 7_200_000, "downloads: size from the site's bitrate for the file's own format, and length")
            expect(Engine.downloadsThatFit([10_000_000, 50_000_000, 50_000_000], free: 2_070_000_000) == 2 && Engine.downloadsThatFit([1, 2], free: nil) == 2
                   && Engine.downloadsThatFit([1], free: 1_000_000_000) == 0, "downloads: as many as fit, keeping 2 GB free")
            expect(Engine.eqPreset([-2, 4, 2]) == "Vocals" && Engine.eqPreset([0, 4, 2]) == "Custom", "equalizer: bands name their preset, or Custom")
            expect(Engine.eqHeadroom([6, 0, 1]) == -3 && Engine.eqHeadroom([-4, 1, -3]) == -0.5 && Engine.eqHeadroom([-4, -1, -3]) == 0, "equalizer: turned down by half the biggest boost")
            let lrc = Engine.parseLrc("[ar:Juice WRLD]\n[00:12.50]second line\n[00:03.00]<00:03.00>first <00:03.60>line <00:04.20>here\n[00:20.00]<00:20.00>wrong count")
            expect(lrc.map(\.at) == [3, 12.5, 20] && lrc[0].line == "first line here", "lrc: tags skipped, sorted by time, word times taken out of the text")
            expect(lrc[0].words == [3, 3.6, 4.2] && lrc[1].words.isEmpty && lrc[2].words.isEmpty, "lrc: word times only when every word has one")
            expect(Engine.parseLrc(Engine.formatLrc(lrc)) == lrc, "lrc: what's written reads back the same")
            expect(Engine.lrcStamp(83.456) == "01:23.46" && Engine.lrcStamp(600) == "10:00.00", "lrc: times as mm:ss.xx")
            expect(Engine.litWords(lrc, 0, at: 3.7) == (2, true) && Engine.litWords(lrc, 0, at: 13) == (3, false), "lrc: word times light the words they time")
            expect(Engine.litWords(lrc, 1, at: 12.5 + 7.5 * 0.85 / 2) == (1, true) && Engine.litWords(lrc, 1, at: 19.9) == (2, false), "lrc: an untimed line spreads over its words")
            expect(Engine.wordleScore("LLAMA", "HELLO") == [1, 1, 0, 0, 0], "wordle: a repeated letter is yellow as often as the answer has it")
            expect(Engine.wordleScore("EERIE", "THREE") == [1, 0, 2, 0, 2], "wordle: greens first, then yellows from what's left")
            expect(Engine.wordleScore("LUCIDDREAMS", "LUCID DREAMS") == Array(repeating: 2, count: 11), "wordle: spaces don't count")
        }

        // Cover art (beyond the page): added to each format, tags and audio untouched, and refused the second time.
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0x42, count: 5000) + [0xFF, 0xD9]
        for name in ["written.mp3", "written.flac", "written.m4a"] {
            let url = dir.appendingPathComponent("files/\(name)"), ext = Engine.extOf(name)
            let orig = [UInt8](try Data(contentsOf: url)), before = TagReader.read(url, ext: ext)
            do {
                let out = try TagWriter.addArt(orig, ext: ext, jpeg: jpeg, width: 600, height: 600)
                let copy = dir.appendingPathComponent("art-\(name)")
                try Data(out).write(to: copy)
                expect(TagReader.hasArt(copy, ext: ext), "\(name): cover art reads back from disk")
                expect(TagReader.read(copy, ext: ext) == before, "\(name): tags unchanged by adding cover art (\(TagReader.read(copy, ext: ext)) vs \(before))")
                expect(!TagReader.hasArt(orig, ext: ext), "\(name): the original had no art")
                expect((try? TagWriter.addArt(out, ext: ext, jpeg: jpeg, width: 600, height: 600)) == nil, "\(name): a second picture is refused")
            } catch { expect(false, "\(name): adding cover art failed: \(error.localizedDescription)") }
        }

        print("\(checks - failures) of \(checks) engine checks match the page")
        if failures > 0 { exit(1) }
    }
}
