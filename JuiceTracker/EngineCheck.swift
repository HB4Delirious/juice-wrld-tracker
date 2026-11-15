import AppKit
import SwiftUI

// Stage 1 of replacing the HTML engine: copy the folder settings and tag cache out of the web view, then run the Swift engine on
// your real catalog and music folder and compare every answer with the page's. Nothing here writes to your music,
// and the page stays in charge until the Swift engine matches it.

/// Where the Swift engine keeps its files: ~/Library/Application Support/JuiceTracker/<app id>/engine/.
enum EngineFiles {
    static var dir: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/JuiceTracker/\(Bundle.main.bundleIdentifier ?? "com.hb4delirious.JuiceTracker")/engine")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func write(_ name: String, _ data: Data) throws { try data.write(to: dir.appendingPathComponent(name), options: .atomic) }
    static func read(_ name: String) -> Data? { try? Data(contentsOf: dir.appendingPathComponent(name)) }

    /// The tag cache in the engine's format (path → size, date, tags).
    static func tagCache() -> [String: Engine.CachedTags] {
        read("tags.json").flatMap { try? JSONDecoder().decode([String: Engine.CachedTags].self, from: $0) } ?? [:]
    }
}

@MainActor final class EngineCheck: ObservableObject {
    static let shared = EngineCheck()
    @Published var lines: [String] = []
    @Published var running = false
    @Published var verdict: String?
    private var window: NSWindow?

    static func show() {
        let c = shared
        if c.window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Check Swift Engine"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: EngineCheckView())
            w.center()
            c.window = w
        }
        c.window?.makeKeyAndOrderFront(nil)
        if !c.running && c.verdict == nil { Task { await c.run() } }
    }

    private func say(_ s: String) { lines.append(s) }

    func run() async {
        running = true; verdict = nil; lines = []
        defer { running = false }
        let store = NativeStore.shared
        var problems = 0, report: [String: Any] = [:]
        do {
            // 1. Saved data, copied out of the web view.
            say("Reading the folder settings…")
            let export = try await store.tryAct("engineExport")
            guard let ex = try JSONSerialization.jsonObject(with: Data(export.utf8)) as? [String: Any] else { throw EngineError("The page gave no saved data.") }
            // (the catalog, wishlist and notes are Swift's own since stage 2; see EngineState)
            try EngineFiles.write("settings.json", JSONSerialization.data(withJSONObject: ["onlyJuice": ex["onlyJuice"] ?? true, "root": ex["root"] ?? ""]))
            let cache = EngineFiles.tagCache() // Swift's own since stage 4b (see EngineLibrary)
            say("  \(cache.count) cached tags, in \(EngineFiles.dir.path).")

            // 2. The page's answers.
            let parityRaw = try await store.tryAct("engineParity")
            guard let parity = try JSONSerialization.jsonObject(with: Data(parityRaw.utf8)) as? [String: Any] else { throw EngineError("The page gave no results.") }
            let pageCatalog = (parity["catalog"] as? [[String: Any]] ?? []).map(Engine.cleanSong)
            let pageLibrary = try JSONDecoder().decode([LibraryFile].self, from: JSONSerialization.data(withJSONObject: parity["library"] ?? []))
            let overrides = (parity["overrides"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            var pageOwned: [Int: [String]] = [:]
            for pair in parity["owned"] as? [[Any]] ?? [] { if let i = (pair.first as? NSNumber)?.intValue { pageOwned[i] = pair.last as? [String] ?? [] } }
            guard !pageCatalog.isEmpty else { throw EngineError("Load the catalog first, then run the check again.") }

            // 3. Catalog: fetch it in Swift and have the page clean the very same songs.
            say("Downloading the catalog in Swift…")
            let fetched = try await Engine.fetchCatalog { n, total in
                Task { @MainActor in self.progress("  \(n) of \(total.map(String.init) ?? "?") songs") }
            }
            let cleanedRaw = try await store.tryAct("engineClean", -1, ["raw": String(decoding: JSONSerialization.data(withJSONObject: fetched.raw), as: UTF8.self)])
            let pageClean = (try JSONSerialization.jsonObject(with: Data(cleanedRaw.utf8)) as? [[String: Any]]) ?? []
            var catalogDiffs: [String] = []
            for (n, raw) in fetched.raw.enumerated() where n < pageClean.count {
                let mine = Self.dict(Engine.cleanSong(raw)), page = pageClean[n]
                for k in Set(mine.keys).union(page.keys) where !Self.same(mine[k], page[k]) { catalogDiffs.append("\(page["name"] ?? "?") \(k): Swift \(mine[k] ?? "nil"), page \(page[k] ?? "nil")") }
            }
            if pageClean.count != fetched.raw.count { catalogDiffs.append("page cleaned \(pageClean.count) songs, Swift \(fetched.raw.count)") }
            problems += catalogDiffs.count
            report["catalog"] = Array(catalogDiffs.prefix(200))
            say(catalogDiffs.isEmpty ? "✓ Catalog: all \(fetched.songs.count) songs read the same in Swift and the page." : "✗ Catalog: \(catalogDiffs.count) differences, e.g. \(catalogDiffs[0])")
            let newIds = Set(fetched.songs.map(\.id)).subtracting(pageCatalog.map(\.id)).count
            if newIds > 0 { say("  (The site has \(newIds) songs the page hasn't loaded yet. That's not a difference, just a newer catalog.)") }

            // 4. Folder scan: the cached tags, plus a fresh read of a sample of files.
            let settings = (EngineFiles.read("settings.json").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            let rootPath = settings["root"] as? String ?? ""
            if rootPath.isEmpty { say("– Folder scan: skipped, no music folder is chosen.") } else {
                say("Scanning your music folder in Swift…")
                let root = URL(fileURLWithPath: rootPath)
                let scan = await Engine.scan(root: root, onlyJuice: settings["onlyJuice"] as? Bool ?? true, cache: cache, reread: false) { done, total in
                    Task { @MainActor in self.progress("  \(done) of \(total) files") }
                }
                let mine = Dictionary(scan.files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
                let page = Dictionary(pageLibrary.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
                var scanDiffs: [String] = []
                for p in Set(page.keys).subtracting(mine.keys).sorted() { scanDiffs.append("only the page has \(p)") }
                for p in Set(mine.keys).subtracting(page.keys).sorted() { scanDiffs.append("only Swift has \(p)") }
                for (p, a) in mine { if let b = page[p], (a.title, a.key, a.stem, a.fromTags) != (b.title, b.key, b.stem, b.fromTags) {
                    scanDiffs.append("\(p): Swift \"\(a.title)\" (\(a.key)), page \"\(b.title)\" (\(b.key))") } }
                problems += scanDiffs.count
                report["scan"] = Array(scanDiffs.prefix(200))
                say(scanDiffs.isEmpty ? "✓ Folder scan: the same \(mine.count) files, titles and match keys." : "✗ Folder scan: \(scanDiffs.count) differences, e.g. \(scanDiffs[0])")

                // Tag reading on real files: read a sample fresh and compare with what the page read.
                let sample = Array(pageLibrary.filter { !$0.tags.isEmpty }.shuffled().prefix(30))
                say("Reading tags of \(sample.count) of your files in Swift…")
                var tagDiffs: [String] = [], stale: [String] = []
                let parent = root.deletingLastPathComponent()
                for f in sample {
                    let url = parent.appendingPathComponent(f.path)
                    let got = await Task.detached { TagReader.read(url, ext: f.ext) }.value
                    guard got != f.tags else { continue }
                    // The page trusts its tag cache without looking at the file; a file changed since then isn't a difference.
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                    if let cached = cache[f.path], let size, cached.size != size { stale.append(f.path) }
                    else { tagDiffs.append("\(f.path): Swift \(got), page \(f.tags)") }
                }
                problems += tagDiffs.count
                report["tags"] = tagDiffs
                report["staleCache"] = stale
                say(tagDiffs.isEmpty ? "✓ Tags: \(sample.count - stale.count) files read the same." : "✗ Tags: \(tagDiffs.count) files read differently, e.g. \(tagDiffs[0])")
                if !stale.isEmpty { say("  (\(stale.count) changed since the page last read them, so its cached tags are out of date. Rescan folder fixes that.)") }
            }

            // 5. Matching: the Swift matcher on the page's own catalog and files.
            say("Matching in Swift…")
            let started = Date()
            let match = Engine.match(catalog: pageCatalog, files: pageLibrary, overrides: overrides)
            let took = Date().timeIntervalSince(started)
            var matchDiffs: [String] = []
            for i in Set(match.owned.keys).union(pageOwned.keys).sorted() {
                let a = Set(match.owned[i] ?? []), b = Set(pageOwned[i] ?? [])
                if a != b { matchDiffs.append("\(pageCatalog.indices.contains(i) ? pageCatalog[i].name : "#\(i)"): Swift \(a.sorted()), page \(b.sorted())") }
            }
            problems += matchDiffs.count
            report["matching"] = Array(matchDiffs.prefix(200))
            say(matchDiffs.isEmpty ? "✓ Matching: the same \(match.owned.count) songs owned, in \(String(format: "%.2f", took)) s." : "✗ Matching: \(matchDiffs.count) songs differ, e.g. \(matchDiffs[0])")
        } catch {
            problems += 1
            say("Stopped: \(error.localizedDescription)")
            report["error"] = error.localizedDescription
        }
        report["problems"] = problems
        report["at"] = ISO8601DateFormatter().string(from: Date())
        try? EngineFiles.write("check-report.json", JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]))
        verdict = problems == 0 ? "The Swift engine matches the page." : "\(problems) \(problems == 1 ? "difference" : "differences"). The details are in check-report.json."
    }

    /// Replaces the last line when it's a progress line, so counts tick in place.
    private func progress(_ s: String) {
        if let last = lines.last, last.hasPrefix("  "), last.contains(" of ") { lines[lines.count - 1] = s } else { lines.append(s) }
    }

    static func dict(_ s: EngineSong) -> [String: Any] { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(s))) as? [String: Any] ?? [:] }
    static func same(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return (try? JSONSerialization.data(withJSONObject: [a], options: .sortedKeys)) == (try? JSONSerialization.data(withJSONObject: [b], options: .sortedKeys))
    }
}

struct EngineCheckView: View {
    @ObservedObject private var check = EngineCheck.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compares the new Swift engine with the page, on your own catalog and music folder. It only reads; nothing in your music changes.")
                .font(.callout).foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(check.lines.enumerated()), id: \.offset) { _, l in Text(l).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if check.running { ProgressView().controlSize(.small); Text("Checking…") }
                if let v = check.verdict { Text(v).bold() }
                Spacer()
                Button("Show Files") { NSWorkspace.shared.activateFileViewerSelecting([EngineFiles.dir.appendingPathComponent("check-report.json")]) }
                    .disabled(check.verdict == nil)
                Button("Run Again") { Task { await check.run() } }.disabled(check.running)
            }
        }
        .padding(18)
        .frame(minWidth: 520, minHeight: 360)
    }
}
