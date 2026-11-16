using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace JuiceTracker.App;

/// The Player tab: what's playing (cover, era, seek, controls, the lyrics line by line), Up next (reorder, remove),
/// and your playable songs by era to play now, next, or a whole era in order or shuffled. The page is built when the
/// library changes; the player's 4-times-a-second updates only touch the parts that move.
public sealed class PlayerPage : ToolPage
{
    readonly Image cover = new() { Stretch = Stretch.UniformToFill };
    readonly TextBlock title = UI.Marker("Nothing playing", 24), era = UI.Muted("", 14), time = UI.Muted("0:00", 11, false), length = UI.Muted("0:00", 11, false);
    readonly Slider seek = new() { VerticalAlignment = VerticalAlignment.Center }, volume = new() { Minimum = 0, Maximum = 100, Width = 110, VerticalAlignment = VerticalAlignment.Center };
    readonly StackPanel lyrics = new(), upNext = new(), rows = new();
    readonly TextBox search = new() { Width = 180 };
    readonly ComboBox eraPick = new() { MinWidth = 160 }, shuffle = new() { MinWidth = 180 };
    readonly CheckBox inOrder = new() { Content = "In recording order", Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
    readonly Button play;
    string? file, upNextKey; List<(double At, string Line)> synced = []; string plain = ""; int line = -2; bool dragging, updating; int limit = 250;

    public PlayerPage()
    {
        play = UI.IconButton("", "Play", Toggle, 30, JT.Lavender);
        seek.PreviewMouseDown += (_, _) => dragging = true;
        seek.PreviewMouseUp += (_, _) => { dragging = false; Player.Shared.Seek(TimeSpan.FromSeconds(seek.Value)); };
        UI.AutomationName(seek, "Position in the song");
        volume.ValueChanged += (_, e) => { if (!updating) Player.Shared.Volume = e.NewValue; };
        volume.PreviewMouseUp += (_, _) => Store.Shared.SavePersonal();
        UI.AutomationName(volume, "Volume");
        search.TextChanged += (_, _) => { limit = 250; BuildRows(); };
        UI.AutomationName(search, "Search your songs");
        eraPick.SelectionChanged += (_, _) => { if (!updating) { limit = 250; Refresh(); } };
        UI.AutomationName(eraPick, "Show songs from");
        shuffle.SelectionChanged += (_, _) => { if (!updating && shuffle.SelectedItem is string e) Player.Shared.SetEra(e == "Shuffle: all eras" ? "" : e["Shuffle: ".Length..]); };
        UI.AutomationName(shuffle, "Which era the music shuffles from");
        inOrder.Click += (_, _) => Player.Shared.SetInOrder(inOrder.IsChecked == true);
        Loaded += (_, _) => { Player.Shared.Changed += Tick; Tick(); };
        Unloaded += (_, _) => Player.Shared.Changed -= Tick;
        Refresh();
    }

    static List<Song> Mine() => Store.Shared.Songs.Where(s => s.Owned && Listen.FileFor(s.I) is not null).ToList();

    public override void Refresh()
    {
        var mine = Mine();
        Start("Player", "Play your own songs: pick one to play now or next, play a whole era in the order it was recorded, or shuffle.");
        if (mine.Count == 0) { Add(UI.Muted("Songs you have that this PC can play show up here.", 15)); return; }
        var eras = mine.Select(s => s.Era).Distinct().ToList();

        updating = true;
        var picked = eraPick.SelectedItem as string ?? "All eras";
        eraPick.Items.Clear(); eraPick.Items.Add("All eras"); foreach (var e in eras) eraPick.Items.Add(e);
        eraPick.SelectedItem = eras.Contains(picked) ? picked : "All eras";
        shuffle.Items.Clear(); shuffle.Items.Add("Shuffle: all eras"); foreach (var e in eras) shuffle.Items.Add($"Shuffle: {e}");
        updating = false;

        // left: the cover, the song and its controls, then the lyrics
        var art = new Border { CornerRadius = new CornerRadius(18), ClipToBounds = true, Background = JT.Brush(JT.Raise), Height = 330, Child = cover };
        art.Clip = new RectangleGeometry(new Rect(0, 0, 360, 330), 18, 18);
        var seekRow = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
        DockPanel.SetDock(time, Dock.Left); DockPanel.SetDock(length, Dock.Right);
        time.Margin = new Thickness(0, 0, 6, 0); length.Margin = new Thickness(6, 0, 0, 0);
        Detach(time, length, seek); seekRow.Children.Add(time); seekRow.Children.Add(length); seekRow.Children.Add(seek);
        Button? sleep = null;
        sleep = UI.IconButton("", "Sleep timer", () => { var m = Listen.SleepMenu(); m.PlacementTarget = sleep; m.IsOpen = true; }, 15);
        Detach(play, volume, shuffle, inOrder, title, era, cover, lyrics, upNext, rows, search, eraPick);
        var controls = UI.Row(14, play, UI.IconButton("", "Next song", Player.Shared.Skip, 20), UI.Icon("", 14, JT.Muted), volume, sleep,
                              UI.IconButton("", "Big lyrics window", LyricsWindow.Open, 15), UI.IconButton("", "Mini player", MiniPlayer.Open, 15));
        controls.Margin = new Thickness(0, 10, 0, 0);
        var mix = UI.Row(0, shuffle, inOrder); mix.Margin = new Thickness(0, 12, 0, 0);
        title.TextWrapping = TextWrapping.Wrap; title.Margin = new Thickness(0, 12, 0, 0);
        var now = UI.Panel(UI.Column(0, art, title, era, seekRow, controls, mix), 1, 16);
        var words = UI.Panel(UI.Column(8, UI.Text("Lyrics", 15, weight: FontWeights.SemiBold), lyrics), 2, 16); words.Margin = new Thickness(0, 14, 0, 0);
        var left = UI.Column(0, now, words); left.Width = 392;

        // right: Up next, then your songs
        var next = UI.Panel(upNext, 3, 16);
        var head = new DockPanel();
        var filters = UI.Row(10, UI.Icon("", 13, JT.Muted), search, eraPick); DockPanel.SetDock(filters, Dock.Right); head.Children.Add(filters);
        head.Children.Add(UI.Text("Your songs", 15, weight: FontWeights.SemiBold));
        var songsBox = UI.Column(10, head);
        if (eraPick.SelectedItem is string e2 && e2 != "All eras")
        {
            var inEra = mine.Where(s => s.Era == e2).OrderBy(s => Engine.RecordMonth(s.S.RecordDates) ?? int.MaxValue).ThenBy(s => s.Name).Select(s => s.I).ToList();
            songsBox.Children.Add(UI.Row(10, UI.Button($"Play {e2} in order", () => Listen.PlayInOrder(inEra), ""), UI.Button($"Shuffle {e2}", () => Player.Shared.SetEra(e2), "")));
        }
        songsBox.Children.Add(rows);
        var songs = UI.Panel(songsBox, 4, 16); songs.Margin = new Thickness(0, 14, 0, 0);
        var right = UI.Column(0, next, songs); right.Margin = new Thickness(24, 0, 0, 0); right.MinWidth = 420;

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(right, 1); grid.Children.Add(left); grid.Children.Add(right);
        Body.MaxWidth = 1180; Body.HorizontalAlignment = HorizontalAlignment.Stretch;
        Add(grid);
        file = "\0"; upNextKey = null; line = -2; // draw the moving parts afresh
        BuildRows();
        Tick();
    }

    /// The page is rebuilt in place; these keep their state (search text, slider positions) and move to the new layout.
    static void Detach(params FrameworkElement[] items) { foreach (var e in items) if (e.Parent is Panel p) p.Children.Remove(e); else if (e.Parent is Decorator d) d.Child = null; }

    void BuildRows()
    {
        var p = Player.Shared; var q = search.Text.Trim().ToLowerInvariant(); var picked = eraPick.SelectedItem as string ?? "All eras";
        var shown = Mine().Where(s => (picked == "All eras" || s.Era == picked) && (q.Length == 0 || s.Name.ToLowerInvariant().Contains(q))).ToList();
        rows.Children.Clear();
        foreach (var s in shown.Take(limit))
        {
            var f = Listen.FileFor(s.I)!; bool on = string.Equals(f, p.CurrentFile, StringComparison.OrdinalIgnoreCase);
            var row = new DockPanel { Margin = new Thickness(0, 0, 0, 2), Background = Brushes.Transparent, Tag = f };
            var tools = UI.Row(4, UI.IconButton("", $"Play {s.Name}", () => Player.Shared.PlaySong(f, s.Name), 12), UI.IconButton("", $"Play {s.Name} next", () => Listen.PlayNext(s), 12));
            DockPanel.SetDock(tools, Dock.Right); row.Children.Add(tools);
            var name = UI.Text(s.Name, 14, on ? JT.Lavender : JT.Mist);
            var text = picked == "All eras" ? UI.Column(1, name, UI.Text(s.Era, 12, JT.Muted)) : UI.Column(0, name);
            row.Children.Add(UI.Row(10, UI.Icon(on ? "" : "", 13, on ? JT.Lavender : JT.Muted), text));
            row.MouseLeftButtonDown += (_, e) => { if (e.ClickCount == 2) Player.Shared.PlaySong(f, s.Name); };
            row.ToolTip = "Double-click to play";
            rows.Children.Add(new Border { Padding = new Thickness(8, 6, 8, 6), BorderBrush = JT.Brush(JT.Line), BorderThickness = new Thickness(0, 0, 0, 1), Child = row });
        }
        if (shown.Count == 0) rows.Children.Add(UI.Muted("No songs match.", 13));
        if (shown.Count > limit) rows.Children.Add(UI.Link($"Show {Math.Min(250, shown.Count - limit)} more", () => { limit += 250; BuildRows(); }, 13).Also(l => l.Margin = new Thickness(0, 8, 0, 0)));
    }

    void Toggle()
    {
        var p = Player.Shared;
        if (p.CurrentFile is null && !Store.Shared.Me.AmbientOn) p.SetOn(true); else p.TogglePause();
    }

    /// The parts that move with the music.
    async void Tick()
    {
        var p = Player.Shared; var store = Store.Shared;
        updating = true;
        title.Text = p.Title ?? "Nothing playing";
        ((TextBlock)play.Content).Text = p.IsPlaying ? "" : "";
        UI.AutomationName(play, p.IsPlaying ? "Pause" : "Play");
        var dur = p.Duration.TotalSeconds;
        seek.Maximum = Math.Max(dur, 1); seek.IsEnabled = dur > 0;
        if (!dragging) seek.Value = Math.Min(p.Position.TotalSeconds, seek.Maximum);
        time.Text = Engine.FmtTime(p.Position.TotalSeconds); length.Text = Engine.FmtTime(dur);
        if (!volume.IsMouseCaptureWithin) volume.Value = p.Volume;
        var mixEra = store.Me.AmbientEra.Length > 0 && shuffle.Items.Contains($"Shuffle: {store.Me.AmbientEra}") ? $"Shuffle: {store.Me.AmbientEra}" : "Shuffle: all eras";
        if (shuffle.SelectedItem as string != mixEra) shuffle.SelectedItem = mixEra;
        inOrder.IsChecked = store.Me.InOrder;
        updating = false;

        var key = string.Join("\n", p.UpNext.Select(x => x.Title));
        if (key != upNextKey) { upNextKey = key; DrawUpNext(); }

        if (p.CurrentFile != file)
        {
            file = p.CurrentFile; synced = []; plain = ""; line = -2;
            cover.Source = JT.Image("jt-logo"); cover.Stretch = Stretch.None;
            era.Text = file is null ? "Press play for a shuffle of your songs" : "";
            foreach (var b in rows.Children.OfType<Border>()) if (b.Child is DockPanel r && r.Tag is string f) Mark(r, string.Equals(f, file, StringComparison.OrdinalIgnoreCase));
            var i = file is null ? -1 : store.SongForFile(file);
            var playing = file;
            if (i >= 0)
            {
                era.Text = Engine.EraName(store.Catalog[i]);
                // lyrics and era art come live from the site, never saved
                if (await store.DetailsAsync(store.Catalog[i]) is { } json && playing == file)
                {
                    synced = Listen.ParseSynced(json["synced_lyrics"]?.GetValue<string>() ?? "");
                    plain = (json["lyrics"]?.GetValue<string>() ?? "").Trim();
                    if (json["image_url"]?.GetValue<string>() is { Length: > 0 } img && Uri.TryCreate(new Uri("https://juicewrldapi.com"), img, out var url))
                        try { cover.Source = new BitmapImage(url); cover.Stretch = Stretch.UniformToFill; } catch (Exception) { }
                }
            }
            line = -2;
        }
        DrawLyrics(p.Position.TotalSeconds);
    }

    static void Mark(DockPanel row, bool on)
    {
        if (row.Children.OfType<StackPanel>().LastOrDefault() is not { } label || label.Children.Count < 2) return;
        if (label.Children[0] is TextBlock icon) { icon.Text = on ? "" : ""; icon.Foreground = JT.Brush(on ? JT.Lavender : JT.Muted); }
        if (label.Children[1] is StackPanel text && text.Children[0] is TextBlock name) name.Foreground = JT.Brush(on ? JT.Lavender : JT.Mist);
    }

    void DrawLyrics(double at)
    {
        int n = synced.FindLastIndex(x => x.At <= at + 0.15);
        if (n == line) return;
        line = n; lyrics.Children.Clear();
        if (synced.Count > 0)
            for (int k = Math.Max(0, n - 1); k <= Math.Min(synced.Count - 1, Math.Max(n, 0) + 4); k++)
                lyrics.Children.Add(new TextBlock
                {
                    Text = synced[k].Line.Length == 0 ? "♪" : synced[k].Line, TextWrapping = TextWrapping.Wrap, FontSize = k == n ? 17 : 14,
                    FontWeight = k == n ? FontWeights.SemiBold : FontWeights.Normal,
                    Foreground = JT.Brush(k == n ? JT.Mist : Color.FromArgb((byte)(k < n ? 102 : 190), JT.Muted.R, JT.Muted.G, JT.Muted.B)),
                });
        else if (plain.Length > 0) lyrics.Children.Add(new ScrollViewer { MaxHeight = 220, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = UI.Text(plain, 14, JT.Muted, wrap: true) });
        else lyrics.Children.Add(UI.Muted(file is null ? "Lyrics show here while a song plays." : "The site has no lyrics for this song.", 13));
    }

    void DrawUpNext()
    {
        var p = Player.Shared; var store = Store.Shared;
        upNext.Children.Clear();
        var head = new DockPanel();
        if (p.UpNext.Count > 0) { var clear = UI.Link("Clear", p.ClearUpNext, 13); DockPanel.SetDock(clear, Dock.Right); head.Children.Add(clear); }
        head.Children.Add(UI.Text("Up next", 15, weight: FontWeights.SemiBold));
        upNext.Children.Add(head);
        if (p.UpNext.Count == 0)
        {
            var after = store.Me.AmbientEra.Length == 0 ? "the shuffle" : store.Me.InOrder ? $"the next {store.Me.AmbientEra} song" : $"a shuffle of {store.Me.AmbientEra}";
            upNext.Children.Add(UI.Muted($"Nothing picked. After this song comes {after}. Use + on a song to play it next.", 13).Also(t => t.Margin = new Thickness(0, 6, 0, 0)));
            return;
        }
        for (int k = 0; k < p.UpNext.Count; k++)
        {
            int n = k; var item = p.UpNext[k];
            var row = new DockPanel { Margin = new Thickness(0, 6, 0, 0) };
            var up = UI.IconButton("", $"Move {item.Title} up", () => p.MoveUpNext(n, -1), 11); up.IsEnabled = n > 0;
            var down = UI.IconButton("", $"Move {item.Title} down", () => p.MoveUpNext(n, 1), 11); down.IsEnabled = n < p.UpNext.Count - 1;
            var tools = UI.Row(4, up, down, UI.IconButton("", $"Remove {item.Title}", () => p.RemoveUpNext(n), 11));
            DockPanel.SetDock(tools, Dock.Right); row.Children.Add(tools);
            var num = UI.Text($"{n + 1}", 13, JT.Muted); num.Width = 22; num.TextAlignment = TextAlignment.Right;
            row.Children.Add(UI.Row(10, num, UI.Text(item.Title, 14)));
            upNext.Children.Add(row);
        }
    }
}
