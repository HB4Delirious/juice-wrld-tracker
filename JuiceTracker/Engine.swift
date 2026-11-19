import Foundation

// The engine's pure logic: the catalog, reading and writing tags, scanning, matching, and the rules behind what the
// screens show. It was ported line for line from the old HTML page; tests/fixtures holds that page's answers for a
// set of tricky inputs, and scripts/test-engine.sh checks this code still gives them. Foundation only, so the tests
// can compile it on its own.

enum Engine {
    static let api = "https://juicewrldapi.com/juicewrld/songs/"
    static let fuzzyCutoff = 0.88
    static let audioExts: Set<String> = ["mp3", "flac", "m4a", "m4b", "aac", "alac", "ogg", "opus", "wav", "aiff", "aif", "wma"]
}

// MARK: - Text helpers (same rules as the page)

extension Engine {
    /// The match key of a title: no accents, brackets, "feat ..." tails or punctuation; "&" becomes "and".
    static func normalize(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "" }
        let raw = String(String.UnicodeScalarView(title.decomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { !(0x300...0x36F).contains($0.value) })).lowercased()
        var t = raw.replacingOccurrences(of: #"\s*[\(\[\{][^\)\]\}]*[\)\]\}]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\b(feat|ft|prod)\.?\s.*$"#, with: "", options: .regularExpression)
        t = squash(t.replacingOccurrences(of: "&", with: " and "))
        return t.isEmpty ? squash(raw) : t
    }
    /// Keeps a-z, 0-9 and spaces, with runs of spaces made one and the ends trimmed.
    private static func squash(_ s: String) -> String {
        let kept = String(String.UnicodeScalarView(s.unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == " " }))
        return kept.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    static func hasValue(_ v: String) -> Bool {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.range(of: #"^(n/?a|none|unknown|tba|tbd|null|-+|\?+)$"#, options: [.regularExpression, .caseInsensitive]) == nil
    }
    static func yearOf(_ v: String) -> String {
        guard let r = v.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) else { return "" }
        return String(v[r])
    }
    /// Whether the library counts a file as Juice WRLD: its path or its artist tags say so.
    static func countsAsJuice(path: String, tags: Tags) -> Bool {
        hasArtist(path) || hasArtist("\(tags["artist"] ?? "") \(tags["albumartist"] ?? "")")
    }
    /// Whether a file has finished arriving (a copy can take minutes): its size didn't change between two looks a few
    /// seconds apart, and it wasn't written to in the last 10 seconds.
    static func settled(sizeBefore: Int, sizeNow: Int, modified: Date, now: Date) -> Bool {
        // A date in the future (a NAS whose clock runs ahead, bad metadata) says nothing about the copy; the size does.
        sizeNow > 0 && sizeNow == sizeBefore && (now.timeIntervalSince(modified) >= 10 || modified > now)
    }
    /// A song title as a Wordle answer: bracketed parts ("(feat. …)", "[v2]") dropped, letters and digits upper-cased,
    /// spaces kept between words; nil when it isn't 4 to 14 letters long.
    static func wordleWord(_ title: String) -> String? {
        let bare = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        let words = bare.uppercased().folding(options: .diacriticInsensitive, locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map { $0.filter { $0 != "'" } }.filter { !$0.isEmpty }
        let letters = words.joined().count
        return (4...14).contains(letters) && words.joined().allSatisfy({ $0.isASCII }) ? words.joined(separator: " ") : nil
    }
    /// A Wordle guess against the answer, letter by letter (spaces ignored): 2 right place, 1 in the word elsewhere, 0
    /// not in it. A repeated letter is only yellow as many times as the answer still has it.
    static func wordleScore(_ guess: String, _ answer: String) -> [Int] {
        let g = Array(guess.filter { $0 != " " }), a = Array(answer.filter { $0 != " " })
        guard g.count == a.count else { return [] }
        var out = [Int](repeating: 0, count: g.count), left: [Character: Int] = [:]
        for k in g.indices { if g[k] == a[k] { out[k] = 2 } else { left[a[k], default: 0] += 1 } }
        for k in g.indices where out[k] == 0 { if let n = left[g[k]], n > 0 { out[k] = 1; left[g[k]] = n - 1 } }
        return out
    }
    /// The eras a spoken name fits, best first: the short name ("drfl"), then the full name ("Death Race For Love"),
    /// then names containing the words ("party never ends" fits TPNE and TPNE 2.0). Case, "&" and punctuation don't matter.
    static func erasNamed(_ spoken: String, eras: [(name: String, full: String)]) -> [String] {
        func plain(_ s: String) -> String {
            let t = s.lowercased().replacingOccurrences(of: "&", with: " and ")
            return String(String.UnicodeScalarView(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }))
                .split(separator: " ").joined(separator: " ")
        }
        let s = plain(spoken)
        guard !s.isEmpty else { return [] }
        for test in [{ (e: (name: String, full: String)) in plain(e.name) == s }, { plain($0.full) == s },
                     { plain($0.name).contains(s) || plain($0.full).contains(s) }] {
            let hits = eras.filter(test).map(\.name)
            if !hits.isEmpty { return hits }
        }
        return []
    }
    static func hasArtist(_ text: String) -> Bool {
        String(text.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) }).contains("juicewrld")
    }
    static func extOf(_ path: String) -> String {
        guard let r = path.range(of: #"\.([a-zA-Z0-9]+)$"#, options: .regularExpression) else { return "" }
        return String(path[r].dropFirst()).lowercased()
    }
    static func baseName(_ path: String) -> String { String(path.split(omittingEmptySubsequences: false) { $0 == "/" || $0 == "\\" }.last ?? "") }
    static func stemOf(_ path: String) -> String {
        baseName(path).replacingOccurrences(of: #"\.[^.]+$"#, with: "", options: .regularExpression).lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func titleFromFilename(_ path: String) -> String {
        var stem = baseName(path).replacingOccurrences(of: #"\.[^.]+$"#, with: "", options: .regularExpression)
        if stem.contains(" - ") { stem = stem.components(separatedBy: " - ").last ?? stem }
        return stem.replacingOccurrences(of: #"^\d{1,3}[\s._-]+"#, with: "", options: .regularExpression)
    }
}

// MARK: - Catalog

/// A catalog song, cleaned the way the page's cleanSong does it.
struct EngineSong: Codable, Equatable {
    var id, publicId, name: String
    var alt: [String]
    var era, category, length, release, artists, producers, recordDates, engineers, locations, key, info, notes: String
    var previewDate, leakDate, leakType, sessions, dates, bitrate, filePath: String
    var hasDetails: Bool
}

struct EraInfo: Codable, Equatable {
    var id: Int?
    var description: String
    var timeFrame: String
}

extension Engine {
    static let detailKeys = ["engineers", "recording_locations", "original_key", "additional_information", "notes", "preview_date", "date_leaked", "session_titles"]

    // JSON values the way JavaScript sees them: null is missing, and "", 0 and false are falsy.
    private static func present(_ v: Any?) -> Any? { v is NSNull ? nil : v }
    private static func truthy(_ v: Any?) -> Bool {
        switch present(v) {
        case nil: return false
        case let s as String: return !s.isEmpty
        case let n as NSNumber: return n != 0 && !n.doubleValue.isNaN
        default: return true
        }
    }
    /// JavaScript's String(v).
    static func jsString(_ v: Any?) -> String {
        switch present(v) {
        case nil: return ""
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case let a as [Any]: return a.map { present($0) == nil ? "" : jsString($0) }.joined(separator: ",")
        case is [String: Any]: return "[object Object]"
        default: return "\(v!)"
        }
    }
    private static func either(_ s: [String: Any], _ keys: String...) -> Any? {
        for k in keys { if let v = present(s[k]) { return v } }
        return nil
    }
    static func toList(_ v: Any?) -> [String] {
        guard truthy(v) else { return [] }
        if let a = present(v) as? [Any] { return a.filter(truthy).map(jsString) }
        return jsString(v).components(separatedBy: CharacterSet(charactersIn: "\n;|"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    static func textOf(_ v: Any?) -> String {
        if let a = present(v) as? [Any] { return a.filter(truthy).map(jsString).joined(separator: ", ") }
        return truthy(v) ? jsString(v).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    static func cleanSong(_ s: [String: Any]) -> EngineSong {
        let name = truthy(s["name"]) ? jsString(s["name"]) : "Unknown"
        var seen: [String] = []
        let alt = toList(either(s, "alt", "alt_titles", "track_titles")).filter { t in
            let low = t.lowercased()
            guard low != name.lowercased(), !seen.contains(low) else { return false }
            seen.append(low)
            return true
        }
        let era: String
        if let e = present(s["era"]) as? [String: Any] { era = truthy(e["name"]) ? jsString(e["name"]) : "Unknown" }
        else { era = truthy(s["era"]) ? jsString(s["era"]) : "Unknown" }
        let path = present(s["path"]) as? String
        return EngineSong(
            id: jsString(either(s, "id", "public_id") ?? name),
            publicId: present(s["publicId"]).map(jsString) ?? (present(s["public_id"]).map(jsString) ?? ""),
            name: name, alt: alt, era: era,
            category: truthy(s["category"]) ? jsString(s["category"]) : "unknown",
            length: truthy(s["length"]) ? jsString(s["length"]) : "",
            release: textOf(either(s, "release", "release_date")),
            artists: textOf(either(s, "artists", "credited_artists")),
            producers: textOf(s["producers"]),
            recordDates: textOf(either(s, "recordDates", "record_dates")),
            engineers: textOf(s["engineers"]),
            locations: textOf(either(s, "locations", "recording_locations")),
            key: textOf(either(s, "key", "original_key")),
            info: textOf(either(s, "info", "additional_information")),
            notes: textOf(s["notes"]),
            previewDate: textOf(either(s, "previewDate", "preview_date")),
            leakDate: textOf(either(s, "leakDate", "date_leaked")),
            leakType: textOf(either(s, "leakType", "leak_type")),
            sessions: textOf(either(s, "sessions", "session_titles")),
            dates: textOf(s["dates"]),
            bitrate: textOf(s["bitrate"]),
            filePath: (present(s["filePath"]) as? String) ?? (path.map { $0.contains("/") ? $0 : "" } ?? ""),
            hasDetails: (present(s["hasDetails"]) as? Bool) ?? detailKeys.contains { s.keys.contains($0) })
    }

    /// Era descriptions and time frames from raw songs; the first song of an era wins.
    static func collectEras(_ raw: [[String: Any]], into: [String: EraInfo] = [:]) -> [String: EraInfo] {
        var out = into
        for s in raw {
            guard let e = present(s["era"]) as? [String: Any], truthy(e["name"]) else { continue }
            let name = jsString(e["name"])
            if out[name] == nil { out[name] = EraInfo(id: nil, description: textOf(e["description"]), timeFrame: textOf(either(e, "time_frame", "timeFrame"))) }
        }
        return out
    }

    static func songsFromJSON(_ data: Any) -> [[String: Any]] {
        if let a = data as? [[String: Any]] { return a }
        if let d = data as? [String: Any] {
            if let r = d["results"] as? [[String: Any]] { return r }
            if let r = d["songs"] as? [[String: Any]] { return r }
        }
        return []
    }

    /// Cleans and de-duplicates by id: a later copy replaces an earlier one but keeps its place.
    static func mergeSongs(_ lists: [[[String: Any]]]) -> [EngineSong] {
        var order: [String] = [], byId: [String: EngineSong] = [:]
        for list in lists { for raw in list {
            let s = cleanSong(raw)
            if byId[s.id] == nil { order.append(s.id) }
            byId[s.id] = s
        } }
        return order.map { byId[$0]! }
    }

    struct FetchedCatalog { var raw: [[String: Any]]; var songs: [EngineSong]; var eras: [String: EraInfo] }

    /// Downloads the whole catalog, 100 songs a page, waiting out rate limits like the page does.
    static func fetchCatalog(progress: ((Int, Int?) -> Void)? = nil) async throws -> FetchedCatalog {
        var raw: [[String: Any]] = [], total: Int?
        for page in 1...500 {
            var data = Data(), status = 0
            for attempt in 0..<5 {
                var req = URLRequest(url: URL(string: "\(api)?page=\(page)&page_size=100")!)
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                let (d, r) = try await URLSession.shared.data(for: req)
                data = d; status = (r as? HTTPURLResponse)?.statusCode ?? 0
                if status != 429 { break }
                try await Task.sleep(nanoseconds: UInt64(pow(2, Double(attempt)) * 3) * 1_000_000_000)
            }
            if status == 404 && page > 1 { break }
            guard (200..<300).contains(status) else { throw EngineError("The catalog request failed (status \(status)).") }
            let json = try JSONSerialization.jsonObject(with: data)
            let results = songsFromJSON(json)
            raw += results
            let d = json as? [String: Any]
            if let c = d?["count"] as? Int { total = c }
            progress?(raw.count, total)
            if !truthy(d?["next"]) || results.isEmpty || (total.map { raw.count >= $0 } ?? false) { break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        let songs = mergeSongs([raw])
        guard !songs.isEmpty else { throw EngineError("The catalog came back empty.") }
        var eras = collectEras(raw)
        if let listed = try? await fetchEraList() { // the era list is optional
            for (name, info) in listed {
                let have = eras[name] ?? EraInfo(id: nil, description: "", timeFrame: "")
                eras[name] = EraInfo(id: info.id, description: hasValue(have.description) ? have.description : info.description,
                                     timeFrame: hasValue(have.timeFrame) ? have.timeFrame : info.timeFrame)
            }
        }
        return FetchedCatalog(raw: raw, songs: songs, eras: eras)
    }

    static func fetchEraList() async throws -> [String: EraInfo] {
        var eras: [String: EraInfo] = [:]
        var url: URL? = URL(string: "https://juicewrldapi.com/juicewrld/eras/?page_size=100")
        for _ in 0..<20 {
            guard let u = url else { break }
            var req = URLRequest(url: u)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (d, r) = try await URLSession.shared.data(for: req)
            guard (200..<300).contains((r as? HTTPURLResponse)?.statusCode ?? 0) else { break }
            let json = try JSONSerialization.jsonObject(with: d)
            let list = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["results"] as? [[String: Any]]) ?? []
            for e in list where truthy(e["name"]) {
                eras[jsString(e["name"])] = EraInfo(id: present(e["id"]) as? Int, description: textOf(e["description"]), timeFrame: textOf(either(e, "time_frame", "timeFrame")))
            }
            let next = (json as? [String: Any]).flatMap { truthy($0["next"]) ? jsString($0["next"]) : nil }
            url = next.flatMap { URL(string: $0.replacingOccurrences(of: #"^http:"#, with: "https:", options: .regularExpression)) }
        }
        return eras
    }
}

struct EngineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Reading tags (ID3, FLAC, MP4, Ogg); the page's readers, byte for byte

typealias Tags = [String: String]

enum TagReader {
    /// Reads the text tags of one file. Unreadable files give no tags, never an error.
    static func read(_ url: URL, ext: String) -> Tags {
        guard let f = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? f.close() }
        let file = Reader(f)
        if ext == "flac" { return readFlac(file) ?? [:] }
        if ext == "ogg" || ext == "opus" { return readOgg(file) }
        if ["m4a", "m4b", "alac"].contains(ext) { return readMp4(file) ?? readId3v2(file) ?? [:] }
        var tags = readId3v2(file) ?? [:]
        if (tags["title"] ?? "").isEmpty && ext == "mp3" { tags = (readId3v1(file) ?? [:]).merging(tags) { _, v2 in v2 } }
        return tags
    }

    /// Random-access reads, like slicing a File in the browser (out-of-range parts come back short).
    final class Reader {
        let handle: FileHandle
        let size: UInt64
        init(_ h: FileHandle) { handle = h; size = (try? h.seekToEnd()) ?? 0 }
        func bytes(_ start: UInt64, _ end: UInt64) -> [UInt8] {
            let s = min(start, size), e = min(max(end, s), size)
            guard e > s, (try? handle.seek(toOffset: s)) != nil else { return [] }
            return [UInt8]((try? handle.read(upToCount: Int(e - s))) ?? Data())
        }
    }

    // byte helpers
    static func latin1(_ b: ArraySlice<UInt8>) -> String { String(String.UnicodeScalarView(b.map { Unicode.Scalar($0) })) }
    static func sub(_ b: [UInt8], _ s: Int, _ e: Int) -> ArraySlice<UInt8> {
        let a = max(0, min(s, b.count)), z = max(a, min(e, b.count))
        return b[a..<z]
    }
    static func synchsafe(_ b: [UInt8], _ p: Int) -> Int {
        guard p + 3 < b.count else { return 0 }
        return Int(b[p] & 0x7f) << 21 | Int(b[p + 1] & 0x7f) << 14 | Int(b[p + 2] & 0x7f) << 7 | Int(b[p + 3] & 0x7f)
    }
    static func u32(_ b: [UInt8], _ p: Int) -> Int {
        guard p >= 0, p + 3 < b.count else { return 0 }
        return Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
    }
    static func u32le(_ b: [UInt8], _ p: Int) -> Int? {
        guard p >= 0, p + 3 < b.count else { return nil }
        return Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24
    }
    static func cleanText(_ s: String) -> String {
        var t = s
        while t.hasSuffix("\u{0}") { t.removeLast() }
        return t.replacingOccurrences(of: "\u{0}", with: "/").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // Like the browser's TextDecoder, these drop a leading byte order mark.
    static func utf8(_ b: ArraySlice<UInt8>) -> String { noBOM(String(decoding: b, as: UTF8.self)) }
    private static func noBOM(_ s: String) -> String { s.hasPrefix("\u{FEFF}") ? String(s.unicodeScalars.dropFirst()) : s }
    static func utf16(_ b: ArraySlice<UInt8>, bigEndian: Bool) -> String {
        let a = Array(b)
        var units: [UInt16] = []
        units.reserveCapacity(a.count / 2)
        var i = 0
        while i + 1 < a.count { units.append(bigEndian ? UInt16(a[i]) << 8 | UInt16(a[i + 1]) : UInt16(a[i + 1]) << 8 | UInt16(a[i])); i += 2 }
        return noBOM(String(decoding: units, as: UTF16.self) + (a.count % 2 == 1 ? "\u{FFFD}" : ""))
    }

    // ID3
    static func decodeId3Text(_ b: ArraySlice<UInt8>, _ enc: UInt8) -> String {
        switch enc {
        case 0: return cleanText(latin1(b))
        case 3: return cleanText(utf8(b))
        case 2: return cleanText(utf16(b, bigEndian: true))
        case 1:
            let a = Array(b)
            let be = a.count >= 2 && a[0] == 0xfe && a[1] == 0xff
            let bom = be || (a.count >= 2 && a[0] == 0xff && a[1] == 0xfe)
            return cleanText(utf16(bom ? b.dropFirst(2) : b, bigEndian: be))
        default: return ""
        }
    }
    static func splitTxxx(_ body: [UInt8]) -> (desc: String, value: String)? {
        guard body.count >= 2 else { return nil }
        let enc = body[0], rest = Array(body[1...])
        let wide = enc == 1 || enc == 2
        var i = 0
        if wide { while i + 1 < rest.count && !(rest[i] == 0 && rest[i + 1] == 0) { i += 2 } }
        else { while i < rest.count && rest[i] != 0 { i += 1 } }
        return (decodeId3Text(sub(rest, 0, i), enc), decodeId3Text(sub(rest, i + (wide ? 2 : 1), rest.count), enc))
    }
    struct Id3Frame { let id: String; let raw: [UInt8]; let body: [UInt8]; let special: UInt8 }
    struct Id3 { let ver: UInt8; let unsynced: Bool; let damaged: Bool; let tagEnd: Int; let truncated: Bool; let frames: [Id3Frame] }

    static func parseId3(_ b: [UInt8]) -> Id3? {
        guard b.count >= 10, latin1(b[0..<3]) == "ID3" else { return nil }
        let ver = b[3], flags = b[5], size = synchsafe(b, 6)
        var data = Array(sub(b, 10, 10 + size))
        if flags & 0x80 != 0 && ver < 4 { // unsynchronisation: FF 00 means FF
            var out: [UInt8] = []; out.reserveCapacity(data.count)
            var i = 0
            while i < data.count { out.append(data[i]); if data[i] == 0xff && i + 1 < data.count && data[i + 1] == 0 { i += 1 }; i += 1 }
            data = out
        }
        var pos = 0
        if flags & 0x40 != 0 { pos = ver == 4 ? synchsafe(data, 0) : u32(data, 0) + 4 }
        let idLen = ver == 2 ? 3 : 4, hdr = ver == 2 ? 6 : 10
        var frames: [Id3Frame] = [], damaged = false
        while pos + hdr <= data.count {
            if data[pos] == 0 { break } // padding
            let id = latin1(data[pos..<pos + idLen])
            guard id.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) }) else { damaged = true; break }
            let fsize = ver == 2 ? Int(data[pos + 3]) << 16 | Int(data[pos + 4]) << 8 | Int(data[pos + 5])
                : ver == 4 ? synchsafe(data, pos + 4) : u32(data, pos + 4)
            guard pos + hdr + fsize <= data.count else { damaged = true; break }
            let fmt: UInt8 = ver == 2 ? 0 : data[pos + 9]
            frames.append(Id3Frame(id: id, raw: Array(data[pos..<pos + hdr + fsize]), body: Array(data[pos + hdr..<pos + hdr + fsize]),
                                   special: ver == 4 ? fmt & 0x0f : fmt & 0xe0))
            pos += hdr + fsize
        }
        return Id3(ver: ver, unsynced: flags & 0x80 != 0, damaged: damaged, tagEnd: 10 + size + (ver == 4 && flags & 0x10 != 0 ? 10 : 0),
                   truncated: 10 + size > b.count, frames: frames)
    }
    static func tagsFromId3(_ p: Id3) -> Tags {
        var out: Tags = [:]
        let map = p.ver == 2
            ? ["TT2": "title", "TP1": "artist", "TP2": "albumartist", "TAL": "album", "TYE": "year", "TCO": "genre"]
            : ["TIT2": "title", "TPE1": "artist", "TPE2": "albumartist", "TALB": "album", "TYER": "year", "TDRC": "year", "TCON": "genre"]
        for f in p.frames where f.special == 0 && f.body.count >= 2 {
            if let k = map[f.id] { if (out[k] ?? "").isEmpty { out[k] = decodeId3Text(f.body[1...], f.body[0]) } }
            else if (f.id == "TXXX" || f.id == "TXX") && (out["producer"] ?? "").isEmpty {
                if let t = splitTxxx(f.body), t.desc.uppercased() == "PRODUCER" { out["producer"] = t.value }
            } else if (f.id == "COMM" || f.id == "COM") && (out["comment"] ?? "").isEmpty {
                // COMM is TXXX-like with a three-letter language after the encoding byte
                if f.body.count >= 5, let t = splitTxxx([f.body[0]] + f.body[4...]), t.desc.isEmpty { out["comment"] = t.value }
            }
        }
        if let y = out["year"], !y.isEmpty { out["year"] = Engine.yearOf(y).isEmpty ? y : Engine.yearOf(y) }
        return out
    }
    static func readId3v2(_ file: Reader) -> Tags? {
        let h = file.bytes(0, 10)
        guard h.count >= 10, latin1(h[0..<3]) == "ID3" else { return nil }
        let size = synchsafe(h, 6), first = 256 * 1024
        var p = parseId3(file.bytes(0, UInt64(10 + min(size, first))))
        // Most files put text tags before the cover art, so the first 256 KB is usually enough. Read the whole tag (up to
        // 4 MB) when the title wasn't there, or when a frame ran past it: then more frames (album, year) follow the art.
        // (The page only did the first; files with big cover art first kept "missing" their album in the Tag fixer.)
        if let q = p, size > first, (tagsFromId3(q)["title"] ?? "").isEmpty || q.damaged {
            p = parseId3(file.bytes(0, UInt64(10 + min(size, 4 * 1024 * 1024))))
        }
        return p.map(tagsFromId3)
    }
    static func readId3v1(_ file: Reader) -> Tags? {
        guard file.size >= 128 else { return nil }
        let b = file.bytes(file.size - 128, file.size)
        guard b.count == 128, latin1(b[0..<3]) == "TAG" else { return nil }
        return ["title": cleanText(latin1(b[3..<33])), "artist": cleanText(latin1(b[33..<63])), "album": cleanText(latin1(b[63..<93])), "year": Engine.yearOf(latin1(b[93..<97]))]
    }

    // FLAC and Ogg (Vorbis comments)
    static func parseVorbisComments(_ b: [UInt8]) -> Tags {
        var out: Tags = [:]
        let keys = ["TITLE": "title", "ARTIST": "artist", "ALBUMARTIST": "albumartist", "ALBUM ARTIST": "albumartist", "ALBUM": "album",
                    "DATE": "year", "YEAR": "year", "PRODUCER": "producer", "GENRE": "genre", "COMMENT": "comment"]
        var p = 0
        if let vendor = u32le(b, p) {
            p += 4 + vendor
            if let n = u32le(b, p) {
                p += 4
                var i = 0
                while i < n && p + 4 <= b.count, let len = u32le(b, p) { // truncated: keep what was read
                    p += 4
                    let s = utf8(sub(b, p, p + len)); p += len; i += 1
                    guard let eq = s.firstIndex(of: "=") else { continue }
                    if let key = keys[String(s[..<eq]).uppercased()], (out[key] ?? "").isEmpty {
                        out[key] = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }
        if let y = out["year"], !y.isEmpty { out["year"] = Engine.yearOf(y).isEmpty ? y : Engine.yearOf(y) }
        return out
    }
    static func readFlac(_ file: Reader) -> Tags? {
        guard latin1(file.bytes(0, 4)[...]) == "fLaC" else { return nil }
        var pos: UInt64 = 4
        for _ in 0..<64 {
            let h = file.bytes(pos, pos + 4)
            guard h.count >= 4 else { break }
            let last = h[0] & 0x80 != 0, type = h[0] & 0x7f, len = UInt64(Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3]))
            if type == 4 { return parseVorbisComments(file.bytes(pos + 4, pos + 4 + min(len, 1 << 20))) }
            pos += 4 + len
            if last { break }
        }
        return [:]
    }
    static func readOgg(_ file: Reader) -> Tags {
        let b = file.bytes(0, 256 * 1024)
        if let i = find(b, Array("OpusTags".utf8)) { return parseVorbisComments(Array(b[(i + 8)...])) }
        if let i = find(b, [3] + Array("vorbis".utf8)) { return parseVorbisComments(Array(b[(i + 7)...])) }
        return [:]
    }
    private static func find(_ b: [UInt8], _ needle: [UInt8]) -> Int? {
        guard b.count >= needle.count else { return nil }
        for i in 0...(b.count - needle.count) where b[i] == needle[0] && Array(b[i..<i + needle.count]) == needle { return i }
        return nil
    }

    // MP4 (M4A)
    static let mp4Keys = ["\u{a9}nam": "title", "\u{a9}ART": "artist", "aART": "albumartist", "\u{a9}alb": "album", "\u{a9}day": "year", "\u{a9}gen": "genre", "\u{a9}cmt": "comment"]
    static func walkAtoms(_ b: [UInt8], _ start: Int, _ end: Int, _ cb: (String, Int, Int) -> Void) {
        var p = start
        while p + 8 <= end {
            var len = u32(b, p)
            let type = latin1(sub(b, p + 4, p + 8))
            if len < 8 || p + len > end { len = end - p }
            cb(type, p + 8, p + len)
            p += len
        }
    }
    static func parseMoov(_ b: [UInt8]) -> Tags {
        var out: Tags = [:]
        func walk(_ start: Int, _ end: Int) {
            walkAtoms(b, start, end) { type, s, e in
                if type == "udta" || type == "ilst" { walk(s, e) }
                else if type == "meta" { walk(latin1(sub(b, s + 4, s + 8)) == "hdlr" ? s : s + 4, e) } // usually a full box
                else if let k = mp4Keys[type] {
                    walkAtoms(b, s, e) { t2, s2, e2 in
                        if t2 == "data" && (out[k] ?? "").isEmpty { out[k] = utf8(sub(b, s2 + 8, e2)).trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                } else if type == "----" {
                    var name = "", value = ""
                    walkAtoms(b, s, e) { t2, s2, e2 in
                        if t2 == "name" { name = utf8(sub(b, s2 + 4, e2)) }
                        else if t2 == "data" { value = utf8(sub(b, s2 + 8, e2)).trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    if name.uppercased() == "PRODUCER" && (out["producer"] ?? "").isEmpty { out["producer"] = value }
                }
            }
        }
        walk(0, b.count)
        if let y = out["year"], !y.isEmpty { out["year"] = Engine.yearOf(y).isEmpty ? y : Engine.yearOf(y) }
        return out
    }
    static func readMp4(_ file: Reader) -> Tags? {
        var pos: UInt64 = 0
        for _ in 0..<64 where pos + 8 <= file.size {
            let h = file.bytes(pos, pos + 16)
            guard h.count >= 8 else { break }
            var len = UInt64(u32(h, 0)), hdr: UInt64 = 8
            let type = latin1(h[4..<8])
            if len == 1 { guard h.count >= 16 else { break }; len = UInt64(u32(h, 8)) << 32 | UInt64(u32(h, 12)); hdr = 16 }
            else if len == 0 { len = file.size - pos }
            if len < 8 { break }
            if type == "moov" { return parseMoov(file.bytes(pos + hdr, pos + min(len, 16 * 1024 * 1024))) }
            pos += len
        }
        return nil
    }
}

// MARK: - The music folder

/// One audio file in the music folder, with what matching needs.
struct LibraryFile: Codable, Equatable {
    var path: String   // "<folder name>/<path inside it>", as the page names files
    var ext: String
    var tags: Tags
    var title: String
    var key: String
    var stem: String
    var fromTags: Bool
    var size: Int
}

extension Engine {
    struct CachedTags: Codable { var size: Int; var mtime: Double; var tags: Tags }

    /// Every audio file under `root` (skipping hidden files and folders), named like the page names them.
    static func listAudio(root: URL) -> [(path: String, url: URL)] {
        let prefix = root.lastPathComponent + "/"
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [(String, URL)] = []
        let base = root.standardizedFileURL.path
        for case let url as URL in walker where audioExts.contains(extOf(url.lastPathComponent)) {
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { continue }
            out.append((prefix + String(full.dropFirst(base.count + 1)), url))
        }
        return out
    }

    /// Reads the tags of every audio file (8 at a time; cached tags are reused unless `reread`) and keeps the Juice
    /// WRLD ones (by folder name or artist tag) unless `onlyJuice` is off. Returns the files sorted by path and the
    /// tags read fresh, for the cache.
    static func scan(root: URL, onlyJuice: Bool, cache: [String: CachedTags], reread: Bool,
                     progress: ((Int, Int) -> Void)? = nil) async -> (files: [LibraryFile], audioCount: Int, fresh: [String: CachedTags], paths: [String]) {
        let audio = listAudio(root: root)
        // A network drive answers each read slowly but can serve many at once, so more files are read in parallel there.
        let local = (try? root.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? true
        let parallel = local ? 8 : 16
        var fresh: [String: CachedTags] = [:], found: [LibraryFile] = [], done = 0
        await withTaskGroup(of: (LibraryFile?, CachedTags?, String).self) { group in
            var next = 0
            func add() {
                guard next < audio.count else { return }
                let (path, url) = audio[next]; next += 1
                let hit = reread ? nil : cache[path]
                group.addTask {
                    let ext = extOf(path)
                    var tags: Tags, size: Int, read: CachedTags?
                    if let hit { tags = hit.tags; size = hit.size }
                    else {
                        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        size = values?.fileSize ?? 0
                        tags = TagReader.read(url, ext: ext)
                        read = CachedTags(size: size, mtime: (values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000, tags: tags)
                    }
                    guard !onlyJuice || countsAsJuice(path: path, tags: tags) else { return (nil, read, path) }
                    let title = (tags["title"] ?? "").isEmpty ? titleFromFilename(path) : tags["title"]!
                    return (LibraryFile(path: path, ext: ext, tags: tags, title: title, key: normalize(title), stem: stemOf(path),
                                        fromTags: !(tags["title"] ?? "").isEmpty, size: size), read, path)
                }
            }
            for _ in 0..<parallel { add() }
            for await (file, read, path) in group {
                if let file { found.append(file) }
                if let read { fresh[path] = read }
                done += 1
                if done % 20 == 0 { progress?(done, audio.count) }
                add()
            }
        }
        progress?(audio.count, audio.count)
        return (found.sorted { $0.path.localizedCompare($1.path) == .orderedAscending }, audio.count, fresh, audio.map(\.path))
    }
}

// MARK: - Matching

extension Engine {
    static func similarity(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let la = a.count, lb = b.count
        if la == 0 && lb == 0 { return 1 }
        var prev = Array(0...lb), cur = [Int](repeating: 0, count: lb + 1)
        for i in 1...max(la, 1) where la > 0 {
            cur[0] = i
            for j in 1...max(lb, 1) where lb > 0 { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 2)) }
            swap(&prev, &cur)
        }
        return Double(la + lb - prev[lb]) / Double(la + lb)
    }

    /// The closest title key at or above the cutoff (the later of equally close keys, as the page does).
    static func closestKey(_ key: String, _ keys: [[UInt8]], _ names: [String], cutoff: Double) -> String? {
        let k = Array(key.utf8)
        var best: String?, bestScore = cutoff
        for (n, c) in keys.enumerated() {
            if Double(abs(c.count - k.count)) > Double(max(c.count, k.count)) * 0.25 { continue }
            let score = similarity(k, c)
            if score >= bestScore { bestScore = score; best = names[n] }
        }
        return best
    }

    struct Match {
        var owned: [Int: [String]] = [:]     // song index → paths of its files
        var songsFor: [String: [Int]] = [:]  // path → song indexes
        var how: [String: String] = [:]      // path → manual, title, file or close
        var unmatched: [String] = []
    }

    /// Matches files to catalog songs: a match set by hand, the exact title, the exact file name of the site's file
    /// (for files saved straight from juicewrldapi.com), then a close title.
    static func match(catalog: [EngineSong], files: [LibraryFile], overrides: [String: String]) -> Match {
        var index: [String: [Int]] = [:], keyOrder: [String] = [], stems: [String: [Int]] = [:], byId: [String: Int] = [:]
        for (i, song) in catalog.enumerated() {
            byId[song.id] = i
            for t in [song.name] + song.alt {
                let k = normalize(t)
                guard !k.isEmpty else { continue }
                if index[k] == nil { index[k] = []; keyOrder.append(k) }
                if !index[k]!.contains(i) { index[k]!.append(i) }
            }
            if !song.filePath.isEmpty {
                let st = stemOf(song.filePath)
                if !st.isEmpty { if !(stems[st] ?? []).contains(i) { stems[st, default: []].append(i) } }
            }
        }
        let keyBytes = keyOrder.map { Array($0.utf8) }
        var fuzzy: [String: String?] = [:], m = Match()
        for f in files {
            let o = overrides[f.path]
            if o == "none" { m.unmatched.append(f.path); continue }
            var hits: [Int]?, how = ""
            if let o, let i = byId[o] { hits = [i]; how = "manual" }
            if hits == nil, !f.key.isEmpty, let h = index[f.key] { hits = h; how = "title" }
            if hits == nil, !f.stem.isEmpty, let h = stems[f.stem] { hits = h; how = "file" }
            if hits == nil, !f.key.isEmpty {
                if fuzzy[f.key] == nil { fuzzy[f.key] = .some(closestKey(f.key, keyBytes, keyOrder, cutoff: fuzzyCutoff)) }
                if let k = fuzzy[f.key]!, let h = index[k] { hits = h; how = "close" }
            }
            guard let hits else { m.unmatched.append(f.path); continue }
            m.how[f.path] = how
            m.songsFor[f.path] = hits
            for i in hits { m.owned[i, default: []].append(f.path) }
        }
        return m
    }
}

// MARK: - What the screens show about songs and eras (stage 2)

extension Engine {
    static let noEra = "No era listed"
    static let months = ["jan": 0, "feb": 1, "mar": 2, "apr": 3, "may": 4, "jun": 5, "jul": 6, "aug": 7, "sep": 8, "oct": 9, "nov": 10, "dec": 11]

    static func isReleased(_ s: EngineSong) -> Bool {
        s.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "released" || hasValue(s.release)
    }
    static func eraName(_ s: EngineSong) -> String { hasValue(s.era) ? s.era : noEra }
    /// "recording_session" → "Recording session".
    static func capital(_ c: String) -> String { (c.prefix(1).uppercased() + c.dropFirst()).replacingOccurrences(of: "_", with: " ") }

    /// Compiled patterns, kept: the same few are used for every song (recording dates, years), and compiling one each
    /// time was a good part of opening the tag fixer. NSCache is safe to use from any thread.
    private static let compiled = NSCache<NSString, NSRegularExpression>()
    static func regex(_ pattern: String, _ options: NSRegularExpression.Options) -> NSRegularExpression? {
        let key = "\(options.rawValue)|\(pattern)" as NSString
        if let re = compiled.object(forKey: key) { return re }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        compiled.setObject(re, forKey: key)
        return re
    }

    /// Every match of a regular expression, as its capture groups (missing groups are nil).
    static func groups(_ pattern: String, _ text: String, options: NSRegularExpression.Options = []) -> [[String?]] {
        guard let re = regex(pattern, options) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? nil : ns.substring(with: m.range(at: $0)) }
        }
    }
    /// Splits a text at every match of a pattern (like JavaScript's split with a regular expression).
    static func split(_ text: String, by pattern: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let re = regex(pattern, options) else { return [text] }
        let ns = text as NSString
        var out: [String] = [], from = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: from, length: m.range.location - from)))
            from = m.range.location + m.range.length
        }
        out.append(ns.substring(from: from))
        return out
    }
    private static func uniqueIgnoringCase(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.lowercased()).inserted }
    }

    /// "Nick Mira & Dre Moon, Taz Taylor" → the names.
    static func splitNames(_ text: String) -> [String] {
        var t = text.replacingOccurrences(of: #"\((?:feat|ft|prod)\.?(?:\s*by)?\s*"#, with: ",", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "[()]", with: ",", options: .regularExpression)
        return uniqueIgnoringCase(split(t, by: #"\s*(?:,|;|/|&|\+|\band\b|\bfeat\.?|\bft\.)\s*"#, options: .caseInsensitive)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { hasValue($0) && $0.utf16.count > 1 })
    }
    static func splitStudios(_ text: String) -> [String] {
        uniqueIgnoringCase(split(text, by: #"\s*(?:;|\n|\||/)\s*"#).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter(hasValue))
    }
    /// The years a text mentions, with short ranges ("2017-2019") filled in, in the page's order.
    static func yearsIn(_ text: String) -> [Int] {
        var out: [Int] = []
        func add(_ y: Int) { if !out.contains(y) { out.append(y) } }
        for g in groups(#"\b(?:19|20)\d{2}\b"#, text) { add(Int(g[0]!)!) }
        for g in groups(#"\b((?:19|20)\d{2})\s*(?:-|–|—|to)\s*((?:19|20)\d{2})\b"#, text) {
            let a = Int(g[1]!)!, b = Int(g[2]!)!
            if b > a && b - a <= 6 { for y in a...b { add(y) } }
        }
        return out
    }
    /// The month a song was recorded, as year * 12 + month (0-11).
    static func recordMonth(_ text: String) -> Int? {
        if let g = groups(#"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(?:\d{1,2}(?:st|nd|rd|th)?,?\s+)?((?:19|20)\d{2})\b"#, text, options: .caseInsensitive).first {
            return Int(g[2]!)! * 12 + months[g[1]!.lowercased()]!
        }
        if let g = groups(#"\b((?:19|20)\d{2})-(\d{2})-\d{2}\b"#, text).first, let m = Int(g[2]!), (1...12).contains(m) { return Int(g[1]!)! * 12 + m - 1 }
        return nil
    }
    /// For sorting eras: year * 12 + month (January when there's no month).
    static func timeKey(_ text: String) -> Int? {
        guard let g = groups(#"(?:\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?,?\s+)?\b((?:19|20)\d{2})\b"#, text, options: .caseInsensitive).first else { return nil }
        return Int(g[2]!)! * 12 + (g[1].map { months[$0.lowercased()]! } ?? 0)
    }
    /// Every "Month D, YYYY" in a text.
    static func datesIn(_ text: String) -> [(y: Int, m: Int, d: Int)] {
        groups(#"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+((?:19|20)\d{2})\b"#, text, options: .caseInsensitive)
            .map { (Int($0[3]!)!, months[$0[1]!.lowercased()]!, Int($0[2]!)!) }
    }

    struct EraStat: Equatable { var name: String; var have: Int; var total: Int; var timeFrame: String; var description: String }

    /// The eras in time order (by the era's time frame, else its earliest song), with how many songs you have.
    static func eraStats(_ catalog: [EngineSong], owned: Set<Int>, eras: [String: EraInfo]) -> [EraStat] {
        var order: [String] = [], stats: [String: (total: Int, have: Int, earliest: Int?)] = [:]
        for (i, s) in catalog.enumerated() {
            let name = eraName(s)
            if stats[name] == nil { order.append(name); stats[name] = (0, 0, nil) }
            stats[name]!.total += 1
            if owned.contains(i) { stats[name]!.have += 1 }
            if let k = timeKey(s.recordDates) ?? timeKey(s.release), stats[name]!.earliest.map({ k < $0 }) ?? true { stats[name]!.earliest = k }
        }
        let list = order.map { name -> (EraStat, Double, Int) in
            let st = stats[name]!, info = eras[name]
            let key: Double = name == noEra ? .infinity : Double(info.flatMap { timeKey($0.timeFrame) } ?? st.earliest ?? Int.max)
            return (EraStat(name: name, have: st.have, total: st.total, timeFrame: info?.timeFrame ?? "", description: info?.description ?? ""),
                    key == Double(Int.max) ? .infinity : key, info?.id ?? 1_000_000_000)
        }
        return list.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.2 != b.2 { return a.2 < b.2 }
            return a.0.name.localizedCompare(b.0.name) == .orderedAscending
        }.map(\.0)
    }
}

// MARK: - Export helpers (stage 3)

extension Engine {
    /// JavaScript's encodeURIComponent.
    static func encodeURIComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")) ?? s
    }
    static func fileUrl(_ s: EngineSong) -> String {
        s.filePath.isEmpty ? "" : "https://juicewrldapi.com/juicewrld/files/download/?path=\(encodeURIComponent(s.filePath))"
    }
    /// Spreadsheet text: a byte order mark (so Excel reads UTF-8), every cell quoted, Windows line ends.
    static func csvText(_ lines: [[String]]) -> String {
        "\u{FEFF}" + lines.map { $0.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",") }.joined(separator: "\r\n")
    }
}

// MARK: - Writing tags (stage 4): the page's writers and safety checks, byte for byte

/// Rewrites a file's tags and leaves its audio bytes alone. Each writer returns the new file; its verify step re-reads
/// it and throws unless the audio is untouched and every tag reads back, so a bad write is never saved.
enum TagWriter {
    static let fields = ["title", "artist", "albumartist", "album", "year", "producer", "genre", "comment"]
    static let fieldLabels = ["title": "Title", "artist": "Artist", "albumartist": "Album artist", "album": "Album", "year": "Year",
                              "producer": "Producers", "genre": "Genre", "comment": "Comment"]
    struct Written { var out: [UInt8]; var audioLength = 0; var delta = 0; var moovStart = 0; var oldMoovEnd = 0 }

    /// Writes and checks: the new file's bytes, or an error saying why the file was left unchanged.
    static func write(_ orig: [UInt8], ext: String, tags desired: Tags) throws -> [UInt8] {
        let want = desired.filter { !$0.value.isEmpty }
        switch ext {
        case "mp3": let r = try writeMp3(orig, want); try verifyMp3(orig, r, want); return r.out
        case "flac": let r = try writeFlac(orig, want); try verifyFlac(orig, r, want); return r.out
        case "m4a": let r = try writeM4a(orig, want); try verifyM4a(orig, r, want); return r.out
        default: throw EngineError("can't be tagged here (only MP3, FLAC and M4A)")
        }
    }

    // byte helpers
    static func ascii(_ s: String) -> [UInt8] { s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } }
    static func utf8(_ s: String) -> [UInt8] { Array(s.utf8) }
    static func utf16le(_ s: String) -> [UInt8] { s.utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] } }
    static func u32be(_ n: Int) -> [UInt8] { [UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] }
    static func u32le(_ n: Int) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255), UInt8(n >> 16 & 255), UInt8(n >> 24 & 255)] }
    static func sameTail(_ a: [UInt8], _ b: [UInt8], _ count: Int = 512) -> Bool {
        let n = min(count, a.count, b.count)
        return n == 0 || a[(a.count - n)...] == b[(b.count - n)...]
    }
    static func checkTags(_ read: Tags, _ desired: Tags) throws {
        for k in fields {
            guard let d = desired[k], !d.isEmpty else { continue }
            let want = k == "year" ? (Engine.yearOf(d).isEmpty ? d : Engine.yearOf(d)) : d
            if (read[k] ?? "") != want { throw EngineError("failed a safety check (\(fieldLabels[k]!.lowercased()) didn't read back), so it was left unchanged") }
        }
    }

    // MP3 (ID3v2.3 and 2.4)
    static func id3Frame(_ id: String, _ body: [UInt8], _ ver: UInt8) -> [UInt8] {
        let n = body.count
        let size: [UInt8] = ver == 4 ? [UInt8(n >> 21 & 0x7f), UInt8(n >> 14 & 0x7f), UInt8(n >> 7 & 0x7f), UInt8(n & 0x7f)] : u32be(n)
        return ascii(id) + size + [0, 0] + body
    }
    static func id3Text(_ id: String, _ value: String, _ ver: UInt8) -> [UInt8] {
        id3Frame(id, ver == 4 ? [3] + utf8(value) : [1, 0xff, 0xfe] + utf16le(value), ver)
    }
    static func id3Txxx(_ desc: String, _ value: String, _ ver: UInt8) -> [UInt8] {
        id3Frame("TXXX", ver == 4 ? [3] + utf8(desc) + [0] + utf8(value) : [1, 0xff, 0xfe] + utf16le(desc) + [0, 0, 0xff, 0xfe] + utf16le(value), ver)
    }
    static func id3Comm(_ value: String, _ ver: UInt8) -> [UInt8] {
        id3Frame("COMM", ver == 4 ? [3] + ascii("eng") + [0] + utf8(value) : [1] + ascii("eng") + [0xff, 0xfe, 0, 0, 0xff, 0xfe] + utf16le(value), ver)
    }
    static func splitComm(_ body: [UInt8]) -> (desc: String, value: String)? { body.count < 5 ? nil : TagReader.splitTxxx([body[0]] + body[4...]) }

    static func writeMp3(_ orig: [UInt8], _ d: Tags, art: [UInt8]? = nil) throws -> Written {
        let p = TagReader.parseId3(orig)
        if let p {
            if p.ver != 3 && p.ver != 4 { throw EngineError("uses an older ID3 tag version that can't be edited here") }
            if p.unsynced { throw EngineError("uses an ID3 option that can't be edited here") }
            if p.damaged || p.truncated { throw EngineError("has a damaged ID3 tag") }
        }
        let ver = p?.ver ?? 3
        var drop = Set<String>()
        if d["title"] != nil { drop.insert("TIT2") }
        if d["artist"] != nil { drop.insert("TPE1") }
        if d["albumartist"] != nil { drop.insert("TPE2") }
        if d["album"] != nil { drop.insert("TALB") }
        if d["year"] != nil { drop.insert("TYER"); drop.insert("TDRC") }
        if d["genre"] != nil { drop.insert("TCON") }
        let kept = (p?.frames ?? []).filter { f in
            if drop.contains(f.id) { return false }
            if d["producer"] != nil && f.id == "TXXX" { return (TagReader.splitTxxx(f.body)?.desc ?? "").uppercased() != "PRODUCER" }
            if d["comment"] != nil && f.id == "COMM" { return !(splitComm(f.body)?.desc ?? "").isEmpty }
            return true
        }.flatMap(\.raw)
        var added: [UInt8] = []
        if let v = d["title"] { added += id3Text("TIT2", v, ver) }
        if let v = d["artist"] { added += id3Text("TPE1", v, ver) }
        if let v = d["albumartist"] { added += id3Text("TPE2", v, ver) }
        if let v = d["album"] { added += id3Text("TALB", v, ver) }
        if let v = d["year"] { added += id3Text(ver == 4 ? "TDRC" : "TYER", v, ver) }
        if let v = d["producer"] { added += id3Txxx("PRODUCER", v, ver) }
        if let v = d["genre"] { added += id3Text("TCON", v, ver) }
        if let v = d["comment"] { added += id3Comm(v, ver) }
        if let art { added += id3Frame("APIC", [0] + ascii("image/jpeg") + [0, 3, 0] + art, ver) } // front cover, no description
        let frames = kept + added, size = frames.count + 2048
        let header: [UInt8] = [0x49, 0x44, 0x33, ver, 0, 0, UInt8(size >> 21 & 0x7f), UInt8(size >> 14 & 0x7f), UInt8(size >> 7 & 0x7f), UInt8(size & 0x7f)]
        let audio = orig[min(p?.tagEnd ?? 0, orig.count)...]
        if audio.isEmpty { throw EngineError("has no audio after its tag") }
        return Written(out: header + frames + [UInt8](repeating: 0, count: 2048) + audio, audioLength: audio.count)
    }
    static func verifyMp3(_ orig: [UInt8], _ r: Written, _ d: Tags) throws {
        guard let p = TagReader.parseId3(r.out), !p.damaged, !p.truncated else { throw EngineError("failed a safety check (new tag unreadable), so it was left unchanged") }
        if r.out.count - p.tagEnd != r.audioLength || !sameTail(orig, r.out) { throw EngineError("failed a safety check (audio mismatch), so it was left unchanged") }
        try checkTags(TagReader.tagsFromId3(p), d)
    }

    // FLAC (Vorbis comments)
    struct FlacBlock { var type: UInt8; var body: [UInt8] }
    static func parseFlacBlocks(_ b: [UInt8]) throws -> (blocks: [FlacBlock], audioStart: Int) {
        guard b.count >= 8, TagReader.latin1(b[0..<4]) == "fLaC" else { throw EngineError("isn't a valid FLAC file") }
        var pos = 4, blocks: [FlacBlock] = []
        while true {
            if pos + 4 > b.count || blocks.count > 512 { throw EngineError("has a damaged FLAC header") }
            let h = b[pos], type = h & 0x7f, len = Int(b[pos + 1]) << 16 | Int(b[pos + 2]) << 8 | Int(b[pos + 3])
            if type == 127 || pos + 4 + len > b.count { throw EngineError("has a damaged FLAC header") }
            blocks.append(FlacBlock(type: type, body: Array(b[pos + 4..<pos + 4 + len])))
            pos += 4 + len
            if h & 0x80 != 0 { break }
        }
        if blocks[0].type != 0 { throw EngineError("has a damaged FLAC header") }
        return (blocks, pos)
    }
    static func parseVorbisStrict(_ b: [UInt8]) throws -> (vendor: [UInt8], comments: [String]) {
        let fail = EngineError("has a damaged tag block")
        guard b.count >= 8, let vlen = TagReader.u32le(b, 0), 8 + vlen <= b.count else { throw fail }
        let vendor = Array(b[4..<4 + vlen])
        var p = 4 + vlen
        guard let n = TagReader.u32le(b, p) else { throw fail }
        p += 4
        var comments: [String] = []
        for _ in 0..<n {
            guard p + 4 <= b.count, let len = TagReader.u32le(b, p) else { throw fail }
            p += 4
            guard p + len <= b.count else { throw fail }
            comments.append(TagReader.utf8(b[p..<p + len])); p += len
        }
        return (vendor, comments)
    }
    static let vorbisReadKeys = ["title": ["TITLE"], "artist": ["ARTIST"], "albumartist": ["ALBUMARTIST", "ALBUM ARTIST"], "album": ["ALBUM"],
                                 "year": ["DATE", "YEAR"], "producer": ["PRODUCER"], "genre": ["GENRE"], "comment": ["COMMENT"]]
    static let vorbisWriteKey = ["title": "TITLE", "artist": "ARTIST", "albumartist": "ALBUMARTIST", "album": "ALBUM", "year": "DATE",
                                 "producer": "PRODUCER", "genre": "GENRE", "comment": "COMMENT"]

    static func writeFlac(_ orig: [UInt8], _ d: Tags, art: (jpeg: [UInt8], width: Int, height: Int)? = nil) throws -> Written {
        let (blocks, audioStart) = try parseFlacBlocks(orig)
        let ci: Int? = blocks.firstIndex { $0.type == 4 }
        var vendor = utf8("Juice WRLD collection tracker"), comments: [String] = []
        if let ci { (vendor, comments) = try parseVorbisStrict(blocks[ci].body) }
        var drop = Set<String>()
        for k in fields where d[k] != nil { vorbisReadKeys[k]!.forEach { drop.insert($0) } }
        comments = comments.filter { c in !drop.contains((c.firstIndex(of: "=").map { String(c[..<$0]) } ?? c).uppercased()) }
        for k in fields { if let v = d[k] { comments.append("\(vorbisWriteKey[k]!)=\(v)") } }
        var body = u32le(vendor.count) + vendor + u32le(comments.count)
        for c in comments { let e = utf8(c); body += u32le(e.count) + e }
        var out = blocks.filter { $0.type != 4 }
        var insertAt = 1
        if let c = ci { insertAt = Swift.max(1, blocks[..<c].filter { $0.type != 4 }.count) }
        out.insert(FlacBlock(type: 4, body: body), at: Swift.min(insertAt, out.count))
        if let art { // a front cover PICTURE block, right after the comments
            let mime = ascii("image/jpeg")
            let pic = u32be(3) + u32be(mime.count) + mime + u32be(0) + u32be(art.width) + u32be(art.height) + u32be(24) + u32be(0) + u32be(art.jpeg.count) + art.jpeg
            out.insert(FlacBlock(type: 6, body: pic), at: Swift.min(insertAt + 1, out.count))
        }
        if !out.contains(where: { $0.type == 1 }) { out.append(FlacBlock(type: 1, body: [UInt8](repeating: 0, count: 1024))) }
        var pieces = ascii("fLaC")
        for (i, bl) in out.enumerated() {
            let len = bl.body.count
            if len >= 1 << 24 { throw EngineError("has a tag block that's too large to edit") }
            pieces += [(i == out.count - 1 ? 0x80 : 0) | bl.type, UInt8(len >> 16 & 255), UInt8(len >> 8 & 255), UInt8(len & 255)] + bl.body
        }
        let audio = orig[audioStart...]
        if audio.isEmpty { throw EngineError("has no audio after its header") }
        return Written(out: pieces + audio, audioLength: audio.count)
    }
    static func verifyFlac(_ orig: [UInt8], _ r: Written, _ d: Tags) throws {
        guard let parsed = try? parseFlacBlocks(r.out) else { throw EngineError("failed a safety check (new header unreadable), so it was left unchanged") }
        if r.out.count - parsed.audioStart != r.audioLength || !sameTail(orig, r.out) { throw EngineError("failed a safety check (audio mismatch), so it was left unchanged") }
        try checkTags(parsed.blocks.first { $0.type == 4 }.map { TagReader.parseVorbisComments($0.body) } ?? [:], d)
    }

    // M4A (the iTunes tag list in moov/udta/meta/ilst)
    struct Atom { let type: String; let start: Int; let hdr: Int; let end: Int }
    /// The boxes between start and end, strictly. A few stray trailing bytes (QuickTime's terminator) are ignored.
    static func readAtoms(_ b: [UInt8], _ start: Int, _ end: Int) throws -> [Atom] {
        var out: [Atom] = [], p = start
        while p + 8 <= end {
            var size = TagReader.u32(b, p), hdr = 8
            let type = TagReader.latin1(b[p + 4..<p + 8])
            if size == 1 {
                if p + 16 > end { throw EngineError("has a damaged MP4 header") }
                size = TagReader.u32(b, p + 8) * 4294967296 + TagReader.u32(b, p + 12); hdr = 16
            } else if size == 0 { size = end - p }
            if size < hdr || p + size > end { throw EngineError("has a damaged MP4 header") }
            out.append(Atom(type: type, start: p, hdr: hdr, end: p + size))
            p += size
        }
        return out
    }
    static func mp4Box(_ type: String, _ parts: [UInt8]...) throws -> [UInt8] {
        let body = parts.flatMap { $0 }, n = body.count + 8
        if n > 0xffffffff { throw EngineError("has a tag block that's too large to edit") }
        return u32be(n) + ascii(type) + body
    }
    static let mp4TextFlags: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 0]
    static let mp4Keys: [(String, String)] = [("title", "\u{a9}nam"), ("artist", "\u{a9}ART"), ("albumartist", "aART"), ("album", "\u{a9}alb"),
                                              ("year", "\u{a9}day"), ("genre", "\u{a9}gen"), ("comment", "\u{a9}cmt")]
    static func freeformName(_ b: [UInt8], _ item: Atom) throws -> String {
        for c in try readAtoms(b, item.start + item.hdr, item.end) where c.type == "name" { return TagReader.utf8(TagReader.sub(b, c.start + c.hdr + 4, c.end)) }
        return ""
    }
    static let mp4Containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]
    /// Every chunk offset table (stco or co64) in the boxes between s and e: where its entries start, how many, how wide.
    static func stcoTables(_ b: [UInt8], _ s: Int, _ e: Int) throws -> [(p: Int, n: Int, wide: Bool)] {
        var out: [(Int, Int, Bool)] = []
        for a in try readAtoms(b, s, e) {
            if mp4Containers.contains(a.type) { out += try stcoTables(b, a.start + a.hdr, a.end) }
            else if a.type == "stco" || a.type == "co64" {
                let p = a.start + a.hdr, wide = a.type == "co64"
                if p + 8 > a.end { throw EngineError("has a damaged MP4 header") }
                let n = TagReader.u32(b, p + 4)
                if p + 8 + n * (wide ? 8 : 4) > a.end { throw EngineError("has a damaged MP4 header") }
                out.append((p + 8, n, wide))
            }
        }
        return out
    }
    static func u64(_ b: [UInt8], _ p: Int) -> Int { TagReader.u32(b, p) * 4294967296 + TagReader.u32(b, p + 4) }
    static func chunkOffsets(_ b: [UInt8], _ s: Int, _ e: Int) throws -> [Int] {
        try stcoTables(b, s, e).flatMap { t in (0..<t.n).map { t.wide ? u64(b, t.p + $0 * 8) : TagReader.u32(b, t.p + $0 * 4) } }
    }

    static func writeM4a(_ orig: [UInt8], _ d: Tags, art: [UInt8]? = nil) throws -> Written {
        let top = try readAtoms(orig, 0, orig.count)
        guard top.first?.type == "ftyp" else { throw EngineError("isn't a valid M4A file") }
        if top.contains(where: { $0.type == "moof" }) { throw EngineError("is a fragmented MP4, which can't be edited here") }
        let moovs = top.filter { $0.type == "moov" }
        if moovs.count != 1 { throw EngineError("has a damaged MP4 header") }
        if !top.contains(where: { $0.type == "mdat" }) { throw EngineError("has no audio after its header") }
        let moov = moovs[0]
        func raw(_ a: Atom) -> [UInt8] { Array(orig[a.start..<a.end]) }

        let kids = try readAtoms(orig, moov.start + moov.hdr, moov.end)
        let udta = kids.first { $0.type == "udta" }
        let udtaKids = try udta.map { try readAtoms(orig, $0.start + $0.hdr, $0.end) } ?? []
        let meta = udtaKids.first { $0.type == "meta" }
        if meta == nil && kids.contains(where: { $0.type == "meta" }) { throw EngineError("uses an MP4 tag layout that can't be edited here") }
        var metaKids: [Atom] = [], metaPrefix: [UInt8] = [0, 0, 0, 0]
        if let meta {
            let s = meta.start + meta.hdr, cs = TagReader.latin1(TagReader.sub(orig, s + 4, s + 8)) == "hdlr" ? s : s + 4
            metaPrefix = Array(orig[s..<cs])
            metaKids = try readAtoms(orig, cs, meta.end)
        }
        let ilst = metaKids.first { $0.type == "ilst" }
        var drop = Set<String>()
        for (k, key) in mp4Keys where d[k] != nil { drop.insert(key) }
        if d["genre"] != nil { drop.insert("gnre") }
        let items = try ilst.map { try readAtoms(orig, $0.start + $0.hdr, $0.end) } ?? []
        var kept: [UInt8] = []
        for it in items {
            if drop.contains(it.type) { continue }
            if d["producer"] != nil && it.type == "----", try freeformName(orig, it).uppercased() == "PRODUCER" { continue }
            kept += raw(it)
        }
        var added: [UInt8] = []
        for (k, key) in mp4Keys { if let v = d[k] { added += try mp4Box(key, try mp4Box("data", mp4TextFlags, utf8(v))) } }
        if let v = d["producer"] {
            added += try mp4Box("----", try mp4Box("mean", [0, 0, 0, 0], ascii("com.apple.iTunes")), try mp4Box("name", [0, 0, 0, 0], utf8("PRODUCER")),
                                try mp4Box("data", mp4TextFlags, utf8(v)))
        }
        if let art { added += try mp4Box("covr", try mp4Box("data", [0, 0, 0, 13, 0, 0, 0, 0], art)) } // 13: JPEG
        let newIlst = try mp4Box("ilst", kept, added)
        let hdlrBytes = try metaKids.first { $0.type == "hdlr" }.map(raw) ?? mp4Box("hdlr", [UInt8](repeating: 0, count: 8), ascii("mdirappl"), [UInt8](repeating: 0, count: 9))
        let newMeta = try mp4Box("meta", metaPrefix, hdlrBytes, newIlst, metaKids.filter { $0.type != "hdlr" && $0.type != "ilst" }.flatMap(raw))
        var udtaParts = udtaKids.flatMap { $0.start == meta?.start ? newMeta : raw($0) }
        if meta == nil { udtaParts += newMeta }
        let newUdta = try mp4Box("udta", udtaParts)
        var moovParts = kids.flatMap { $0.start == udta?.start ? newUdta : raw($0) }
        if udta == nil { moovParts += newUdta }
        var newMoov = try mp4Box("moov", moovParts)

        let delta = newMoov.count - (moov.end - moov.start)
        if delta != 0 {
            for t in try stcoTables(newMoov, 0, newMoov.count) {
                for k in 0..<t.n {
                    if t.wide {
                        let at = t.p + k * 8, v = u64(newMoov, at)
                        if v > moov.start { let nv = v + delta; for i in 0..<8 { newMoov[at + i] = UInt8(nv >> (56 - 8 * i) & 255) } }
                    } else {
                        let at = t.p + k * 4, v = TagReader.u32(newMoov, at)
                        if v > moov.start {
                            let nv = v + delta
                            if nv > 0xffffffff || nv < 0 { throw EngineError("would need 64-bit audio offsets, which can't be edited here") }
                            newMoov.replaceSubrange(at..<at + 4, with: u32be(nv))
                        }
                    }
                }
            }
        }
        return Written(out: Array(orig[..<moov.start]) + newMoov + Array(orig[moov.end...]), delta: delta, moovStart: moov.start, oldMoovEnd: moov.end)
    }
    static func verifyM4a(_ orig: [UInt8], _ r: Written, _ d: Tags) throws {
        func fail(_ why: String) -> EngineError { EngineError("failed a safety check (\(why)), so it was left unchanged") }
        guard let top = try? readAtoms(r.out, 0, r.out.count), let moov = top.first(where: { $0.type == "moov" }) else { throw fail("new header unreadable") }
        if moov.start != r.moovStart || r.out.count != orig.count + r.delta || moov.end - moov.start != r.oldMoovEnd - r.moovStart + r.delta { throw fail("layout changed") }
        func sameRange(_ a: [UInt8], _ ast: Int, _ b: [UInt8], _ bst: Int, _ n: Int) -> Bool {
            ast + n <= a.count && bst + n <= b.count && a[ast..<ast + n] == b[bst..<bst + n]
        }
        if !sameRange(orig, 0, r.out, 0, r.moovStart) || !sameRange(orig, r.oldMoovEnd, r.out, moov.end, orig.count - r.oldMoovEnd) { throw fail("audio mismatch") }
        guard let before = try? chunkOffsets(orig, r.moovStart, r.oldMoovEnd), let after = try? chunkOffsets(r.out, moov.start, moov.end) else { throw fail("audio offsets unreadable") }
        if before.isEmpty || before.count != after.count || zip(before, after).contains(where: { v, a in a != (v > r.moovStart ? v + r.delta : v) }) { throw fail("audio offsets") }
        try checkTags(TagReader.parseMoov(Array(r.out[moov.start + moov.hdr..<moov.end])), d)
    }
}

// MARK: - Where a missing song is saved (stage 4c): learned from where your matched files already live

extension Engine {
    struct Layout: Equatable {
        var byEra: [(era: String, folder: String)] = []
        var eraRoot: String?       // the folder that holds era-named folders ("" for the top of the music folder)
        var topParent: String?     // where most Juice WRLD files sit
        var fallback = "Music/Juice WRLD"
        static func == (a: Layout, b: Layout) -> Bool {
            a.byEra.map { $0.era + "\u{0}" + $0.folder } == b.byEra.map { $0.era + "\u{0}" + $0.folder } && a.eraRoot == b.eraRoot && a.topParent == b.topParent && a.fallback == b.fallback
        }
    }

    static func parentOf(_ path: String) -> String { path.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/") }
    /// A name that's safe as a file or folder name.
    static func safeName(_ s: String) -> String {
        var t = String(String.UnicodeScalarView(s.unicodeScalars.filter { !"\\/:*?\"<>|".unicodeScalars.contains($0) && $0.value > 0x1f }))
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: #"[. ]+$"#, with: "", options: .regularExpression)
        return t.isEmpty ? "Unknown" : t
    }
    /// Counts in first-seen order; the most common (the first of equals).
    private struct Counts {
        var order: [String] = [], n: [String: Int] = [:]
        mutating func bump(_ k: String) { if n[k] == nil { order.append(k) }; n[k, default: 0] += 1 }
        var mostCommon: String? { var best: String?, top = 0; for k in order where n[k]! > top { best = k; top = n[k]! }; return best }
    }

    /// How the library is laid out: where each era's songs live, whether folders are named after eras, and where
    /// most Juice WRLD files sit. Only files matched to exactly one song, not by a close title, count.
    static func layout(catalog: [EngineSong], files: [LibraryFile], match: Match) -> Layout {
        var songOrder: [Int] = [], seen = Set<Int>(), filesOf: [Int: [String]] = [:]
        for f in files { for i in match.songsFor[f.path] ?? [] { if seen.insert(i).inserted { songOrder.append(i) }; filesOf[i, default: []].append(f.path) } }
        var perEraOrder: [String] = [], perEra: [String: Counts] = [:], parents = Counts()
        for i in songOrder {
            let era = eraName(catalog[i])
            for path in filesOf[i]! {
                guard match.songsFor[path]?.count == 1, match.how[path] != "close" else { continue }
                let p = parentOf(path)
                guard !p.isEmpty else { continue }
                if perEra[era] == nil { perEraOrder.append(era); perEra[era] = Counts() }
                perEra[era]!.bump(p)
                parents.bump(p)
            }
        }
        var out = Layout()
        out.byEra = perEraOrder.map { ($0, perEra[$0]!.mostCommon!) }
        var roots = Counts(), eraLike = 0
        for (era, folder) in out.byEra {
            let a = normalize(baseName(folder)), b = normalize(era)
            if !a.isEmpty && !b.isEmpty && (a == b || a.contains(b) || b.contains(a)) { eraLike += 1; roots.bump(parentOf(folder)) }
        }
        let rootName = files.first.map { String($0.path.split(separator: "/", omittingEmptySubsequences: false).first ?? "") } ?? ""
        out.eraRoot = eraLike > 0 && Double(eraLike) >= Double(out.byEra.count) / 2 ? roots.mostCommon : nil
        out.topParent = parents.mostCommon
        out.fallback = "\(rootName.isEmpty ? "Music" : rootName)/Juice WRLD"
        return out
    }
    /// The folder (library-style path, starting with the music folder's name) a missing song is saved into.
    static func saveFolder(_ song: EngineSong, _ l: Layout) -> String {
        let era = eraName(song)
        if let f = l.byEra.first(where: { $0.era == era }) { return f.folder }
        if let root = l.eraRoot { return root.isEmpty ? safeName(era) : "\(root)/\(safeName(era))" }
        if let top = l.topParent { return top }
        return "\(l.fallback)/\(safeName(era))"
    }
    static func saveFileName(_ song: EngineSong) -> String { song.filePath.isEmpty ? "\(safeName(song.name)).mp3" : baseName(song.filePath) }
}

extension Engine {
    /// The library snapshot: every file with its tags, size and the songs it matched.
    static func snapshotCSV(files: [LibraryFile], match: Match, catalog: [EngineSong]) -> String {
        var lines = [["path", "title", "artist", "album", "year", "format", "size_bytes", "song_ids", "song_names", "era"]]
        for f in files {
            let songs = (match.songsFor[f.path] ?? []).filter(catalog.indices.contains).map { catalog[$0] }
            lines.append([f.path, f.tags["title"] ?? "", f.tags["artist"] ?? "", f.tags["album"] ?? "", f.tags["year"] ?? "", f.ext, "\(f.size)",
                          songs.map(\.id).joined(separator: " "), songs.map(\.name).joined(separator: " / "), songs.first.map(eraName) ?? ""])
        }
        return csvText(lines)
    }
}

// MARK: - The tag fixer, duplicates and file health (stage 4d): the page's rules

extension Engine {
    static let defaultGenre = "Hip-Hop/Rap"
    static let editableExts: Set<String> = ["mp3", "flac", "m4a"]
    static let lossless: Set<String> = ["flac", "wav", "aiff", "aif", "alac"]

    static func stripLabel(_ value: String, _ label: String) -> String {
        value.replacingOccurrences(of: "^\\s*\(label)\\s*[:\\-–]?\\s*", with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// A short comment like "Unreleased. Recorded March 2018."
    static func catalogComment(_ s: EngineSong) -> String {
        let cat = s.category.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if hasValue(cat) && cat.lowercased() != "unknown" { parts.append(cat.prefix(1).uppercased() + String(cat.dropFirst()).replacingOccurrences(of: "_", with: " ")) }
        var rec = stripLabel(s.recordDates, "Recorded").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        rec = rec.replacingOccurrences(of: #"[.,;\s]+$"#, with: "", options: .regularExpression)
        if hasValue(rec) { parts.append("Recorded \(rec.utf16.count > 120 ? String(decoding: Array(rec.utf16.prefix(120)), as: UTF16.self) + "…" : rec)") }
        return parts.isEmpty ? "" : parts.joined(separator: ". ") + "."
    }
    /// The tags the fixer would write for a catalog song.
    static func plannedTags(_ s: EngineSong, genre: String = defaultGenre) -> Tags {
        var artist = "Juice WRLD"
        if hasValue(s.artists) { artist = hasArtist(s.artists) ? s.artists : "Juice WRLD, \(s.artists)" }
        let rel = isReleased(s) ? yearOf(s.release) : ""
        let year = !rel.isEmpty ? rel : !yearOf(s.recordDates).isEmpty ? yearOf(s.recordDates) : yearOf(s.release)
        return ["title": s.name, "artist": artist, "albumartist": "Juice WRLD", "album": hasValue(s.era) ? s.era : "", "year": year,
                "producer": hasValue(s.producers) ? s.producers : "", "genre": genre, "comment": catalogComment(s)]
    }

    struct FixChange: Equatable { var key: String; var from: String; var to: String }
    /// The changes the fixer would make to one file's tags: the fields chosen, skipping ones already right (and, with
    /// onlyBlanks, ones that have something in them).
    static func fixFor(tags: Tags, song: EngineSong, fields: [String], onlyBlanks: Bool, genre: String) -> (changes: [FixChange], desired: Tags) {
        let want = plannedTags(song, genre: genre)
        var changes: [FixChange] = [], desired: Tags = [:]
        for k in fields {
            let to = (want[k] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !to.isEmpty else { continue }
            let from = (tags[k] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if (onlyBlanks && !from.isEmpty) || from == to { continue }
            changes.append(FixChange(key: k, from: from, to: to)); desired[k] = to
        }
        return (changes, desired)
    }
    struct FixItem { var path: String; var song: Int; var changes: [FixChange]; var desired: Tags }
    /// Every matched file whose tags would change (files that fit several songs are picked by hand instead).
    static func buildPlan(files: [LibraryFile], match: Match, catalog: [EngineSong], fields: [String], onlyBlanks: Bool, genre: String)
        -> (changes: [FixItem], skipped: [(path: String, reason: String)], same: Int) {
        var changes: [FixItem] = [], skipped: [(String, String)] = [], same = 0
        for f in files {
            guard let songs = match.songsFor[f.path], songs.count == 1 else { continue }
            if !editableExts.contains(f.ext) { skipped.append((f.path, ".\(f.ext) files can't be edited yet")); continue }
            let it = fixFor(tags: f.tags, song: catalog[songs[0]], fields: fields, onlyBlanks: onlyBlanks, genre: genre)
            if it.changes.isEmpty { same += 1; continue }
            changes.append(FixItem(path: f.path, song: songs[0], changes: it.changes, desired: it.desired))
        }
        return (changes, skipped, same)
    }

    /// A line of timed lyrics (LRC): when it starts, its text, and when each word starts (empty when only the line is timed).
    struct LrcLine: Equatable { var at: Double; var line: String; var words: [Double] = [] }

    /// "[01:23.45] line" lines, with word times written "<01:23.80>word"; lines without a time (tags like [ar:…]) are
    /// skipped. Word times are kept only when there is one for every word.
    static func parseLrc(_ text: String) -> [LrcLine] {
        func seconds(_ m: String, _ s: String) -> Double? { guard let m = Double(m), let s = Double(s) else { return nil }; return m * 60 + s }
        return text.split(whereSeparator: \.isNewline).compactMap { raw -> LrcLine? in
            guard let g = groups(#"^\s*\[(\d+):(\d+(?:\.\d+)?)\](.*)$"#, String(raw)).first, let at = seconds(g[1]!, g[2]!) else { return nil }
            let rest = g[3]!
            let words = groups(#"<(\d+):(\d+(?:\.\d+)?)>"#, rest).compactMap { seconds($0[1]!, $0[2]!) }
            let line = rest.replacingOccurrences(of: #"<\d+:\d+(?:\.\d+)?>"#, with: " ", options: .regularExpression)
                .split(separator: " ").joined(separator: " ")
            return LrcLine(at: at, line: line, words: words.count == line.split(separator: " ").count ? words : [])
        }
        .sorted { $0.at < $1.at }
    }
    /// 83.456 → "01:23.46".
    static func lrcStamp(_ t: Double) -> String {
        let cs = Int((max(0, t) * 100).rounded())
        return String(format: "%02d:%02d.%02d", cs / 6000, cs % 6000 / 100, cs % 100)
    }
    static func formatLrc(_ lines: [LrcLine]) -> String {
        lines.map { l in
            let words = l.line.split(separator: " ").map(String.init)
            let text = l.words.count == words.count && !words.isEmpty ? zip(l.words, words).map { "<\(lrcStamp($0))>\($1)" }.joined(separator: " ") : l.line
            return "[\(lrcStamp(l.at))]\(text)"
        }
        .joined(separator: "\n")
    }
    /// How many words of line n are sung at `time`, and whether the last of them is still being sung. With word times
    /// it follows them; without, the line's time is spread over its words.
    static func litWords(_ lines: [LrcLine], _ n: Int, at time: Double) -> (words: Int, singing: Bool) {
        let l = lines[n], end = n + 1 < lines.count ? lines[n + 1].at : l.at + 4
        if !l.words.isEmpty {
            let on = l.words.filter { $0 <= time + 0.05 }.count
            return (on, on > 0 && time < (on < l.words.count ? l.words[on] : end))
        }
        let count = l.line.split(separator: " ").count
        let progress = min(1, max(0, (time - l.at) / max(0.5, (end - l.at) * 0.85)))
        return (Int((Double(count) * progress).rounded(.up)), progress < 1)
    }

    /// Plays per bucket of `bucketDays` days, oldest first, the last bucket ending today (the listening timeline).
    static func playTimeline(_ times: [Date], buckets: Int, bucketDays: Int, now: Date, calendar: Calendar = .current) -> [Int] {
        var out = Array(repeating: 0, count: buckets)
        let today = calendar.startOfDay(for: now)
        for t in times {
            guard let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: t), to: today).day, days >= 0 else { continue }
            let b = buckets - 1 - days / bucketDays
            if b >= 0 { out[b] += 1 }
        }
        return out
    }
    /// A playlist as an .m3u file other players open: each song's length, title and full path.
    static func m3u(_ entries: [(path: String, title: String, seconds: Double?)]) -> String {
        "#EXTM3U\n" + entries.map { e in
            "#EXTINF:\(e.seconds.map { Int($0) } ?? -1),Juice WRLD - \(e.title.split(whereSeparator: \.isNewline).joined(separator: " "))\n\(e.path)\n"
        }.joined()
    }

    /// plays.tsv: a play a line, "seconds since 1970", a tab, then the file's path (which may hold tabs itself).
    static func parsePlays(_ text: String) -> [(path: String, at: Date)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let t = Double(parts[0]) else { return nil }
            return (String(parts[1]), Date(timeIntervalSince1970: t))
        }
    }

    /// Days since 1970 counted in a time zone: the daily games' "today", which turns over at local midnight (counted in
    /// UTC, it turned over at 7 pm in New York while the saved round still said "today").
    static func localDay(_ date: Date, _ tz: TimeZone = .current) -> Int {
        Int(((date.timeIntervalSince1970 + Double(tz.secondsFromGMT(for: date))) / 86400).rounded(.down))
    }
    /// About how big the site's file for a song is, from the bitrate and length it lists (12 MB when it lists neither).
    static func estimatedBytes(_ s: EngineSong) -> Int {
        let kbps = siteKbps(s.bitrate, "")
        guard kbps > 0, let seconds = lengthSeconds(s.length) else { return 12_000_000 }
        return Int(Double(kbps) * 1000 / 8 * seconds)
    }
    /// How many of these downloads (in order) fit on a drive with `free` bytes while keeping `keep` free; all when the
    /// free space can't be told.
    static func downloadsThatFit(_ sizes: [Int], free: Int64?, keep: Int64 = 2_000_000_000) -> Int {
        guard let free else { return sizes.count }
        var room = free - keep, n = 0
        for s in sizes { room -= Int64(s); if room < 0 { break }; n += 1 }
        return n
    }
    /// Duplicate groups with the same files shown once (a file that could be several versions of a song is in each
    /// version's group).
    static func distinctGroups(_ groups: [DupGroup]) -> [DupGroup] {
        var seen = Set<[String]>()
        return groups.filter { seen.insert($0.files.map(\.path).sorted()).inserted }
    }

    /// The site's date notes as one sentence. They often carry their own label on its own line ("First Teased" then
    /// "March 23, 2018."): that label leads ("First teased March 23, 2018."), else `fallback` does. "" when there's no date.
    static func dateSentence(_ text: String, fallback: String, extra: String = "") -> String {
        let joined = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        var label = fallback, rest = joined
        if let g = groups(#"^((?:first\s+)?(?:teased|previewed|surfaced|released|leaked))\b\s*(.*)$"#, joined, options: .caseInsensitive).first {
            label = g[1]!; rest = g[2] ?? ""
        }
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !rest.isEmpty else { return "" }
        let more = extra.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return "\(label.prefix(1).uppercased())\(label.dropFirst().lowercased()) \(rest)\(more.isEmpty ? "" : " (\(more))")."
    }

    /// Of the songs a file could be (versions share a title), the one whose listed length is closest to the file's.
    static func closestByLength(_ candidates: [Int], catalog: [EngineSong], seconds: Double?) -> Int? {
        guard let seconds, candidates.count > 1 else { return candidates.first }
        func off(_ i: Int) -> Double { lengthSeconds(catalog[i].length).map { abs($0 - seconds) } ?? .infinity }
        return candidates.min { off($0) < off($1) }
    }

    /// The equalizer's presets: bass, mids and treble in dB.
    static let eqPresets: [(name: String, bands: [Double])] = [("Flat", [0, 0, 0]), ("Bass boost", [6, 0, 1]), ("Vocals", [-2, 4, 2]), ("Bright", [0, 1, 5]), ("Late night", [-4, 1, -3])]
    /// The preset these bands match, or "Custom".
    static func eqPreset(_ bands: [Double]) -> String { eqPresets.first { $0.bands == bands }?.name ?? "Custom" }
    /// How far everything is turned down so boosted bands don't clip: half the biggest boost.
    static func eqHeadroom(_ bands: [Double]) -> Double { -max(0, bands.max() ?? 0) / 2 }

    /// Quiet songs still move the visuals: the level measured against the song's recent loudest, which falls back
    /// slowly (about 7% a second at 15 readings a second), never below 0.25 so near-silence isn't blown up.
    static func boosted(_ level: Double, peak: Double) -> (level: Double, peak: Double) {
        let p = max(level, peak * 0.995, 0.25)
        return (min(1, level / p), p)
    }

    /// "4:26" or "1:02:03" to seconds.
    static func lengthSeconds(_ text: String) -> Double? {
        guard let g = groups(#"^\s*(?:(\d+):)?(\d{1,2}):(\d{2})\s*$"#, text).first else { return nil }
        return Double(Int(g[1] ?? "0")! * 3600 + Int(g[2]!)! * 60 + Int(g[3]!)!)
    }
    /// The best bitrate the site lists for a format ("2117kbps (.wav)"), or 0.
    static func siteKbps(_ text: String, _ ext: String) -> Int {
        groups(#"(\d{2,5})\s*k[bp]{1,2}s\s*\(\.(\w+)\)"#, text, options: .caseInsensitive)
            .filter { ext.isEmpty || $0[2]!.lowercased() == ext }.map { Int($0[1]!)! }.max() ?? 0
    }
    static func formatSize(_ bytes: Int) -> String {
        if bytes >= 1_000_000_000 { return String(format: "%.2f GB", Double(bytes) / 1e9) }
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1e6) }
        return "\(max(1, Int((Double(bytes) / 1e3).rounded()))) KB"
    }
    static func fmtTime(_ s: Double) -> String {
        let secs = Int((s.truncatingRemainder(dividingBy: 60)).rounded())
        return "\(Int(s / 60)):\(secs < 10 ? "0" : "")\(secs)"
    }
    /// Lower case, no accents, words separated by single spaces (search keys; a duplicate's "same title").
    static func cmdkKey(_ text: String) -> String {
        let t = String(String.UnicodeScalarView(text.lowercased().decomposedStringWithCompatibilityMapping.unicodeScalars.filter { !(0x300...0x36F).contains($0.value) }))
        return t.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    // Duplicates
    struct DupGroup { var song: Int?; var title: String; var files: [LibraryFile]; var extra: Int }
    /// Lossless beats lossy; then the biggest file (the first of equals).
    static func bestCopy(_ files: [LibraryFile]) -> LibraryFile {
        files.enumerated().min { a, b in
            let la = lossless.contains(a.element.ext), lb = lossless.contains(b.element.ext)
            if la != lb { return la }
            if a.element.size != b.element.size { return a.element.size > b.element.size }
            return a.offset < b.offset
        }!.element
    }
    /// Only files that read as exactly the same title, so a remix or "v2" is never treated as a copy.
    static func isExactDuplicate(_ g: DupGroup) -> Bool { Set(g.files.map { cmdkKey($0.title) }).count == 1 }
    /// The files to move to the Trash: each extra copy once, never a kept one.
    static func extraCopies(_ groups: [DupGroup]) -> [LibraryFile] {
        let kept = Set(groups.map { bestCopy($0.files).path })
        var seen = Set<String>(), out: [LibraryFile] = []
        for g in groups { for f in g.files where !kept.contains(f.path) && seen.insert(f.path).inserted { out.append(f) } }
        return out
    }
    /// Songs with more than one file, and unmatched files that share a title.
    static func duplicateGroups(files: [LibraryFile], match: Match, catalog: [EngineSong]) -> [DupGroup] {
        let byPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var order: [Int] = [], seen = Set<Int>(), filesOf: [Int: [String]] = [:]
        for f in files { for i in match.songsFor[f.path] ?? [] { if seen.insert(i).inserted { order.append(i) }; if !(filesOf[i] ?? []).contains(f.path) { filesOf[i, default: []].append(f.path) } } }
        var groups: [DupGroup] = order.compactMap { i in
            let fs = filesOf[i]!.compactMap { byPath[$0] }
            return fs.count > 1 ? DupGroup(song: i, title: catalog[i].name, files: fs, extra: 0) : nil
        }
        var keyOrder: [String] = [], byKey: [String: [LibraryFile]] = [:]
        for p in match.unmatched { guard let f = byPath[p], !f.key.isEmpty else { continue }; if byKey[f.key] == nil { keyOrder.append(f.key) }; byKey[f.key, default: []].append(f) }
        for k in keyOrder where byKey[k]!.count > 1 { groups.append(DupGroup(song: nil, title: byKey[k]![0].title, files: byKey[k]!, extra: 0)) }
        for n in groups.indices {
            groups[n].files = groups[n].files.enumerated().sorted { $0.element.size != $1.element.size ? $0.element.size > $1.element.size : $0.offset < $1.offset }.map(\.element)
            groups[n].extra = groups[n].files.dropFirst().reduce(0) { $0 + $1.size }
        }
        return groups.enumerated().sorted { a, b in
            if a.element.files.count != b.element.files.count { return a.element.files.count > b.element.files.count }
            if a.element.extra != b.element.extra { return a.element.extra > b.element.extra }
            let c = a.element.title.localizedCompare(b.element.title)
            return c != .orderedSame ? c == .orderedAscending : a.offset < b.offset
        }.map(\.element)
    }

    // File health
    struct Probe: Codable {
        var ok: Bool; var seconds: Double; var size: Int
        var loudness: Double? = nil // average level in dBFS, from a few short samples
        var art: Bool? = nil        // has cover art (only checked for files the app can write)
    }
    struct HealthIssue: Equatable { var path: String; var group: String; var text: String }
    /// What to look at: files that may be damaged or cut off, better copies on the site, and tags to fix.
    static func healthIssues(files: [LibraryFile], match: Match, catalog: [EngineSong], probes: [String: Probe]) -> [HealthIssue] {
        var out: [HealthIssue] = []
        for f in files {
            let songs = match.songsFor[f.path] ?? [], song = songs.count == 1 ? catalog[songs[0]] : nil
            let p = probes[f.path], before = out.count
            let size = (p?.size ?? 0) > 0 ? p!.size : f.size
            if let p, !p.ok { out.append(.init(path: f.path, group: "damaged", text: "Doesn't open as audio. It may be damaged.")) }
            else if let p, song != nil || p.seconds < 5 {
                let want = song.flatMap { lengthSeconds($0.length) } ?? 0 // 0: no length listed
                if (want != 0 && want >= 45 && p.seconds < want * 0.6) || p.seconds < 5 {
                    out.append(.init(path: f.path, group: "damaged", text: "Plays for \(fmtTime(p.seconds))\(want != 0 ? ", but “\(song!.name)” is \(song!.length)" : ""). It may be cut off."))
                }
            }
            if out.count == before && size < 300 * 1024 { out.append(.init(path: f.path, group: "damaged", text: "Very small for a song (\(formatSize(size))).")) }
            if let song, out.count == before, !lossless.contains(f.ext), !song.filePath.isEmpty {
                let siteExt = extOf(song.filePath), want = lengthSeconds(song.length), site = siteKbps(song.bitrate, siteExt)
                let mine = (want ?? 0) != 0 && size > 0 ? Double(size) * 8 / 1000 / want! : 0
                if lossless.contains(siteExt) { out.append(.init(path: f.path, group: "upgrade", text: "The site has a lossless copy (\(siteExt.uppercased())); yours is \(f.ext.uppercased()).")) }
                else if mine > 0 && site > 0 && mine < Double(site) * 0.7 { out.append(.init(path: f.path, group: "upgrade", text: "Yours is about \(Int(mine.rounded())) kbps; the site's copy is \(site) kbps.")) }
            }
            if !f.fromTags { out.append(.init(path: f.path, group: "tags", text: "No title tag, so it's matched by its file name.")) }
            else if songs.isEmpty { out.append(.init(path: f.path, group: "tags", text: "Its title, “\(f.title)”, isn't in the catalog.")) }
            else if match.how[f.path] == "close" { out.append(.init(path: f.path, group: "tags", text: "Its title, “\(f.title)”, is close to “\(catalog[songs[0]].name)” but not exact.")) }
        }
        // Beyond the page: a file far from the library's typical level, and files with no cover art.
        let levels = files.compactMap { probes[$0.path]?.loudness }.sorted()
        if levels.count >= 5 {
            let typical = levels[levels.count / 2]
            for f in files {
                guard let l = probes[f.path]?.loudness, abs(l - typical) >= 6 else { continue }
                out.append(.init(path: f.path, group: "loudness", text: "About \(Int(abs(l - typical).rounded())) dB \(l < typical ? "quieter" : "louder") than the rest of your library."))
            }
        }
        for f in files where probes[f.path]?.art == false { out.append(.init(path: f.path, group: "art", text: "No cover art.")) }
        return out
    }
}

// MARK: - Reading a snapshot back (stage 5)

extension Engine {
    /// A CSV file's rows (quotes, doubled quotes, commas and line breaks inside quotes).
    static func parseCsv(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false
        let t = Array((text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text).unicodeScalars)
        var n = 0
        while n < t.count {
            let c = t[n]
            if quoted {
                if c != "\"" { cell.unicodeScalars.append(c) }
                else if n + 1 < t.count && t[n + 1] == "\"" { cell += "\""; n += 1 }
                else { quoted = false }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(cell); cell = "" }
            else if c == "\n" || c == "\r" {
                if c == "\r" && n + 1 < t.count && t[n + 1] == "\n" { n += 1 }
                row.append(cell); rows.append(row); row = []; cell = ""
            } else { cell.unicodeScalars.append(c) }
            n += 1
        }
        if !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(row) }
        return rows
    }

    /// The songs a library snapshot had (one per file: the version whose name is the file's title).
    static func snapshotSongIds(_ text: String) throws -> Set<String> {
        let rows = parseCsv(text)
        guard let head = rows.first, let col = head.firstIndex(of: "song_ids") else { throw EngineError("That file isn't a Juice Tracker library snapshot.") }
        let nameCol = head.firstIndex(of: "song_names"), titleCol = head.firstIndex(of: "title"), pathCol = head.firstIndex(of: "path")
        func at(_ r: [String], _ i: Int?) -> String { i.map { $0 < r.count ? r[$0] : "" } ?? "" }
        return Set(rows.dropFirst().compactMap { r -> String? in
            let list = at(r, col).split(separator: " ").map(String.init), names = at(r, nameCol).components(separatedBy: " / ")
            let t = at(r, titleCol), title = t.isEmpty ? titleFromFilename(at(r, pathCol)) : t
            var k = names.firstIndex { cmdkKey($0) == cmdkKey(title) } ?? -1
            if k < 0 { k = names.firstIndex { normalize($0) == normalize(title) } ?? -1 }
            let pick = k >= 0 && k < list.count ? k : 0
            return list.indices.contains(pick) ? list[pick] : nil
        })
    }
}

// MARK: - Rarity

extension Engine {
    /// How hard a song is to find: a grail is unreleased with no file on the site, and you have it anyway; rare is
    /// unreleased with no file on the site (yet). Released songs and ones the site has a file for are nil (common).
    static func rarity(_ s: EngineSong, owned: Bool) -> String? {
        guard !isReleased(s), s.filePath.isEmpty else { return nil }
        return owned ? "Grail" : "Rare"
    }
}


// MARK: - Cover art

extension TagReader {
    /// Whether a file already has cover art (an ID3 picture, an MP4 "covr" item, or a FLAC PICTURE block).
    static func hasArt(_ b: [UInt8], ext: String) -> Bool {
        switch ext {
        case "flac": return (try? TagWriter.parseFlacBlocks(b))?.blocks.contains { $0.type == 6 } ?? false
        case "m4a", "m4b", "alac":
            guard let top = try? TagWriter.readAtoms(b, 0, b.count), let moov = top.first(where: { $0.type == "moov" }) else { return false }
            var found = false
            func walk(_ s: Int, _ e: Int) {
                walkAtoms(b, s, e) { type, s2, e2 in
                    if type == "covr" { found = true }
                    else if type == "udta" || type == "ilst" { walk(s2, e2) }
                    else if type == "meta" { walk(latin1(sub(b, s2 + 4, s2 + 8)) == "hdlr" ? s2 : s2 + 4, e2) }
                }
            }
            walk(moov.start + moov.hdr, moov.end)
            return found
        default: return parseId3(b)?.frames.contains { $0.id == "APIC" || $0.id == "PIC" } ?? false
        }
    }

    /// The same for a file on disk, reading only the tag (an MP3's ID3 tag, an M4A's moov box, a FLAC's header).
    static func hasArt(_ url: URL, ext: String) -> Bool {
        guard let f = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? f.close() }
        let file = Reader(f)
        switch ext {
        case "flac":
            guard latin1(file.bytes(0, 4)[...]) == "fLaC" else { return false }
            var pos: UInt64 = 4
            for _ in 0..<64 {
                let h = file.bytes(pos, pos + 4)
                guard h.count >= 4 else { break }
                if h[0] & 0x7f == 6 { return true }
                pos += 4 + UInt64(Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3]))
                if h[0] & 0x80 != 0 { break }
            }
            return false
        case "m4a", "m4b", "alac":
            return hasArt(file.bytes(0, min(file.size, 64 * 1024 * 1024)), ext: ext) // shortcut: songs with the moov after 64 MB of audio aren't checked
        default:
            let h = file.bytes(0, 10)
            guard h.count >= 10, latin1(h[0..<3]) == "ID3" else { return false }
            return hasArt(file.bytes(0, UInt64(10 + min(synchsafe(h, 6), 64 * 1024 * 1024))), ext: ext) // the whole tag, even with big art
        }
    }
}

extension TagWriter {
    /// Adds a front cover (JPEG) to a file that has none, leaving its tags and audio as they are. Runs the same safety
    /// check as a tag write, and checks the picture reads back.
    static func addArt(_ orig: [UInt8], ext: String, jpeg: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        guard !TagReader.hasArt(orig, ext: ext) else { throw EngineError("already has cover art") }
        let r: Written
        switch ext {
        case "mp3": r = try writeMp3(orig, [:], art: jpeg); try verifyMp3(orig, r, [:])
        case "flac": r = try writeFlac(orig, [:], art: (jpeg, width, height)); try verifyFlac(orig, r, [:])
        case "m4a": r = try writeM4a(orig, [:], art: jpeg); try verifyM4a(orig, r, [:])
        default: throw EngineError("can't get cover art here (only MP3, FLAC and M4A)")
        }
        guard TagReader.hasArt(r.out, ext: ext) else { throw EngineError("failed a safety check (the picture didn't read back), so it was left unchanged") }
        return r.out
    }
}

// MARK: - File organizer (beyond the page)

extension Engine {
    /// The song a file most likely is when its title matches several versions: one match is that song; otherwise the
    /// plain-named versions (no "(Live)", "[v1]"…) must share one name, and the era most of them are from wins. A tie,
    /// or different names, gives nil.
    static func primarySong(_ songs: [Int], catalog: [EngineSong]) -> Int? {
        let valid = songs.filter(catalog.indices.contains)
        if valid.count == 1 { return valid[0] }
        let plain = valid.filter { !catalog[$0].name.contains("(") && !catalog[$0].name.contains("[") }
        guard !plain.isEmpty, Set(plain.map { catalog[$0].name.lowercased() }).count == 1 else { return nil }
        let votes = Dictionary(grouping: plain) { eraName(catalog[$0]) }.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
        guard votes.count == 1 || votes[0].value.count > votes[1].value.count else { return nil }
        return votes[0].value.min()
    }

    /// Where each matched file would go under a pattern like "{era}/{song}" (also {category}, {year}). Only files
    /// matched by title, file name or hand (not a close title) to one song, or to versions `primarySong` can settle, move,
    /// and only where the library still counts them as Juice WRLD files. A file never moves onto
    /// another file's place: the first one wins and the rest stay where they are.
    static func organizePlan(files: [LibraryFile], match: Match, catalog: [EngineSong], pattern: String) -> [(from: String, to: String)] {
        var taken = Set(files.map { $0.path.lowercased() }), out: [(String, String)] = []
        for f in files {
            guard let songs = match.songsFor[f.path], match.how[f.path] != "close", let primary = primarySong(songs, catalog: catalog) else { continue }
            let s = catalog[primary], root = f.path.split(separator: "/").first.map(String.init) ?? ""
            var rel = pattern
            for (k, v) in ["{era}": eraName(s), "{song}": s.name, "{category}": s.category, "{year}": yearOf(s.recordDates)] {
                rel = rel.replacingOccurrences(of: k, with: safeName(v.isEmpty ? "Unknown" : v))
            }
            let parts = rel.split(separator: "/").map { safeName(String($0)) }
            guard !parts.isEmpty else { continue }
            let to = ([root] + parts).joined(separator: "/") + "." + f.ext
            // A file counted only because its folder says Juice WRLD would drop out of the library at its new place.
            guard to != f.path, !taken.contains(to.lowercased()), countsAsJuice(path: to, tags: f.tags) else { continue }
            taken.remove(f.path.lowercased()); taken.insert(to.lowercased())
            out.append((f.path, to))
        }
        return out
    }
}
