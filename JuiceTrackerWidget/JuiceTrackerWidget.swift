import SwiftUI
import WidgetKit

// The desktop widget: your collection count, what's playing and "On this day". The app writes a small summary to
// ~/Library/Application Support/JuiceTracker/<app id>/widget.json; the widget (sandboxed) may read only that folder.

struct WidgetSummary: Codable {
    var have = 0
    var total = 0
    var playing: String?
    var today: String?
}

struct Entry: TimelineEntry {
    let date: Date
    let summary: WidgetSummary
}

struct Provider: TimelineProvider {
    /// The real home folder (inside the sandbox, NSHomeDirectory() is the widget's own container).
    private var file: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        let appID = (Bundle.main.bundleIdentifier ?? "com.hb4delirious.JuiceTracker.Widget").replacingOccurrences(of: ".Widget", with: "")
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/JuiceTracker/\(appID)/widget.json")
    }
    private func read() -> WidgetSummary {
        (try? JSONDecoder().decode(WidgetSummary.self, from: Data(contentsOf: file))) ?? WidgetSummary()
    }
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), summary: WidgetSummary(have: 772, total: 2777, playing: "Lucid Dreams", today: nil)) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: Date(), summary: read())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: Date(), summary: read())], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct WidgetView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family
    private let lime = Color(red: 201 / 255, green: 242 / 255, blue: 74 / 255)
    private let pink = Color(red: 1, green: 106 / 255, blue: 213 / 255)
    private let muted = Color(red: 195 / 255, green: 178 / 255, blue: 227 / 255)
    private var rainbow: LinearGradient {
        LinearGradient(colors: [Color(red: 1, green: 0.36, blue: 0.42), Color(red: 1, green: 0.63, blue: 0.29), Color(red: 1, green: 0.88, blue: 0.29),
                                lime, Color(red: 0.31, green: 0.85, blue: 1), Color(red: 0.72, green: 0.48, blue: 1), pink], startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        let s = entry.summary
        let pct = s.total > 0 ? Double(s.have) / Double(s.total) : 0
        VStack(alignment: .leading, spacing: 6) {
            Text("JUICE TRACKER").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundColor(pink)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(s.have)").font(.system(size: family == .systemSmall ? 30 : 34, weight: .black, design: .rounded)).foregroundStyle(rainbow)
                Text("of \(s.total)").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(muted)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(rainbow).frame(width: max(6, g.size.width * pct))
                }
            }
            .frame(height: 6)
            Text("\(Int((pct * 100).rounded()))% collected").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(lime)
            Spacer(minLength: 0)
            if let p = s.playing, !p.isEmpty {
                Label(p, systemImage: "music.note").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(.white).lineLimit(1)
            }
            if family != .systemSmall, let t = s.today, !t.isEmpty {
                Text("On this day: \(t)").font(.system(size: 11, design: .rounded)).foregroundColor(muted).lineLimit(2)
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 7 / 255, green: 4 / 255, blue: 15 / 255), Color(red: 42 / 255, green: 12 / 255, blue: 62 / 255)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

@main
struct JuiceTrackerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JuiceTrackerWidget", provider: Provider()) { WidgetView(entry: $0) }
            .configurationDisplayName("Juice Tracker")
            .description("Your Juice WRLD collection, what's playing, and songs from this day.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
