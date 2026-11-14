import SwiftUI

// SwiftUI stage 2: Timeline, Stats and Credits. All read-only, drawn from the songs in the page's snapshot.

private func monthLabel(_ m: Int) -> String {
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][m % 12] + " \(m / 12)"
}

private struct Legend: View {
    let items: [(String, Color)]
    var body: some View {
        HStack(spacing: 16) {
            ForEach(items, id: \.0) { label, color in
                HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10); Text(label) }
            }
        }
        .font(.caption).foregroundColor(JT.muted)
    }
}

// MARK: - Timeline

struct TimelineScreen: View {
    let songs: [Song]

    var body: some View {
        let dated = songs.filter { $0.s.m != nil }
        let byMonth = Dictionary(grouping: dated) { $0.s.m! }
        let first = byMonth.keys.min() ?? 0, last = byMonth.keys.max() ?? 0
        let have = dated.filter(\.o).count
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(text: "Timeline")
                if dated.isEmpty {
                    Text("No recording dates in the catalog yet.").foregroundColor(JT.muted)
                } else {
                    (Text("Recorded \(monthLabel(first)) to \(monthLabel(last)). You have ") + Text("\(have)").bold().foregroundColor(JT.have)
                        + Text(" of the \(dated.count) songs with a recording month. \(songs.count - dated.count) more have no exact month."))
                        .foregroundColor(JT.muted)
                    Legend(items: [("In your library", JT.have), ("Not in your library", JT.muted.opacity(0.4))])
                    ScrollView(.horizontal, showsIndicators: true) {
                        LazyHStack(alignment: .bottom, spacing: 3) {
                            ForEach(first...last, id: \.self) { m in MonthColumn(month: m, songs: (byMonth[m] ?? []).sorted { $0.o && !$1.o }) }
                        }
                        .padding(14)
                    }
                    .frame(height: 300)
                    .doodled(14)
                    Text("Each dot is a song, placed in the month it was recorded. Scroll sideways; click a dot to open the song.")
                        .font(.caption).foregroundColor(JT.muted)
                }
            }
            .padding(.horizontal, 34).padding(.top, 40).padding(.bottom, 60)
            .frame(maxWidth: 1080, alignment: .leading)
        }
    }
}

private struct MonthColumn: View {
    let month: Int
    let songs: [Song]
    private let perColumn = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(stride(from: 0, to: songs.count, by: perColumn)), id: \.self) { start in
                    VStack(spacing: 2) {
                        ForEach(songs[start..<min(start + perColumn, songs.count)].reversed()) { s in Dot(song: s, month: month) }
                    }
                }
            }
            .frame(minWidth: songs.isEmpty ? 3 : 9, alignment: .leading)
            Text(verbatim: month % 12 == 0 ? String(month / 12) : " ").font(.caption2.bold()).foregroundColor(JT.muted).fixedSize()
        }
        .padding(.leading, month % 12 == 0 ? 10 : 0)
        .overlay(alignment: .leading) { if month % 12 == 0 { Rectangle().fill(JT.line).frame(width: 1) } }
    }
}

private struct Dot: View {
    let song: Song
    let month: Int
    @State private var hover = false
    var body: some View {
        Circle()
            .fill(hover ? JT.lavender : song.o ? JT.have : JT.muted.opacity(0.3))
            .frame(width: 9, height: 9)
            .shadow(color: song.o ? JT.have.opacity(0.6) : .clear, radius: 3)
            .scaleEffect(hover ? 1.6 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: hover)
            .onHover { hover = $0 }
            .onTapGesture { NativeStore.shared.openSong = song }
            .help("\(song.n), \(monthLabel(month))\(song.o ? " (in your library)" : "")")
    }
}

// MARK: - Stats

/// Vertical bars per year; each year can have several series side by side, or stacked.
private struct YearBars: View {
    let years: [Int]
    let values: [Int: [Int]]  // year -> one count per series
    let colors: [Color]
    var stacked = false

    var body: some View {
        let peak = max(1, years.map { y in stacked ? (values[y] ?? []).reduce(0, +) : (values[y] ?? []).max() ?? 0 }.max() ?? 1)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: stacked ? 10 : 14) {
                ForEach(years, id: \.self) { y in
                    let v = values[y] ?? Array(repeating: 0, count: colors.count)
                    VStack(spacing: 4) {
                        Text("\(stacked ? v.reduce(0, +) : v.max() ?? 0)").font(.caption2).foregroundColor(JT.muted)
                        if stacked {
                            VStack(spacing: 0) {
                                ForEach(Array(v.enumerated().reversed()), id: \.offset) { n, count in
                                    Rectangle().fill(colors[n]).frame(width: 26, height: CGFloat(count) / CGFloat(peak) * 170)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        } else {
                            HStack(alignment: .bottom, spacing: 2) {
                                ForEach(Array(v.enumerated()), id: \.offset) { n, count in
                                    RoundedRectangle(cornerRadius: 3).fill(colors[n]).frame(width: 9, height: max(2, CGFloat(count) / CGFloat(peak) * 170))
                                        .help("\(count)")
                                }
                            }
                        }
                        Text(String(y)).font(.caption2).foregroundColor(JT.muted)
                    }
                }
            }
            .frame(height: 220, alignment: .bottom)
            .padding(14)
        }
        .doodled(14)
    }
}

struct StatsScreen: View {
    let state: NState
    let songs: [Song]

    var body: some View {
        let recorded = yearly { $0.s.ry.map { y in (y, 0) } }
        let recordedHave = yearly { s in s.o ? s.s.ry.map { ($0, 0) } : [] }
        let recYears = span(recorded.keys)
        let recValues = Dictionary(uniqueKeysWithValues: recYears.map { y in (y, [recordedHave[y]?[0] ?? 0, (recorded[y]?[0] ?? 0) - (recordedHave[y]?[0] ?? 0)]) })
        let events = yearly { s in [s.s.py.map { ($0, 0) }, s.s.sy.map { ($0, 1) }, s.s.rl.map { ($0, 2) }].compactMap { $0 } }
        let eventYears = span(events.keys)
        let released = songs.filter { $0.s.rl != nil }.count
        let allYears = recorded.keys.sorted()
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ScreenTitle(text: "Stats")
                (Text("\(state.total)").bold() + Text(" songs")
                    + Text(allYears.isEmpty ? "" : ", recorded \(String(allYears.first!)) to \(String(allYears.last!))")
                    + Text(". You have ") + Text("\(state.have)").bold().foregroundColor(JT.have)
                    + Text(" (\(Int((Double(state.have) / Double(max(state.total, 1)) * 100).rounded()))%). \(released) officially released."))
                    .font(.title3)

                Text("Songs per era").font(.headline)
                VStack(spacing: 6) {
                    let peak = max(1, state.eras.map(\.total).max() ?? 1)
                    ForEach(state.eras.filter { $0.total > 0 }) { e in
                        HStack(spacing: 12) {
                            Text(e.name).lineLimit(1).frame(width: 170, alignment: .leading)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.08)).frame(width: g.size.width * CGFloat(e.total) / CGFloat(peak))
                                    Capsule().fill(JT.have).frame(width: g.size.width * CGFloat(e.have) / CGFloat(peak))
                                }
                            }
                            .frame(height: 10)
                            Text("\(e.have) / \(e.total)").font(.caption.monospacedDigit()).foregroundColor(JT.muted).frame(width: 74, alignment: .trailing)
                        }
                        .font(.callout)
                    }
                }
                .padding(14).doodled(14)

                Text("Songs recorded by year").font(.headline)
                Legend(items: [("In your library", JT.have), ("Not in your library", JT.lavender.opacity(0.75))])
                YearBars(years: recYears, values: recValues, colors: [JT.have, JT.lavender.opacity(0.75)], stacked: true)
                Text("A song recorded across several years counts in each of them.").font(.caption).foregroundColor(JT.muted)

                Text("Previews, surfaced songs and releases by year").font(.headline)
                Legend(items: [("Previewed", Color(red: 1, green: 0.63, blue: 0.29)), ("Surfaced", JT.missing), ("Released", JT.have)])
                YearBars(years: eventYears, values: events, colors: [Color(red: 1, green: 0.63, blue: 0.29), JT.missing, JT.have])
                Text("Listening stats from Plex are in the classic window's Stats for now.").font(.caption).foregroundColor(JT.muted)
            }
            .padding(.horizontal, 34).padding(.top, 40).padding(.bottom, 60)
            .frame(maxWidth: 1080, alignment: .leading)
        }
    }

    /// Counts per year and series: each song gives (year, series) pairs.
    private func yearly(_ pairs: (Song) -> [(Int, Int)]) -> [Int: [Int]] {
        var out: [Int: [Int]] = [:]
        for s in songs {
            for (y, n) in pairs(s) {
                var row = out[y] ?? [0, 0, 0]
                row[n] += 1
                out[y] = row
            }
        }
        return out
    }

    /// Every year from the first to the last, so gaps show (unless the range is implausibly long).
    private func span(_ years: Dictionary<Int, [Int]>.Keys) -> [Int] {
        guard let lo = years.min(), let hi = years.max() else { return [] }
        return hi - lo > 40 ? years.sorted() : Array(lo...hi)
    }
}

// MARK: - Credits

struct CreditsScreen: View {
    let songs: [Song]
    @State private var role = "pr"
    @State private var query = ""
    @State private var picked: String?
    @State private var limit = 150

    private struct Person: Identifiable { let id: String; let name: String; var songs: [Song] }

    private var people: [Person] {
        var map: [String: Person] = [:]
        for s in songs {
            let names: [String] = role == "pr" ? s.s.pr : role == "ar" ? s.s.ar : role == "en" ? s.s.en : s.s.st
            for n in Set(names) {
                let key = n.lowercased()
                if role == "ar", key == "juice wrld" { continue } // he's on everything
                map[key, default: Person(id: key, name: n, songs: [])].songs.append(s)
            }
        }
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return map.values.filter { q.isEmpty || $0.id.contains(q) }.sorted { $0.songs.count != $1.songs.count ? $0.songs.count > $1.songs.count : $0.name < $1.name }
    }

    var body: some View {
        let list = people
        let selected = list.first { $0.id == picked }
        return VStack(alignment: .leading, spacing: 18) {
            ScreenTitle(text: "Credits")
            HStack(spacing: 12) {
                Picker("", selection: $role) {
                    Text("Producers").tag("pr"); Text("Artists").tag("ar"); Text("Engineers").tag("en"); Text("Studios").tag("st")
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                TextField("Search names", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            }
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(list.prefix(limit).enumerated()), id: \.element.id) { rank, p in
                            Button { picked = p.id } label: {
                                HStack {
                                    Text("\(rank + 1)").font(.caption.monospacedDigit()).foregroundColor(JT.muted).frame(width: 30, alignment: .trailing)
                                    Text(p.name).lineLimit(1)
                                    Spacer()
                                    Text("\(p.songs.filter(\.o).count) / \(p.songs.count)").font(.caption.monospacedDigit()).foregroundColor(JT.muted)
                                }
                                .padding(.vertical, 7).padding(.horizontal, 10)
                                .background(picked == p.id ? JT.lavender.opacity(0.18) : .clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if list.count > limit { Button("Show more") { limit += 200 }.buttonStyle(.borderless).padding(10) }
                        if list.isEmpty { Text("Nobody matches that name.").foregroundColor(JT.muted).padding(10) }
                    }
                }
                .frame(width: 340)
                .doodled(14)

                VStack(alignment: .leading, spacing: 10) {
                    if let p = selected {
                        Text(p.name).font(JT.marker(28))
                        Text("\(p.songs.count) songs, \(p.songs.filter(\.o).count) in your library").foregroundColor(JT.muted)
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(p.songs.sorted { $0.n < $1.n }) { s in SongRow(song: s, open: { NativeStore.shared.openSong = s }, compact: true) }
                            }
                        }
                        .doodled(14)
                    } else {
                        Text("Pick a name to see their songs. The numbers show how many you have of how many they're credited on.")
                            .foregroundColor(JT.muted).padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 34).padding(.top, 40).padding(.bottom, 24)
        .frame(maxWidth: 1180, alignment: .topLeading)
        .onChange(of: role) { _ in picked = nil; limit = 150 }
    }
}
