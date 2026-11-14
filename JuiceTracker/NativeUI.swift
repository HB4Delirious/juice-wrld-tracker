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
    struct Song: Decodable, Hashable, Identifiable { let i: Int; let n: String; let e: String; let c: String; let l: String; let o: Bool; let w: Bool; let f: Bool; var id: Int { i } }
    struct Queue: Decodable, Hashable { let done: Int; let total: Int; let current: String; let waiting: Bool }
    let total: Int
    let have: Int
    let folder: String
    let queue: Queue?
    let cats: [Cat]
    let eras: [Era]
    let songs: [Song]
}

struct SongDetails: Decodable {
    let name, era, category, length, key, recordDates, previewDate, release, leakDate, leakType, sessions: String
    let artists, producers, engineers, locations, notes, info, alt, siteUrl: String
    let files: [String]
    let playable: Bool
}

final class NativeStore: NSObject, ObservableObject, WKScriptMessageHandler {
    static let shared = NativeStore()
    @Published var state: NState?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let json = message.body as? String else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let decoded = try? JSONDecoder().decode(NState.self, from: Data(json.utf8)) else { return }
            DispatchQueue.main.async { self.state = decoded }
        }
    }

    /// Runs an action in the page (wish, download, play, details, refresh) and returns its text result.
    @MainActor @discardableResult func act(_ op: String, _ i: Int = -1) async -> String {
        let result = try? await WebViewStore.shared.webView.callAsyncJavaScript(
            "return await (window.jwNativeAction ? window.jwNativeAction(a) : '')", arguments: ["a": ["op": op, "i": i]], contentWorld: .page)
        return result as? String ?? ""
    }

    @MainActor func details(_ i: Int) async -> SongDetails? {
        let json = await act("details", i)
        return try? JSONDecoder().decode(SongDetails.self, from: Data(json.utf8))
    }

    /// Opens a screen that hasn't moved over yet in the classic window.
    @MainActor func openClassic(_ view: String) {
        AppDelegate.shared?.showMainWindow()
        WebViewStore.shared.webView.evaluateJavaScript("showView('\(view)')")
    }
}

// MARK: - The sky, drawn by Core Animation (it runs on the graphics chip, not in the app)

final class SkyNSView: NSView {
    private var builtFor: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 7 / 255, green: 4 / 255, blue: 15 / 255, alpha: 1).cgColor
        let nc = NotificationCenter.default
        // Paused while the app is in the background: nothing to see, nothing to spend.
        nc.addObserver(self, selector: #selector(pause), name: NSApplication.didResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(resume), name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        guard bounds.size != builtFor, bounds.width > 0 else { return }
        builtFor = bounds.size
        build()
    }

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

        let night = CAGradientLayer()
        night.frame = b
        night.colors = [NSColor(srgbRed: 42 / 255, green: 12 / 255, blue: 62 / 255, alpha: 1).cgColor,
                        NSColor(srgbRed: 22 / 255, green: 10 / 255, blue: 51 / 255, alpha: 1).cgColor,
                        NSColor(srgbRed: 7 / 255, green: 4 / 255, blue: 15 / 255, alpha: 1).cgColor]
        night.locations = [0, 0.45, 1]
        root.addSublayer(night)

        // nebula glows that breathe slowly
        let glows: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
            (0.52, 0.66, 0.42, NSColor(srgbRed: 232 / 255, green: 110 / 255, blue: 70 / 255, alpha: 0.30)),
            (0.06, 0.30, 0.50, NSColor(srgbRed: 214 / 255, green: 48 / 255, blue: 140 / 255, alpha: 0.42)),
            (0.88, 0.86, 0.45, NSColor(srgbRed: 80 / 255, green: 130 / 255, blue: 255 / 255, alpha: 0.32)),
            (0.70, 0.10, 0.60, NSColor(srgbRed: 140 / 255, green: 40 / 255, blue: 190 / 255, alpha: 0.36)),
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

        // twinkling sparkles
        let sparkles = CALayer()
        sparkles.frame = b
        sparkles.backgroundColor = NSColor(patternImage: Self.sparkleTile()).cgColor
        let twinkle = CABasicAnimation(keyPath: "opacity")
        twinkle.fromValue = 0.15
        twinkle.toValue = 1
        twinkle.duration = 3.8
        twinkle.autoreverses = true
        twinkle.repeatCount = .infinity
        twinkle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sparkles.add(twinkle, forKey: "twinkle")
        root.addSublayer(sparkles)

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
        let field = CALayer()
        field.frame = CGRect(x: 0, y: 0, width: bounds.width + tile, height: bounds.height + tile)
        field.backgroundColor = NSColor(patternImage: Self.starTile(size: tile, count: count, seed: seed, alpha: alpha)).cgColor
        root.addSublayer(field)
        let drift = CABasicAnimation(keyPath: "position")
        drift.fromValue = field.position
        drift.toValue = CGPoint(x: field.position.x - tile, y: field.position.y - tile)
        drift.duration = seconds
        drift.repeatCount = .infinity
        drift.timingFunction = CAMediaTimingFunction(name: .linear)
        field.add(drift, forKey: "drift")
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

// MARK: - Look

enum JT {
    static let lavender = Color(red: 1, green: 106 / 255, blue: 213 / 255)
    static let have = Color(red: 201 / 255, green: 242 / 255, blue: 74 / 255)
    static let missing = Color(red: 1, green: 93 / 255, blue: 108 / 255)
    static let muted = Color(red: 195 / 255, green: 178 / 255, blue: 227 / 255)
    static let line = Color(red: 190 / 255, green: 150 / 255, blue: 1).opacity(0.25)
    static let rainbow = LinearGradient(colors: [Color(red: 1, green: 0.36, blue: 0.42), Color(red: 1, green: 0.63, blue: 0.29), Color(red: 1, green: 0.88, blue: 0.29),
                                                 Color(red: 0.79, green: 0.95, blue: 0.29), Color(red: 0.31, green: 0.85, blue: 1), Color(red: 0.72, green: 0.48, blue: 1),
                                                 Color(red: 1, green: 0.42, blue: 0.84)], startPoint: .leading, endPoint: .trailing)
    static func marker(_ size: CGFloat) -> Font { .custom("Marker Felt", size: size).weight(.bold) }
}

/// A frosted panel with a slightly uneven, hand-drawn outline.
struct Doodled: ViewModifier {
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(red: 24 / 255, green: 12 / 255, blue: 52 / 255).opacity(0.72)))
            .overlay(RoundedRectangle(cornerRadius: radius + 2, style: .continuous).stroke(JT.line, lineWidth: 1.5).rotationEffect(.degrees(0.25)))
    }
}
extension View { func doodled(_ radius: CGFloat = 16) -> some View { modifier(Doodled(radius: radius)) } }

// MARK: - Window

enum NativePage: String, CaseIterable, Identifiable {
    case collection, fixer, dups, health, people, stats, timeline, trivia, export
    var id: String { rawValue }
    var title: String {
        ["collection": "Collection", "fixer": "Tag fixer", "dups": "Duplicates", "health": "File health", "people": "Credits",
         "stats": "Stats", "timeline": "Timeline", "trivia": "Trivia", "export": "Export & backup"][rawValue] ?? rawValue
    }
    var icon: String {
        ["collection": "smallcircle.filled.circle", "fixer": "tag", "dups": "square.on.square", "health": "waveform.path.ecg", "people": "person.2",
         "stats": "chart.bar", "timeline": "point.3.connected.trianglepath.dotted", "trivia": "questionmark.circle", "export": "archivebox"][rawValue] ?? "circle"
    }
    var isNative: Bool { self == .collection }
}

struct NativeRoot: View {
    @ObservedObject private var store = NativeStore.shared
    @State private var page: NativePage = .collection

    var body: some View {
        ZStack {
            SkyBackground().ignoresSafeArea()
            HStack(spacing: 0) {
                sidebar.frame(width: 210)
                Group {
                    if let s = store.state { CollectionScreen(state: s) } else { loading }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .task { await store.act("refresh") }
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Waiting for your catalog and music folder…").foregroundColor(JT.muted)
            Button("Open the classic window") { store.openClassic("collection") }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundColor(JT.lavender)
                Text("Juice\nTracker").font(JT.marker(22)).lineSpacing(-4)
            }
            .padding(.top, 34).padding(.bottom, 18).padding(.horizontal, 10)
            ForEach(NativePage.allCases) { p in
                Button {
                    if p.isNative { page = p } else { store.openClassic(p.rawValue) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: p.icon).frame(width: 18)
                        Text(p.title)
                        Spacer()
                        if !p.isNative { Image(systemName: "arrow.up.forward.square").font(.caption).foregroundColor(JT.muted.opacity(0.7)).help("Opens in the classic window for now") }
                    }
                    .padding(.vertical, 7).padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(page == p ? JT.lavender.opacity(0.18) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(page == p ? .white : JT.muted)
            }
            Spacer()
            if let q = store.state?.queue {
                VStack(alignment: .leading, spacing: 5) {
                    Text(q.waiting ? "Waiting for the music drive…" : "Downloading \(min(q.done + 1, q.total)) of \(q.total)").font(.caption)
                    if !q.current.isEmpty { Text(q.current).font(.caption2).foregroundColor(JT.muted).lineLimit(1) }
                    ProgressView(value: Double(q.done), total: Double(max(q.total, 1))).tint(JT.have)
                }
                .padding(10).doodled(10)
            }
            Text("Native preview (beta). Screens marked ↗ open in the classic window.")
                .font(.caption2).foregroundColor(JT.muted.opacity(0.8)).padding(.horizontal, 6).padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
        .background(Color.black.opacity(0.25))
    }
}

// MARK: - Collection

struct CollectionScreen: View {
    let state: NState
    @State private var tab = "all"
    @State private var query = ""
    @State private var era: String?
    @State private var limit = 200
    @State private var open: NState.Song?

    private var songs: [NState.Song] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return state.songs.filter { s in
            (era == nil || s.e == era) &&
            (tab == "all" || (tab == "have" && s.o) || (tab == "missing" && !s.o) || (tab == "wish" && s.w)) &&
            (q.isEmpty || s.n.lowercased().contains(q) || s.e.lowercased().contains(q))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                scoreboard
                eras
                songList
            }
            .padding(.horizontal, 34).padding(.top, 40).padding(.bottom, 60)
            .frame(maxWidth: 1080, alignment: .leading)
        }
        .sheet(item: $open) { s in SongCard(opened: s, close: { open = nil }) }
    }

    private var scoreboard: some View {
        VStack(alignment: .leading, spacing: 18) {
            (Text("You have ") + Text("\(state.have)").foregroundColor(JT.have) + Text(" of \(state.total) songs").foregroundColor(JT.muted))
                .font(JT.marker(46))
                .rotationEffect(.degrees(-1.2), anchor: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(JT.rainbow).frame(width: max(12, g.size.width * CGFloat(state.have) / CGFloat(max(state.total, 1))))
                }
            }
            .frame(height: 12)
            .animation(.easeOut(duration: 0.9), value: state.have)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                ForEach(state.cats, id: \.self) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(c.name); Spacer(); Text("\(c.have) / \(c.total)").foregroundColor(JT.muted) }.font(.callout)
                        ProgressView(value: Double(c.have), total: Double(max(c.total, 1))).tint(JT.have)
                    }
                    .padding(12).doodled(12)
                }
            }
        }
    }

    private var eras: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Eras").font(JT.marker(28))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                ForEach(state.eras) { e in
                    Button { era = era == e.name ? nil : e.name; limit = 200 } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(e.name).font(.headline)
                            if !e.time.isEmpty { Text(e.time).font(.caption).foregroundColor(JT.muted) }
                            if !e.desc.isEmpty { Text(e.desc).font(.caption).foregroundColor(JT.muted).lineLimit(2) }
                            Spacer(minLength: 6)
                            ProgressView(value: Double(e.have), total: Double(max(e.total, 1))).tint(JT.have)
                            Text("\(e.have) of \(e.total) songs").font(.caption).foregroundColor(JT.muted)
                        }
                        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
                        .padding(14)
                        .doodled(14)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(JT.lavender, lineWidth: era == e.name ? 2.5 : 0))
                    }
                    .buttonStyle(HoverLift())
                }
            }
        }
    }

    private var songList: some View {
        let list = songs
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("", selection: $tab) {
                    Text("All").tag("all"); Text("In your library").tag("have"); Text("Not in your library").tag("missing"); Text("Wishlist").tag("wish")
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 460)
                TextField("Search songs or eras", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                if let era { Button { self.era = nil } label: { Label(era, systemImage: "xmark.circle.fill") }.buttonStyle(.borderless) }
            }
            Text("\(list.count) songs").font(.caption).foregroundColor(JT.muted)
            LazyVStack(spacing: 0) {
                ForEach(list.prefix(limit)) { s in SongRow(song: s, open: { open = s }) }
            }
            .doodled(14)
            if list.count > limit { Button("Show more") { limit += 300 }.buttonStyle(.borderless) }
        }
        .onChange(of: query) { _ in limit = 200 }
        .onChange(of: tab) { _ in limit = 200 }
    }
}

struct HoverLift: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Lifted(configuration: configuration) }
    struct Lifted: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .offset(y: hover ? -3 : 0)
                .rotationEffect(.degrees(hover ? -0.4 : 0))
                .shadow(color: JT.lavender.opacity(hover ? 0.3 : 0), radius: 14, y: 8)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hover)
                .onHover { hover = $0 }
        }
    }
}

struct SongRow: View {
    let song: NState.Song
    let open: () -> Void
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
                    Text(song.e).foregroundColor(JT.muted).lineLimit(1).frame(width: 110, alignment: .leading)
                    Text(song.c).foregroundColor(JT.muted).lineLimit(1).frame(width: 130, alignment: .leading)
                    Text(song.l).foregroundColor(JT.muted).frame(width: 44, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            status.frame(width: 120, alignment: .leading)
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
    let opened: NState.Song
    let close: () -> Void
    @ObservedObject private var store = NativeStore.shared
    @State private var d: SongDetails?
    /// The latest snapshot of this song (the wishlist star and library status change while the card is open).
    private var song: NState.Song { store.state?.songs.first { $0.i == opened.i } ?? opened }

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
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(24)
        .frame(width: 640, height: 560)
        .background(Color(red: 20 / 255, green: 10 / 255, blue: 44 / 255))
        .preferredColorScheme(.dark)
        .task { d = await NativeStore.shared.details(song.i) }
    }

    private func facts(_ d: SongDetails) -> [(String, String)] {
        [("Length", d.length), ("Original key", d.key), ("Recorded", d.recordDates), ("Previewed", d.previewDate), ("Released", d.release),
         ("Surfaced", [d.leakDate, d.leakType].filter { !$0.isEmpty }.joined(separator: ", ")), ("Sessions", d.sessions), ("Artists", d.artists),
         ("Producers", d.producers), ("Engineers", d.engineers), ("Studios", d.locations)]
            .map { ($0.0, $0.1.trimmingCharacters(in: .whitespacesAndNewlines)) }.filter { !$0.1.isEmpty }
    }
}
