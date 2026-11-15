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
                FillBar(fraction: CGFloat(b.have) / CGFloat(max(b.need, 1)), fill: JT.lavender, delay: 0.15 + min(Double(seed) * 0.03, 0.4)).frame(height: 4)
                Text("\(min(b.have, b.need).formatted()) of \(b.need.formatted())").font(JT.body(12)).foregroundColor(JT.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 190)
        .overlay { if b.earned { Shimmer().opacity(0.35).clipShape(DoodleRect(seed: seed)) } }
        .doodled(14, seed: seed, stroke: b.earned ? JT.lavender.opacity(0.8) : JT.line2)
    }
}

// MARK: - Flair

/// The catalog song playing right now, kept apart from NowPlaying (that one ticks 15 times a second, which would
/// redraw every song row).
@MainActor final class PlayingRow: ObservableObject {
    static let shared = PlayingRow()
    @Published var index: Int?
}

/// Three little equalizer bars, bouncing by Core Animation (nothing per frame in the app).
struct EQBars: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 13, height: 12))
        v.wantsLayer = true
        for k in 0..<3 {
            let bar = CALayer()
            bar.backgroundColor = EraTheme.current.accentNS.cgColor
            bar.cornerRadius = 1
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.frame = CGRect(x: CGFloat(k) * 5, y: 0, width: 3, height: 12)
            let bounce = CABasicAnimation(keyPath: "transform.scale.y")
            bounce.fromValue = 0.25
            bounce.toValue = 1
            bounce.duration = [0.42, 0.55, 0.36][k]
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(bounce, forKey: "eq")
            v.layer?.addSublayer(bar)
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

/// Confetti (rainbow bits, hearts, 999s and butterflies) that rains over the window when songs land in the library.
/// The emitter lives for a few seconds per burst, so it costs nothing the rest of the time.
struct Confetti: NSViewRepresentable {
    static let fire = Notification.Name("JTConfetti")
    func makeNSView(context: Context) -> ConfettiView { ConfettiView() }
    func updateNSView(_ v: ConfettiView, context: Context) {}

    final class ConfettiView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            NotificationCenter.default.addObserver(self, selector: #selector(burst), name: Confetti.fire, object: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        @objc private func burst() {
            guard let root = layer, bounds.width > 0 else { return }
            let e = CAEmitterLayer()
            e.frame = bounds
            e.emitterPosition = CGPoint(x: bounds.midX, y: bounds.maxY + 20)
            e.emitterShape = .line
            e.emitterSize = CGSize(width: bounds.width * 0.8, height: 1)
            e.beginTime = CACurrentMediaTime()
            e.emitterCells = Self.cells
            root.addSublayer(e)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { e.birthRate = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { e.removeFromSuperlayer() }
        }

        private static let cells: [CAEmitterCell] = {
            func cell(_ image: CGImage, size: CGFloat, rate: Float) -> CAEmitterCell {
                let c = CAEmitterCell()
                c.contents = image
                c.birthRate = rate
                c.lifetime = 6.5
                c.velocity = 90
                c.velocityRange = 70
                c.emissionLongitude = -.pi / 2 // straight down (the layer's y points up)
                c.emissionRange = .pi / 4
                c.yAcceleration = -110
                c.spin = 2
                c.spinRange = 5
                c.scale = size / CGFloat(image.width)
                c.scaleRange = c.scale * 0.3
                c.alphaSpeed = -0.12
                return c
            }
            let bits = JT.rainbowColors.map { color -> CGImage in
                let img = NSImage(size: NSSize(width: 8, height: 14), flipped: false) { r in NSColor(color).setFill(); NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill(); return true }
                return img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            }
            let stickers = ["jt-heart", "jt-era-999", "jt-fly"].compactMap { NSImage(named: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
            return bits.map { cell($0, size: 8, rate: 26) } + stickers.map { cell($0, size: 26, rate: 6) }
        }()
    }
}

/// The little note that drops in from the top when songs land.
struct LandedToast: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image("jt-heart").resizable().frame(width: 24, height: 24).rotationEffect(.degrees(-12))
            Text(text).font(JT.body(15, .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Capsule().fill(JT.raise))
        .overlay(Capsule().stroke(JT.lavender.opacity(0.7), lineWidth: 1.5))
        .shadow(color: JT.lavender.opacity(0.45), radius: 16, y: 6)
    }
}

// MARK: - More motion (all Core Animation, so the app does nothing per frame)

/// A soft band of light that sweeps across whatever it overlays every few seconds.
struct Shimmer: NSViewRepresentable {
    func makeNSView(context: Context) -> ShimmerView { ShimmerView() }
    func updateNSView(_ v: ShimmerView, context: Context) {}

    final class ShimmerView: NSView {
        private let band = CAGradientLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            band.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.55).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
            band.startPoint = CGPoint(x: 0, y: 0.5)
            band.endPoint = CGPoint(x: 1, y: 0.5)
            layer?.addSublayer(band)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            let w: CGFloat = 90
            band.frame = CGRect(x: -w, y: 0, width: w, height: bounds.height)
            let sweep = CAKeyframeAnimation(keyPath: "position.x")
            sweep.values = [-w / 2, bounds.width + w / 2, bounds.width + w / 2]
            sweep.keyTimes = [0, 0.35, 1]
            sweep.duration = 4.5
            sweep.repeatCount = .infinity
            sweep.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear)]
            band.add(sweep, forKey: "sweep")
        }
    }
}

/// An image that flaps like wings now and then (squeezes sideways a few times, then rests).
struct Flapping: NSViewRepresentable {
    let image: String
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let l = CALayer()
        l.contents = NSImage(named: image)
        l.contentsGravity = .resizeAspect
        l.shadowColor = EraTheme.current.accentNS.cgColor
        l.shadowOpacity = 0.7
        l.shadowRadius = 6
        l.shadowOffset = .zero
        v.layer?.addSublayer(l)
        let flap = CAKeyframeAnimation(keyPath: "transform.scale.x")
        flap.values = [1, 0.45, 1, 0.45, 1, 0.45, 1, 1]
        flap.keyTimes = [0, 0.04, 0.08, 0.12, 0.16, 0.2, 0.24, 1]
        flap.duration = 3.2
        flap.repeatCount = .infinity
        l.add(flap, forKey: "flap")
        context.coordinator.layer = l
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        context.coordinator.layer?.frame = v.bounds
        CATransaction.commit()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var layer: CALayer? }
}

/// A four-point sparkle, drawn once.
func sparkleImage(_ size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
        let c = CGPoint(x: r.midX, y: r.midY), a = r.width / 2, b = r.width / 9
        let p = NSBezierPath()
        p.move(to: CGPoint(x: c.x, y: c.y + a))
        p.curve(to: CGPoint(x: c.x + a, y: c.y), controlPoint1: CGPoint(x: c.x + b, y: c.y + b), controlPoint2: CGPoint(x: c.x + b, y: c.y + b))
        p.curve(to: CGPoint(x: c.x, y: c.y - a), controlPoint1: CGPoint(x: c.x + b, y: c.y - b), controlPoint2: CGPoint(x: c.x + b, y: c.y - b))
        p.curve(to: CGPoint(x: c.x - a, y: c.y), controlPoint1: CGPoint(x: c.x - b, y: c.y - b), controlPoint2: CGPoint(x: c.x - b, y: c.y - b))
        p.curve(to: CGPoint(x: c.x, y: c.y + a), controlPoint1: CGPoint(x: c.x - b, y: c.y + b), controlPoint2: CGPoint(x: c.x - b, y: c.y + b))
        NSColor.white.setFill()
        p.fill()
        return true
    }
}

/// A progress bar that grows from empty when it first shows, then follows its value.
struct FillBar<Fill: ShapeStyle>: View {
    let fraction: CGFloat
    let fill: Fill
    var track: Color = JT.raise
    var delay = 0.0
    @State private var grown = false
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill).frame(width: g.size.width * (grown ? min(1, max(0, fraction)) : 0))
            }
        }
        .animation(.easeOut(duration: 0.6), value: fraction)
        .onAppear { withAnimation(.spring(response: 1, dampingFraction: 0.8).delay(delay)) { grown = true } }
    }
}

/// Little hearts and music notes drifting up out of the player while music plays.
struct NoteDrift: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = DriftView()
        v.wantsLayer = true
        let e = CAEmitterLayer()
        e.emitterShape = .line
        e.emitterCells = Self.cells() // made per view, so a new era theme's color shows
        v.emitter = e
        v.layer?.addSublayer(e)
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}

    private final class DriftView: NSView {
        var emitter: CAEmitterLayer?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            emitter?.frame = bounds
            emitter?.emitterPosition = CGPoint(x: bounds.midX, y: 0)
            emitter?.emitterSize = CGSize(width: bounds.width * 0.8, height: 1)
        }
    }

    private static func cells() -> [CAEmitterCell] {
        func glyph(_ s: String, _ color: NSColor) -> CGImage {
            let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 28, weight: .bold), .foregroundColor: color])
            let size = a.size()
            let img = NSImage(size: size, flipped: false) { _ in a.draw(at: .zero); return true }
            return img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        }
        let accent = EraTheme.current.accentNS
        let images = [glyph("♪", accent), glyph("♫", .white), NSImage(named: "jt-heart")?.cgImage(forProposedRect: nil, context: nil, hints: nil)].compactMap { $0 }
        return images.map { image in
            let c = CAEmitterCell()
            c.contents = image
            c.birthRate = 0.45
            c.lifetime = 4
            c.velocity = 28
            c.velocityRange = 10
            c.emissionLongitude = .pi / 2 // up
            c.emissionRange = .pi / 8
            c.xAcceleration = 0
            c.spin = 0.4
            c.spinRange = 1.2
            c.scale = 13 / CGFloat(image.width)
            c.alphaSpeed = -0.25
            return c
        }
    }
}
