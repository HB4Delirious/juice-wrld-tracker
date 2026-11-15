using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Shapes;

namespace JuiceTracker.App;

/// The Tag fixer: writes the catalog's details into your files' tags. Each file is checked before it's saved (the
/// audio stays byte for byte the same), and the original is backed up first when a backup folder is set.
public sealed class FixerPage : ScrollViewer, IRefresh
{
    readonly StackPanel body = new() { Margin = new Thickness(34, 40, 34, 60), MaxWidth = 1080, HorizontalAlignment = HorizontalAlignment.Left };
    readonly HashSet<string> unticked = [];
    bool writing;
    string status = "";
    const int Shown = 300;

    public FixerPage() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto; Content = body; Refresh(); }

    public void Refresh()
    {
        if (writing) return;
        var store = Store.Shared;
        var plan = Engine.BuildPlan(store.Files, store.Match, store.Catalog, store.FixFields, store.Me.FixBlanks, store.Genre);
        body.Children.Clear();
        body.Children.Add(UI.Title("Tag fixer"));
        var intro = UI.Muted("Writes the catalog's details into your files' tags, so Plex and other players show the right title, artist, album (the era), year and producers. Each file is checked before it's saved: the audio stays byte for byte the same.", 15);
        intro.Margin = new Thickness(0, 18, 0, 18); body.Children.Add(intro);

        // settings: which tags, and the options
        var fields = new StackPanel();
        fields.Children.Add(UI.Text("Tags to update", 15.5, weight: FontWeights.SemiBold));
        foreach (var (key, label) in new[] { ("title", "Title"), ("artist", "Artist, with features"), ("albumartist", "Album artist"), ("album", "Album, set to the era"), ("year", "Year"), ("producer", "Producers"), ("genre", "Genre"), ("comment", "Comment, with category and recording date") })
        {
            var c = new CheckBox { Content = label, IsChecked = store.FixFields.Contains(key), Margin = new Thickness(0, 8, 0, 0) };
            c.Click += (_, _) =>
            {
                var list = store.FixFields.ToList();
                if (c.IsChecked == true) { if (!list.Contains(key)) list.Add(key); } else list.Remove(key);
                store.Me.FixFields = TagWriter.Fields.Where(list.Contains).ToList(); store.SavePersonal();
            };
            fields.Children.Add(c);
        }
        var options = new StackPanel();
        options.Children.Add(UI.Text("Options", 15.5, weight: FontWeights.SemiBold));
        var blanks = new CheckBox { Content = "Keep existing tags and only fill in empty ones", IsChecked = store.Me.FixBlanks, Margin = new Thickness(0, 10, 0, 0) };
        blanks.Click += (_, _) => { store.Me.FixBlanks = blanks.IsChecked == true; store.SavePersonal(); };
        var auto = new CheckBox { Content = "Tag new downloads automatically, with the tags ticked here", IsChecked = store.Me.AutoTag, Margin = new Thickness(0, 8, 0, 0) };
        auto.Click += (_, _) => { store.Me.AutoTag = auto.IsChecked == true; store.SavePersonal(); };
        options.Children.Add(blanks); options.Children.Add(auto);
        var gl = UI.Muted("Genre to write", 12); gl.Margin = new Thickness(0, 12, 0, 4); options.Children.Add(gl);
        var genre = new TextBox { Text = store.Me.FixGenre, MaxWidth = 260, HorizontalAlignment = HorizontalAlignment.Left, ToolTip = Engine.DefaultGenre };
        genre.LostKeyboardFocus += (_, _) => { if (genre.Text != store.Me.FixGenre) { store.Me.FixGenre = genre.Text; store.SavePersonal(); } };
        UI.AutomationName(genre, "Genre to write");
        options.Children.Add(genre);
        var backup = UI.Button("Choose backup folder", ChooseBackup, ""); backup.HorizontalAlignment = HorizontalAlignment.Left; backup.Margin = new Thickness(0, 12, 0, 4);
        options.Children.Add(backup);
        options.Children.Add(UI.Muted(store.Me.BackupDir is { } bd ? $"Backups go to “{System.IO.Path.GetFileName(bd)}”. Each original file is copied there once, before its first edit." : "No backup folder: originals aren't copied before editing.", 12));
        var settings = new Grid();
        settings.ColumnDefinitions.Add(new ColumnDefinition()); settings.ColumnDefinitions.Add(new ColumnDefinition());
        var p1 = UI.Panel(fields, 0, 16); p1.Margin = new Thickness(0, 0, 8, 0);
        var p2 = UI.Panel(options, 1, 16); p2.Margin = new Thickness(8, 0, 0, 0); Grid.SetColumn(p2, 1);
        settings.Children.Add(p1); settings.Children.Add(p2);
        body.Children.Add(settings);

        // files that fit several songs: pick the right one
        var choose = store.Files.Where(f => store.Match.SongsFor.GetValueOrDefault(f.Path) is { Count: > 1 } && store.Match.How.GetValueOrDefault(f.Path) != "manual").ToList();
        int manual = store.Me.MatchOverrides.Count;
        if (choose.Count > 0 || manual > 0)
        {
            var box = new StackPanel();
            if (choose.Count > 0)
            {
                box.Children.Add(UI.Text($"{choose.Count} {(choose.Count == 1 ? "file matches" : "files match")} more than one song. Pick the right one so it counts once and can be tagged.", 15, weight: FontWeights.SemiBold, wrap: true));
                foreach (var f in choose.Take(100))
                {
                    var row = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
                    var pick = new ComboBox { Width = 260, FontSize = 13 };
                    pick.Items.Add(new ComboBoxItem { Content = "Pick a song…", IsEnabled = false });
                    foreach (var i in store.Match.SongsFor[f.Path]) pick.Items.Add(new ComboBoxItem { Content = $"{store.Catalog[i].Name} ({Engine.EraName(store.Catalog[i])})", Tag = store.Catalog[i].Id });
                    pick.Items.Add(new ComboBoxItem { Content = "None of these", Tag = "none" });
                    pick.SelectedIndex = 0;
                    pick.SelectionChanged += (_, _) => { if (pick.SelectedItem is ComboBoxItem { Tag: string id }) store.SetOverride(f.Path, id); };
                    UI.AutomationName(pick, $"Which song is {Engine.BaseName(f.Path)}");
                    DockPanel.SetDock(pick, Dock.Right); row.Children.Add(pick);
                    row.Children.Add(UI.Column(1, UI.Text(Engine.BaseName(f.Path), 14), UI.Text(Engine.ParentOf(f.Path), 12, JT.Muted)));
                    box.Children.Add(row);
                }
            }
            if (manual > 0)
            {
                var undo = UI.Link("Undo all hand matches", () =>
                {
                    if (MessageBox.Show(Window.GetWindow(this), "Those files go back to automatic matching.", "Undo every match you set by hand?", MessageBoxButton.OKCancel) != MessageBoxResult.OK) return;
                    store.Me.MatchOverrides.Clear(); store.SavePersonal(); store.Rematch();
                }, 12);
                var line = UI.Row(8, UI.Muted($"{manual} {(manual == 1 ? "file is" : "files are")} matched by hand.", 12), undo); line.Margin = new Thickness(0, 10, 0, 0);
                box.Children.Add(line);
            }
            var p = UI.Panel(box, 2, 16); p.Margin = new Thickness(0, 18, 0, 0); body.Children.Add(p);
        }

        // the actions line
        var selected = plan.Changes.Count(c => !unticked.Contains(c.Path));
        var actions = new DockPanel { Margin = new Thickness(0, 18, 0, 12) };
        var buttons = UI.Row(10,
            UI.Button("Select all", () => { unticked.Clear(); Refresh(); }),
            UI.Button("Select none", () => { foreach (var c in plan.Changes) unticked.Add(c.Path); Refresh(); }),
            UI.Button(selected > 0 ? $"Write tags to {selected} {(selected == 1 ? "file" : "files")}" : "Write tags", () => Write(plan.Changes.Where(c => !unticked.Contains(c.Path)).ToList()), "", big: true));
        ((Button)buttons.Children[2]).IsEnabled = selected > 0;
        foreach (Button b in buttons.Children.OfType<Button>().Take(2)) b.IsEnabled = plan.Changes.Count > 0;
        DockPanel.SetDock(buttons, Dock.Right); actions.Children.Add(buttons);
        actions.Children.Add(UI.Text(plan.Changes.Count == 0 ? (store.FixFields.Count > 0 ? "Your matched files are up to date." : "Pick at least one tag to update.")
                                                              : $"{selected} of {plan.Changes.Count} files selected. {plan.Same} already match.", 15, JT.Muted));
        body.Children.Add(actions);
        if (status.Length > 0) body.Children.Add(UI.Panel(UI.Text(status, 14, wrap: true), 1, 10));

        // the changes, one row per file
        if (plan.Changes.Count > 0)
        {
            var rows = new StackPanel();
            foreach (var it in plan.Changes.Take(Shown)) rows.Children.Add(Row(it));
            var p = UI.Panel(rows, 0, 0); p.Margin = new Thickness(0, 10, 0, 0); body.Children.Add(p);
            if (plan.Changes.Count > Shown) body.Children.Add(UI.Muted($"Showing the first {Shown} of {plan.Changes.Count}. Write these, and the rest show up next.", 12));
        }
        if (plan.Skipped.Count > 0)
        {
            var exp = new Expander { Header = UI.Text($"{plan.Skipped.Count} matched {(plan.Skipped.Count == 1 ? "file" : "files")} can't be edited", 14, JT.Muted), Margin = new Thickness(0, 14, 0, 0), Foreground = JT.Brush(JT.Mist) };
            var list = new StackPanel();
            foreach (var (path, reason) in plan.Skipped) list.Children.Add(UI.Muted($"{Engine.BaseName(path)}: {reason}", 12));
            exp.Content = list;
            body.Children.Add(exp);
        }
    }

    FrameworkElement Row(Engine.FixItem it)
    {
        var store = Store.Shared;
        var how = store.Match.How.GetValueOrDefault(it.Path, "");
        var grid = new Grid { Margin = new Thickness(14, 9, 14, 9) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(330) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        var tick = new CheckBox { IsChecked = !unticked.Contains(it.Path), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 12, 0) };
        tick.Click += (_, _) => { if (tick.IsChecked == true) unticked.Remove(it.Path); else unticked.Add(it.Path); Refresh(); };
        UI.AutomationName(tick, $"Write {Engine.BaseName(it.Path)}");
        grid.Children.Add(tick);
        var left = new StackPanel();
        left.Children.Add(UI.Text(Engine.BaseName(it.Path), 14));
        var sub = UI.Row(6, UI.Text(store.Catalog[it.Song].Name + (how.Length > 0 ? $" ({how})" : ""), 12, JT.Muted));
        if (how == "close")
        {
            sub.Children.Add(new Border { BorderBrush = JT.Brush(JT.New), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Padding = new Thickness(6, 0, 6, 1), Margin = new Thickness(6, 0, 0, 0), Child = UI.Text("Close match, check it", 11) });
            sub.Children.Add(Spaced(UI.Link("Right song", () => store.SetOverride(it.Path, store.Catalog[it.Song].Id), 12)));
            sub.Children.Add(Spaced(UI.Link("Wrong song", () => store.SetOverride(it.Path, "none"), 12)));
        }
        left.Children.Add(sub);
        Grid.SetColumn(left, 1); grid.Children.Add(left);
        var changes = new StackPanel();
        foreach (var c in it.Changes)
        {
            var t = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap };
            t.Inlines.Add(new Run(TagWriter.FieldLabels[c.Key] + ": ") { Foreground = JT.Brush(JT.Muted) });
            if (c.From.Length > 0)
            {
                t.Inlines.Add(new Run(c.From) { Foreground = JT.Brush(Color.FromArgb(217, JT.Missing.R, JT.Missing.G, JT.Missing.B)), TextDecorations = TextDecorations.Strikethrough });
                t.Inlines.Add(new Run(" → ") { Foreground = JT.Brush(JT.Muted) });
            }
            t.Inlines.Add(new Run(c.To) { Foreground = JT.Brush(JT.Have) });
            changes.Children.Add(t);
        }
        Grid.SetColumn(changes, 2); grid.Children.Add(changes);
        var wrap = new Grid(); wrap.Children.Add(grid);
        wrap.Children.Add(new Rectangle { Height = 0.5, Fill = JT.Brush(JT.Line), VerticalAlignment = VerticalAlignment.Bottom });
        return wrap;
    }
    static FrameworkElement Spaced(FrameworkElement e) { e.Margin = new Thickness(6, 0, 0, 0); return e; }

    void ChooseBackup()
    {
        var store = Store.Shared;
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = "Choose a backup folder" };
        if (dialog.ShowDialog() != true) return;
        var dir = System.IO.Path.GetFullPath(dialog.FolderName);
        if (store.Root is { } root && (dir + "\\").StartsWith(System.IO.Path.GetFullPath(root).TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase))
        {
            status = "That folder is inside your music folder, so Plex would pick up the backups as duplicates. Choose a folder somewhere else.";
            Refresh(); return;
        }
        store.Me.BackupDir = dir; store.SavePersonal();
    }

    async void Write(List<Engine.FixItem> items)
    {
        var store = Store.Shared;
        var ask = store.Me.BackupDir is not null ? "Each original is copied to your backup folder before its first edit." : "No backup folder is set, so the originals won't be saved. Each file is still checked before it's saved.";
        if (MessageBox.Show(Window.GetWindow(this), ask, $"Write new tags to {items.Count} {(items.Count == 1 ? "file" : "files")}?", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
        status = "Writing…"; Refresh(); // draws the status panel the progress below writes into
        writing = true;
        int ok = 0; var failed = new List<string>();
        for (int n = 0; n < items.Count; n++)
        {
            status = $"Writing {n + 1:N0} of {items.Count:N0}: {Engine.BaseName(items[n].Path)}";
            ShowStatus();
            try { await store.WriteTagsAsync(items[n].Path, items[n].Desired); ok++; }
            catch (Exception e)
            {
                var m = e.Message;
                failed.Add($"{Engine.BaseName(items[n].Path)} {(System.Text.RegularExpressions.Regex.IsMatch(m, "^(has|uses|isn't|is |would|failed)") ? m : $"couldn't be saved ({m})")}");
            }
        }
        status = $"Updated {ok:N0} {(ok == 1 ? "file" : "files")}." + (failed.Count > 0 ? $" {failed.Count} {(failed.Count == 1 ? "file was" : "files were")} left unchanged: {string.Join("; ", failed.Take(5))}{(failed.Count > 5 ? "; and more" : "")}." : "") + " In Plex, refresh the library's metadata to see the new tags.";
        writing = false;
        Refresh();
    }
    void ShowStatus()
    {
        if (body.Children.OfType<DoodleBorder>().LastOrDefault(b => b.Child is TextBlock) is { Child: TextBlock t }) t.Text = status;
    }
}
