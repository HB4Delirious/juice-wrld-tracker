using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Path = System.IO.Path;

namespace JuiceTracker.App;

/// A scrolling screen with the Mac app's margins, a marker title and an intro line.
public abstract class ToolPage : ScrollViewer, IRefresh
{
    protected readonly StackPanel Body = new() { Margin = new Thickness(34, 40, 34, 60), MaxWidth = 1080, HorizontalAlignment = HorizontalAlignment.Left };
    protected string Result = ""; protected bool ResultIsError;
    protected ToolPage() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto; Content = Body; }
    public abstract void Refresh();
    protected void Start(string title, string intro)
    {
        Body.Children.Clear();
        Body.Children.Add(UI.Title(title));
        var t = UI.Muted(intro, 15); t.Margin = new Thickness(0, 18, 0, 16); Body.Children.Add(t);
        if (Result.Length > 0)
        {
            var banner = new Border { CornerRadius = new CornerRadius(12), Padding = new Thickness(14, 9, 14, 9), Margin = new Thickness(0, 0, 0, 14), HorizontalAlignment = HorizontalAlignment.Left,
                                      Background = JT.Brush(Color.FromArgb(46, (ResultIsError ? JT.Missing : JT.Lavender).R, (ResultIsError ? JT.Missing : JT.Lavender).G, (ResultIsError ? JT.Missing : JT.Lavender).B)),
                                      BorderBrush = JT.Brush(ResultIsError ? JT.Missing : JT.Lavender), BorderThickness = new Thickness(1),
                                      Child = UI.Row(8, UI.Icon(ResultIsError ? "" : "", 13), UI.Text(Result, 14, wrap: true)) };
            Body.Children.Add(banner);
        }
    }
    protected void Add(UIElement e, double top = 0) { if (e is FrameworkElement f && top > 0) f.Margin = new Thickness(f.Margin.Left, top, f.Margin.Right, f.Margin.Bottom); Body.Children.Add(e); }
    protected bool Ask(string title, string message, string button = "OK") =>
        MessageBox.Show(Window.GetWindow(this), message, title, MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK;
    protected async Task Run(Func<Task<string>> work)
    {
        try { Result = await work(); ResultIsError = false; }
        catch (Exception e) { Result = $"That didn't work: {e.Message}"; ResultIsError = true; }
        Refresh();
    }
    protected static string? PickFolder(string title) { var d = new Microsoft.Win32.OpenFolderDialog { Title = title }; return d.ShowDialog() == true ? d.FolderName : null; }
    protected static string? SaveFile(string name, string filter) { var d = new Microsoft.Win32.SaveFileDialog { FileName = name, Filter = filter }; return d.ShowDialog() == true ? d.FileName : null; }
    protected static FrameworkElement Section(string title, UIElement body, int seed = 0)
    {
        var col = new StackPanel(); col.Children.Add(UI.Text(title, 17, weight: FontWeights.SemiBold));
        if (body is FrameworkElement f) f.Margin = new Thickness(0, 10, 0, 0);
        col.Children.Add(body);
        var p = UI.Panel(col, seed, 16); p.Margin = new Thickness(0, 0, 0, 16); return p;
    }
    /// A list row: text and a muted path, with buttons on the right.
    protected static FrameworkElement FileRow(string text, string path, params UIElement[] buttons)
    {
        var row = new DockPanel { Margin = new Thickness(14, 9, 14, 9) };
        var right = UI.Row(8, buttons); DockPanel.SetDock(right, Dock.Right); row.Children.Add(right);
        var left = new StackPanel(); left.Children.Add(UI.Text(text, 14, wrap: true));
        left.Children.Add(new TextBlock { Text = path, FontFamily = new FontFamily("Consolas"), FontSize = 11.5, Foreground = JT.Brush(JT.Muted), TextTrimming = TextTrimming.CharacterEllipsis });
        row.Children.Add(left);
        var wrap = new Grid(); wrap.Children.Add(row);
        wrap.Children.Add(new Rectangle { Height = 0.5, Fill = JT.Brush(JT.Line), VerticalAlignment = VerticalAlignment.Bottom });
        return wrap;
    }
    protected static void Reveal(string path) { if (Store.Shared.FullPath(path) is { } f) System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{f}\""); }
}

// MARK: - File health

public sealed class HealthPage : ToolPage
{
    static bool running, stopping, done; static string status = "";
    public HealthPage() => Refresh();

    public override void Refresh()
    {
        var store = Store.Shared;
        Start("File health", "Finds files that may be damaged or cut off, songs the site has in better quality, files with missing or mismatched tags, files much quieter or louder than the rest, and files with no cover art. Nothing changes until you click a fix.");
        var run = running ? UI.Button("Stop", () => stopping = true) : UI.Button(done ? "Check again" : "Check my files", () => _ = CheckAsync(), "", big: true);
        Add(UI.Row(12, run, UI.Text(status, 14, JT.Muted)));
        var issues = Engine.HealthIssues(store.Files, store.Match, store.Catalog, store.Probes);
        (string Key, string Title, string Help)[] groups =
        [
            ("damaged", "May be damaged or cut off", "Replace it with the site's copy, or move it to the Recycle Bin."),
            ("upgrade", "Better copies on the site", "Upgrade downloads the site's higher-quality file; yours goes to the Recycle Bin."),
            ("tags", "Tags to fix", "The Tag fixer writes the catalog's tags to matched files. Unmatched files can be matched by hand there."),
            ("loudness", "Much quieter or louder", "Compared with the middle of your library. A very different level can mean a bad rip or a different source."),
            ("art", "No cover art", "Add artwork puts the song's picture from the site into the file. Tags and audio stay as they are; the Tag fixer's backup folder is used when set."),
        ];
        if (issues.Count == 0 && done) Add(UI.Row(8, UI.Icon("", 14, JT.Have), UI.Text("Every file opened and has the catalog's tags.", 15, JT.Have)), 16);
        foreach (var (key, title, help) in groups)
        {
            var items = issues.Where(i => i.Group == key).Take(500).ToList();
            if (items.Count == 0) continue;
            var head = UI.Column(4, UI.Text($"{title} ({items.Count})", 19, weight: FontWeights.Bold), UI.Muted(help, 12));
            head.Margin = new Thickness(0, 20, 0, 10); Add(head);
            if (key == "art" && items.Any(i => store.Match.SongsFor.ContainsKey(i.Path)))
            {
                var all = UI.Button($"Add artwork to all {items.Count(i => store.Match.SongsFor.ContainsKey(i.Path))}", () =>
                {
                    if (!Ask("Add cover art to every matched file without it?", "Each file gets its song's picture from the site. Tags and audio stay the same; originals are copied to the Tag fixer's backup folder first when one is set.")) return;
                    _ = Run(async () =>
                    {
                        int ok = 0; var failed = new List<string>();
                        foreach (var it in items.Where(i => store.Match.SongsFor.ContainsKey(i.Path)))
                            try { await store.AddArtAsync(it.Path); ok++; } catch (Exception e) { failed.Add($"{Engine.BaseName(it.Path)}: {e.Message}"); }
                        return $"Added cover art to {Store.Plural(ok, "file", "files")}." + (failed.Count > 0 ? $" Skipped {string.Join("; ", failed.Take(3))}." : "");
                    });
                });
                all.HorizontalAlignment = HorizontalAlignment.Left; all.Margin = new Thickness(0, 0, 0, 10); Add(all);
            }
            var rows = new StackPanel();
            foreach (var it in items) rows.Children.Add(FileRow(it.Text, it.Path, Buttons(key, it.Path)));
            Add(UI.Panel(rows, 0, 0));
        }
    }

    UIElement[] Buttons(string group, string path)
    {
        var store = Store.Shared;
        var reveal = UI.IconButton("", "Show in File Explorer", () => Reveal(path), 13);
        if (group == "tags") return [UI.Button("Open Tag fixer", () => MainWindow.Current?.Show(Page.Fixer))];
        var list = new List<UIElement> { reveal };
        var song = store.Match.SongsFor.GetValueOrDefault(path) is { Count: > 0 } s ? s[0] : -1;
        if (group == "art") { if (song >= 0) list.Add(UI.Button("Add artwork", () => _ = Run(async () => { await store.AddArtAsync(path); return $"Added cover art to “{Engine.BaseName(path)}”."; }))); return [.. list]; }
        if (song >= 0 && store.Catalog[song].FilePath.Length > 0 && group != "loudness")
            list.Add(UI.Button(group == "upgrade" ? "Upgrade" : "Replace with the site's copy", () =>
            {
                if (!Ask($"Replace “{Engine.BaseName(path)}” with the site's copy?", "The site's file is downloaded and yours goes to the Recycle Bin. If the download fails, yours stays where it is (or, if both have the same name, in the Recycle Bin).")) return;
                _ = Run(() => ReplaceAsync(path, song));
            }));
        list.Add(UI.Button("Move to Recycle Bin", () =>
        {
            if (!Ask($"Move “{Engine.BaseName(path)}” to the Recycle Bin?", "You can put it back from the Recycle Bin.")) return;
            _ = Run(async () => { await store.RecycleAsync(path); store.Probes.Remove(path); return $"Moved “{Engine.BaseName(path)}” to the Recycle Bin."; });
        }));
        return [.. list];
    }

    static async Task<string> ReplaceAsync(string path, int i)
    {
        var store = Store.Shared; var song = store.Catalog[i];
        // same name: the old file must go first (downloads never overwrite); otherwise download first, so a failed
        // download leaves your copy where it was
        bool samePath = $"{Engine.SaveFolder(song, store.Layout)}/{Engine.SaveFileName(song)}" == path;
        if (samePath) await store.RecycleAsync(path);
        (bool Existed, string Note) r;
        try { r = await store.DownloadSongAsync(i); }
        catch (Exception e) { throw new EngineError(samePath ? $"{e.Message} Your old copy is in the Recycle Bin." : e.Message); }
        if (!samePath) await store.RecycleAsync(path);
        store.Probes.Remove(path);
        return r.Existed ? $"“{song.Name}” was already there." : $"Saved “{song.Name}”." + (r.Note.Length > 0 ? $" {r.Note}" : "");
    }

    /// Opens every playable file, two at a time (gentle on a network drive): does it play, for how long, how loud, art?
    async Task CheckAsync()
    {
        var store = Store.Shared;
        var files = store.Files.Where(f => Player.Playable.Contains(f.Ext)).Select(f => (f.Path, Full: store.FullPath(f.Path))).Where(x => x.Full is not null).ToList();
        running = true; stopping = false; store.Probes.Clear(); int count = 0;
        Refresh();
        for (int next = 0; next < files.Count && !stopping; next += 2)
        {
            var batch = files.Skip(next).Take(2).ToList();
            var results = await Task.WhenAll(batch.Select(b => Task.Run(() => (b.Path, Probe: Store.ProbeFile(b.Full!)))));
            foreach (var (p, probe) in results) if (probe is not null) store.Probes[p] = probe;
            count += batch.Count;
            if (count % 10 == 0 || count == files.Count) { status = $"Checked {count:N0} of {Store.Plural(files.Count, "file", "files")}…"; Refresh(); }
        }
        running = false; done = !stopping;
        status = stopping ? $"Stopped after {Store.Plural(count, "file", "files")}." : $"Checked {Store.Plural(files.Count, "file", "files")}.";
        Refresh();
    }
}

// MARK: - Duplicates

public sealed class DuplicatesPage : ToolPage
{
    public DuplicatesPage() => Refresh();
    public override void Refresh()
    {
        var store = Store.Shared;
        Start("Duplicates", "Songs with more than one file in your library. The best copy is kept: lossless first, then the largest file. Only files with exactly the same title are cleaned up, so remixes and versions are never touched.");
        var groups = Engine.DistinctGroups(Engine.DuplicateGroups(store.Files, store.Match, store.Catalog));
        var exact = groups.Where(Engine.IsExactDuplicate).ToList(); var extra = Engine.ExtraCopies(exact);
        if (groups.Count == 0) { Add(UI.Row(8, UI.Icon("", 14, JT.Have), UI.Text("No duplicates. Every song has one file.", 15, JT.Have))); return; }
        if (extra.Count > 0)
        {
            var all = UI.Button($"Clean up {Store.Plural(extra.Count, "extra copy", "extra copies")} ({Engine.FormatSize(extra.Sum(f => f.Size))})", () =>
            {
                if (!Ask($"Move {Store.Plural(extra.Count, "extra copy", "extra copies")} to the Recycle Bin?", "The best copy of each song stays. You can put the others back from the Recycle Bin.")) return;
                _ = Run(() => TrashAsync(extra));
            }, "", big: true);
            all.HorizontalAlignment = HorizontalAlignment.Left; Add(all);
        }
        foreach (var g in groups.Take(300))
        {
            var keep = Engine.BestCopy(g.Files).Path; bool isExact = Engine.IsExactDuplicate(g);
            var head = new DockPanel { Margin = new Thickness(0, 18, 0, 8) };
            var tag = new Border { CornerRadius = new CornerRadius(8), BorderBrush = JT.Brush(isExact ? JT.Have : JT.New), BorderThickness = new Thickness(1), Padding = new Thickness(6, 0, 6, 1), Child = UI.Text(isExact ? "same title" : "different versions", 11) };
            var right = UI.Row(8, tag); DockPanel.SetDock(right, Dock.Right);
            if (isExact) right.Children.Add(UI.Button("Keep the best", () =>
            {
                var extras = Engine.ExtraCopies([g]);
                if (Ask($"Move {Store.Plural(extras.Count, "copy", "copies")} of “{g.Title}” to the Recycle Bin?", "The best copy stays.")) _ = Run(() => TrashAsync(extras));
            }));
            head.Children.Add(right);
            head.Children.Add(UI.Text($"{g.Title} · {g.Files.Count} files, {Engine.FormatSize(g.Extra)} extra", 16, weight: FontWeights.SemiBold));
            Add(head);
            var rows = new StackPanel();
            foreach (var f in g.Files)
                rows.Children.Add(FileRow($"{f.Ext.ToUpperInvariant()} · {Engine.FormatSize(f.Size)}{(f.Path == keep ? " · keep" : "")}", f.Path, UI.IconButton("", "Show in File Explorer", () => Reveal(f.Path), 13)));
            Add(UI.Panel(rows, 1, 0));
        }
    }
    static async Task<string> TrashAsync(List<LibraryFile> files)
    {
        int moved = 0; var failed = new List<string>();
        foreach (var f in files) try { await Store.Shared.RecycleAsync(f.Path); moved++; } catch (Exception e) { failed.Add($"{Engine.BaseName(f.Path)} ({e.Message})"); }
        return $"Moved {Store.Plural(moved, "file", "files")} to the Recycle Bin." + (failed.Count > 0 ? $" Couldn't move {string.Join("; ", failed.Take(3))}." : "");
    }
}

// MARK: - Organize

public sealed class OrganizePage : ToolPage
{
    List<(string From, string To)> plan = []; bool previewed;
    readonly TextBox pattern = new() { Width = 320 };
    double gb = 32; string? target; string fillStatus = ""; bool copying;

    public OrganizePage() { pattern.Text = Store.Shared.Me.OrganizePattern; Refresh(); }

    public override void Refresh()
    {
        var store = Store.Shared;
        Start("Organize", "Rename and move files into a pattern, file new songs from an inbox folder, or copy your best songs to another drive.");
        // the organizer
        if (pattern.Parent is Panel pp) pp.Children.Remove(pattern);
        var org = new StackPanel();
        org.Children.Add(UI.Muted("Renames and moves matched files into a pattern inside your music folder. Use {era}, {song}, {category} and {year}; slashes make folders. Nothing moves until you confirm, a file never replaces another, and Undo puts everything back.", 12.5));
        var buttons = UI.Row(10, pattern, UI.Button("Preview", () => { store.Me.OrganizePattern = pattern.Text; store.SavePersonal(); previewed = true; plan = Engine.OrganizePlan(store.Files, store.Match, store.Catalog, pattern.Text); Refresh(); }));
        if (plan.Count > 0) buttons.Children.Add(Spaced(UI.Button($"Move {Store.Plural(plan.Count, "file", "files")}", () =>
        {
            if (!Ask($"Move {Store.Plural(plan.Count, "file", "files")}?", "They move inside your music folder; nothing is replaced or deleted. Plex sees the new places on its next scan, and Undo puts them back.")) return;
            var p = plan; plan = [];
            _ = Run(() => store.OrganizeAsync(p));
        })));
        if (store.LastOrganize.Count > 0) buttons.Children.Add(Spaced(UI.Button("Undo last organize", () => _ = Run(store.UndoOrganizeAsync))));
        buttons.Margin = new Thickness(0, 10, 0, 6); org.Children.Add(buttons);
        if (plan.Count > 0)
            foreach (var m in plan.Take(200)) org.Children.Add(new TextBlock { Text = $"{m.From}  →  {m.To}", FontFamily = new FontFamily("Consolas"), FontSize = 11.5, Foreground = JT.Brush(JT.Muted), TextTrimming = TextTrimming.CharacterEllipsis });
        else org.Children.Add(UI.Muted(previewed ? "Every file already fits that pattern (or can't be placed for sure, like a title shared by different songs)." : "Preview shows each move before anything happens.", 12));
        if (plan.Count > 200) org.Children.Add(UI.Muted($"and {plan.Count - 200} more", 12));
        Add(Section("File organizer", org, 0));

        // the inbox
        var inbox = new StackPanel();
        inbox.Children.Add(UI.Muted("Drop songs into this folder (outside your music folder). Each one the tracker recognizes moves into its era's folder and gets the catalog's tags, once it has finished copying. Anything else stays in the inbox for you to look at, with a note saying why.", 12.5));
        var ib = UI.Row(10, UI.Button(store.Me.Inbox is null ? "Choose an inbox folder…" : "Change…", PickInbox));
        if (store.Me.Inbox is { } dir) { ib.Children.Add(Spaced(UI.Text(dir, 12, JT.Muted))); ib.Children.Add(Spaced(UI.Button("Stop using it", () => { store.Me.Inbox = null; store.SavePersonal(); store.WatchInbox(); }))); }
        ib.Margin = new Thickness(0, 10, 0, 6); inbox.Children.Add(ib);
        if (store.InboxNote.Length > 0) inbox.Children.Add(UI.Text(store.InboxNote, 12.5, wrap: true));
        Add(Section("Inbox folder", inbox, 1));

        // fill a drive
        var fill = new StackPanel();
        fill.Children.Add(UI.Muted("Copies your best songs to a phone, USB stick or other drive, up to the size you pick: highest rated first, then the rarest, then the most played. Nothing in your library changes.", 12.5));
        var size = new TextBox { Text = gb.ToString(), Width = 70 }; size.LostKeyboardFocus += (_, _) => { if (double.TryParse(size.Text, out var v) && v > 0) { gb = v; Refresh(); } };
        UI.AutomationName(size, "Gigabytes");
        var row = UI.Row(8, UI.Text("Up to", 14), size, UI.Text("GB", 14), UI.Button(target is null ? "Choose where to copy…" : $"To “{Path.GetFileName(target.TrimEnd('\\'))}”", () =>
        {
            if (PickFolder("Copy here") is not { } t) return;
            if (store.Root is { } root && (Path.GetFullPath(t) + "\\").StartsWith(Path.GetFullPath(root).TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase)) { fillStatus = "Pick a place outside your music folder."; Refresh(); return; }
            target = t; Refresh();
        }));
        var picks = FillPicks();
        if (target is not null && picks.Count > 0)
        {
            var copy = UI.Button(copying ? "Copying…" : $"Copy {picks.Count} songs ({Engine.FormatSize(picks.Sum(p => p.Size))})", () => _ = CopyAsync(picks));
            copy.IsEnabled = !copying; row.Children.Add(Spaced(copy));
        }
        row.Margin = new Thickness(0, 10, 0, 6); fill.Children.Add(row);
        if (fillStatus.Length > 0) fill.Children.Add(UI.Text(fillStatus, 12.5, wrap: true));
        Add(Section("Fill a drive", fill, 2));
    }
    static FrameworkElement Spaced(FrameworkElement e) { e.Margin = new Thickness(10, 0, 0, 0); return e; }

    void PickInbox()
    {
        var store = Store.Shared;
        if (PickFolder("Use as inbox") is not { } dir) return;
        var full = Path.GetFullPath(dir).TrimEnd('\\') + "\\";
        if (store.Root is { } root && (full.StartsWith(Path.GetFullPath(root).TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase) || (Path.GetFullPath(root).TrimEnd('\\') + "\\").StartsWith(full, StringComparison.OrdinalIgnoreCase)))
        { Result = "Pick a folder outside your music folder, so the inbox and the library don't overlap."; ResultIsError = true; Refresh(); return; }
        store.Me.Inbox = dir; store.SavePersonal(); store.WatchInbox();
    }

    /// Best rated first, then the rarest, then the most played, until the size is reached.
    List<(string Path, long Size)> FillPicks()
    {
        var store = Store.Shared; var plays = store.PlayCounts();
        (int, int, int) Rank(int i) { var r = Engine.Rarity(store.Catalog[i], true); return (store.Me.Ratings.GetValueOrDefault(store.Catalog[i].Id), r == "Grail" ? 2 : r == "Rare" ? 1 : 0, plays.GetValueOrDefault(i)); }
        var sizes = store.Files.GroupBy(f => f.Path).ToDictionary(g => g.Key, g => g.First().Size);
        var output = new List<(string, long)>(); long total = 0, budget = (long)(gb * 1_000_000_000); var seen = new HashSet<string>();
        foreach (var i in store.Match.Owned.Keys.OrderByDescending(Rank).ThenBy(i => i))
        {
            var path = store.Match.Owned[i][0];
            if (!seen.Add(path)) continue;
            var s = sizes.GetValueOrDefault(path);
            if (total + s > budget) continue;
            total += s; output.Add((path, s));
        }
        return output;
    }
    async Task CopyAsync(List<(string Path, long Size)> picks)
    {
        var store = Store.Shared; copying = true; int done = 0, skipped = 0, failed = 0;
        for (int n = 0; n < picks.Count; n++)
        {
            fillStatus = $"Copying {n + 1} of {picks.Count}…"; Refresh();
            if (store.FullPath(picks[n].Path) is not { } src || target is null) { failed++; continue; }
            var dst = Path.Combine([target, .. picks[n].Path.Split('/').Skip(1)]);
            var r = await Task.Run(() =>
            {
                if (File.Exists(dst)) return 1;
                try { Directory.CreateDirectory(Path.GetDirectoryName(dst)!); File.Copy(src, dst); return 0; } catch (Exception) { return 2; }
            });
            if (r == 0) done++; else if (r == 1) skipped++; else failed++;
        }
        fillStatus = $"Copied {done} songs." + (skipped > 0 ? $" {skipped} were there already." : "") + (failed > 0 ? $" {failed} couldn't be copied (is the drive full?)." : "");
        copying = false; Refresh();
    }
}

// MARK: - Export & backup

public sealed class ExportPage : ToolPage
{
    (string Drive, List<int> OnlyHere, List<int> OnlyThere, int Both)? compare; string compareStatus = ""; bool comparing;
    public ExportPage() => Refresh();

    public override void Refresh()
    {
        var store = Store.Shared;
        Start("Export & backup", "Keep your wishlist, notes, ratings and matches safe, take your collection to a spreadsheet, or make a picture of it.");
        var grid = new System.Windows.Controls.Primitives.UniformGrid { Columns = 2 };
        grid.Children.Add(Card("Backup", "Your wishlist, notes, ratings, playlists and hand matches in one file. The Mac app reads it too.", 0,
            UI.Button("Save a backup…", () => Save($"juice-tracker-backup-{DateTime.Now:yyyy-MM-dd}.json", "Backup|*.json", store.BackupJson(), "Saved your backup.")),
            UI.Button("Restore a backup…", () =>
            {
                var d = new Microsoft.Win32.OpenFileDialog { Filter = "Backup|*.json" };
                if (d.ShowDialog() == true) _ = Run(() => Task.FromResult(store.Restore(File.ReadAllText(d.FileName))));
            })));
        grid.Children.Add(Card("Catalog spreadsheet", "Every song with what you have, your rating and note, and the site's file link. Opens in Excel.", 1,
            UI.Button("Save the spreadsheet…", () => Save($"juice-wrld-catalog-{DateTime.Now:yyyy-MM-dd}.csv", "CSV|*.csv", store.CatalogCsv(), "Saved the catalog spreadsheet."))));
        grid.Children.Add(Card("Library snapshot", "Every file with its tags and the songs it matched, to keep a record off the music drive.", 2,
            UI.Button("Save a snapshot…", () => Save($"juice-wrld-library-{DateTime.Now:yyyy-MM-dd}.csv", "CSV|*.csv", store.SnapshotCsv(), "Saved a snapshot of your library."))));
        grid.Children.Add(Card("Collection card", "A picture of your progress to post or keep.", 3, UI.Button("Save collection card…", SaveCard)));
        Add(grid);

        // compare with another drive
        var cmp = new StackPanel();
        cmp.Children.Add(UI.Muted("Scans another folder, like a backup drive, and shows the songs that are only on one of them. Nothing on either drive changes.", 12.5));
        var b = UI.Button(comparing ? "Scanning…" : "Choose a folder to compare…", () => _ = CompareAsync()); b.IsEnabled = !comparing && store.Root is not null;
        var row = UI.Row(10, b, UI.Text(compareStatus, 12, JT.Muted)); row.Margin = new Thickness(0, 10, 0, 6); cmp.Children.Add(row);
        if (compare is { } r)
        {
            cmp.Children.Add(UI.Text($"{r.Both:N0} songs on both. {r.OnlyHere.Count:N0} only here, {r.OnlyThere.Count:N0} only on “{r.Drive}”.", 14));
            void List(string title, List<int> songs)
            {
                if (songs.Count == 0) return;
                var t = UI.Text(title, 12, weight: FontWeights.Bold); t.Margin = new Thickness(0, 6, 0, 0); cmp.Children.Add(t);
                cmp.Children.Add(UI.Muted(string.Join(", ", songs.Take(12).Select(i => store.Catalog[i].Name)) + (songs.Count > 12 ? $", and {songs.Count - 12} more" : ""), 12));
            }
            List("Only here (not backed up)", r.OnlyHere); List($"Only on “{r.Drive}”", r.OnlyThere);
            var fetchable = r.OnlyThere.Where(i => store.Catalog[i].FilePath.Length > 0).ToList();
            if (fetchable.Count > 0) { var dl = UI.Button($"Download the {fetchable.Count} missing here from the site", () => store.AddDownloads(fetchable.Select(i => store.Catalog[i].Id))); dl.HorizontalAlignment = HorizontalAlignment.Left; dl.Margin = new Thickness(0, 8, 0, 0); cmp.Children.Add(dl); }
        }
        var sec = Section("Compare with another drive", cmp, 4); sec.Margin = new Thickness(0, 16, 0, 0); Add(sec);
    }

    static FrameworkElement Card(string title, string text, int seed, params UIElement[] buttons)
    {
        var col = new StackPanel();
        col.Children.Add(UI.Text(title, 17, weight: FontWeights.SemiBold));
        var t = UI.Muted(text, 12.5); t.Margin = new Thickness(0, 6, 0, 12); col.Children.Add(t);
        col.Children.Add(UI.Row(10, buttons));
        var p = UI.Panel(col, seed, 16); p.Margin = new Thickness(0, 0, 14, 14); p.MinHeight = 150;
        return p;
    }
    void Save(string name, string filter, string text, string done)
    {
        if (SaveFile(name, filter) is not { } file) return;
        _ = Run(async () => { await File.WriteAllTextAsync(file, text, new System.Text.UTF8Encoding(false)); return done; });
    }
    async Task CompareAsync()
    {
        if (PickFolder("Compare") is not { } dir) return;
        comparing = true; compare = null; Refresh();
        try { compare = await Store.Shared.CompareAsync(dir, (d, t) => Dispatcher.Invoke(() => { compareStatus = $"Reading {d:N0} of {t:N0}…"; })); }
        catch (Exception e) { Result = $"That didn't work: {e.Message}"; ResultIsError = true; }
        comparing = false; compareStatus = ""; Refresh();
    }

    /// The card's picture: the night sky, your count, a rainbow bar and your top and most complete eras (1200 × 630).
    void SaveCard()
    {
        if (SaveFile($"juice-wrld-collection-{DateTime.Now:yyyy-MM-dd}.png", "PNG image|*.png") is not { } file) return;
        var store = Store.Shared; int have = store.Owned.Count, total = store.Catalog.Count;
        var eras = store.EraList.Where(e => e.Name != Engine.NoEra).ToList();
        var top = eras.OrderByDescending(e => e.Have).FirstOrDefault();
        var best = eras.Where(e => e.Total >= 10).OrderByDescending(e => (double)e.Have / e.Total).FirstOrDefault();
        var canvas = new Grid { Width = 1200, Height = 630, Background = new LinearGradientBrush(new GradientStopCollection { new(Color.FromRgb(7, 4, 15), 0), new(Color.FromRgb(29, 11, 64), 0.55), new(Color.FromRgb(74, 18, 80), 1) }, new Point(0, 0), new Point(0.4, 1)) };
        var stars = new Canvas(); double seed = 999;
        double Rand() { seed = seed * 16807 % 2147483647; return seed / 2147483647; }
        for (int n = 0; n < 170; n++) { double a = 0.25 + Rand() * 0.7, x = Rand() * 1200, y = Rand() * 630, r = Rand() * 1.6 + 0.3; var e = new Ellipse { Width = 2 * r, Height = 2 * r, Fill = JT.Brush(Color.FromArgb((byte)(a * 255), 255, 246, 251)) }; Canvas.SetLeft(e, x - r); Canvas.SetTop(e, y - r); stars.Children.Add(e); }
        canvas.Children.Add(stars);
        var col = new StackPanel { Margin = new Thickness(80, 84, 80, 60) };
        col.Children.Add(new TextBlock { Text = "MY JUICE WRLD COLLECTION", FontFamily = JT.Body, FontSize = 26, FontWeight = FontWeights.SemiBold, Foreground = JT.Brush(JT.LavenderHi) });
        var count = new TextBlock(); count.Inlines.Add(new System.Windows.Documents.Run($"{have:N0}") { FontFamily = JT.Marker, FontSize = 120, Foreground = JT.Brush(JT.Mist) });
        count.Inlines.Add(new System.Windows.Documents.Run($"  of {total:N0} songs") { FontFamily = JT.Body, FontSize = 38, FontWeight = FontWeights.SemiBold, Foreground = JT.Brush(JT.Muted) });
        col.Children.Add(count);
        var bar = new Grid { Height = 22, Margin = new Thickness(0, 10, 0, 30) };
        bar.Children.Add(new Border { CornerRadius = new CornerRadius(11), Background = JT.Brush(Color.FromArgb(40, 255, 255, 255)) });
        bar.Children.Add(new Border { CornerRadius = new CornerRadius(11), Background = JT.Gradient(JT.Rainbow), HorizontalAlignment = HorizontalAlignment.Left, Width = Math.Max(22, 1040.0 * have / Math.Max(total, 1)) });
        col.Children.Add(bar);
        if (top is not null) col.Children.Add(new TextBlock { Text = $"Most songs from {top.Name} ({top.Have:N0})", FontFamily = JT.Body, FontSize = 28, Foreground = JT.Brush(JT.Mist) });
        if (best is not null) col.Children.Add(new TextBlock { Text = $"Most complete: {best.Name} ({best.Have} of {best.Total})", FontFamily = JT.Body, FontSize = 28, Foreground = JT.Brush(JT.Mist), Margin = new Thickness(0, 8, 0, 0) });
        canvas.Children.Add(col);
        canvas.Children.Add(new TextBlock { Text = "999", FontFamily = JT.Marker, FontSize = 90, Foreground = JT.Gradient(JT.Count), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 60, 30), RenderTransform = new RotateTransform(-8) });
        var bmp = Games.Render(canvas, 1200, 630);
        Games.SavePng(bmp, file);
        Result = "Saved your collection card."; ResultIsError = false; Refresh();
    }
}
