import AppKit
import QuartzCore
import SwiftUI
import WebKit

// The native (SwiftUI) interface, stage 1. The classic page stays the engine: it loads the catalog, scans and
// matches the library, writes tags and downloads, and sends a snapshot here after each change. This window draws
// that snapshot and sends actions back (jwNativeAction in juice-tracker.html). Screens move here one at a time.

// MARK: - Snapshot from the page

struct NState: Decodable {
    struct Cat: Decodable, Hashable { let name: String; let have: Int; let total: Int }
    struct Era: Decodable, Hashable, Identifiable { let name: String; let have: Int; let total: Int; let time: String; let desc: String; var id: String { name } }
    struct Queue: Decodable, Hashable { let done: Int; let total: Int; let current: String; let waiting: Bool }
    struct Drive: Decodable, Hashable { let kind: String; let text: String }
    struct Notice: Decodable, Hashable { let text: String; let released: Bool }
    struct TodayRow: Decodable, Hashable { let head: String; let songs: [Int]; let more: Int }
    /// A catalog song's fixed details: sent once, and again only when they change.
    struct CatSong: Decodable, Hashable {
        let i: Int; let id: String; let n: String; let a: [String]; let rel: Bool; let e: String; let c: String; let l: String; let f: Bool
        let m: Int?             // recording month as year * 12 + month (0-11)
        let ry: [Int]           // recording years
        let py: Int?, sy: Int?, rl: Int?  // previewed, surfaced, released years
        let pr: [String], ar: [String], en: [String], st: [String]  // producers, artists, engineers, studios
    }
    let total: Int
    let have: Int
    let folder: String
    let queue: Queue?
    let cats: [Cat]
    let eras: [Era]
    let owned: [Int]
    let wished: [Int]
    let fresh: [Int]      // new since the last check
    let released: [Int]   // newly released since the last check
    let files: Int
    let drive: Drive?
    let notices: [Notice]
    let today: [TodayRow]
    let catalog: [CatSong]?
}

/// A song as the screens show it: its details plus whether you have it and whether it's on your wishlist.
struct Song: Hashable, Identifiable {
    let s: NState.CatSong
    let o: Bool
    let w: Bool
    var id: Int { s.i }
    var i: Int { s.i }
    var n: String { s.n }
    var e: String { s.e }
    var c: String { s.c }
    var l: String { s.l }
    var f: Bool { s.f }
}

struct SongDetails: Decodable {
    let name, era, category, length, key, recordDates, previewDate, release, leakDate, leakType, sessions: String
    let artists, producers, engineers, locations, notes, info, alt, siteUrl: String
    let files: [String]
    let playable: Bool
    let note: String
}

final class NativeStore: NSObject, ObservableObject, WKScriptMessageHandler {
    static let shared = NativeStore()
    @Published var state: NState?
    @Published var songs: [Song] = []
    @Published var page: NativePage = .collection // the screen showing in the native window
    @Published var eraFilter: String?            // the era picked on the Collection screen (or from ⌘K)
    @Published var showSetup = false
    @Published var version = 0 // bumps with every snapshot, so screens that ask the page for more can refresh
    private var catalog: [NState.CatSong] = []

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let json = message.body as? String else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let decoded: NState
            do { decoded = try JSONDecoder().decode(NState.self, from: Data(json.utf8)) }
            catch { NSLog("Juice Tracker: couldn't read the page's snapshot: \(error)"); return }
            DispatchQueue.main.async {
                if let c = decoded.catalog { self.catalog = c }
                let owned = Set(decoded.owned), wished = Set(decoded.wished)
                self.songs = self.catalog.map { Song(s: $0, o: owned.contains($0.i), w: wished.contains($0.i)) }
                self.state = decoded
                self.version += 1
                SpotlightIndex.update(self.songs)
                WidgetFeed.update()
                if let id = SpotlightIndex.pending, let s = self.songs.first(where: { $0.s.id == id }) { SpotlightIndex.pending = nil; self.openSong = s }
            }
        }
    }

    /// The song card opened from any screen.
    @Published var openSong: Song?

    /// Runs an action in the page (wish, download, play, details, refresh) and returns its text result.
    @MainActor @discardableResult func act(_ op: String, _ i: Int = -1, _ extra: [String: Any] = [:]) async -> String {
        (try? await tryAct(op, i, extra)) ?? ""
    }

    /// Like act, but passes on the page's error (for file fixes, whose failures the screen shows).
    @MainActor func tryAct(_ op: String, _ i: Int = -1, _ extra: [String: Any] = [:]) async throws -> String {
        var a: [String: Any] = ["op": op, "i": i]
        a.merge(extra) { _, new in new }
        do {
            let result = try await WebViewStore.shared.webView.callAsyncJavaScript(
                "return await (window.jwNativeAction ? window.jwNativeAction(a) : '')", arguments: ["a": a], contentWorld: .page)
            return result as? String ?? ""
        } catch {
            // WebKit's own text is just "a JavaScript exception occurred"; the page's message is in userInfo.
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            throw PageError(message: message.replacingOccurrences(of: "Error: ", with: ""))
        }
    }
    struct PageError: LocalizedError { let message: String; var errorDescription: String? { message } }

    @MainActor func details(_ i: Int) async -> SongDetails? {
        let json = await act("details", i)
        return try? JSONDecoder().decode(SongDetails.self, from: Data(json.utf8))
    }

    /// Opens a screen in the classic window.
    @MainActor func openClassic(_ view: String) {
        AppDelegate.shared?.showClassicWindow()
        WebViewStore.shared.webView.evaluateJavaScript("showView('\(view)')")
    }
}

// MARK: - The sky, drawn by Core Animation (it runs on the graphics chip, not in the app)

final class SkyNSView: NSView {
    private var builtFor: CGSize = .zero
    private let glow = CAGradientLayer()
    static weak var current: SkyNSView?

    /// Brightens a soft pink glow with the music's loudness (0...1). Called by NowPlaying while music plays.
    func setGlow(_ level: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.opacity = level * 0.55
        CATransaction.commit()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 7 / 255, green: 4 / 255, blue: 15 / 255, alpha: 1).cgColor
        let nc = NotificationCenter.default
        // Paused while the app is in the background: nothing to see, nothing to spend.
        nc.addObserver(self, selector: #selector(pause), name: NSApplication.didResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(resume), name: NSApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(rebuildForTheme), name: EraTheme.changed, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        guard bounds.size != builtFor, bounds.width > 0 else { return }
        builtFor = bounds.size
        build()
    }

    @objc private func rebuildForTheme() { builtFor = .zero; needsLayout = true }

    @objc private func pause() {
        guard let l = layer, l.speed != 0 else { return }
        l.timeOffset = l.convertTime(CACurrentMediaTime(), from: nil)
        l.speed = 0
    }
    @objc private func resume() {
        guard let l = layer, l.speed == 0 else { return }
        let paused = l.timeOffset
        l.speed = 1
        l.timeOffset = 0
        l.beginTime = 0
        l.beginTime = l.convertTime(CACurrentMediaTime(), from: nil) - paused
    }

    private func build() {
        guard let root = layer else { return }
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        let b = bounds
        SkyNSView.current = self

        let night = CAGradientLayer()
        night.frame = b
        night.colors = [NSColor(srgbRed: 42 / 255, green: 12 / 255, blue: 62 / 255, alpha: 1).cgColor,
                        NSColor(srgbRed: 22 / 255, green: 10 / 255, blue: 51 / 255, alpha: 1).cgColor,
                        NSColor(srgbRed: 7 / 255, green: 4 / 255, blue: 15 / 255, alpha: 1).cgColor]
        night.locations = [0, 0.45, 1]
        root.addSublayer(night)

        // nebula glows that breathe slowly
        let theme = EraTheme.current.glows // the nebula takes the era theme's colors
        let glows: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
            (0.52, 0.66, 0.42, theme[0]), (0.06, 0.30, 0.50, theme[1]), (0.88, 0.86, 0.45, theme[2]), (0.70, 0.10, 0.60, theme[3]),
        ]
        for (n, g) in glows.enumerated() {
            let size = max(b.width, b.height) * g.2
            let glow = CAGradientLayer()
            glow.type = .radial
            glow.colors = [g.3.cgColor, g.3.withAlphaComponent(0).cgColor]
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            glow.frame = CGRect(x: b.width * g.0 - size / 2, y: b.height * g.1 - size / 2, width: size, height: size)
            root.addSublayer(glow)
            let drift = CABasicAnimation(keyPath: "transform")
            drift.toValue = CATransform3DConcat(CATransform3DMakeScale(1.12, 1.12, 1), CATransform3DMakeTranslation(n.isMultiple(of: 2) ? -30 : 30, 18, 0))
            drift.duration = 40 + Double(n) * 6
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(drift, forKey: "drift")
        }

        // two star fields drifting at different speeds; each moves exactly one tile per loop, so it's seamless
        addStarField(to: root, tile: 420, count: 70, seed: 7, seconds: 260, alpha: 0.8)
        addStarField(to: root, tile: 690, count: 55, seed: 21, seconds: 190, alpha: 1)

        // the faint tattoo-flash doodles (hearts, lightning, butterflies, chains, crowns), drifting the other way
        if let flash = NSImage(named: "jt-flash") {
            let tile: CGFloat = 560
            let layer = Self.tiled(flash, tile: tile, covering: CGSize(width: bounds.width + tile, height: bounds.height + tile))
            layer.frame.origin = CGPoint(x: -tile, y: 0)
            root.addSublayer(layer)
            let drift = CABasicAnimation(keyPath: "position")
            drift.fromValue = layer.position
            drift.toValue = CGPoint(x: layer.position.x + tile, y: layer.position.y - tile)
            drift.duration = 150
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(drift, forKey: "drift")
        }

        // twinkling sparkles
        let sparkles = CALayer()
        sparkles.frame = b
        let sparkleTiles = Self.tiled(NSImage(named: "jt-sparkles") ?? Self.sparkleTile(), tile: 520, covering: b.size)
        sparkles.addSublayer(sparkleTiles)
        let twinkle = CABasicAnimation(keyPath: "opacity")
        twinkle.fromValue = 0.15
        twinkle.toValue = 1
        twinkle.duration = 3.8
        twinkle.autoreverses = true
        twinkle.repeatCount = .infinity
        twinkle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sparkles.add(twinkle, forKey: "twinkle")
        root.addSublayer(sparkles)

        // Juice tattoo flash (race car, halo, 999, roses, chains, a UFO), slower and the other way
        if let juice = NSImage(named: "jt-juiceflash") {
            let tile: CGFloat = 640
            let layer = Self.tiled(juice, tile: tile, covering: CGSize(width: bounds.width + tile, height: bounds.height + tile))
            layer.frame.origin = CGPoint(x: 0, y: -tile)
            root.addSublayer(layer)
            let drift = CABasicAnimation(keyPath: "position")
            drift.fromValue = layer.position
            drift.toValue = CGPoint(x: layer.position.x - tile, y: layer.position.y + tile)
            drift.duration = 220
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(drift, forKey: "drift")
        }

        // the glow that pulses with the music
        glow.type = .radial
        glow.colors = [EraTheme.current.accentNS.withAlphaComponent(0.35).cgColor, EraTheme.current.accentNS.withAlphaComponent(0).cgColor]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.frame = CGRect(x: b.width * 0.2, y: -b.height * 0.2, width: b.width * 0.9, height: b.height * 0.9)
        glow.opacity = 0
        root.addSublayer(glow)

        // a shooting star every 14 seconds
        let streak = CAGradientLayer()
        streak.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.95).cgColor]
        streak.startPoint = CGPoint(x: 0, y: 0.5)
        streak.endPoint = CGPoint(x: 1, y: 0.5)
        streak.bounds = CGRect(x: 0, y: 0, width: 170, height: 2)
        streak.cornerRadius = 1
        streak.shadowColor = NSColor.white.cgColor
        streak.shadowRadius = 4
        streak.shadowOpacity = 0.9
        streak.shadowOffset = .zero
        streak.opacity = 0
        streak.setAffineTransform(CGAffineTransform(rotationAngle: -20 * .pi / 180))
        root.addSublayer(streak)
        let from = CGPoint(x: -b.width * 0.1, y: b.height * 0.9), to = CGPoint(x: b.width * 0.6, y: b.height * 0.9 - b.width * 0.26)
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = [from, to, to]
        move.keyTimes = [0, 0.06, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0, 0]
        fade.keyTimes = [0, 0.01, 0.06, 1]
        let shoot = CAAnimationGroup()
        shoot.animations = [move, fade]
        shoot.duration = 14
        shoot.beginTime = CACurrentMediaTime() + 3
        shoot.repeatCount = .infinity
        streak.add(shoot, forKey: "shoot")
    }

    private func addStarField(to root: CALayer, tile: CGFloat, count: Int, seed: UInt64, seconds: Double, alpha: CGFloat) {
        let field = Self.tiled(Self.starTile(size: tile, count: count, seed: seed, alpha: alpha), tile: tile,
                               covering: CGSize(width: bounds.width + tile, height: bounds.height + tile))
        root.addSublayer(field)
        let drift = CABasicAnimation(keyPath: "position")
        drift.fromValue = field.position
        drift.toValue = CGPoint(x: field.position.x - tile, y: field.position.y - tile)
        drift.duration = seconds
        drift.repeatCount = .infinity
        drift.timingFunction = CAMediaTimingFunction(name: .linear)
        field.add(drift, forKey: "drift")
    }

    /// A layer covering `size` with copies of one image, repeated by Core Animation on the graphics chip. (A pattern
    /// color did the same but made the app redraw the tiles itself whenever the layer moved: about a third of a core.)
    private static func tiled(_ image: NSImage, tile: CGFloat, covering size: CGSize) -> CALayer {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let one = CALayer()
        one.frame = CGRect(x: 0, y: 0, width: tile, height: tile)
        one.contents = image.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: AffineTransform(scale: scale)])
        one.contentsScale = scale
        let row = CAReplicatorLayer()
        row.frame = CGRect(x: 0, y: 0, width: size.width, height: tile)
        row.instanceCount = Int((size.width / tile).rounded(.up))
        row.instanceTransform = CATransform3DMakeTranslation(tile, 0, 0)
        row.addSublayer(one)
        let grid = CAReplicatorLayer()
        grid.frame = CGRect(origin: .zero, size: size)
        grid.instanceCount = Int((size.height / tile).rounded(.up))
        grid.instanceTransform = CATransform3DMakeTranslation(0, tile, 0)
        grid.addSublayer(row)
        return grid
    }

    private static func starTile(size: CGFloat, count: Int, seed: UInt64, alpha: CGFloat) -> NSImage {
        var state = seed
        func rand() -> CGFloat { state = state &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((state >> 33) % 10_000) / 10_000 }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            for _ in 0..<count {
                let r = 0.4 + rand() * 0.9
                NSColor.white.withAlphaComponent(alpha * (0.4 + rand() * 0.6)).setFill()
                NSBezierPath(ovalIn: NSRect(x: rand() * size, y: rand() * size, width: r * 2, height: r * 2)).fill()
            }
            return true
        }
    }

    private static func sparkleTile() -> NSImage {
        let spots: [(CGFloat, CGFloat, CGFloat)] = [(60, 90, 8), (380, 60, 6), (250, 300, 10), (450, 420, 6), (120, 440, 7)]
        return NSImage(size: NSSize(width: 520, height: 520), flipped: false) { _ in
            NSColor.white.setFill()
            for (x, y, r) in spots {
                let p = NSBezierPath()
                p.move(to: NSPoint(x: x, y: y + r))
                p.curve(to: NSPoint(x: x + r, y: y), controlPoint1: NSPoint(x: x, y: y), controlPoint2: NSPoint(x: x, y: y))
                p.curve(to: NSPoint(x: x, y: y - r), controlPoint1: NSPoint(x: x, y: y), controlPoint2: NSPoint(x: x, y: y))
                p.curve(to: NSPoint(x: x - r, y: y), controlPoint1: NSPoint(x: x, y: y), controlPoint2: NSPoint(x: x, y: y))
                p.curve(to: NSPoint(x: x, y: y + r), controlPoint1: NSPoint(x: x, y: y), controlPoint2: NSPoint(x: x, y: y))
                p.fill()
            }
            return true
        }
    }
}

struct SkyBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> SkyNSView { SkyNSView() }
    func updateNSView(_ view: SkyNSView, context: Context) {}
}

// MARK: - Look (the classic page's colors, fonts and hand-drawn outlines)

enum JT {
    static let night = Color(red: 10 / 255, green: 6 / 255, blue: 24 / 255)
    static let dusk = Color(red: 24 / 255, green: 12 / 255, blue: 52 / 255).opacity(0.82)
    static let raise = Color(red: 58 / 255, green: 30 / 255, blue: 108 / 255).opacity(0.82)
    static let line = Color(red: 190 / 255, green: 150 / 255, blue: 1).opacity(0.2)
    static let line2 = Color(red: 210 / 255, green: 170 / 255, blue: 1).opacity(0.38)
    static let mist = Color(red: 1, green: 246 / 255, blue: 251 / 255)
    static let muted = Color(red: 195 / 255, green: 178 / 255, blue: 227 / 255)
    /// The accent follows the era theme picked in Settings (pink in the original Cosmic theme).
    static var lavender: Color { EraTheme.current.accent }
    static var lavenderHi: Color { EraTheme.current.accentHi }
    static let have = Color(red: 201 / 255, green: 242 / 255, blue: 74 / 255)
    static let new = Color(red: 1, green: 160 / 255, blue: 74 / 255)
    static let missing = Color(red: 1, green: 93 / 255, blue: 108 / 255)
    static let yellow = Color(red: 1, green: 225 / 255, blue: 74 / 255)
    static let rainbowColors = [Color(red: 1, green: 93 / 255, blue: 108 / 255), Color(red: 1, green: 160 / 255, blue: 74 / 255),
                                Color(red: 1, green: 225 / 255, blue: 74 / 255), Color(red: 201 / 255, green: 242 / 255, blue: 74 / 255),
                                Color(red: 79 / 255, green: 216 / 255, blue: 1), Color(red: 106 / 255, green: 168 / 255, blue: 1),
                                Color(red: 183 / 255, green: 123 / 255, blue: 1), Color(red: 1, green: 106 / 255, blue: 213 / 255)]
    static let rainbow = LinearGradient(colors: rainbowColors, startPoint: .leading, endPoint: .trailing)
    static let countGradient = LinearGradient(colors: [Color(red: 1, green: 160 / 255, blue: 74 / 255), Color(red: 1, green: 225 / 255, blue: 74 / 255),
                                                       Color(red: 201 / 255, green: 242 / 255, blue: 74 / 255), Color(red: 79 / 255, green: 216 / 255, blue: 1),
                                                       Color(red: 1, green: 106 / 255, blue: 213 / 255)], startPoint: .leading, endPoint: .trailing)
    /// Permanent Marker: the app's own voice (brand, hero, page titles).
    static func marker(_ size: CGFloat) -> Font { .custom("Permanent Marker", size: size) }
    /// Figtree: everything you read.
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Figtree", size: size).weight(weight) }
}

/// A rounded box drawn by hand: each corner a different size, each side bowing a little (like the classic outlines).
struct DoodleRect: Shape {
    var seed = 0
    func path(in r: CGRect) -> Path {
        let shapes: [[CGFloat]] = [[20, 30, 18, 26], [14, 22, 12, 20], [22, 15, 20, 17], [26, 18, 24, 16]]
        let scale = min(1, min(r.width, r.height) / 90)
        let c = shapes[abs(seed) % shapes.count].map { min($0 * scale, min(r.width, r.height) / 2) }
        let bows: [CGFloat] = [1.4, -1.1, 1.2, -1.3]
        let b = (0..<4).map { bows[($0 + seed) % 4] }
        var p = Path()
        p.move(to: CGPoint(x: r.minX + c[0], y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - c[1], y: r.minY), control: CGPoint(x: r.midX, y: r.minY + b[0]))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + c[1]), control: CGPoint(x: r.maxX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - c[2]), control: CGPoint(x: r.maxX + b[1], y: r.midY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - c[2], y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX + c[3], y: r.maxY), control: CGPoint(x: r.midX, y: r.maxY + b[2]))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - c[3]), control: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + c[0]), control: CGPoint(x: r.minX + b[3], y: r.midY))
        p.addQuadCurve(to: CGPoint(x: r.minX + c[0], y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// A frosted panel with a hand-drawn outline, like the classic page's boxes.
struct Doodled: ViewModifier {
    var radius: CGFloat = 16
    var seed = 0
    var stroke = JT.line2
    func body(content: Content) -> some View {
        content
            .background(DoodleRect(seed: seed).fill(JT.dusk))
            .overlay(DoodleRect(seed: seed).stroke(stroke, lineWidth: 1.6))
    }
}
extension View {
    func doodled(_ radius: CGFloat = 16, seed: Int = 0, stroke: Color = JT.line2) -> some View { modifier(Doodled(radius: radius, seed: seed, stroke: stroke)) }
}

/// A page title: marker lettering, tilted a touch, with the rainbow squiggle underneath.
struct ScreenTitle: View {
    let text: String
    var size: CGFloat = 40
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(JT.marker(size)).foregroundColor(JT.mist)
            Image("jt-squiggle").resizable().frame(width: size * 3, height: size * 0.27)
        }
        .rotationEffect(.degrees(-1), anchor: .leading)
    }
}

// MARK: - Window

enum NativePage: String, CaseIterable, Identifiable {
    case collection, fixer, dups, health, people, stats, timeline, badges, trivia, export
    var id: String { rawValue }
    var title: String {
        ["collection": "Collection", "fixer": "Tag fixer", "dups": "Duplicates", "health": "File health", "people": "Credits",
         "stats": "Stats", "timeline": "Timeline", "badges": "Badges", "trivia": "Trivia", "export": "Export & backup"][rawValue] ?? rawValue
    }
    var icon: String {
        ["collection": "smallcircle.filled.circle", "fixer": "tag", "dups": "square.on.square", "health": "waveform.path.ecg", "people": "person.2",
         "stats": "chart.bar", "timeline": "point.3.connected.trianglepath.dotted", "badges": "rosette", "trivia": "questionmark.circle", "export": "archivebox"][rawValue] ?? "circle"
    }
}

struct NativeRoot: View {
    @ObservedObject private var store = NativeStore.shared
    @ObservedObject private var theme = ThemeWatcher.shared
    @State private var searching = false
    private var page: NativePage { store.page }

    var body: some View {
        ZStack {
            SkyBackground().ignoresSafeArea()
            HStack(spacing: 0) {
                Sidebar(searching: $searching).frame(width: 238)
                Group {
                    if let s = store.state, !store.songs.isEmpty {
                        switch page {
                        case .timeline: TimelineScreen(songs: store.songs)
                        case .stats: StatsScreen(state: s, songs: store.songs)
                        case .people: CreditsScreen(songs: store.songs)
                        case .dups: DuplicatesScreen()
                        case .health: HealthScreen()
                        case .fixer: TagFixerScreen()
                        case .trivia: TriviaScreen()
                        case .export: ExportScreen()
                        case .badges: BadgesScreen(state: s, songs: store.songs)
                        default: CollectionScreen(state: s, songs: store.songs)
                        }
                    } else { SetupView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(JT.body(15))
        .foregroundColor(JT.mist)
        .preferredColorScheme(.dark)
        .id(theme.id) // a new era theme redraws everything in its colors
        .sheet(item: $store.openSong) { s in SongCard(opened: s, close: { store.openSong = nil }) }
        .sheet(isPresented: $searching) { QuickSearch(close: { searching = false }) }
        .task { await store.act("refresh") }
    }
}

// MARK: - Sidebar (the classic rail)

struct Sidebar: View {
    @ObservedObject private var store = NativeStore.shared
    @Binding var searching: Bool
    @State private var hovered: NativePage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { store.page = .collection } label: {
                HStack(spacing: 10) {
                    Image("jt-logo").resizable().frame(width: 44, height: 44)
                    Text("Juice\nTracker").font(JT.marker(23)).lineSpacing(-6).foregroundColor(JT.mist).fixedSize()
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 38).padding(.horizontal, 8).padding(.bottom, 22)

            Button { searching = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold))
                    Text("Search")
                    Spacer()
                    Text("⌘K").font(JT.body(12, .medium)).padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(JT.line2))
                }
                .foregroundColor(JT.muted)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(JT.line))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .padding(.bottom, 22)

            ForEach(NativePage.allCases) { p in navItem(p) }
            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                if let q = store.state?.queue {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(q.waiting ? "Waiting for the music drive…" : "Downloading \(min(q.done + 1, q.total)) of \(q.total)").font(JT.body(12))
                            Spacer()
                            Button("Stop") { Task { await store.act("stopQueue") } }.buttonStyle(.borderless).font(JT.body(12))
                        }
                        if !q.current.isEmpty { Text(q.current).font(JT.body(11)).foregroundColor(JT.muted).lineLimit(1) }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(JT.line)
                                Capsule().fill(JT.have).frame(width: g.size.width * CGFloat(q.done) / CGFloat(max(q.total, 1)))
                            }
                        }
                        .frame(height: 4)
                    }
                    .padding(10).overlay(RoundedRectangle(cornerRadius: 10).stroke(JT.line))
                }
                if let d = store.state?.drive {
                    Button { Task { await store.act("driveCheck") } } label: {
                        HStack(spacing: 8) {
                            Circle().fill(d.kind == "ok" ? JT.have : d.kind == "slow" ? JT.new : d.kind == "off" ? JT.missing : JT.muted).frame(width: 8, height: 8)
                            Text(d.text).font(JT.body(12.5)).foregroundColor(JT.muted).lineLimit(1)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .overlay(Capsule().stroke(JT.line))
                    }
                    .buttonStyle(.plain)
                }
                PlayerPanel()
                Link(destination: URL(string: "https://ko-fi.com/hb4delirious")!) {
                    HStack(spacing: 8) {
                        Image(systemName: "heart.fill").foregroundColor(JT.missing)
                        Text("Support this project").font(JT.body(14, .semibold)).foregroundColor(JT.night)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Capsule().fill(LinearGradient(colors: [Color(red: 1, green: 0.72, blue: 0.35), JT.new], startPoint: .top, endPoint: .bottom)))
                }
                (Text("Your files stay on this computer. Only song info comes from ") + Text("juicewrldapi.com").foregroundColor(JT.lavender).underline() + Text("."))
                    .font(JT.body(12.5)).foregroundColor(JT.muted).lineLimit(3).minimumScaleFactor(0.9)
                Button { store.openClassic(store.page.rawValue) } label: { Label("Classic window", systemImage: "macwindow") }
                    .buttonStyle(.borderless).font(JT.body(12)).foregroundColor(JT.muted.opacity(0.8))
                    .help("The original HTML interface (⌘2)")
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 16)
        .background(LinearGradient(colors: [Color(red: 13 / 255, green: 7 / 255, blue: 30 / 255).opacity(0.92), Color(red: 22 / 255, green: 10 / 255, blue: 44 / 255).opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom))
        .overlay(Rectangle().fill(JT.line).frame(width: 1), alignment: .trailing)
    }

    private func navItem(_ p: NativePage) -> some View {
        let current = store.page == p
        return Button { store.page = p } label: {
            HStack(spacing: 12) {
                Image(systemName: p.icon).font(.system(size: 15, weight: .medium)).frame(width: 22)
                    .foregroundColor(current ? JT.lavender : nil)
                    .rotationEffect(.degrees(current || hovered == p ? -10 : 0)).scaleEffect(current || hovered == p ? 1.15 : 1)
                Text(p.title).font(JT.body(16))
                Spacer()
            }
            .foregroundColor(current || hovered == p ? JT.mist : JT.muted)
            .padding(.vertical, 9).padding(.horizontal, 12)
            .background(
                ZStack {
                    if current {
                        RoundedRectangle(cornerRadius: 12).fill(JT.raise)
                        Image("jt-scribble").resizable()
                    } else if hovered == p {
                        RoundedRectangle(cornerRadius: 12).fill(JT.raise.opacity(0.6))
                    }
                }
            )
            .overlay(alignment: .leading) {
                if current { Capsule().fill(LinearGradient(colors: JT.rainbowColors, startPoint: .top, endPoint: .bottom)).frame(width: 3).padding(.vertical, 7) }
            }
            .contentShape(Rectangle())
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: hovered)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? p : (hovered == p ? nil : hovered) }
    }
}

/// ⌘K: jump to a page, an era or a song.
struct QuickSearch: View {
    @ObservedObject private var store = NativeStore.shared
    let close: () -> Void
    @State private var query = ""

    private enum Hit: Identifiable { case page(NativePage), era(String), song(Song)
        var id: String { switch self { case .page(let p): return "p" + p.rawValue; case .era(let e): return "e" + e; case .song(let s): return "s\(s.i)" } }
    }

    private var hits: [Hit] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return NativePage.allCases.map { .page($0) } }
        let pages = NativePage.allCases.filter { $0.title.lowercased().contains(q) }.map { Hit.page($0) }
        let eras = (store.state?.eras ?? []).filter { $0.name.lowercased().contains(q) }.prefix(6).map { Hit.era($0.name) }
        let songs = store.songs.filter { $0.n.lowercased().contains(q) || $0.s.a.contains { $0.lowercased().contains(q) } }
            .sorted { ($0.n.lowercased().hasPrefix(q) ? 0 : 1, $0.n) < ($1.n.lowercased().hasPrefix(q) ? 0 : 1, $1.n) }.prefix(30).map { Hit.song($0) }
        return pages + eras + songs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search songs, eras and pages", text: $query).textFieldStyle(.plain).font(JT.body(20))
                .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
                .onSubmit { if let first = hits.first { pick(first) } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(hits) { hit in
                        Button { pick(hit) } label: {
                            HStack {
                                switch hit {
                                case .page(let p): Image(systemName: p.icon).frame(width: 22); Text(p.title); Spacer(); Text("Page").foregroundColor(JT.muted)
                                case .era(let e): Image(systemName: "sparkles").frame(width: 22); Text(e); Spacer(); Text("Era").foregroundColor(JT.muted)
                                case .song(let s): Image(systemName: s.o ? "checkmark.circle.fill" : "music.note").foregroundColor(s.o ? JT.have : JT.muted).frame(width: 22)
                                    Text(s.n).lineLimit(1); Spacer(); Text(s.e).foregroundColor(JT.muted)
                                }
                            }
                            .padding(.vertical, 7).padding(.horizontal, 10).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack { Spacer(); Button("Close", action: close).keyboardShortcut(.cancelAction) }
        }
        .padding(18).frame(width: 560, height: 480).background(JT.night).font(JT.body(15)).preferredColorScheme(.dark)
    }

    private func pick(_ hit: Hit) {
        close()
        switch hit {
        case .page(let p): store.page = p
        case .era(let e): store.page = .collection; store.eraFilter = e
        case .song(let s): DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { store.openSong = s }
        }
    }
}

// MARK: - Collection (the classic home page)

struct CollectionScreen: View {
    let state: NState
    let all: [Song]
    @ObservedObject private var store = NativeStore.shared
    @State private var tab = "all"
    @State private var query = ""
    @State private var limit = 200
    @State private var askAll: [Int] = []
    init(state: NState, songs: [Song]) { self.state = state; self.all = songs }

    private var era: String? { store.eraFilter }
    private var fresh: Set<Int> { Set(state.fresh) }
    private var releasedNow: Set<Int> { Set(state.released) }

    private var songs: [Song] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let fresh = self.fresh, rel = releasedNow
        return all.filter { s in
            (era == nil || s.e == era) &&
            (tab == "all" || (tab == "have" && s.o) || (tab == "missing" && !s.o) || (tab == "wish" && s.w) || (tab == "new" && fresh.contains(s.i)) || (tab == "released" && rel.contains(s.i))) &&
            (q.isEmpty || s.n.lowercased().contains(q) || s.e.lowercased().contains(q) || s.s.a.contains { $0.lowercased().contains(q) })
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topLine.padding(.bottom, 22)
                    scoreboard
                    notices.padding(.top, 26)
                    erasSection.padding(.top, 44)
                    songList.padding(.top, 34).id("songs")
                }
                .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 80)
                .frame(maxWidth: 1240, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: store.eraFilter) { e in if e != nil { withAnimation { proxy.scrollTo("songs", anchor: .top) } } }
        }
    }

    private var topLine: some View {
        HStack(spacing: 22) {
            (Text("\(state.total.formatted())").bold() + Text(" songs in the catalog").foregroundColor(JT.muted))
            (Text("\(state.files.formatted())").bold() + Text(" files in your music folder").foregroundColor(JT.muted))
            Spacer()
            Button("Setup (show)") { store.showSetup = true }.buttonStyle(.plain).foregroundColor(JT.lavender)
        }
        .font(JT.body(15.5))
        .sheet(isPresented: $store.showSetup) {
            VStack { SetupView(); HStack { Spacer(); Button("Done") { store.showSetup = false }.keyboardShortcut(.cancelAction) }.padding() }
                .frame(width: 820, height: 420).background(JT.night).preferredColorScheme(.dark)
        }
    }

    private var scoreboard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                (Text("You have ") + Text(state.have.formatted()).foregroundColor(.clear) + Text(" of \(state.total.formatted()) songs").foregroundColor(JT.muted.opacity(0.95)))
                    .font(JT.marker(64)).lineSpacing(-6)
                    .overlay(alignment: .topLeading) { countOverlay }
                    .shadow(color: JT.lavender.opacity(0.45), radius: 14)
                    .rotationEffect(.degrees(-1.2), anchor: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 200)
                FloatingDoodles().frame(width: 240, height: 230).offset(x: 24, y: -40).allowsHitTesting(false)
            }
            meter.padding(.top, 26)
            categories.padding(.top, 24)
        }
    }

    /// The count in rainbow letters, laid exactly over the gap left for it in the headline.
    private var countOverlay: some View {
        (Text("You have ").foregroundColor(.clear) + Text(state.have.formatted()).foregroundColor(.white))
            .font(JT.marker(64))
            .overlay(JT.countGradient.mask((Text("You have ").foregroundColor(.clear) + Text(state.have.formatted())).font(JT.marker(64))))
            .foregroundColor(.clear)
    }

    private var meter: some View {
        GeometryReader { g in
            let pct = CGFloat(state.have) / CGFloat(max(state.total, 1))
            ZStack(alignment: .leading) {
                Capsule().fill(JT.raise)
                JT.rainbow.frame(width: g.size.width).mask(alignment: .leading) { Capsule().frame(width: max(12, g.size.width * pct)) }
                Image("jt-fly").resizable().frame(width: 32, height: 32).shadow(color: JT.lavender.opacity(0.6), radius: 6)
                    .offset(x: max(0, g.size.width * pct - 16), y: -10)
            }
            .animation(.easeOut(duration: 0.9), value: state.have)
        }
        .frame(height: 12)
    }

    private var categories: some View {
        HStack(spacing: 0) {
            ForEach(Array(state.cats.enumerated()), id: \.element) { n, c in
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(c.name); Spacer(); Text("\(c.have.formatted()) / \(c.total.formatted())").foregroundColor(JT.muted) }.font(JT.body(15.5))
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(JT.raise)
                            Capsule().fill(JT.have).frame(width: g.size.width * CGFloat(c.have) / CGFloat(max(c.total, 1)))
                        }
                    }
                    .frame(height: 4)
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
                .overlay(alignment: .leading) { if n > 0 { Rectangle().fill(JT.line).frame(width: 1) } }
            }
        }
        .doodled(16, seed: 1)
    }

    @ViewBuilder private var notices: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(state.notices, id: \.self) { n in
                HStack(spacing: 18) {
                    Capsule().fill(n.released ? JT.have : JT.new).frame(width: 2.5)
                    Text(n.text).font(JT.body(16))
                }
                .padding(.vertical, 8)
            }
            if !state.today.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On this day").font(JT.marker(20)).padding(.bottom, 4)
                    ForEach(state.today, id: \.self) { row in
                        todayLine(row)
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .doodled(16, seed: 2)
            }
        }
    }

    private func todayLine(_ row: NState.TodayRow) -> some View {
        // A flowing line of tappable song names, with a check for the ones you have.
        var text = Text(row.head + " ").font(JT.body(15.5)).bold()
        for (k, i) in row.songs.enumerated() where all.indices.contains(i) {
            let s = all[i]
            text = text + Text(s.n).font(JT.body(15.5)) + (s.o ? Text(" ✓").foregroundColor(JT.have) : Text("")) + Text(k < row.songs.count - 1 ? ", " : "")
        }
        if row.more > 0 { text = text + Text(" and \(row.more) more") }
        return text
            .onTapGesture { if let first = row.songs.first, all.indices.contains(first) { store.openSong = all[first] } }
            .help("Click to open the first song")
    }

    private var erasSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScreenTitle(text: "Eras", size: 34)
            Text("Pick an era to see its songs below.").font(JT.body(16)).foregroundColor(JT.muted).padding(.bottom, 10)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                ForEach(Array(state.eras.enumerated()), id: \.element) { n, e in EraCard(era: e, sticker: eraSticker(e.name, fallback: n), seed: n, picked: era == e.name) }
            }
        }
    }

    /// The song list keeps the earlier native design (segmented tabs, one-line rows), which you preferred to the
    /// classic page's table.
    private var songList: some View {
        let list = songs
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("", selection: $tab) {
                    Text("All").tag("all"); Text("In your library").tag("have"); Text("Not in your library").tag("missing"); Text("Wishlist").tag("wish")
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 460)
                TextField("Search songs or eras", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                if let era { Button { store.eraFilter = nil } label: { Label(era, systemImage: "xmark.circle.fill") }.buttonStyle(.borderless) }
            }
            HStack {
                Text("\(list.count) songs").font(.caption).foregroundColor(JT.muted)
                Spacer()
                let missing = list.filter { !$0.o && $0.f }
                if !missing.isEmpty {
                    Button { askAll = missing.map(\.i) } label: {
                        Label(era != nil && tab == "all" && query.isEmpty ? "Complete this era (\(missing.count))" : "Download all \(missing.count) missing", systemImage: "arrow.down.circle")
                    }
                }
            }
            .alert("Download \(askAll.count) songs into your music folder?", isPresented: Binding(get: { !askAll.isEmpty }, set: { if !$0 { askAll = [] } })) {
                Button("Download") { let ids = askAll; Task { await NativeStore.shared.act("downloadMany", -1, ["ids": ids]) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("They download one at a time into the folders the tracker picks for each era, and carry on after a restart or if the drive drops.") }
            LazyVStack(spacing: 0) {
                ForEach(list.prefix(limit)) { s in SongRow(song: s, open: { NativeStore.shared.openSong = s }) }
            }
            .doodled(14)
            if list.count > limit { Button("Show more") { limit += 300 }.buttonStyle(.borderless) }
        }
        .onChange(of: query) { _ in limit = 200 }
        .onChange(of: tab) { _ in limit = 200 }
    }
}

/// The planet and the cracked heart, bobbing. Animated by Core Animation, so the app does nothing per frame
/// (an endless SwiftUI animation here cost about 13% CPU).
private struct FloatingDoodles: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 230))
        v.wantsLayer = true
        func add(_ name: String, _ frame: CGRect, rise: CGFloat, turn: CGFloat, delay: Double) {
            guard let image = NSImage(named: name) else { return }
            let l = CALayer()
            l.frame = frame
            l.contents = image
            l.contentsGravity = .resizeAspect
            v.layer?.addSublayer(l)
            let bob = CABasicAnimation(keyPath: "transform")
            bob.fromValue = CATransform3DIdentity
            bob.toValue = CATransform3DConcat(CATransform3DMakeRotation(turn * .pi / 180, 0, 0, 1), CATransform3DMakeTranslation(0, rise, 0))
            bob.duration = 4.5
            bob.autoreverses = true
            bob.repeatCount = .infinity
            bob.beginTime = CACurrentMediaTime() + delay
            bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            l.add(bob, forKey: "bob")
        }
        add("jt-planet", CGRect(x: 40, y: 30, width: 200, height: 200), rise: 8, turn: 0, delay: 0)
        add("jt-heart", CGRect(x: 10, y: 0, width: 46, height: 46), rise: 10, turn: 7, delay: 2)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct EraCard: View {
    let era: NState.Era
    let sticker: String
    let seed: Int
    let picked: Bool
    @State private var hover = false

    var body: some View {
        Button { NativeStore.shared.eraFilter = picked ? nil : era.name } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(era.name).font(JT.body(17, .semibold)).lineLimit(1)
                if !era.time.isEmpty { Text(era.time).font(JT.body(13.5)).foregroundColor(JT.muted).lineLimit(1) }
                if !era.desc.isEmpty { Text(era.desc).font(JT.body(14)).foregroundColor(JT.muted).lineLimit(2).padding(.top, 10) }
                Spacer(minLength: 12)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(picked ? JT.night : JT.raise)
                        Capsule().fill(JT.have).frame(width: g.size.width * CGFloat(era.have) / CGFloat(max(era.total, 1)))
                    }
                }
                .frame(height: 4)
                Text("\(era.have.formatted()) of \(era.total.formatted()) \(era.total == 1 ? "song" : "songs")").font(JT.body(13.5)).foregroundColor(JT.muted)
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
            .background(DoodleRect(seed: seed).fill(hover || picked ? JT.raise : JT.dusk))
            .overlay(DoodleRect(seed: seed).stroke(picked ? JT.lavender : hover ? JT.lavender.opacity(0.8) : JT.line2, lineWidth: picked ? 2.6 : 1.6))
            .overlay(alignment: .topTrailing) {
                Image(sticker).resizable().frame(width: 30, height: 30)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 3)
                    .rotationEffect(.degrees(hover ? -10 : 14)).scaleEffect(hover ? 1.3 : 1)
                    .offset(x: 9, y: -12)
            }
            .shadow(color: JT.lavender.opacity(picked ? 0.35 : hover ? 0.22 : 0), radius: picked ? 18 : 14, y: hover ? 10 : 0)
            .offset(y: hover ? -3 : 0)
            .rotationEffect(.degrees(hover ? -0.4 : 0))
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct SongRow: View {
    let song: Song
    let open: () -> Void
    var compact = false // narrow lists (Credits): no category column
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Button { Task { await NativeStore.shared.act("wish", song.i) } } label: {
                Image(systemName: song.w ? "star.fill" : "star").foregroundColor(song.w ? Color(red: 1, green: 0.88, blue: 0.29) : JT.muted)
            }
            .buttonStyle(.plain)
            .help(song.w ? "On your wishlist" : "Add to wishlist")
            Button(action: open) {
                HStack(spacing: 12) {
                    Text(song.n).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(song.e).foregroundColor(JT.muted).lineLimit(1).frame(width: compact ? 80 : 110, alignment: .leading)
                    if !compact { Text(song.c).foregroundColor(JT.muted).lineLimit(1).frame(width: 130, alignment: .leading) }
                    Text(song.l).foregroundColor(JT.muted).frame(width: 44, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            status.frame(width: compact ? 100 : 120, alignment: .leading)
        }
        .font(.callout)
        .padding(.vertical, 8).padding(.horizontal, 14)
        .background(hover ? Color.white.opacity(0.05) : .clear)
        .onHover { hover = $0 }
        .overlay(Rectangle().fill(JT.line).frame(height: 0.5), alignment: .bottom)
    }

    @ViewBuilder private var status: some View {
        if song.o {
            Label("In library", systemImage: "checkmark").foregroundColor(JT.have)
        } else if song.f {
            Button { Task { await NativeStore.shared.act("download", song.i) } } label: { Label("Download", systemImage: "arrow.down.circle") }
                .buttonStyle(.borderless).foregroundColor(JT.lavender)
        } else {
            Text("No file").foregroundColor(JT.muted.opacity(0.7))
        }
    }
}

struct SongCard: View {
    let opened: Song
    let close: () -> Void
    @ObservedObject private var store = NativeStore.shared
    @State private var d: SongDetails?
    @State private var note = ""
    /// The latest snapshot of this song (the wishlist star and library status change while the card is open).
    private var song: Song { store.songs.indices.contains(opened.i) && store.songs[opened.i].i == opened.i ? store.songs[opened.i] : opened }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.n).font(JT.marker(30))
                    Text("\(song.c) · \(song.e) era").foregroundColor(JT.muted)
                    if let alt = d?.alt, !alt.isEmpty { Text("Also known as \(alt)").font(.caption).foregroundColor(JT.muted) }
                }
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
            if let d {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(facts(d), id: \.0) { k, v in
                            HStack(alignment: .top) { Text(k).foregroundColor(JT.muted).frame(width: 110, alignment: .leading); Text(v).textSelection(.enabled) }
                        }
                        if !d.notes.isEmpty || !d.info.isEmpty {
                            Text("Notes").font(.headline).padding(.top, 6)
                            Text([d.notes, d.info].filter { !$0.isEmpty }.joined(separator: "\n\n")).foregroundColor(JT.muted).textSelection(.enabled)
                        }
                        SongExtrasView(song: song)
                        Text("Your note").font(.headline).padding(.top, 6)
                        TextEditor(text: $note).frame(minHeight: 54).font(.callout)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(JT.line))
                            .onChange(of: note) { text in
                                Task { try? await Task.sleep(nanoseconds: 500_000_000); if text == note { await NativeStore.shared.act("note", song.i, ["text": text]) } }
                            }
                        Text("Your library").font(.headline).padding(.top, 6)
                        if d.files.isEmpty { Text("Not in your library.").foregroundColor(JT.muted) }
                        ForEach(d.files, id: \.self) { Text($0).font(.caption.monospaced()).foregroundColor(JT.muted) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button { Task { await NativeStore.shared.act("wish", song.i) } } label: { Label(song.w ? "On your wishlist" : "Add to wishlist", systemImage: song.w ? "star.fill" : "star") }
                    if d.playable { Button { Task { await NativeStore.shared.act("play", song.i) } } label: { Label("Play", systemImage: "play.fill") } }
                    if !song.o && song.f { Button { Task { await NativeStore.shared.act("download", song.i) } } label: { Label("Download", systemImage: "arrow.down.circle") } }
                    Spacer()
                    if let url = URL(string: d.siteUrl), !d.siteUrl.isEmpty { Link("Open the file on the site", destination: url) }
                }
            } else {
                Spinner999().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(24)
        .frame(width: 640, height: 560)
        .background(Color(red: 20 / 255, green: 10 / 255, blue: 44 / 255))
        .preferredColorScheme(.dark)
        .task { d = await NativeStore.shared.details(song.i); note = d?.note ?? "" }
    }

    private func facts(_ d: SongDetails) -> [(String, String)] {
        [("Length", d.length), ("Original key", d.key), ("Recorded", d.recordDates), ("Previewed", d.previewDate), ("Released", d.release),
         ("Surfaced", [d.leakDate, d.leakType].filter { !$0.isEmpty }.joined(separator: ", ")), ("Sessions", d.sessions), ("Artists", d.artists),
         ("Producers", d.producers), ("Engineers", d.engineers), ("Studios", d.locations)]
            .map { ($0.0, $0.1.trimmingCharacters(in: .whitespacesAndNewlines)) }.filter { !$0.1.isEmpty }
    }
}

/// Holds the page (the engine) inside the native window, tiny and covered by the interface. It stays in a visible
/// window so WebKit keeps its timers and network at full speed; it draws nothing you can see.
final class EngineHostView: NSView {
    func adopt(_ webView: WKWebView) {
        guard webView.superview !== self else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        webView.alphaValue = 0.01
        addSubview(webView)
    }
}
