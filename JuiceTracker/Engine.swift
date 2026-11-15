import Foundation

// The Swift engine (stage 1 of replacing the HTML page): the catalog, reading tags, scanning the music folder and
// matching files to songs. It is a line-for-line port of the page's logic, so both give the same answers; "Check
// Swift Engine" (Window menu) compares them. Foundation only, so tests/EngineTests.swift can compile it on its own.

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
        // Most files put text tags before the cover art; read the whole tag only when the title wasn't in the first part.
        if let q = p, size > first, (tagsFromId3(q)["title"] ?? "").isEmpty { p = parseId3(file.bytes(0, UInt64(10 + min(size, 4 * 1024 * 1024)))) }
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
                     progress: ((Int, Int) -> Void)? = nil) async -> (files: [LibraryFile], audioCount: Int, fresh: [String: CachedTags]) {
        let audio = listAudio(root: root)
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
                    guard !onlyJuice || hasArtist(path) || hasArtist("\(tags["artist"] ?? "") \(tags["albumartist"] ?? "")") else { return (nil, read, path) }
                    let title = (tags["title"] ?? "").isEmpty ? titleFromFilename(path) : tags["title"]!
                    return (LibraryFile(path: path, ext: ext, tags: tags, title: title, key: normalize(title), stem: stemOf(path),
                                        fromTags: !(tags["title"] ?? "").isEmpty, size: size), read, path)
                }
            }
            for _ in 0..<8 { add() }
            for await (file, read, path) in group {
                if let file { found.append(file) }
                if let read { fresh[path] = read }
                done += 1
                if done % 20 == 0 { progress?(done, audio.count) }
                add()
            }
        }
        progress?(audio.count, audio.count)
        return (found.sorted { $0.path.localizedCompare($1.path) == .orderedAscending }, audio.count, fresh)
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

    /// Every match of a regular expression, as its capture groups (missing groups are nil).
    static func groups(_ pattern: String, _ text: String, options: NSRegularExpression.Options = []) -> [[String?]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? nil : ns.substring(with: m.range(at: $0)) }
        }
    }
    /// Splits a text at every match of a pattern (like JavaScript's split with a regular expression).
    static func split(_ text: String, by pattern: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [text] }
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

    static func writeMp3(_ orig: [UInt8], _ d: Tags) throws -> Written {
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

    static func writeFlac(_ orig: [UInt8], _ d: Tags) throws -> Written {
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

    static func writeM4a(_ orig: [UInt8], _ d: Tags) throws -> Written {
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
