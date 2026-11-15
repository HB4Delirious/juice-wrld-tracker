// Checks the Swift engine (JuiceTracker/Engine.swift) against the page's own answers in fixtures.json, written by
// tests/engine-fixtures.mjs. Run: scripts/test-engine.sh
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
            let write: ([UInt8], Tags) throws -> TagWriter.Written = ext == "mp3" ? TagWriter.writeMp3 : ext == "flac" ? TagWriter.writeFlac : TagWriter.writeM4a
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

        print("\(checks - failures) of \(checks) engine checks match the page")
        if failures > 0 { exit(1) }
    }
}
