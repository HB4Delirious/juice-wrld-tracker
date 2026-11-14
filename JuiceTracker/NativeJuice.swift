import AppKit
import SwiftUI

// Juice WRLD-themed touches (all original art): era stickers that fit each era, era color themes, badges, and the
// 999 loading spinner.

// MARK: - Era stickers

/// The sticker that fits an era: a race car for DRFL, a halo for LND, a demon for FD, balloons for the party eras,
/// 999 flash for the 999 eras, and so on. Other eras get one of the tattoo-flash doodles.
func eraSticker(_ name: String, fallback n: Int) -> String {
    let k = name.lowercased()
    let rules: [(String, [String])] = [
        ("jt-era-race", ["drfl", "death race"]), ("jt-era-halo", ["lnd", "legends"]), ("jt-era-demon", ["fd", "fighting demons"]),
        ("jt-era-party", ["tpne", "tpp", "party"]), ("jt-era-999", ["999"]), ("jt-sticker2", ["gb&gr", "goodbye"]),
        ("jt-era-globe", ["wod", "wrld on drugs"]), ("jt-era-vinyl", ["vinyl"]), ("jt-era-mic", ["soundcloud", "smule", "youtube", "session"]),
    ]
    for (image, keys) in rules where keys.contains(where: { key in
        key.count <= 4 ? k.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "&" }).contains { $0 == key } || k.hasPrefix(key + " ") || k == key : k.contains(key)
    }) { return image }
    return "jt-sticker\(n % 6 + 1)"
}

// MARK: - Era themes

/// Color themes from the eras' moods. "Cosmic" is the original look.
struct EraTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let accent: Color
    let accentHi: Color
    let accentNS: NSColor
    let glows: [NSColor] // the four nebula glows in the sky

    static let all: [EraTheme] = [
        EraTheme(id: "cosmic", name: "Cosmic (original)", accent: Color(red: 1, green: 106 / 255, blue: 213 / 255), accentHi: Color(red: 1, green: 148 / 255, blue: 226 / 255),
                 accentNS: NSColor(srgbRed: 1, green: 106 / 255, blue: 213 / 255, alpha: 1),
                 glows: [rgb(232, 110, 70, 0.30), rgb(214, 48, 140, 0.42), rgb(80, 130, 255, 0.32), rgb(140, 40, 190, 0.36)]),
        EraTheme(id: "gbgr", name: "Goodbye & Good Riddance (heartbreak blue)", accent: Color(red: 0.42, green: 0.66, blue: 1), accentHi: Color(red: 0.6, green: 0.78, blue: 1),
                 accentNS: rgb(106, 168, 255, 1), glows: [rgb(70, 140, 232, 0.32), rgb(120, 90, 214, 0.38), rgb(60, 200, 255, 0.28), rgb(90, 60, 190, 0.36)]),
        EraTheme(id: "drfl", name: "Death Race for Love (racing red)", accent: Color(red: 1, green: 0.3, blue: 0.35), accentHi: Color(red: 1, green: 0.5, blue: 0.5),
                 accentNS: rgb(255, 77, 90, 1), glows: [rgb(255, 80, 60, 0.34), rgb(200, 30, 60, 0.42), rgb(255, 170, 60, 0.26), rgb(120, 20, 60, 0.4)]),
        EraTheme(id: "lnd", name: "Legends Never Die (sunset gold)", accent: Color(red: 1, green: 0.72, blue: 0.3), accentHi: Color(red: 1, green: 0.82, blue: 0.5),
                 accentNS: rgb(255, 184, 77, 1), glows: [rgb(255, 160, 60, 0.36), rgb(255, 90, 120, 0.34), rgb(255, 210, 90, 0.26), rgb(170, 70, 160, 0.34)]),
        EraTheme(id: "fd", name: "Fighting Demons (demon green)", accent: Color(red: 0.6, green: 1, blue: 0.42), accentHi: Color(red: 0.75, green: 1, blue: 0.6),
                 accentNS: rgb(155, 255, 106, 1), glows: [rgb(120, 220, 80, 0.26), rgb(140, 40, 200, 0.42), rgb(60, 200, 140, 0.26), rgb(90, 30, 160, 0.4)]),
        EraTheme(id: "wod", name: "WRLD on Drugs (electric cyan)", accent: Color(red: 0.31, green: 0.85, blue: 1), accentHi: Color(red: 0.55, green: 0.92, blue: 1),
                 accentNS: rgb(79, 216, 255, 1), glows: [rgb(60, 200, 255, 0.32), rgb(40, 90, 220, 0.4), rgb(120, 255, 220, 0.22), rgb(30, 60, 160, 0.4)]),
    ]

    static var current: EraTheme {
        let id = UserDefaults.standard.string(forKey: "eraTheme") ?? "cosmic"
        return all.first { $0.id == id } ?? all[0]
    }
    static let changed = Notification.Name("EraThemeChanged")

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }
}

/// Watches the theme setting, so the window redraws in the new colors when it changes.
final class ThemeWatcher: ObservableObject {
    static let shared = ThemeWatcher()
    @Published private(set) var id = EraTheme.current.id
    private init() {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            let now = EraTheme.current.id
            if now != self?.id { self?.id = now; NotificationCenter.default.post(name: EraTheme.changed, object: nil) }
        }
    }
}

// MARK: - 999 spinner

/// The loading spinner: "999" in marker lettering, turning slowly with a glow.
struct Spinner999: View {
    var size: CGFloat = 34
    @State private var turn = false
    var body: some View {
        Text("999").font(JT.marker(size)).foregroundStyle(JT.countGradient)
            .shadow(color: JT.lavender.opacity(0.6), radius: 10)
            .rotationEffect(.degrees(turn ? 360 : 0))
            .animation(.linear(duration: 2.4).repeatForever(autoreverses: false), value: turn)
            .onAppear { turn = true }
            .accessibilityLabel("Loading")
    }
}

// MARK: - Badges

private struct Badge: Identifiable {
    let id: String
    let image: String
    let title: String
    let detail: String
    let have: Int
    let need: Int
    var earned: Bool { have >= need }
}

struct BadgesScreen: View {
    @ObservedObject private var store = NativeStore.shared
    let state: NState
    let songs: [Song]

    private var badges: [Badge] {
        let have = state.have
        let released = songs.filter(\.s.rel), releasedHave = released.filter(\.o).count
        let wishedHave = songs.filter { $0.w && $0.o }.count
        let plays = AmbientPlayer.playLog.count
        var out: [Badge] = [
            Badge(id: "first", image: "jt-heart", title: "First song", detail: "Your first song in the library.", have: have, need: 1),
            Badge(id: "100", image: "jt-sticker1", title: "Hundred club", detail: "100 songs in your library.", have: have, need: 100),
            Badge(id: "500", image: "jt-sticker3", title: "Five hundred deep", detail: "500 songs in your library.", have: have, need: 500),
            Badge(id: "999", image: "jt-era-999", title: "999 club", detail: "999 songs in your library.", have: have, need: 999),
            Badge(id: "1500", image: "jt-sticker5", title: "Vault keeper", detail: "1,500 songs in your library.", have: have, need: 1500),
            Badge(id: "all", image: "jt-planet", title: "The whole WRLD", detail: "Every song in the catalog.", have: have, need: state.total),
            Badge(id: "released", image: "jt-era-vinyl", title: "Every release", detail: "All officially released songs.", have: releasedHave, need: max(released.count, 1)),
            Badge(id: "wish", image: "jt-sticker4", title: "Wish granted", detail: "10 songs from your wishlist found.", have: wishedHave, need: 10),
            Badge(id: "plays", image: "jt-era-mic", title: "On repeat", detail: "100 songs played in the app.", have: plays, need: 100),
        ]
        for (n, e) in state.eras.enumerated() where e.total >= 3 && e.name != "Other" {
            out.append(Badge(id: "era-\(e.name)", image: eraSticker(e.name, fallback: n), title: e.name, detail: "Every song from this era.", have: e.have, need: e.total))
        }
        return out
    }

    var body: some View {
        let list = badges
        let earned = list.filter(\.earned).count
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenTitle(text: "Badges")
                Text("\(earned) of \(list.count) earned. Era badges come from having every song of the era.").foregroundColor(JT.muted)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { n, b in card(b, seed: n) }
                }
            }
            .padding(.horizontal, 40).padding(.top, 40).padding(.bottom, 60)
            .frame(maxWidth: 1180, alignment: .leading)
        }
    }

    private func card(_ b: Badge, seed: Int) -> some View {
        VStack(spacing: 8) {
            Image(b.image).resizable().aspectRatio(contentMode: .fit).frame(width: 54, height: 54)
                .saturation(b.earned ? 1 : 0).opacity(b.earned ? 1 : 0.4)
                .shadow(color: b.earned ? JT.lavender.opacity(0.6) : .clear, radius: 10)
                .rotationEffect(.degrees(b.earned ? -6 : 0))
            Text(b.title).font(JT.body(15, .semibold)).multilineTextAlignment(.center).lineLimit(2)
            Text(b.detail).font(JT.body(12)).foregroundColor(JT.muted).multilineTextAlignment(.center).lineLimit(2)
            if b.earned {
                Label("Earned", systemImage: "checkmark.seal.fill").font(JT.body(12, .semibold)).foregroundColor(JT.have)
            } else {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(JT.raise)
                        Capsule().fill(JT.lavender).frame(width: g.size.width * min(1, CGFloat(b.have) / CGFloat(max(b.need, 1))))
                    }
                }
                .frame(height: 4)
                Text("\(min(b.have, b.need).formatted()) of \(b.need.formatted())").font(JT.body(12)).foregroundColor(JT.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 190)
        .doodled(14, seed: seed, stroke: b.earned ? JT.lavender.opacity(0.8) : JT.line2)
    }
}
