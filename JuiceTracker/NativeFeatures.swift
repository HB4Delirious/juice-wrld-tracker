import AppKit
import SwiftUI

// Ratings, rarity, the year in review, the lyrics window and the drive comparison.

// MARK: - Ratings

/// 1–5 hearts for a song (click the same heart again to clear).
struct RatingHearts: View {
    let id: String
    @ObservedObject private var store = NativeStore.shared // redraws when a rating changes
    var size: CGFloat = 16

    var body: some View {
        let rating = EngineState.shared.ratings[id] ?? 0
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { n in
                Button { EngineState.shared.setRating(id, n == rating ? 0 : n) } label: {
                    Image(systemName: n <= rating ? "heart.fill" : "heart").font(.system(size: size))
                        .foregroundColor(n <= rating ? JT.missing : JT.muted.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(n == rating ? "Clear the rating" : "\(n) \(n == 1 ? "heart" : "hearts")")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue(rating == 0 ? "Not rated" : "\(rating) of 5 hearts")
        .accessibilityAdjustableAction { d in
            if d == .increment { EngineState.shared.setRating(id, min(5, rating + 1)) }
            if d == .decrement { EngineState.shared.setRating(id, max(0, rating - 1)) }
        }
    }
}

// MARK: - Rarity

/// "Grail" or "Rare" (unreleased with no file on the site), or nothing.
struct RarityChip: View {
    let song: Song
    var body: some View {
        let state = EngineState.shared
        if state.catalog.indices.contains(song.i), let r = Engine.rarity(state.catalog[song.i], owned: song.o) {
            Text(r.uppercased()).font(JT.body(11, .bold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .foregroundColor(r == "Grail" ? JT.night : JT.mist)
                .background(Capsule().fill(r == "Grail" ? JT.yellowGold : JT.raise))
                .help(r == "Grail" ? "Unreleased, no file on the site, and you have it" : "Unreleased, and the site has no file for it")
        }
    }
}
extension JT { static let yellowGold = Color(red: 1, green: 0.85, blue: 0.3) }

// MARK: - Year in review

/// Your year so far from the app's play history: plays, time listened, top songs and eras, and the busiest month.
struct YearInReviewSection: View {
    @ObservedObject private var store = NativeStore.shared
    @State private var r: Review?

    struct Review { var plays = 0, minutes = 0; var top: [(String, Int)] = [], eras: [(String, Int)] = []; var month = "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your \(String(Calendar.current.component(.year, from: Date()))) so far").font(.headline)
            if let r, r.plays > 0 {
                Text(summary(r))
                HStack(alignment: .top, spacing: 30) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Top songs").font(.subheadline.bold())
                        ForEach(Array(r.top.enumerated()), id: \.offset) { n, t in row(n, t.0, t.1) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Top eras").font(.subheadline.bold())
                        ForEach(Array(r.eras.enumerated()), id: \.offset) { n, t in row(n, t.0, t.1) }
                    }
                }
                .font(.callout)
            } else {
                Text("Nothing played in the app this year yet.").foregroundColor(JT.muted)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).doodled(14)
        .task(id: store.version) { r = review() }
    }

    private func row(_ n: Int, _ name: String, _ plays: Int) -> some View {
        HStack(spacing: 8) { Text("\(n + 1). \(name)").lineLimit(1); Text("\(plays)").foregroundColor(JT.muted) }
    }

    private func summary(_ r: Review) -> String {
        let time = r.minutes >= 120 ? "\((r.minutes / 60).formatted()) hours" : "\(r.minutes) minutes"
        let month = r.month.isEmpty ? "" : " Your busiest month was \(r.month)."
        return "\(r.plays.formatted()) plays, about \(time) of Juice WRLD.\(month)"
    }

    private func review() -> Review {
        let cal = Calendar.current, year = cal.component(.year, from: Date())
        let log = AmbientPlayer.playLog.filter { cal.component(.year, from: $0.at) == year }
        guard !log.isEmpty else { return Review() }
        let catalog = EngineState.shared.catalog
        let paths = Array(Set(log.map(\.path))), songs = EngineRouter.songsFor(paths: paths)
        let songFor = Dictionary(uniqueKeysWithValues: zip(paths, songs))
        var out = Review(plays: log.count)
        var bySong: [Int: Int] = [:], byEra: [String: Int] = [:], byMonth: [Int: Int] = [:], seconds = 0.0
        for e in log {
            byMonth[cal.component(.month, from: e.at), default: 0] += 1
            guard let i = songFor[e.path], i >= 0, catalog.indices.contains(i) else { seconds += 180; continue } // unknown: a typical song
            bySong[i, default: 0] += 1
            byEra[Engine.eraName(catalog[i]), default: 0] += 1
            seconds += Engine.lengthSeconds(catalog[i].length) ?? 180
        }
        out.minutes = Int(seconds / 60)
        out.top = bySong.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5).map { (catalog[$0.key].name, $0.value) }
        out.eras = byEra.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3).map { ($0.key, $0.value) }
        if let m = byMonth.max(by: { $0.value < $1.value })?.key, byMonth.count > 1 { out.month = cal.monthSymbols[m - 1] }
        return out
    }
}

// MARK: - Lyrics

/// A big window with the words of the song playing: the line being sung large, the ones around it dimmed (or the
/// plain lyrics when the site has no timing). Shown live from juicewrldapi.com, never saved.
enum LyricsWindow {
    private static var window: NSWindow?
    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Lyrics"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: LyricsView())
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct LyricsView: View {
    @ObservedObject private var now = NowPlaying.shared

    var body: some View {
        ZStack {
            SkyBackground().ignoresSafeArea()
            if let x = now.extras, !x.synced.isEmpty {
                let n = now.lineIndex ?? -1
                VStack(spacing: 18) {
                    ForEach(max(0, n - 2)...min(x.synced.count - 1, max(n, 0) + 3), id: \.self) { k in
                        Text(x.synced[k].line.isEmpty ? "♪" : x.synced[k].line)
                            .font(k == n ? JT.marker(40) : JT.body(22))
                            .foregroundColor(k == n ? JT.mist : JT.muted.opacity(k < n ? 0.35 : 0.6))
                            .multilineTextAlignment(.center)
                            .shadow(color: k == n ? JT.lavender.opacity(0.6) : .clear, radius: 12)
                    }
                }
                .padding(40)
                .animation(.easeOut(duration: 0.3), value: n)
            } else if let x = now.extras, !x.lyrics.isEmpty {
                ScrollView { Text(x.lyrics).font(JT.body(20)).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(40) }
            } else {
                Text(now.song == nil ? "Play a song to see its lyrics." : "The site has no lyrics for this song.").font(JT.body(18)).foregroundColor(JT.muted)
            }
        }
        .overlay(alignment: .top) {
            if let s = now.song { Text(s.n).font(JT.marker(20)).foregroundColor(JT.lavender).padding(.top, 34) }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 480, minHeight: 360)
    }
}

// MARK: - Compare with another drive

/// Scans a second folder (a backup drive) and shows which songs are only on one of them.
struct DriveCompareCard: View {
    @ObservedObject private var store = NativeStore.shared
    @State private var result: EngineLibrary.Comparison?
    @State private var running = false
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compare with another drive").font(.headline)
            Text("Scans another folder, like a backup drive, and shows the songs that are only on one of them. Nothing on either drive changes.")
                .font(.caption).foregroundColor(JT.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(running ? "Scanning…" : "Choose a folder to compare…") { pick() }.disabled(running || EngineLibrary.shared.root == nil)
                if !status.isEmpty { Text(status).font(.caption).foregroundColor(JT.muted) }
            }
            if let r = result {
                Text("\(r.both.formatted()) songs on both. \(r.onlyHere.count.formatted()) only here, \(r.onlyThere.count.formatted()) only on “\(r.drive)”.").font(.callout)
                list("Only here (not backed up)", r.onlyHere)
                list("Only on “\(r.drive)”", r.onlyThere)
                let fetchable = r.onlyThere.filter { store.songs.indices.contains($0) && store.songs[$0].f }
                if !fetchable.isEmpty {
                    Button("Download the \(fetchable.count) missing here from the site") { EngineDownloads.shared.add(fetchable.map { store.songs[$0].s.id }) }
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading).doodled(14)
    }

    @ViewBuilder private func list(_ title: String, _ songs: [Int]) -> some View {
        if !songs.isEmpty {
            Text(title).font(.caption.bold()).padding(.top, 4)
            Text(songs.prefix(12).compactMap { store.songs.indices.contains($0) ? store.songs[$0].n : nil }.joined(separator: ", ") + (songs.count > 12 ? ", and \(songs.count - 12) more" : ""))
                .font(.caption).foregroundColor(JT.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Compare"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        running = true; result = nil
        Task {
            let r = await EngineLibrary.shared.compare(with: url) { done, total in status = "Reading \(done.formatted()) of \(total.formatted())…" }
            result = r; running = false; status = ""
        }
    }
}
