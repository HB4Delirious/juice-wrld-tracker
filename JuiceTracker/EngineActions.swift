import AppKit
import SwiftUI

// Backup and restore, the full catalog spreadsheet and the collection card.

extension EngineState {
    // MARK: Backup and restore

    /// A backup file in the same format as before, so old and new backups restore either way.
    func backupJSON() async -> String {
        let names = Dictionary(catalog.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let backup: [String: Any] = [
            "app": "juice-wrld-collection-tracker", "version": 1, "exportedAt": Self.isoString(Date()),
            "wishlist": wish.sorted { $0.value < $1.value }.map { ["id": $0.key, "name": names[$0.key] ?? "", "added": $0.value] },
            "notes": notes.sorted { $0.key < $1.key }.map { ["id": $0.key, "name": names[$0.key] ?? "", "text": $0.value] },
            "ratings": ratings, "trivia": personalAny("trivia") ?? [:], "linkTemplate": personalAny("linkTemplate") ?? "",
            "matchOverrides": personalAny("matchOverrides") ?? [:], "opened": personalAny("opened") ?? [:], "fixGenre": personalAny("fixGenre") ?? "",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Merges a backup into what's here (nothing is overwritten). Throws if the file isn't a backup.
    func restore(_ text: String) async throws -> String {
        guard let data = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              data["app"] as? String == "juice-wrld-collection-tracker" else { throw EngineError("That file isn't a backup from this tracker.") }
        let added = mergeBackup(wishlist: data["wishlist"] as? [[String: Any]] ?? [], notes: data["notes"] as? [[String: Any]] ?? [])
        var r = ratings
        for (k, v) in data["ratings"] as? [String: Any] ?? [:] where r[k] == nil { r[k] = (v as? NSNumber)?.intValue }
        setPersonal("ratings", r)
        var trivia = personalAny("trivia") as? [String: Any] ?? [:]
        for (k, v) in data["trivia"] as? [String: Any] ?? [:] { trivia[k] = max((trivia[k] as? NSNumber)?.intValue ?? 0, (v as? NSNumber)?.intValue ?? 0) }
        setPersonal("trivia", trivia)
        if let t = data["linkTemplate"] as? String, !t.isEmpty, personalString("linkTemplate").isEmpty { setPersonal("linkTemplate", t) }
        var opened = personalAny("opened") as? [String: Any] ?? [:]
        for (k, v) in data["opened"] as? [String: Any] ?? [:] where opened[k] == nil { opened[k] = v }
        setPersonal("opened", opened)
        if let g = data["fixGenre"] as? String, !g.isEmpty, personalString("fixGenre").isEmpty { setPersonal("fixGenre", g) }
        EngineLibrary.shared.mergeOverrides((data["matchOverrides"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String })
        func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n.formatted()) \(n == 1 ? one : many)" }
        return "Restored \(plural(added.wish, "wishlist song", "wishlist songs")) and \(plural(added.notes, "note", "notes")). Anything you already had was kept."
    }

    // MARK: The full catalog spreadsheet

    static let fullColumns: [(String, (EngineSong, [String: EraInfo]) -> String)] = [
        ("id", { s, _ in s.id }), ("name", { s, _ in s.name }), ("also_known_as", { s, _ in s.alt.joined(separator: " / ") }), ("category", { s, _ in s.category }),
        ("era", { s, _ in s.era }), ("era_time_frame", { s, e in e[s.era]?.timeFrame ?? "" }), ("length", { s, _ in s.length }), ("original_key", { s, _ in s.key }),
        ("credited_artists", { s, _ in s.artists }), ("producers", { s, _ in s.producers }), ("engineers", { s, _ in s.engineers }), ("recording_locations", { s, _ in s.locations }),
        ("record_dates", { s, _ in s.recordDates }), ("preview_date", { s, _ in s.previewDate }), ("release_date", { s, _ in s.release }), ("date_surfaced", { s, _ in s.leakDate }),
        ("surfaced_type", { s, _ in s.leakType }), ("session_titles", { s, _ in s.sessions }), ("other_dates", { s, _ in s.dates }), ("notes", { s, _ in s.notes }),
        ("additional_information", { s, _ in s.info }), ("site_file_url", { s, _ in Engine.fileUrl(s) }),
    ]

    /// Every song with all its details, plus your files, wishlist, notes and what's new.
    func catalogCSV() async -> String {
        let files = EngineLibrary.shared.match.owned // which files you have for each song
        let newIds = Set(saved.newIds), releasedIds = Set(saved.releasedIds), wished = wish, noteText = notes
        var lines = [Self.fullColumns.map(\.0) + ["in_your_library", "your_files", "on_wishlist", "your_note", "new_since_last_check", "now_released"]]
        for (i, s) in catalog.enumerated() {
            lines.append(Self.fullColumns.map { $0.1(s, eras) } + [
                files[i] != nil ? "yes" : "no", (files[i] ?? []).joined(separator: " | "), wished[s.id] != nil ? "yes" : "",
                noteText[s.id] ?? "", newIds.contains(s.id) ? "yes" : "", releasedIds.contains(s.id) ? "yes" : "",
            ])
        }
        return Engine.csvText(lines)
    }

    // MARK: The collection card

    /// A 1200 × 630 picture of your collection to post or keep.
    func collectionCard() -> NSImage? {
        guard let state = NativeStore.shared.state else { return nil }
        let eras = state.eras.filter { $0.name != Engine.noEra }
        let top = eras.enumerated().max { a, b in a.element.have != b.element.have ? a.element.have < b.element.have : a.offset > b.offset }?.element
        let best = eras.filter { $0.total >= 10 }.enumerated().max { a, b in
            let x = Double(a.element.have) / Double(a.element.total), y = Double(b.element.have) / Double(b.element.total)
            return x != y ? x < y : a.offset > b.offset
        }?.element
        let view = CollectionCardView(have: state.have, total: state.total, top: top, best: best)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 630)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    static func isoString(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}

/// The card's picture: the night sky, your count, a rainbow bar, your top and most complete eras, and a 999.
private struct CollectionCardView: View {
    let have: Int, total: Int
    let top: NState.Era?, best: NState.Era?

    private var pct: Double { total > 0 ? Double(have) / Double(total) * 100 : 0 }
    private var pctText: String { let r = (pct * 10).rounded() / 10; return r == r.rounded() ? "\(Int(r))" : "\(r)" }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(stops: [.init(color: hex(0x07040f), location: 0), .init(color: hex(0x1d0b40), location: 0.55), .init(color: hex(0x4a1250), location: 1)],
                           startPoint: .topLeading, endPoint: UnitPoint(x: 0.4, y: 1))
            Canvas { g, size in
                var seed = 999.0 // the same stars every time, like the page's card
                func rand() -> Double { seed = (seed * 16807).truncatingRemainder(dividingBy: 2147483647); return seed / 2147483647 }
                for _ in 0..<170 {
                    let alpha = 0.25 + rand() * 0.7, x = rand() * size.width, y = rand() * size.height, r = rand() * 1.6 + 0.3
                    g.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(hex(0xfff6fb).opacity(alpha)))
                }
                func sparkle(_ x: Double, _ y: Double, _ r: Double, _ color: UInt32) {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: y - r))
                    p.addQuadCurve(to: CGPoint(x: x + r, y: y), control: CGPoint(x: x, y: y))
                    p.addQuadCurve(to: CGPoint(x: x, y: y + r), control: CGPoint(x: x, y: y))
                    p.addQuadCurve(to: CGPoint(x: x - r, y: y), control: CGPoint(x: x, y: y))
                    p.addQuadCurve(to: CGPoint(x: x, y: y - r), control: CGPoint(x: x, y: y))
                    g.fill(p, with: .color(hex(color)))
                }
                sparkle(1080, 110, 26, 0xff94e2); sparkle(1010, 190, 12, 0xffe14a); sparkle(140, 540, 16, 0x4fd8ff)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("MY JUICE WRLD COLLECTION").font(JT.body(26, .semibold)).foregroundColor(hex(0xff94e2)).padding(.top, 84)
                HStack(alignment: .firstTextBaseline, spacing: 22) {
                    Text(verbatim: have.formatted()).font(JT.marker(120)).foregroundColor(hex(0xfff6fb))
                    Text(verbatim: "of \(total.formatted()) songs").font(JT.body(38, .semibold)).foregroundColor(hex(0xc3b2e3))
                }
                .padding(.top, 2)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(red: 190 / 255, green: 150 / 255, blue: 1).opacity(0.18))
                    LinearGradient(colors: [0xff5d6c, 0xffa04a, 0xffe14a, 0xc9f24a, 0x4fd8ff, 0x6aa8ff, 0xb77bff, 0xff6ad5].map(hex), startPoint: .leading, endPoint: .trailing)
                        .frame(width: 1040).mask(alignment: .leading) { Capsule().frame(width: max(26, 1040 * pct / 100)) }
                }
                .frame(width: 1040, height: 26).padding(.top, 18)
                Text(verbatim: "\(pctText)% complete").font(JT.body(34, .semibold)).foregroundColor(hex(0xc9f24a)).padding(.top, 30)
                VStack(alignment: .leading, spacing: 14) {
                    if let top, top.have > 0 { Text(verbatim: "Top era: \(top.name) (\(top.have.formatted()) \(top.have == 1 ? "song" : "songs"))") }
                    if let best, best.have > 0 { Text(verbatim: "Most complete: \(best.name) (\(Int((Double(best.have) / Double(best.total) * 100).rounded()))%)") }
                }
                .font(JT.body(28, .medium)).foregroundColor(hex(0xfff6fb)).padding(.top, 36)
            }
            .padding(.leading, 80)
            VStack(alignment: .trailing, spacing: 6) {
                Text("999").font(JT.marker(96)).foregroundColor(hex(0xff6ad5))
                Text(verbatim: "Juice Tracker · \(Date().formatted(.dateTime.month(.wide).year()))").font(JT.body(22, .medium)).foregroundColor(hex(0xc3b2e3))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 80).padding(.bottom, 26)
        }
        .frame(width: 1200, height: 630)
        .environment(\.colorScheme, .dark)
    }

    private func hex(_ v: UInt32) -> Color { Color(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255) }
}
