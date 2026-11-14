import SwiftUI

// SwiftUI stage 3: Duplicates and File health. Anything that touches files (Trash, replace, the audio check) runs in
// the page's tested code; these screens show its results, ask for confirmation here, then call it.

private func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
private func fileName(_ path: String) -> String { (path as NSString).lastPathComponent }

/// A question to confirm before a fix runs.
private struct Pending: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let button: String
    let run: () async throws -> String
}

/// The result of the last fix, shown at the top of the screen.
private struct Banner: View {
    let text: String
    let error: Bool
    var body: some View {
        Label(text, systemImage: error ? "xmark.octagon" : "sparkles")
            .padding(.vertical, 9).padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 12).fill((error ? JT.missing : JT.lavender).opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(error ? JT.missing : JT.lavender, lineWidth: 1))
    }
}

private extension View {
    /// Asks before running `pending`, then shows what happened.
    func confirming(_ pending: Binding<Pending?>, result: Binding<(String, Bool)?>) -> some View {
        alert(pending.wrappedValue?.title ?? "", isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
              presenting: pending.wrappedValue) { p in
            Button(p.button, role: .destructive) {
                Task { @MainActor in
                    do { let text = try await p.run(); result.wrappedValue = text.isEmpty ? nil : (text, false) }
                    catch { result.wrappedValue = ("That didn't work: \(error.localizedDescription)", true) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { p in Text(p.message) }
    }
}

// MARK: - Duplicates

private struct DupFile: Decodable, Hashable { let path: String; let ext: String; let size: Int; let title: String; let keep: Bool; let onDisk: Bool }
private struct DupGroup: Decodable, Hashable { let title: String; let i: Int?; let exact: Bool; let extra: Int; let files: [DupFile] }
private struct DupData: Decodable { let canTrash: Bool; let exactExtra: Int; let groups: [DupGroup] }

struct DuplicatesScreen: View {
    @ObservedObject private var store = NativeStore.shared
    @State private var data: DupData?
    @State private var limit = 40
    @State private var pending: Pending?
    @State private var result: (String, Bool)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenTitle(text: "Duplicates")
                if let result { Banner(text: result.0, error: result.1) }
                if let d = data {
                    let files = d.groups.reduce(0) { $0 + $1.files.count }, extra = d.groups.reduce(0) { $0 + $1.extra }
                    HStack {
                        Text(d.groups.isEmpty ? "Every song in your library has a single file."
                             : "\(d.groups.count) songs with \(files) files in total. Extra copies use about \(size(extra)).")
                            .foregroundColor(JT.muted)
                        Spacer()
                        if d.exactExtra > 0 {
                            Button { askCleanAll(d.exactExtra) } label: { Label("Move \(d.exactExtra) extra \(d.exactExtra == 1 ? "copy" : "copies") to the Trash", systemImage: "trash") }
                                .help("Keeps the best copy of each song whose files all have the same title.")
                        }
                    }
                    Text("The best copy is kept: lossless first, then the largest file. Only files with exactly the same title are cleaned up, so remixes and versions are never touched.")
                        .font(.caption).foregroundColor(JT.muted)
                    ForEach(d.groups.prefix(limit), id: \.self) { g in group(g, canTrash: d.canTrash) }
                    if d.groups.count > limit { Button("Show more") { limit += 60 }.buttonStyle(.borderless) }
                } else {
                    Spinner999().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, 34).padding(.top, 40).padding(.bottom, 60)
            .frame(maxWidth: 1080, alignment: .leading)
        }
        .task(id: store.version) { await load() }
        .confirming($pending, result: $result)
    }

    private func load() async {
        let json = await store.act("dups")
        data = try? JSONDecoder().decode(DupData.self, from: Data(json.utf8))
    }

    private func group(_ g: DupGroup, canTrash: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let i = g.i {
                    Button(g.title) { if store.songs.indices.contains(i) { store.openSong = store.songs[i] } }.buttonStyle(.plain).font(.headline)
                } else {
                    Text(g.title).font(.headline)
                }
                Text(g.exact ? "same title" : "different versions").font(.caption)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill((g.exact ? JT.have : JT.muted).opacity(0.18)))
                if g.i == nil { Text("not in the catalog").font(.caption).foregroundColor(JT.muted) }
                Spacer()
                if g.exact && canTrash, let first = g.files.first {
                    Button("Clean up") { askCleanGroup(g, first.path) }.buttonStyle(.borderless).foregroundColor(JT.lavender)
                }
            }
            ForEach(g.files, id: \.self) { f in
                HStack(spacing: 10) {
                    Image(systemName: f.keep ? "checkmark.seal.fill" : "doc").foregroundColor(f.keep ? JT.have : JT.muted)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(fileName(f.path)).lineLimit(1)
                        Text(f.path).font(.caption.monospaced()).foregroundColor(JT.muted).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(f.ext.uppercased()).font(.caption).foregroundColor(JT.muted)
                    Text(size(f.size)).font(.caption.monospacedDigit()).foregroundColor(JT.muted).frame(width: 70, alignment: .trailing)
                    if f.keep { Text("kept").font(.caption).foregroundColor(JT.have) }
                    if f.onDisk {
                        Button { Task { _ = try? await store.tryAct("healthFix", -1, ["fix": "reveal", "path": f.path]) } } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(.borderless).help("Show in Finder").accessibilityLabel("Show in Finder")
                    }
                }
                .font(.callout)
            }
        }
        .padding(14).doodled(14)
    }

    private func askCleanAll(_ n: Int) {
        pending = Pending(title: "Move \(n) \(n == 1 ? "file" : "files") to the Trash?",
                          message: "The best copy of each song is kept. Only songs whose files all have the same title are cleaned up. You can put files back from the Trash.",
                          button: "Move to Trash") { try await store.tryAct("trashDups") }
    }

    private func askCleanGroup(_ g: DupGroup, _ path: String) {
        let extra = g.files.filter { !$0.keep }.count
        pending = Pending(title: "Move \(extra) \(extra == 1 ? "copy" : "copies") of “\(g.title)” to the Trash?",
                          message: "The best copy is kept. You can put files back from the Trash.",
                          button: "Move to Trash") { try await store.tryAct("trashDups", -1, ["path": path]) }
    }
}

// MARK: - File health

private struct HealthItem: Decodable, Hashable { let path: String; let text: String; let reveal: Bool; let trash: Bool; let replace: Bool }
private struct HealthGroup: Decodable, Hashable { let key: String; let title: String; let help: String; let items: [HealthItem] }
private struct HealthData: Decodable { let running: Bool; let done: Bool; let status: String; let probeable: Bool; let groups: [HealthGroup] }

struct HealthScreen: View {
    @ObservedObject private var store = NativeStore.shared
    @State private var data: HealthData?
    @State private var pending: Pending?
    @State private var result: (String, Bool)?
    @State private var tick = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenTitle(text: "File health")
                Text("Finds files that may be damaged or cut off, songs the site has in better quality, and files with missing or mismatched tags. Nothing changes until you click a fix.")
                    .foregroundColor(JT.muted)
                if let result { Banner(text: result.0, error: result.1) }
                HStack(spacing: 12) {
                    if data?.running == true {
                        ProgressView().controlSize(.small)
                        Button("Stop") { Task { await store.act("healthStop") } }
                    } else {
                        Button { Task { await store.act("healthRun"); tick += 1 } } label: {
                            Label(data?.done == true ? "Check again" : "Check my files", systemImage: "waveform.path.ecg")
                        }
                        .controlSize(.large)
                    }
                    if let status = data?.status, !status.isEmpty { Text(status).foregroundColor(JT.muted) }
                }
                if let d = data {
                    if d.groups.isEmpty, d.done { Label("Every file opened and has the catalog's tags.", systemImage: "checkmark.seal").foregroundColor(JT.have) }
                    ForEach(d.groups, id: \.self) { g in group(g) }
                }
            }
            .padding(.horizontal, 34).padding(.top, 40).padding(.bottom, 60)
            .frame(maxWidth: 1080, alignment: .leading)
        }
        .task(id: "\(store.version)-\(tick)") { await load() }
        .confirming($pending, result: $result)
    }

    /// Loads the results, and keeps reloading once a second while a check runs.
    private func load() async {
        repeat {
            let json = await store.act("health")
            data = try? JSONDecoder().decode(HealthData.self, from: Data(json.utf8))
            guard data?.running == true else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        } while !Task.isCancelled
    }

    private func group(_ g: HealthGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(g.title) (\(g.items.count))").font(.title3.bold())
            Text(g.help).font(.caption).foregroundColor(JT.muted)
            VStack(spacing: 0) {
                ForEach(g.items, id: \.self) { x in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(x.text)
                            Text(x.path).font(.caption.monospaced()).foregroundColor(JT.muted).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if g.key == "tags" {
                            Button("Open Tag fixer") { store.page = .fixer }
                        } else {
                            if x.reveal { Button { fix("reveal", x) } label: { Image(systemName: "magnifyingglass") }.help("Show in Finder").accessibilityLabel("Show in Finder") }
                            if x.replace { Button(g.key == "upgrade" ? "Upgrade" : "Replace with the site's copy") { fix("replace", x) } }
                            if x.trash { Button("Move to Trash") { fix("trash", x) } }
                        }
                    }
                    .font(.callout)
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .overlay(Rectangle().fill(JT.line).frame(height: 0.5), alignment: .bottom)
                }
            }
            .doodled(14)
        }
    }

    private func fix(_ op: String, _ x: HealthItem) {
        let run: () async throws -> String = { try await store.tryAct("healthFix", -1, ["fix": op, "path": x.path]) }
        switch op {
        case "trash":
            pending = Pending(title: "Move “\(fileName(x.path))” to the Trash?", message: "You can put it back from the Trash.", button: "Move to Trash", run: run)
        case "replace":
            pending = Pending(title: "Replace “\(fileName(x.path))” with the site's copy?",
                              message: "The site's file is downloaded and yours goes to the Trash. If the download fails, yours stays where it is (or, if both have the same name, in the Trash).",
                              button: "Replace", run: run)
        default:
            Task { do { _ = try await run() } catch { result = ("That didn't work: \(error.localizedDescription)", true) } }
        }
    }
}
