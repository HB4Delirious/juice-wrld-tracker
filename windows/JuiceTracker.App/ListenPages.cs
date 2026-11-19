using System.IO;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Path = System.IO.Path;

namespace JuiceTracker.App;

/// Playing helpers shared by the song card, rows and screens.
public static class Listen
{
    public static string? FileFor(int i)
    {
        var store = Store.Shared;
        foreach (var p in store.Match.Owned.GetValueOrDefault(i) ?? []) if (Player.Playable.Contains(Engine.ExtOf(p)) && store.FullPath(p) is { } full) return full;
        return null;
    }
    public static void PlayNext(Song s) { if (FileFor(s.I) is { } f) Player.Shared.QueueNext(f, s.Name); }
    /// Plays these songs next, in order.
    public static void PlayInOrder(IEnumerable<int> songs)
    {
        var p = Player.Shared; var list = songs.Select(i => (File: FileFor(i), Name: Store.Shared.Catalog[i].Name)).Where(x => x.File is not null).ToList();
        if (list.Count == 0) return;
        bool playing = p.CurrentFile is not null;
        p.ClearUpNext();
        foreach (var x in list) p.QueueNext(x.File!, x.Name);
        if (playing) p.Skip();
    }
    /// An M3U playlist of the songs you have (full paths, so Groove, VLC, foobar2000 and Plex on this PC can open it).
    public static void SaveM3U(IEnumerable<int> songs, string name)
    {
        var d = new Microsoft.Win32.SaveFileDialog { FileName = Engine.SafeName(name) + ".m3u", Filter = "Playlist|*.m3u" };
        if (d.ShowDialog() != true) return;
        var entries = songs.Select(i => (File: FileFor(i), Song: Store.Shared.Catalog[i])).Where(x => x.File is not null)
                           .Select(x => (x.File!, x.Song.Name, Engine.LengthSeconds(x.Song.Length)));
        File.WriteAllText(d.FileName, Engine.M3u(entries), new System.Text.UTF8Encoding(false));
    }
    /// "Add to playlist" as a menu.
    public static ContextMenu PlaylistMenu(IEnumerable<string> ids)
    {
        var store = Store.Shared; var menu = new ContextMenu(); var list = ids.ToList();
        foreach (var p in store.Me.Playlists) { var item = new MenuItem { Header = p.Name }; item.Click += (_, _) => store.AddToPlaylist(p.Id, list); menu.Items.Add(item); }
        if (store.Me.Playlists.Count > 0) menu.Items.Add(new Separator());
        var make = new MenuItem { Header = "New playlist" };
        make.Click += (_, _) => { store.Me.Playlists.Add(new Store.Playlist(Guid.NewGuid().ToString(), "New playlist", list)); store.SavePersonal(); MainWindow.Current?.CloseOverlay(); MainWindow.Current?.Show(Page.Playlists); };
        menu.Items.Add(make);
        return menu;
    }
    public static Button MenuButton(string label, Func<ContextMenu> menu, string? icon = null)
    {
        var b = UI.Button(label, () => { }, icon);
        b.Click += (_, _) => { var m = menu(); m.PlacementTarget = b; m.Placement = PlacementMode.Bottom; m.IsOpen = true; };
        return b;
    }
    /// The sleep timer's choices.
    public static ContextMenu SleepMenu()
    {
        var p = Player.Shared; var m = new ContextMenu();
        foreach (var min in new[] { 15, 30, 60 }) { var i = new MenuItem { Header = $"In {min} minutes" }; i.Click += (_, _) => p.Sleep(min); m.Items.Add(i); }
        var end = new MenuItem { Header = "At the end of this song" }; end.Click += (_, _) => p.Sleep(null, true); m.Items.Add(end);
        if (p.SleepAt is not null || p.SleepAtEnd) { m.Items.Add(new Separator()); var off = new MenuItem { Header = "Turn off the sleep timer" }; off.Click += (_, _) => p.Sleep(null); m.Items.Add(off); }
        return m;
    }
}

// MARK: - Playlists

public sealed class PlaylistsPage : ToolPage
{
    string? picked; readonly TextBox name = new() { FontSize = 18, Width = 320 };
    public PlaylistsPage()
    {
        name.LostKeyboardFocus += (_, _) => Rename();
        name.TextChanged += (_, _) => Rename(); // saved on every keystroke, so switching playlists right away keeps it
        UI.AutomationName(name, "Playlist name");
        Refresh();
    }
    void Rename()
    {
        var store = Store.Shared; var n = store.Me.Playlists.FindIndex(p => p.Id == picked);
        if (n < 0 || name.Text.Trim().Length == 0 || store.Me.Playlists[n].Name == name.Text) return;
        store.Me.Playlists[n] = store.Me.Playlists[n] with { Name = name.Text };
        store.SavePersonal();
    }

    public override void Refresh()
    {
        var store = Store.Shared;
        Start("Playlists", "Make your own playlists, play them in order, and export them as M3U for Plex, VLC or other players.");
        var lists = store.Me.Playlists;
        var current = lists.FirstOrDefault(p => p.Id == picked) ?? lists.FirstOrDefault();
        picked = current?.Id;
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(240) }); grid.ColumnDefinitions.Add(new ColumnDefinition());
        var left = new StackPanel { Margin = new Thickness(0, 0, 20, 0) };
        foreach (var p in lists)
        {
            var row = new DockPanel(); var count = UI.Text($"{p.Songs.Count}", 13, JT.Muted); DockPanel.SetDock(count, Dock.Right); row.Children.Add(count); row.Children.Add(UI.Text(p.Name, 14));
            var b = new Button { Content = new Border { Padding = new Thickness(10, 6, 10, 6), CornerRadius = new CornerRadius(8), Background = p.Id == picked ? JT.Brush(JT.Raise) : Brushes.Transparent, Child = row },
                                 Style = (Style)Application.Current.FindResource("Plain"), HorizontalContentAlignment = HorizontalAlignment.Stretch };
            b.Click += (_, _) => { picked = p.Id; Refresh(); };
            left.Children.Add(b);
        }
        var add = UI.Link("+ New playlist", () => { var p = new Store.Playlist(Guid.NewGuid().ToString(), "New playlist", []); store.Me.Playlists.Add(p); picked = p.Id; store.SavePersonal(); }); add.Margin = new Thickness(10, 8, 0, 14);
        left.Children.Add(add);
        left.Children.Add(UI.Text("Smart M3U", 12, JT.Muted, FontWeights.Bold));
        var owned = store.Songs.Where(s => s.Owned).ToList();
        void Smart(string label, Func<IEnumerable<int>> songs) { var l = UI.Link(label, () => Listen.SaveM3U(songs(), label), 13); l.Margin = new Thickness(0, 6, 0, 0); left.Children.Add(l); }
        var eraMenu = Listen.MenuButton("Export an era…", () =>
        {
            var m = new ContextMenu();
            foreach (var e in owned.Select(s => s.Era).Distinct().Order())
            {
                var i = new MenuItem { Header = e };
                i.Click += (_, _) => Listen.SaveM3U(owned.Where(s => s.Era == e).OrderBy(s => Engine.RecordMonth(s.S.RecordDates) ?? 0).Select(s => s.I), e);
                m.Items.Add(i);
            }
            return m;
        });
        eraMenu.HorizontalAlignment = HorizontalAlignment.Left; eraMenu.Margin = new Thickness(0, 6, 0, 0); left.Children.Add(eraMenu);
        Smart("Top rated", () => owned.Where(s => store.Me.Ratings.ContainsKey(s.S.Id)).OrderByDescending(s => store.Me.Ratings[s.S.Id]).Select(s => s.I));
        Smart("Wishlist (the ones you have)", () => owned.Where(s => s.Wished).Select(s => s.I));
        Smart("Never played", () => { var plays = store.PlayCounts(); return owned.Where(s => plays.GetValueOrDefault(s.I) == 0).Select(s => s.I); });
        grid.Children.Add(left);

        var right = new StackPanel(); Grid.SetColumn(right, 1);
        if (current is null)
            right.Children.Add(UI.Panel(UI.Column(10,
                UI.Icon("\uE90B", 30, JT.Lavender).Also(i => i.HorizontalAlignment = HorizontalAlignment.Center),
                UI.Text("No playlists yet", 18, weight: FontWeights.Bold).Also(t => t.HorizontalAlignment = HorizontalAlignment.Center),
                UI.Muted("Make one with New playlist, then add songs from a song's card or a row's right-click menu.", 14).Also(t => { t.TextAlignment = TextAlignment.Center; t.TextWrapping = TextWrapping.Wrap; t.MaxWidth = 360; t.HorizontalAlignment = HorizontalAlignment.Center; })
            ).Also(c => c.Margin = new Thickness(32)), 1, 0));
        else
        {
            var byId = store.Songs.GroupBy(s => s.S.Id).ToDictionary(g => g.Key, g => g.First());
            var songs = current.Songs.Where(byId.ContainsKey).Select(id => byId[id]).ToList();
            if (name.Parent is Panel pp) pp.Children.Remove(name);
            if (!name.IsKeyboardFocused) name.Text = current.Name;
            var head = UI.Row(10, name, UI.Button("Play", () => Listen.PlayInOrder(songs.Where(s => s.Owned).Select(s => s.I)), ""),
                              UI.Button("Export M3U…", () => Listen.SaveM3U(songs.Select(s => s.I), current.Name)),
                              songs.Where(s => !s.Owned && s.HasFile).ToList() is { Count: > 0 } missing ? UI.Button($"Download {missing.Count} missing", () =>
                              {
                                  if (MessageBox.Show(Window.GetWindow(this), "The songs in this playlist you don't have yet, one at a time, into the folders the tracker picks for each era.",
                                                      $"Download {missing.Count} songs into your music folder?", MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK)
                                      store.AddDownloads(missing.Select(s => s.S.Id));
                              }) : new Border(),
                              Plex.Configured ? UI.Button("Send to Plex", async () =>
                              {
                                  try { var n = await Plex.MakePlaylist(current.Name, songs.Where(s => s.Owned).Select(s => s.I)); MessageBox.Show($"“{current.Name}” is in Plex with {n:N0} songs.", "Sent to Plex"); }
                                  catch (Exception e) { MessageBox.Show(e.Message, "Couldn't send to Plex"); }
                              }) : new Border(),
                              UI.IconButton("", "Delete this playlist", () => { if (Ask($"Delete “{current.Name}”?", "The songs stay in your library.")) { store.Me.Playlists.Remove(current); store.SavePersonal(); } }));
            right.Children.Add(head);
            var hint = UI.Muted("Songs you don't have yet stay on the list but are skipped when playing and exporting. Use the arrows to reorder.", 12); hint.Margin = new Thickness(0, 8, 0, 8); right.Children.Add(hint);
            var rows = new StackPanel();
            for (int n = 0; n < songs.Count; n++)
            {
                int k = n; var s = songs[n];
                var row = new DockPanel { Margin = new Thickness(12, 6, 12, 6) };
                var tools = UI.Row(4,
                    UI.IconButton("", $"Move {s.Name} up", () => Move(current, k, -1), 12), UI.IconButton("", $"Move {s.Name} down", () => Move(current, k, 1), 12),
                    UI.IconButton("", $"Remove {s.Name}", () => { current.Songs.RemoveAt(k); store.SavePersonal(); }, 12));
                DockPanel.SetDock(tools, Dock.Right); row.Children.Add(tools);
                row.Children.Add(UI.Row(10, UI.Text($"{k + 1}", 12, JT.Muted), UI.Text(s.Name, 14, s.Owned ? JT.Mist : JT.Muted), UI.Text(s.Era, 12, JT.Muted)));
                rows.Children.Add(row);
            }
            right.Children.Add(UI.Panel(rows, 1, 0));
        }
        grid.Children.Add(right);
        Add(grid);
    }
    static void Move(Store.Playlist p, int at, int by)
    {
        int to = at + by;
        if (to < 0 || to >= p.Songs.Count) return;
        (p.Songs[at], p.Songs[to]) = (p.Songs[to], p.Songs[at]);
        Store.Shared.SavePersonal();
    }
}

// MARK: - Stats

public sealed class StatsPage : ToolPage
{
    int? pickedMonth;
    public StatsPage() => Refresh();
    public override void Refresh()
    {
        var store = Store.Shared; var songs = store.Songs;
        Start("Stats", "Your collection in numbers, and what you've been listening to.");
        var recYears = songs.SelectMany(s => Engine.YearsIn(s.S.RecordDates)).ToList();
        var released = songs.Count(s => Engine.IsReleased(s.S));
        int have = store.Owned.Count;
        var line = new TextBlock { FontSize = 19, TextWrapping = TextWrapping.Wrap };
        line.Inlines.Add(new System.Windows.Documents.Run($"{songs.Count:N0}") { FontWeight = FontWeights.Bold });
        line.Inlines.Add(new System.Windows.Documents.Run($" songs{(recYears.Count > 0 ? $", recorded {recYears.Min()} to {recYears.Max()}" : "")}. You have "));
        line.Inlines.Add(new System.Windows.Documents.Run($"{have:N0}") { FontWeight = FontWeights.Bold, Foreground = JT.Brush(JT.Have) });
        line.Inlines.Add(new System.Windows.Documents.Run($" ({Math.Round(100.0 * have / Math.Max(songs.Count, 1))}%). {released:N0} officially released."));
        Add(line);

        // songs per era
        Add(UI.Text("Songs per era", 16, weight: FontWeights.SemiBold), 22);
        var eras = new StackPanel(); var peak = Math.Max(1, store.EraList.Max(e => (int?)e.Total) ?? 1);
        foreach (var e in store.EraList.Where(e => e.Total > 0))
        {
            var row = new Grid { Margin = new Thickness(0, 3, 0, 3) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(170) }); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(80) });
            row.Children.Add(UI.Text(e.Name, 14));
            var track = new Grid { Height = 10, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 0, 12, 0) };
            var bar = UI.Bar((double)e.Have / Math.Max(e.Total, 1), JT.Brush(JT.Have), 10, 0.1);
            track.Children.Add(bar); Grid.SetColumn(track, 1); row.Children.Add(track);
            row.SizeChanged += (_, a) => track.Width = Math.Max(10, (a.NewSize.Width - 250) * e.Total / peak);
            var n = UI.Text($"{e.Have} / {e.Total}", 12, JT.Muted); n.HorizontalAlignment = HorizontalAlignment.Right; Grid.SetColumn(n, 2); row.Children.Add(n);
            eras.Children.Add(row);
        }
        Add(UI.Panel(eras, 0, 14), 8);

        // songs recorded by year, and previews, surfaced songs and releases by year
        var recorded = new SortedDictionary<int, int[]>();
        foreach (var s in songs) foreach (var y in Engine.YearsIn(s.S.RecordDates)) { var r = recorded.TryGetValue(y, out var v) ? v : recorded[y] = new int[3]; r[s.Owned ? 0 : 1]++; }
        Add(UI.Text("Songs recorded by year", 16, weight: FontWeights.SemiBold), 22);
        Add(Legend(("In your library", JT.Have), ("Not in your library", Color.FromArgb(191, JT.Lavender.R, JT.Lavender.G, JT.Lavender.B))), 6);
        Add(YearBars(recorded, [JT.Have, Color.FromArgb(191, JT.Lavender.R, JT.Lavender.G, JT.Lavender.B)], stacked: true), 8);
        Add(UI.Muted("A song recorded across several years counts in each of them.", 12), 4);
        var events = new SortedDictionary<int, int[]>();
        int? Year(string t) => int.TryParse(Engine.YearOf(t), out var y) ? y : null;
        foreach (var s in songs)
            foreach (var (y, k) in new[] { (Year(s.S.PreviewDate), 0), (Year(s.S.LeakDate), 1), (Engine.IsReleased(s.S) ? Year(s.S.Release) : null, 2) })
                if (y is { } yy) { var r = events.TryGetValue(yy, out var v) ? v : events[yy] = new int[3]; r[k]++; }
        Add(UI.Text("Previews, surfaced songs and releases by year", 16, weight: FontWeights.SemiBold), 22);
        Add(Legend(("Previewed", JT.New), ("Surfaced", JT.Missing), ("Released", JT.Have)), 6);
        Add(YearBars(events, [JT.New, JT.Missing, JT.Have], stacked: false), 8);

        // listening
        var log = Store.PlayLog(); var songFor = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var f in log.Select(e => e.File).Distinct(StringComparer.OrdinalIgnoreCase)) songFor[f] = store.SongForFile(f);
        List<(string Name, int Plays)> Top(IEnumerable<(DateTime At, string File)> entries) =>
            entries.Select(e => songFor.GetValueOrDefault(e.File, -1)).Where(i => i >= 0).GroupBy(i => i).OrderByDescending(g => g.Count()).Take(8).Select(g => (store.Catalog[g.Key].Name, g.Count())).ToList();
        var listening = new Grid(); listening.ColumnDefinitions.Add(new ColumnDefinition()); listening.ColumnDefinitions.Add(new ColumnDefinition());
        var week = TopList("This week", Top(log.Where(e => e.At > DateTime.Now.AddDays(-7)))); var all = TopList("All time", Top(log)); Grid.SetColumn(all, 1);
        listening.Children.Add(week); listening.Children.Add(all);
        var lp = new StackPanel(); lp.Children.Add(UI.Text("Your listening in Juice Tracker", 16, weight: FontWeights.SemiBold));
        lp.Children.Add(UI.Muted(log.Count == 0 ? "Nothing played yet." : $"{log.Count:N0} plays so far.", 13));
        if (log.Count > 0) lp.Children.Add(Timeline(log.Select(e => e.At).ToList()));
        lp.Children.Add(listening);
        if (log.Count > 0)
        {
            var mostPlayed = log.Select(e => songFor.GetValueOrDefault(e.File, -1)).Where(i => i >= 0).GroupBy(i => i).OrderByDescending(g => g.Count()).Take(25).Select(g => g.Key).ToList();
            lp.Children.Add(UI.Button("Play your most played", () => Listen.PlayInOrder(mostPlayed)).Also(b => { b.HorizontalAlignment = HorizontalAlignment.Left; b.Margin = new Thickness(0, 12, 0, 0); }));
            var eraPlays = log.Select(e => songFor.GetValueOrDefault(e.File, -1)).Where(i => i >= 0).GroupBy(i => Engine.EraName(store.Catalog[i])).OrderByDescending(g => g.Count()).Take(8).Select(g => (g.Key, g.Count())).ToList();
            var recent = log.AsEnumerable().Reverse().Where(e => songFor.GetValueOrDefault(e.File, -1) >= 0).Take(10)
                .Select(e => (store.Catalog[songFor[e.File]].Name, Ago(e.At))).ToList();
            var more = new Grid(); more.ColumnDefinitions.Add(new ColumnDefinition()); more.ColumnDefinitions.Add(new ColumnDefinition());
            var eraCol = new StackPanel { Margin = new Thickness(0, 10, 20, 0) }; eraCol.Children.Add(UI.Text("Most played eras", 13.5, weight: FontWeights.Bold));
            foreach (var (name, n) in eraPlays)
                eraCol.Children.Add(UI.Row(8, UI.Text(name, 13.5).Also(t => { t.Width = 150; t.TextTrimming = TextTrimming.CharacterEllipsis; }),
                    new Rectangle { Width = Math.Max(4, 140.0 * n / eraPlays[0].Item2), Height = 8, RadiusX = 4, RadiusY = 4, Fill = JT.Brush(JT.Lavender), VerticalAlignment = VerticalAlignment.Center }, UI.Text($"{n}", 13, JT.Muted)));
            var recentCol = new StackPanel { Margin = new Thickness(0, 10, 20, 0) }; recentCol.Children.Add(UI.Text("Recently played", 13.5, weight: FontWeights.Bold));
            foreach (var (name, when) in recent) recentCol.Children.Add(UI.Row(8, UI.Text(name, 13.5), UI.Text(when, 13, JT.Muted)));
            Grid.SetColumn(recentCol, 1); more.Children.Add(eraCol); more.Children.Add(recentCol);
            lp.Children.Add(more);
        }
        Add(UI.Panel(lp, 1, 16), 22);

        // the year so far
        var thisYear = log.Where(e => e.At.Year == DateTime.Now.Year).ToList();
        var yir = new StackPanel();
        var yirHead = new DockPanel(); yirHead.Children.Add(UI.Text($"Your {DateTime.Now.Year} so far", 16, weight: FontWeights.SemiBold)); yir.Children.Add(yirHead);
        if (thisYear.Count == 0) yir.Children.Add(UI.Muted("Nothing played in the app this year yet.", 13));
        else
        {
            double secs = thisYear.Sum(e => songFor.GetValueOrDefault(e.File, -1) is var i and >= 0 ? Engine.LengthSeconds(store.Catalog[i].Length) ?? 180 : 180);
            var busiest = thisYear.GroupBy(e => e.At.Month).OrderByDescending(g => g.Count()).First();
            var minutes = (int)(secs / 60);
            yir.Children.Add(UI.Text($"{thisYear.Count:N0} plays, about {(minutes >= 120 ? $"{minutes / 60:N0} hours" : $"{minutes} minutes")} of Juice WRLD." + (thisYear.Select(e => e.At.Month).Distinct().Count() > 1 ? $" Your busiest month was {new DateTime(2000, busiest.Key, 1):MMMM}." : ""), 14, wrap: true));
            var eraTop = thisYear.Select(e => songFor.GetValueOrDefault(e.File, -1)).Where(i => i >= 0).GroupBy(i => Engine.EraName(store.Catalog[i])).OrderByDescending(g => g.Count()).Take(3).Select(g => (g.Key, g.Count())).ToList();
            var g2 = new Grid(); g2.ColumnDefinitions.Add(new ColumnDefinition()); g2.ColumnDefinitions.Add(new ColumnDefinition());
            var ts = TopList("Top songs", Top(thisYear).Take(5).ToList()); var te = TopList("Top eras", eraTop); Grid.SetColumn(te, 1);
            g2.Children.Add(ts); g2.Children.Add(te); yir.Children.Add(g2);
            var wrapped = Listen.MenuButton("Wrapped picture", () => WrappedMenu(thisYear.Count, minutes, Top(thisYear).Take(5).Select(t => t.Name).ToList(), eraTop.Select(e => e.Item1).ToList(),
                                                                                  thisYear.Select(e => e.At.Month).Distinct().Count() > 1 ? new DateTime(2000, busiest.Key, 1).ToString("MMMM") : ""));
            DockPanel.SetDock(wrapped, Dock.Right); yirHead.Children.Insert(0, wrapped);
        }
        Add(UI.Panel(yir, 2, 16), 16);
        Add(Calendar(log), 16);
        Add(Gaps(), 16);
    }

    /// Plays per day (the last 30 days) or per week (the last 26 weeks).
    FrameworkElement Timeline(List<DateTime> times)
    {
        var me = Store.Shared.Me; bool weeks = me.TimelineWeeks;
        var counts = Engine.PlayTimeline(times, weeks ? 26 : 30, weeks ? 7 : 1, DateTime.Now);
        int top = Math.Max(1, counts.Max());
        var col = new StackPanel { Margin = new Thickness(0, 10, 0, 6) };
        var mode = new ComboBox { Width = 100, ItemsSource = new[] { "Days", "Weeks" }, SelectedIndex = weeks ? 1 : 0 };
        mode.SelectionChanged += (_, _) => { me.TimelineWeeks = mode.SelectedIndex == 1; Store.Shared.SavePersonal(); Refresh(); };
        UI.AutomationName(mode, "Timeline by day or week");
        var head = new DockPanel(); DockPanel.SetDock(mode, Dock.Right); head.Children.Add(mode); head.Children.Add(UI.Text("Listening timeline", 13.5, weight: FontWeights.Bold));
        col.Children.Add(head);
        var bars = new UniformGrid { Rows = 1, Height = 70, Margin = new Thickness(0, 6, 0, 2) };
        for (int k = 0; k < counts.Length; k++)
        {
            int back = (counts.Length - 1 - k) * (weeks ? 7 : 1);
            string when = back == 0 ? (weeks ? "this week" : "today") : (weeks ? "the week of " : "on ") + DateTime.Now.AddDays(-back).ToString("MMM d");
            bars.Children.Add(new Border { Height = Math.Max(3, 70.0 * counts[k] / top), VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(1.5, 0, 1.5, 0), CornerRadius = new CornerRadius(2),
                                           Background = JT.Brush(counts[k] == 0 ? Color.FromArgb(20, 255, 255, 255) : Color.FromArgb((byte)(k == counts.Length - 1 ? 255 : 178), JT.Lavender.R, JT.Lavender.G, JT.Lavender.B)),
                                           ToolTip = $"{counts[k]} play{(counts[k] == 1 ? "" : "s")} {when}" });
        }
        col.Children.Add(bars);
        var ends = new DockPanel(); var right = UI.Text(weeks ? "this week" : "today", 12, JT.Muted); DockPanel.SetDock(right, Dock.Right);
        ends.Children.Add(right); ends.Children.Add(UI.Text(DateTime.Now.AddDays(-(counts.Length - 1) * (weeks ? 7 : 1)).ToString("MMM d"), 12, JT.Muted));
        col.Children.Add(ends);
        return col;
    }

    /// Your year as a picture (1080 × 1350) to save or copy.
    static ContextMenu WrappedMenu(int plays, int minutes, List<string> top, List<string> eras, string month)
    {
        BitmapSource Make()
        {
            var card = new Grid { Width = 1080, Height = 1350, Background = Games.Night };
            var col = new StackPanel { Margin = new Thickness(90, 0, 90, 0), VerticalAlignment = VerticalAlignment.Center };
            col.Children.Add(new TextBlock { Text = $"My {DateTime.Now.Year} in", FontSize = 34, FontWeight = FontWeights.SemiBold, Foreground = JT.Brush(Color.FromArgb(178, 255, 255, 255)) });
            col.Children.Add(new TextBlock { Text = "Juice WRLD", FontFamily = JT.Marker, FontSize = 96, Foreground = JT.Brush(JT.Lavender), Margin = new Thickness(0, 0, 0, 34) });
            StackPanel Stat(string v, string l) => new StackPanel { Margin = new Thickness(0, 0, 60, 0), Children = { new TextBlock { Text = v, FontSize = 64, FontWeight = FontWeights.Black, Foreground = Brushes.White }, new TextBlock { Text = l, FontSize = 28, FontWeight = FontWeights.SemiBold, Foreground = JT.Brush(Color.FromArgb(153, 255, 255, 255)) } } };
            col.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 34), Children = { Stat($"{plays:N0}", "plays"), Stat(minutes >= 120 ? $"{minutes / 60:N0} hours" : $"{minutes} minutes", "listened") } });
            col.Children.Add(new TextBlock { Text = "Top songs", FontSize = 30, FontWeight = FontWeights.Bold, Foreground = JT.Brush(Color.FromArgb(153, 255, 255, 255)), Margin = new Thickness(0, 0, 0, 12) });
            for (int n = 0; n < top.Count; n++) col.Children.Add(new TextBlock { Text = $"{n + 1}. {top[n]}", FontSize = 40, FontWeight = FontWeights.Black, Foreground = Brushes.White, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 0, 0, 12) });
            col.Children.Add(new TextBlock { Text = "Top eras", FontSize = 30, FontWeight = FontWeights.Bold, Foreground = JT.Brush(Color.FromArgb(153, 255, 255, 255)), Margin = new Thickness(0, 22, 0, 12) });
            col.Children.Add(new TextBlock { Text = string.Join(" · ", eras), FontSize = 38, FontWeight = FontWeights.Black, Foreground = JT.Brush(JT.Lavender), TextWrapping = TextWrapping.Wrap });
            if (month.Length > 0) col.Children.Add(new TextBlock { Text = $"Busiest month: {month}", FontSize = 30, FontWeight = FontWeights.SemiBold, Foreground = JT.Brush(Color.FromArgb(191, 255, 255, 255)), Margin = new Thickness(0, 34, 0, 0) });
            card.Children.Add(col);
            card.Children.Add(new TextBlock { Text = "Juice Tracker", FontFamily = JT.Marker, FontSize = 22, Foreground = JT.Brush(Color.FromArgb(89, 255, 255, 255)), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 36) });
            var bmp = Games.Render(card, 1080, 1350);
            return bmp;
        }
        var menu = new ContextMenu();
        var save = new MenuItem { Header = "Save picture…" };
        save.Click += (_, _) =>
        {
            var d = new Microsoft.Win32.SaveFileDialog { FileName = $"Juice WRLD {DateTime.Now.Year} wrapped.png", Filter = "PNG image|*.png" };
            if (d.ShowDialog() != true) return;
            Games.SavePng(Make(), d.FileName);
        };
        var copy = new MenuItem { Header = "Copy picture" }; copy.Click += (_, _) => Clipboard.SetImage(Make());
        menu.Items.Add(save); menu.Items.Add(copy);
        return menu;
    }

    static string Ago(DateTime at)
    {
        var d = DateTime.Now - at;
        return d.TotalMinutes < 1 ? "just now" : d.TotalHours < 1 ? $"{(int)d.TotalMinutes} min ago" : d.TotalDays < 1 ? $"{(int)d.TotalHours} h ago" : d.TotalDays < 2 ? "yesterday" : $"{(int)d.TotalDays} days ago";
    }
    static FrameworkElement TopList(string title, List<(string Name, int Plays)> items)
    {
        var col = new StackPanel { Margin = new Thickness(0, 10, 20, 0) }; col.Children.Add(UI.Text(title, 13.5, weight: FontWeights.Bold));
        for (int n = 0; n < items.Count; n++) col.Children.Add(UI.Row(8, UI.Text($"{n + 1}. {items[n].Name}", 13.5), UI.Text($"{items[n].Plays}", 13, JT.Muted)));
        return col;
    }
    static FrameworkElement Legend(params (string Label, Color C)[] items)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (label, c) in items) row.Children.Add(UI.Row(6, new Rectangle { Width = 10, Height = 10, RadiusX = 2, RadiusY = 2, Fill = JT.Brush(c), Margin = new Thickness(0, 0, 0, 0) }, UI.Text(label, 12, JT.Muted)).Also(r => r.Margin = new Thickness(0, 0, 16, 0)));
        return row;
    }
    /// Bars per year (stacked or side by side), every year from the first to the last so gaps show.
    static FrameworkElement YearBars(SortedDictionary<int, int[]> data, Color[] colors, bool stacked)
    {
        var grid = new Grid { Height = 180 };
        if (data.Count == 0) return grid;
        int lo = data.Keys.Min(), hi = data.Keys.Max();
        var years = hi - lo > 40 ? data.Keys.ToList() : Enumerable.Range(lo, hi - lo + 1).ToList();
        int peak = Math.Max(1, years.Max(y => data.TryGetValue(y, out var v) ? (stacked ? v.Sum() : v.Max()) : 0));
        var bars = new UniformGrid { Rows = 1 };
        foreach (var y in years)
        {
            var v = data.TryGetValue(y, out var r) ? r : new int[3];
            var cell = new DockPanel { Margin = new Thickness(2, 0, 2, 0) };
            var label = UI.Text($"{y}", 10, JT.Muted); label.HorizontalAlignment = HorizontalAlignment.Center; DockPanel.SetDock(label, Dock.Bottom); cell.Children.Add(label);
            var count = UI.Text($"{(stacked ? v.Sum() : v.Max())}", 10, JT.Muted); count.HorizontalAlignment = HorizontalAlignment.Center;
            var stack = stacked ? new StackPanel { VerticalAlignment = VerticalAlignment.Bottom } : null;
            var side = stacked ? null : new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center };
            for (int k = colors.Length - 1; k >= 0; k--)
            {
                if (stacked) { if (v[k] > 0) stack!.Children.Add(new Rectangle { Height = 150.0 * v[k] / peak, Fill = JT.Brush(colors[k]), RadiusX = 2, RadiusY = 2 }); }
                else side!.Children.Insert(0, new Rectangle { Width = 6, Height = Math.Max(0, 150.0 * v[k] / peak), Fill = JT.Brush(colors[k]), Margin = new Thickness(1, 0, 1, 0), VerticalAlignment = VerticalAlignment.Bottom });
            }
            var col = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom }; col.Children.Add(count); col.Children.Add((UIElement?)stack ?? side!);
            cell.Children.Add(col);
            cell.ToolTip = $"{y}: " + string.Join(", ", v.Take(colors.Length));
            bars.Children.Add(cell);
        }
        grid.Children.Add(bars);
        return grid;
    }

    /// Plays per day over the last year, GitHub style, with your current and longest streaks.
    static FrameworkElement Calendar(List<(DateTime At, string File)> log)
    {
        var perDay = log.GroupBy(e => e.At.Date).ToDictionary(g => g.Key, g => g.Count());
        var today = DateTime.Today; int weekday = (int)today.DayOfWeek;
        var start = today.AddDays(-(52 * 7 + weekday)); int top = Math.Max(1, perDay.Values.DefaultIfEmpty(1).Max());
        int current = 0; for (var d = perDay.ContainsKey(today) ? today : today.AddDays(-1); perDay.ContainsKey(d); d = d.AddDays(-1)) current++;
        int longest = 0, run = 0; DateTime? prev = null;
        foreach (var d in perDay.Keys.Order()) { run = prev is { } p && (d - p).TotalDays == 1 ? run + 1 : 1; longest = Math.Max(longest, run); prev = d; }
        var col = new StackPanel();
        var head = new DockPanel(); var streak = UI.Text($"Streak: {current} {(current == 1 ? "day" : "days")} · longest {longest}", 12, JT.Muted); DockPanel.SetDock(streak, Dock.Right); head.Children.Add(streak);
        head.Children.Add(UI.Text("Listening calendar", 16, weight: FontWeights.SemiBold)); col.Children.Add(head);
        var weeks = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 0) };
        for (int w = 0; w < 53; w++)
        {
            var days = new StackPanel { Margin = new Thickness(0, 0, 3, 0) };
            for (int d = 0; d < 7; d++)
            {
                var day = start.AddDays(w * 7 + d); int n = perDay.GetValueOrDefault(day);
                days.Children.Add(new Rectangle
                {
                    Width = 11, Height = 11, RadiusX = 2, RadiusY = 2, Margin = new Thickness(0, 0, 0, 3), ToolTip = $"{day:MMM d, yyyy}: {n} {(n == 1 ? "play" : "plays")}",
                    Fill = day > today ? Brushes.Transparent : n == 0 ? JT.Brush(Color.FromArgb(150, JT.Raise.R, JT.Raise.G, JT.Raise.B)) : JT.Brush(Color.FromArgb((byte)(255 * (0.25 + 0.75 * n / top)), JT.Lavender.R, JT.Lavender.G, JT.Lavender.B)),
                });
            }
            weeks.Children.Add(days);
        }
        col.Children.Add(weeks);
        UI.AutomationName(weeks, $"Listening calendar: {perDay.Count} days with plays, current streak {current} days");
        return UI.Panel(col, 3, 16);
    }

    /// Every month from 2014 to 2024: how much of what was recorded then you have. Click a month for its songs.
    FrameworkElement Gaps()
    {
        var store = Store.Shared; var total = new Dictionary<int, int>(); var have = new Dictionary<int, int>();
        foreach (var s in store.Songs) if (Engine.RecordMonth(s.S.RecordDates) is { } m) { total[m] = total.GetValueOrDefault(m) + 1; if (s.Owned) have[m] = have.GetValueOrDefault(m) + 1; }
        var col = new StackPanel();
        col.Children.Add(UI.Text("Gaps by month recorded", 16, weight: FontWeights.SemiBold));
        col.Children.Add(UI.Muted("Each square is a month; the brighter it is, the more of that month's recordings you have. Click one to see its songs.", 12));
        var months = System.Globalization.CultureInfo.CurrentCulture.DateTimeFormat.AbbreviatedMonthNames;
        var head = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(38, 8, 0, 2) };
        for (int m = 0; m < 12; m++) head.Children.Add(new TextBlock { Text = months[m], Width = 33, FontSize = 9, Foreground = JT.Brush(JT.Muted) });
        col.Children.Add(head);
        for (int y = 2014; y <= 2024; y++)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 3) };
            row.Children.Add(new TextBlock { Text = $"{y}", Width = 38, FontSize = 12, Foreground = JT.Brush(JT.Muted) });
            for (int m = 0; m < 12; m++)
            {
                int key = y * 12 + m, t = total.GetValueOrDefault(key), h = have.GetValueOrDefault(key);
                var cell = new Border
                {
                    Width = 30, Height = 16, CornerRadius = new CornerRadius(3), Margin = new Thickness(0, 0, 3, 0), ToolTip = t == 0 ? $"{months[m]} {y}: nothing recorded" : $"{months[m]} {y}: {h} of {t}",
                    Background = t == 0 ? Brushes.Transparent : h == 0 ? JT.Brush(Color.FromArgb(89, JT.Missing.R, JT.Missing.G, JT.Missing.B)) : JT.Brush(Color.FromArgb((byte)(255 * (0.2 + 0.8 * h / t)), JT.Have.R, JT.Have.G, JT.Have.B)),
                    BorderBrush = pickedMonth == key ? JT.Brush(JT.Mist) : JT.Brush(JT.Line), BorderThickness = new Thickness(pickedMonth == key ? 2 : t == 0 ? 0.5 : 0),
                    Cursor = t > 0 ? Cursors.Hand : null,
                };
                if (t > 0) cell.MouseLeftButtonUp += (_, _) => { pickedMonth = pickedMonth == key ? null : key; Refresh(); };
                row.Children.Add(cell);
            }
            col.Children.Add(row);
        }
        if (pickedMonth is { } pm)
        {
            var list = store.Songs.Where(s => Engine.RecordMonth(s.S.RecordDates) == pm).OrderBy(s => s.Owned).ThenBy(s => s.Name).ToList();
            var t = UI.Text($"{months[pm % 12]} {pm / 12}: {list.Count(s => s.Owned)} of {list.Count}", 14, weight: FontWeights.Bold); t.Margin = new Thickness(0, 10, 0, 6); col.Children.Add(t);
            var rows = new StackPanel(); foreach (var s in list) rows.Children.Add(new SongRow(s)); col.Children.Add(UI.Panel(rows, 1, 0));
        }
        return UI.Panel(col, 4, 16);
    }
}

public static class Ext { public static T Also<T>(this T t, Action<T> a) { a(t); return t; } }

// MARK: - Hunt

public sealed class HuntPage : ToolPage
{
    int skip;
    public HuntPage() => Refresh();
    Song? Pick()
    {
        var missing = Store.Shared.Songs.Where(s => !s.Owned).ToList();
        if (missing.Count == 0) return null;
        long day = (long)(DateTime.Today - DateTime.UnixEpoch).TotalDays;
        return missing[(int)((day * 7919 + skip * 104729L) % missing.Count)];
    }
    public override void Refresh()
    {
        var store = Store.Shared;
        Start("Hunt", "One song you don't have, picked for you each day: its story, and where it might turn up.");
        if (Pick() is not { } s) { Add(UI.Row(8, UI.Icon("", 14, JT.Have), UI.Text("You have every song in the catalog.", 15, JT.Have))); }
        else
        {
            var card = new StackPanel();
            var top = UI.Row(16, new Image { Source = JT.Image(CollectionPage.EraSticker(s.Era, s.I)), Width = 70, Height = 70, RenderTransform = new RotateTransform(-8) },
                UI.Column(4, UI.Text(skip == 0 ? "Today's song" : "Another one", 12, JT.Lavender, FontWeights.Bold), new TextBlock { Text = s.Name, FontFamily = JT.Marker, FontSize = 40, TextWrapping = TextWrapping.Wrap },
                          UI.Text($"{s.Category} · {s.Era} era", 14, JT.Muted)));
            card.Children.Add(top);
            var story = new StackPanel { Margin = new Thickness(0, 12, 0, 0) }; story.Children.Add(UI.Muted("Loading its story…", 14));
            card.Children.Add(story);
            var actions = new WrapPanel { Margin = new Thickness(0, 14, 0, 0) };
            if (s.HasFile) actions.Children.Add(UI.Button("Download it", () => store.AddDownloads([s.S.Id]), "", big: true));
            actions.Children.Add(Spaced(UI.Button(s.Wished ? "On your wishlist" : "Add to wishlist", () => store.ToggleWish(s.S.Id), s.Wished ? "" : "")));
            actions.Children.Add(Spaced(UI.Button("Open song card", () => MainWindow.Current?.OpenSong(s))));
            actions.Children.Add(Spaced(UI.Button("Another one", () => { skip++; Refresh(); })));
            card.Children.Add(actions);
            Add(UI.Panel(card, 0, 20));
            _ = FillStory(s, story);
        }
        Add(Suggestions(), 18);
    }
    static FrameworkElement Spaced(FrameworkElement e) { e.Margin = new Thickness(10, 0, 0, 0); return e; }
    static async Task FillStory(Song s, StackPanel into)
    {
        var json = await Store.Shared.DetailsAsync(s.S);
        var d = json is not null ? Engine.CleanSong(json) : s.S;
        into.Children.Clear();
        static string Clean(string t) => t.Trim().TrimEnd('.', ' ');
        var when = Clean(Regex.Replace(d.RecordDates, @"^\s*recorded\s*", "", RegexOptions.IgnoreCase));
        var lines = new List<string>();
        if (when.Length > 0) lines.Add($"Recorded {when}{(Clean(d.Locations).Length > 0 ? $" at {Clean(d.Locations)}" : "")}{(Clean(d.Producers).Length > 0 ? $", produced by {Clean(d.Producers)}" : "")}.");
        if (d.Sessions.Length > 0) lines.Add($"Sessions: {d.Sessions}.");
        lines.AddRange(new[] { Engine.DateSentence(d.PreviewDate, "Previewed"), Engine.DateSentence(d.LeakDate, "Surfaced", d.LeakType) }.Where(l => l.Length > 0));
        if (d.Notes.Length > 0) lines.Add(d.Notes);
        if (lines.Count == 0) lines.Add("The catalog has no story for this one yet.");
        foreach (var l in lines) into.Children.Add(UI.Text(l, 14.5, wrap: true).Also(t => t.Margin = new Thickness(0, 0, 0, 6)));
        into.Children.Add(UI.Text("Where it might turn up", 15, weight: FontWeights.SemiBold).Also(t => t.Margin = new Thickness(0, 6, 0, 4)));
        var where = s.HasFile ? "juicewrldapi.com has a file for it: Download it puts it straight into the right era folder."
            : Engine.IsReleased(s.S) ? "It's released, so it's on the streaming services and stores; buy or rip your own copy and drop it in your inbox folder (Organize)."
            : d.LeakDate.Length > 0 || d.PreviewDate.Length > 0 ? "No file on the site yet. Songs that were previewed or snippeted often surface later in leaks or group buys. Put it on your wishlist and the daily check tells you the moment a file appears."
            : "Nothing has surfaced yet. Wishlist it: the daily check watches for a file and alerts you with a Download button.";
        into.Children.Add(UI.Muted(where, 14));
    }
    /// "You rated these highly, so try…": songs you don't have that share a name, producer or era with your 4-5 heart songs.
    static FrameworkElement Suggestions()
    {
        var store = Store.Shared; var loved = store.Songs.Where(s => store.Me.Ratings.GetValueOrDefault(s.S.Id) >= 4).ToList();
        var score = new Dictionary<int, (int Score, string Why)>();
        void Bump(Song s, int n, string why) { if (!s.Owned && (!score.TryGetValue(s.I, out var c) || c.Score < n)) score[s.I] = (n, why); }
        foreach (var l in loved)
        {
            var key = Engine.Normalize(l.Name); var producers = Engine.SplitNames(l.S.Producers).ToHashSet(StringComparer.OrdinalIgnoreCase);
            foreach (var s in store.Songs.Where(s => s.I != l.I && !s.Owned))
            {
                if (Engine.Normalize(s.Name) == key) Bump(s, 3, $"another version of “{l.Name}”");
                else if (Engine.SplitNames(s.S.Producers).FirstOrDefault(producers.Contains) is { } p) Bump(s, 2, $"produced by {p}, like “{l.Name}”");
                else if (s.Era == l.Era && s.HasFile) Bump(s, 1, $"from the {l.Era} era, like “{l.Name}”");
            }
        }
        var col = new StackPanel(); col.Children.Add(UI.Text("You rated these highly, so try…", 17, weight: FontWeights.Bold));
        if (score.Count == 0) col.Children.Add(UI.Muted("Rate songs 4 or 5 hearts on their cards, and suggestions show up here.", 13));
        foreach (var (i, (_, why)) in score.OrderByDescending(kv => kv.Value.Score).ThenBy(kv => kv.Key).Take(12))
        {
            var s = store.Songs[i]; var row = new DockPanel { Margin = new Thickness(0, 6, 0, 0) };
            if (s.HasFile) { var b = UI.Button("Download", () => store.AddDownloads([s.S.Id])); DockPanel.SetDock(b, Dock.Right); row.Children.Add(b); }
            row.Children.Add(UI.Row(10, UI.Link(s.Name, () => MainWindow.Current?.OpenSong(s)), UI.Text(why, 12, JT.Muted)));
            col.Children.Add(row);
        }
        return UI.Panel(col, 2, 16);
    }
}

// MARK: - Lyrics, the mini player and A/B compare

/// A big window with the words of the song playing: the line being sung large, the ones around it dimmed (or the
/// plain lyrics when the site has no timing). Shown live from juicewrldapi.com, never saved.
public sealed class LyricsWindow : Window
{
    static LyricsWindow? open;
    public static void Open() { if (open is null) { open = new LyricsWindow { Owner = MainWindow.Current }; open.Closed += (_, _) => open = null; open.Show(); } else open.Activate(); }
    readonly StackPanel lines = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(40) };
    readonly TextBlock title = new() { FontFamily = JT.Marker, FontSize = 20, Foreground = JT.Brush(JT.Lavender), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 24, 0, 0) };
    string? file; List<Engine.LrcLine> synced = []; string plain = ""; int shown = -2;
    LyricsWindow()
    {
        Title = "Lyrics"; Width = 760; Height = 560; Background = JT.Brush(JT.Night); WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var grid = new Grid(); grid.Children.Add(new Sky()); var dock = new DockPanel(); DockPanel.SetDock(title, Dock.Top); dock.Children.Add(title);
        dock.Children.Add(new ScrollViewer { Content = lines, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }); grid.Children.Add(dock); Content = grid;
        Player.Shared.Changed += Update; Closed += (_, _) => Player.Shared.Changed -= Update; Update();
    }
    async void Update()
    {
        var p = Player.Shared;
        if (p.CurrentFile != file)
        {
            file = p.CurrentFile; synced = []; plain = ""; shown = -2; title.Text = p.Title ?? "";
            var i = file is null ? -1 : Store.Shared.SongForFile(file);
            if (i >= 0 && await Store.Shared.DetailsAsync(Store.Shared.Catalog[i]) is { } json)
            {
                synced = MyLyrics.Synced(Store.Shared.Catalog[i], json);
                plain = (json["lyrics"]?.GetValue<string>() ?? "").Trim();
            }
        }
        int n = synced.FindLastIndex(x => x.At <= p.Position.TotalSeconds);
        if (n == shown) return;
        shown = n; lines.Children.Clear();
        if (synced.Count > 0)
            for (int k = Math.Max(0, n - 2); k <= Math.Min(synced.Count - 1, Math.Max(n, 0) + 3); k++)
                lines.Children.Add(new TextBlock
                {
                    Text = synced[k].Line.Length == 0 ? "♪" : synced[k].Line, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 9, 0, 9),
                    FontFamily = k == n ? JT.Marker : JT.Body, FontSize = k == n ? 40 : 22, Foreground = JT.Brush(k == n ? JT.Mist : Color.FromArgb((byte)(k < n ? 89 : 153), JT.Muted.R, JT.Muted.G, JT.Muted.B)),
                    Effect = k == n ? UI.Glow(JT.Lavender, 12, 0.6) : null,
                });
        else lines.Children.Add(new TextBlock { Text = plain.Length > 0 ? plain : file is null ? "Play a song to see its lyrics." : "The site has no lyrics for this song.", FontSize = 20, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Foreground = JT.Brush(plain.Length > 0 ? JT.Mist : JT.Muted) });
    }
}

/// A small window that stays on top: what's playing, play/pause, next, and the seek bar.
public sealed class MiniPlayer : Window
{
    static MiniPlayer? open;
    public static void Open() { if (open is null) { open = new MiniPlayer(); open.Closed += (_, _) => open = null; open.Show(); } else open.Activate(); }
    readonly TextBlock title = UI.Text("Not playing", 14, weight: FontWeights.SemiBold); readonly Slider seek = new() { Width = 170 }; readonly Button play;
    bool dragging;
    MiniPlayer()
    {
        Title = "Juice Tracker"; Width = 340; Height = 120; Topmost = true; ResizeMode = ResizeMode.NoResize; WindowStyle = WindowStyle.ToolWindow;
        Background = new LinearGradientBrush(JT.Night, Color.FromRgb(42, 12, 62), 90);
        play = UI.IconButton("", "Pause", Player.Shared.TogglePause, 16);
        seek.AddHandler(Thumb.DragStartedEvent, new DragStartedEventHandler((_, _) => dragging = true));
        seek.AddHandler(Thumb.DragCompletedEvent, new DragCompletedEventHandler((_, _) => { dragging = false; Player.Shared.Seek(TimeSpan.FromSeconds(seek.Value)); }));
        UI.AutomationName(seek, "Position in the song");
        var row = UI.Row(14, play, UI.IconButton("", "Next song", Player.Shared.Skip, 16), UI.IconButton("", "Open Juice Tracker", () => { MainWindow.Current?.Activate(); }, 14), seek);
        Content = UI.Row(12, new Image { Source = JT.Image("jt-logo"), Width = 54, Height = 54 }, UI.Column(6, title, row)).Also(r => r.Margin = new Thickness(12));
        Player.Shared.Changed += Update; Closed += (_, _) => Player.Shared.Changed -= Update; Update();
    }
    void Update()
    {
        var p = Player.Shared; title.Text = p.Title ?? "Not playing";
        ((TextBlock)play.Content).Text = p.IsPlaying ? "" : "";
        seek.Maximum = Math.Max(1, p.Duration.TotalSeconds); if (!dragging) seek.Value = Math.Min(p.Position.TotalSeconds, seek.Maximum);
    }
}

/// Plays two versions together, in step, and switches between them instantly. The background music pauses meanwhile.
public sealed class ABWindow : Window
{
    readonly MediaPlayer a = new(), b = new(); bool onB, playing, musicWasPlaying;
    readonly ComboBox pickA = new(), pickB = new(); readonly Slider pos = new(); readonly Button playButton; readonly Button flip;
    readonly List<Song> versions; readonly System.Windows.Threading.DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(500) };

    public static void Open(List<Song> versions, Song start) => new ABWindow(versions, start) { Owner = MainWindow.Current }.Show();

    ABWindow(List<Song> versions, Song start)
    {
        this.versions = versions;
        Title = "Compare versions"; Width = 540; SizeToContent = SizeToContent.Height; ResizeMode = ResizeMode.NoResize; Background = JT.Brush(Color.FromRgb(20, 10, 44));
        foreach (var v in versions) { pickA.Items.Add(v.Name); pickB.Items.Add(v.Name); }
        pickA.SelectedIndex = versions.IndexOf(start); pickB.SelectedIndex = versions.FindIndex(v => v.I != start.I);
        pickA.SelectionChanged += (_, _) => Load(); pickB.SelectionChanged += (_, _) => Load();
        flip = UI.Button("Switch to B", Flip, big: true); flip.HorizontalAlignment = HorizontalAlignment.Stretch;
        playButton = UI.IconButton("", "Play", Toggle, 18);
        pos.PreviewMouseLeftButtonUp += (_, _) => Seek(pos.Value); UI.AutomationName(pos, "Position");
        var grid = new System.Windows.Controls.Primitives.UniformGrid { Columns = 2 };
        grid.Children.Add(Side("A", pickA)); grid.Children.Add(Side("B", pickB));
        var seekRow = new DockPanel(); DockPanel.SetDock(playButton, Dock.Left); seekRow.Children.Add(playButton); seekRow.Children.Add(pos.Also(s => s.Margin = new Thickness(10, 0, 0, 0)));
        Content = UI.Column(14, grid, flip, seekRow, UI.Muted("Space plays and pauses; Tab switches. Both play together from the same point, so you hear the difference right away.", 12)).Also(c => c.Margin = new Thickness(20));
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Space) { Toggle(); e.Handled = true; } else if (e.Key == Key.Tab) { Flip(); e.Handled = true; } };
        timer.Tick += (_, _) => { pos.Maximum = Math.Max(1, Math.Max(a.NaturalDuration.HasTimeSpan ? a.NaturalDuration.TimeSpan.TotalSeconds : 0, b.NaturalDuration.HasTimeSpan ? b.NaturalDuration.TimeSpan.TotalSeconds : 0)); if (!pos.IsMouseCaptureWithin) pos.Value = (onB ? b : a).Position.TotalSeconds; };
        timer.Start();
        Closed += (_, _) => { timer.Stop(); a.Close(); b.Close(); if (musicWasPlaying) Player.Shared.Resume(); }; // stop the players when the window closes
        Load();
    }
    static FrameworkElement Side(string label, ComboBox pick) => UI.Panel(UI.Column(6, new TextBlock { Text = label, FontFamily = JT.Marker, FontSize = 28, Foreground = JT.Brush(JT.Lavender) }, pick), label == "A" ? 0 : 1, 12).Also(p => p.Margin = new Thickness(0, 0, 8, 0));
    void Load()
    {
        a.Stop(); b.Stop(); playing = false; ((TextBlock)playButton.Content).Text = "";
        if (pickA.SelectedIndex >= 0 && Listen.FileFor(versions[pickA.SelectedIndex].I) is { } fa) a.Open(new Uri(fa));
        if (pickB.SelectedIndex >= 0 && Listen.FileFor(versions[pickB.SelectedIndex].I) is { } fb) b.Open(new Uri(fb));
        Apply();
    }
    void Apply() { a.Volume = onB ? 0 : 0.8; b.Volume = onB ? 0.8 : 0; ((TextBlock)((StackPanel)flip.Content).Children[^1]).Text = $"Switch to {(onB ? "A" : "B")}"; }
    void Flip() { onB = !onB; Apply(); }
    void Toggle()
    {
        if (playing) { a.Pause(); b.Pause(); playing = false; }
        else
        {
            if (Player.Shared.IsPlaying) { musicWasPlaying = true; Player.Shared.Pause(); }
            b.Position = a.Position; a.Play(); b.Play(); playing = true;
        }
        ((TextBlock)playButton.Content).Text = playing ? "" : "";
    }
    void Seek(double t) { a.Position = TimeSpan.FromSeconds(t); b.Position = TimeSpan.FromSeconds(t); }
}
