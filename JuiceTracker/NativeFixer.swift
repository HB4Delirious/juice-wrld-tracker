import SwiftUI

// SwiftUI stage 4: the Tag fixer. The plan, the settings and the writing all stay in the page: its writers check that
// the audio bytes are unchanged before saving, and back up originals. This screen shows the plan, changes the
// page's settings, and asks before writing.

private struct FixField: Decodable, Hashable { let key: String; let label: String; let on: Bool }
private struct FixChange: Decodable, Hashable { let label: String; let from: String; let to: String }
private struct FixItem: Decodable, Hashable { let path: String; let file: String; let song: String; let fuzzy: Bool; let selected: Bool; let how: String; let changes: [FixChange] }
private struct FixSkip: Decodable, Hashable { let file: String; let reason: String }
private struct FixOption: Decodable, Hashable { let id: String; let label: String }
private struct FixChoose: Decodable, Hashable { let path: String; let file: String; let folder: String; let options: [FixOption] }
private struct FixData: Decodable {
    let support: String
    let fields: [FixField]
    let blanks: Bool, autoTag: Bool, autoTagShown: Bool
    let genre: String, genrePlaceholder: String
    let backup: String, backupSet: Bool, canPickBackup: Bool
    let writing: Bool, status: String
    let same: Int, total: Int, selected: Int
    let changes: [FixItem]
    let skipped: [FixSkip]
    let choose: [FixChoose]
    let manual: Int
}

struct TagFixerScreen: View {
    @ObservedObject private var store = NativeStore.shared
    @State private var data: FixData?
    @State private var genre = ""
    @State private var tick = 0
    @State private var askWrite = false
    @State private var askUndo = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(text: "Tag fixer")
                Text("Writes the catalog's details into your files' tags, so Plex and other players show the right title, artist, album (the era), year and producers. Each file is checked before it's saved: the audio stays byte for byte the same.")
                    .foregroundColor(JT.muted)
                if let d = data {
                    if !d.support.isEmpty { Label(d.support, systemImage: "exclamationmark.triangle").foregroundColor(JT.missing) }
                    settings(d)
                    if !d.choose.isEmpty || d.manual > 0 { choose(d) }
                    actions(d)
                    changes(d)
                    if !d.skipped.isEmpty {
                        DisclosureGroup("\(d.skipped.count) matched \(d.skipped.count == 1 ? "file" : "files") can't be edited") {
                            ForEach(d.skipped, id: \.self) { Text("\($0.file): \($0.reason)").font(.caption).foregroundColor(JT.muted) }
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, 34).padding(.top, 40).padding(.bottom, 60)
            .frame(maxWidth: 1080, alignment: .leading)
        }
        .task(id: "\(store.version)-\(tick)") { await load() }
        .alert("Write new tags to \(data?.selected ?? 0) \(data?.selected == 1 ? "file" : "files")?", isPresented: $askWrite) {
            Button("Write tags") { Task { await store.act("fixWrite"); tick += 1 } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(data?.backupSet == true ? "Each original is copied to your backup folder before its first edit."
                 : "No backup folder is set, so the originals won't be saved. Each file is still checked before it's saved.")
        }
        .alert("Undo every match you set by hand?", isPresented: $askUndo) {
            Button("Undo matches", role: .destructive) { Task { await store.act("fixUndoMatches"); tick += 1 } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Those files go back to automatic matching.") }
    }

    /// Loads the plan, and keeps reloading once a second while tags are being written.
    private func load() async {
        repeat {
            let json = await store.act("fixer")
            if let d = try? JSONDecoder().decode(FixData.self, from: Data(json.utf8)) {
                if data == nil { genre = d.genre }
                data = d
            }
            guard data?.writing == true else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        } while !Task.isCancelled
    }

    private func set(_ key: String, _ on: Bool) { Task { await store.act("fixSet", -1, ["key": key, "on": on]); tick += 1 } }

    private func settings(_ d: FixData) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tags to update").font(.headline)
                ForEach(d.fields, id: \.self) { f in
                    Toggle(f.label, isOn: Binding(get: { f.on }, set: { set("field:\(f.key)", $0) }))
                }
            }
            .toggleStyle(.checkbox)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).doodled(14)

            VStack(alignment: .leading, spacing: 10) {
                Text("Options").font(.headline)
                Toggle("Keep existing tags and only fill in empty ones", isOn: Binding(get: { d.blanks }, set: { set("blanks", $0) }))
                if d.autoTagShown {
                    Toggle("Tag new downloads automatically, with the tags ticked here", isOn: Binding(get: { d.autoTag }, set: { set("autoTag", $0) }))
                }
                Text("Genre to write").font(.caption).foregroundColor(JT.muted).padding(.top, 4)
                TextField(d.genrePlaceholder, text: $genre).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    .onSubmit { Task { await store.act("fixGenre", -1, ["value": genre]); tick += 1 } }
                    .onChange(of: genre) { value in
                        Task { try? await Task.sleep(nanoseconds: 400_000_000); if value == genre { await store.act("fixGenre", -1, ["value": value]); tick += 1 } }
                    }
                if d.canPickBackup {
                    Button { Task { await store.act("fixBackup"); tick += 1 } } label: { Label("Choose backup folder", systemImage: "externaldrive") }
                        .padding(.top, 4)
                    Text(d.backup).font(.caption).foregroundColor(JT.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).doodled(14)
        }
    }

    private func choose(_ d: FixData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !d.choose.isEmpty {
                Text("\(d.choose.count) \(d.choose.count == 1 ? "file matches" : "files match") more than one song. Pick the right one so it counts once and can be tagged.")
                    .font(.headline)
                ForEach(d.choose, id: \.self) { c in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.file)
                            Text(c.folder).font(.caption).foregroundColor(JT.muted)
                        }
                        Spacer()
                        Menu("Pick a song…") {
                            ForEach(c.options, id: \.self) { o in Button(o.label) { match(c.path, o.id) } }
                            Divider()
                            Button("None of these") { match(c.path, "none") }
                        }
                        .frame(width: 260)
                    }
                }
            }
            if d.manual > 0 {
                HStack {
                    Text("\(d.manual) \(d.manual == 1 ? "file is" : "files are") matched by hand.").font(.caption).foregroundColor(JT.muted)
                    Button("Undo all hand matches") { askUndo = true }.buttonStyle(.borderless).font(.caption)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).doodled(14)
    }

    private func match(_ path: String, _ value: String) { Task { await store.act("fixMatch", -1, ["path": path, "value": value]); tick += 1 } }

    private func actions(_ d: FixData) -> some View {
        HStack(spacing: 12) {
            Text(d.total == 0 ? (d.fields.contains(where: \.on) ? "Your matched files are up to date." : "Pick at least one tag to update.")
                 : "\(d.selected) of \(d.total) files selected. \(d.same) already match.")
                .foregroundColor(JT.muted)
            Spacer()
            if d.writing {
                ProgressView().controlSize(.small)
                Text(d.status).foregroundColor(JT.muted).lineLimit(1)
            } else {
                Button("Select all") { Task { await store.act("fixAll"); tick += 1 } }.disabled(d.total == 0)
                Button("Select none") { Task { await store.act("fixNone"); tick += 1 } }.disabled(d.total == 0)
                Button { askWrite = true } label: { Label(d.selected > 0 ? "Write tags to \(d.selected) \(d.selected == 1 ? "file" : "files")" : "Write tags", systemImage: "tag") }
                    .controlSize(.large).keyboardShortcut(.defaultAction)
                    .disabled(d.selected == 0 || !d.support.isEmpty)
            }
        }
    }

    @ViewBuilder private func changes(_ d: FixData) -> some View {
        if !d.writing, !d.status.isEmpty { Text(d.status).padding(10).frame(maxWidth: .infinity, alignment: .leading).doodled(10) }
        if !d.changes.isEmpty {
            LazyVStack(spacing: 0) {
                ForEach(d.changes, id: \.self) { it in row(it, writing: d.writing) }
            }
            .doodled(14)
            if d.total > d.changes.count { Text("Showing the first \(d.changes.count) of \(d.total). Write these, and the rest show up next.").font(.caption).foregroundColor(JT.muted) }
        }
    }

    private func row(_ it: FixItem, writing: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(get: { it.selected }, set: { on in Task { await store.act("fixSel", -1, ["path": it.path, "on": on]); tick += 1 } }))
                .toggleStyle(.checkbox).labelsHidden().disabled(writing)
            VStack(alignment: .leading, spacing: 3) {
                Text(it.file).lineLimit(1)
                HStack(spacing: 6) {
                    Text(it.song + (it.how.isEmpty ? "" : " (\(it.how))")).font(.caption).foregroundColor(JT.muted)
                    if it.fuzzy {
                        Text("Close match, check it").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                            .overlay(Capsule().stroke(Color(red: 1, green: 0.63, blue: 0.29), lineWidth: 1))
                        Button("Right song") { match(it.path, "confirm") }.buttonStyle(.borderless).font(.caption)
                        Button("Wrong song") { match(it.path, "none") }.buttonStyle(.borderless).font(.caption)
                    }
                }
            }
            .frame(width: 330, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(it.changes, id: \.self) { c in
                    (Text("\(c.label): ").foregroundColor(JT.muted)
                     + (c.from.isEmpty ? Text("") : Text(c.from).strikethrough().foregroundColor(JT.missing.opacity(0.85)) + Text(" → ").foregroundColor(JT.muted))
                     + Text(c.to).foregroundColor(JT.have))
                        .font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9).padding(.horizontal, 14)
        .overlay(Rectangle().fill(JT.line).frame(height: 0.5), alignment: .bottom)
    }
}
