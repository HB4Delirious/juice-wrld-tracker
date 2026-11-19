using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace JuiceTracker.App;

// Heardle (name the song from a growing clip of your own files), the desktop widgets (clock, what's playing, up next,
// edge light) and the song share picture. The Mac app's NativeGames.swift.

static class Art
{
    /// The song's picture from the site (at most 600 px), ready to draw; null when the site has none or is offline.
    public static async Task<BitmapImage?> For(EngineSong s)
    {
        try
        {
            var (jpeg, _, _) = await Store.Shared.ArtworkAsync(s);
            var img = new BitmapImage(); img.BeginInit(); img.StreamSource = new MemoryStream(jpeg); img.CacheOption = BitmapCacheOption.OnLoad; img.EndInit(); img.Freeze();
            return img;
        }
        catch (Exception) { return null; }
    }
}

// MARK: - Heardle

public sealed class HeardlePage : ToolPage
{
    static readonly double[] Steps = [1, 2, 4, 7, 11, 16];
    readonly TextBox query = new() { Width = 360, FontSize = 15 };
    readonly StackPanel matches = new() { Width = 360, HorizontalAlignment = HorizontalAlignment.Left };
    int unlimitedPick = Random.Shared.Next(10_000);
    List<string> unlimitedGuesses = [];
    Song? answer; int seed;

    public HeardlePage()
    {
        query.TextChanged += (_, _) => DrawMatches(); // only the list: rebuilding the box would lose the cursor
        UI.AutomationName(query, "Search for the song");
        Unloaded += (_, _) => StopClip();
        Refresh();
    }

    static Store.Personal Me => Store.Shared.Me;
    static string Today => DateTime.Now.ToString("yyyy-MM-dd");
    static string Key => $"{Today}|{Me.HeardleEra}|{Me.HeardleIntro}";

    /// Songs you have that can play, one per title (versions count as the same song), in a fixed order.
    static List<Song> Pool()
    {
        var seen = new HashSet<string>();
        return Store.Shared.Songs.Where(s => s.Owned && (Me.HeardleEra.Length == 0 || s.Era == Me.HeardleEra) && Listen.FileFor(s.I) is not null)
            .Where(s => seen.Add(Engine.Normalize(s.Name))).OrderBy(s => Engine.Normalize(s.Name), StringComparer.Ordinal).ToList();
    }
    List<string> Guesses
    {
        get
        {
            if (!Me.HeardleDaily) return unlimitedGuesses;
            var parts = Me.HeardleSaved.Split('|');
            return parts.Length == 4 && string.Join('|', parts[..3]) == Key ? [.. parts[3].Split(',', StringSplitOptions.RemoveEmptyEntries)] : [];
        }
        set { if (Me.HeardleDaily) { Me.HeardleSaved = $"{Key}|{string.Join(',', value)}"; Store.Shared.SavePersonal(); } else unlimitedGuesses = value; }
    }
    Song? ById(string id) => Store.Shared.Songs.FirstOrDefault(s => s.S.Id == id);

    public override void Refresh()
    {
        Start("Heardle", "Name the song from a clip of your own files. You hear one second; each wrong guess or skip plays more. Six tries.");
        var mode = new ComboBox { Width = 130, ItemsSource = new[] { "Daily", "Unlimited" }, SelectedIndex = Me.HeardleDaily ? 0 : 1 };
        mode.SelectionChanged += (_, _) => { Me.HeardleDaily = mode.SelectedIndex == 0; Store.Shared.SavePersonal(); query.Clear(); Refresh(); };
        var from = new ComboBox { Width = 150, ItemsSource = new[] { "From the intro", "From inside" }, SelectedIndex = Me.HeardleIntro ? 0 : 1 };
        from.SelectionChanged += (_, _) => { Me.HeardleIntro = from.SelectedIndex == 0; Store.Shared.SavePersonal(); unlimitedGuesses = []; Refresh(); };
        var eras = new List<string> { "All eras" }; eras.AddRange(Store.Shared.Songs.Where(s => s.Owned).Select(s => s.Era).Distinct());
        var era = new ComboBox { MinWidth = 140, ItemsSource = eras, SelectedItem = Me.HeardleEra.Length == 0 ? "All eras" : Me.HeardleEra };
        era.SelectionChanged += (_, _) => { Me.HeardleEra = era.SelectedItem as string is { } e && e != "All eras" ? e : ""; Store.Shared.SavePersonal(); unlimitedGuesses = []; Refresh(); };
        UI.AutomationName(mode, "Daily or unlimited"); UI.AutomationName(from, "Where the clip starts"); UI.AutomationName(era, "Era");
        var st = (Me.HeardleStats + ",0,0,0,0").Split(',').Select(x => int.TryParse(x, out var n) ? n : 0).ToArray();
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 14) };
        var stats = UI.Muted($"Daily: played {st[0]} · won {st[1]} · streak {st[2]} · best {st[3]}", 13); DockPanel.SetDock(stats, Dock.Right); stats.VerticalAlignment = VerticalAlignment.Center;
        head.Children.Add(stats); head.Children.Add(UI.Row(12, mode, from, era));
        Add(head);
        var pool = Pool();
        if (pool.Count == 0) { answer = null; Add(UI.Muted("No songs you have to play in this era.", 14)); return; }
        int day = Engine.LocalDay(DateTimeOffset.Now); // turns over at local midnight, with the saved round
        seed = Me.HeardleDaily ? day : unlimitedPick;
        answer = Me.HeardleDaily ? pool[day * 7919 % pool.Count] : pool[unlimitedPick % pool.Count];
        var a = answer; var list = Guesses; var target = Engine.Normalize(a.Name);
        bool won = list.Count > 0 && ById(list[^1]) is { } last && Engine.Normalize(last.Name) == target, done = won || list.Count >= 6;
        double seconds = done ? 16 : Steps[Math.Min(list.Count, 5)];

        var bar = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        for (int k = 0; k < 6; k++)
            bar.Children.Add(new Border { Width = Steps[k] * 6 + 8, Height = 6, CornerRadius = new CornerRadius(3), Margin = new Thickness(0, 0, 3, 0),
                                          Background = JT.Brush(k <= Math.Min(list.Count, 5) || done ? JT.Lavender : Color.FromArgb(38, 255, 255, 255)) });
        Add(UI.Row(12, UI.Button($"Play {seconds} second{(seconds == 1 ? "" : "s")}", () => PlayClip(a, seconds), ""), bar));

        var rows = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
        for (int r = 0; r < 6; r++)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            if (r < list.Count && list[r] == "-") row.Children.Add(UI.Text("⏭  Skipped", 14, JT.Muted));
            else if (r < list.Count && ById(list[r]) is { } s)
            {
                bool right = Engine.Normalize(s.Name) == target;
                row.Children.Add(UI.Text(right ? "✓  " : "✗  ", 14, right ? JT.Have : JT.Missing, FontWeights.Bold));
                row.Children.Add(UI.Text(s.Name, 14));
                if (!right && s.Era == a.Era)
                    row.Children.Add(new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(6, 1, 6, 1), Margin = new Thickness(8, 0, 0, 0), Background = JT.Brush(Games.Yellow),
                                                  Child = UI.Text("right era", 11, Colors.Black, FontWeights.Bold) });
            }
            rows.Children.Add(new Border { Width = 520, MinHeight = 32, Padding = new Thickness(10, 0, 10, 0), Margin = new Thickness(0, 0, 0, 5), CornerRadius = new CornerRadius(8),
                                           HorizontalAlignment = HorizontalAlignment.Left, Background = JT.Brush(Color.FromArgb((byte)(r < list.Count ? 20 : 10), 255, 255, 255)), Child = row });
        }
        Add(rows);

        if (query.Parent is Panel holder) holder.Children.Remove(query);
        if (matches.Parent is Panel mh) mh.Children.Remove(matches);
        if (done)
        {
            Add(UI.Text(won ? $"Got it with {Steps[list.Count - 1]} second{(list.Count == 1 ? "" : "s")}!" : "Out of tries. It was:", 18, weight: FontWeights.Bold), 14);
            Add(UI.Marker(a.Name, 28).Also(t => t.Foreground = JT.Brush(JT.Lavender)));
            Add(UI.Muted(a.Era, 14));
            var buttons = UI.Row(10, UI.Button("Open the song card", () => MainWindow.Current?.OpenSong(a)));
            if (Me.HeardleDaily) buttons.Children.Add(UI.Muted("A new song tomorrow.", 13).Also(t => t.VerticalAlignment = VerticalAlignment.Center));
            else buttons.Children.Add(UI.Button("Next song", () => { StopClip(); unlimitedPick = Random.Shared.Next(10_000); unlimitedGuesses = []; Refresh(); }));
            Add(buttons, 10);
            Count(won);
            return;
        }
        int more = (int)(Steps[Math.Min(list.Count + 1, 5)] - Steps[Math.Min(list.Count, 5)]);
        Add(UI.Row(10, query, UI.Button(more > 0 ? $"Skip (+{more}s)" : "Skip", () => Guess("-"))), 12);
        Add(matches, 4);
        DrawMatches();
        Dispatcher.BeginInvoke(() => query.Focus());
    }

    void DrawMatches()
    {
        matches.Children.Clear();
        var q = Engine.Normalize(query.Text);
        if (q.Length < 2) return;
        var seen = new HashSet<string>();
        foreach (var s in Store.Shared.Songs.Where(s => Engine.Normalize(s.Name).Contains(q) && seen.Add(Engine.Normalize(s.Name))).Take(8))
        {
            var row = new DockPanel();
            var e = UI.Text(s.Era, 13, JT.Muted); DockPanel.SetDock(e, Dock.Right); row.Children.Add(e); row.Children.Add(UI.Text(s.Name, 14));
            var b = new Button { Content = row, Style = (Style)Application.Current.FindResource("Plain"), Cursor = Cursors.Hand, Padding = new Thickness(10, 6, 10, 6), HorizontalContentAlignment = HorizontalAlignment.Stretch,
                                 Background = JT.Brush(Color.FromArgb(102, 0, 0, 0)) };
            b.Click += (_, _) => Guess(s.S.Id);
            UI.AutomationName(b, s.Name);
            matches.Children.Add(b);
        }
    }

    void Guess(string id) { Guesses = [.. Guesses, id]; query.Clear(); Refresh(); }

    static void Count(bool won)
    {
        if (!Me.HeardleDaily || Me.HeardleCounted == Today) return;
        var st = (Me.HeardleStats + ",0,0,0,0").Split(',').Select(x => int.TryParse(x, out var n) ? n : 0).Take(4).ToArray();
        st[0]++;
        if (won) { st[1]++; st[2] = Me.HeardleCounted == DateTime.Now.AddDays(-1).ToString("yyyy-MM-dd") ? st[2] + 1 : 1; st[3] = Math.Max(st[3], st[2]); } else st[2] = 0;
        Me.HeardleStats = string.Join(',', st); Me.HeardleCounted = Today; Store.Shared.SavePersonal();
    }

    // The clip: its own player, so the music in the background pauses for it and comes back when you leave the page.
    static MediaPlayer? clip; static DispatcherTimer? clipEnd; static bool pausedMusic;
    void PlayClip(Song s, double seconds)
    {
        if (Listen.FileFor(s.I) is not { } file) return;
        if (Player.Shared.IsPlaying) { Player.Shared.Pause(); pausedMusic = true; }
        clipEnd?.Stop(); clip?.Close();
        var c = clip = new MediaPlayer { Volume = 0.8 };
        double start = 0;
        if (!Me.HeardleIntro)
        {
            double length = Engine.LengthSeconds(s.Length) ?? 180;
            start = length * (0.2 + 0.5 * ((uint)seed * 2654435761u % 1000) / 1000.0);
        }
        c.MediaOpened += (_, _) => { c.Position = TimeSpan.FromSeconds(start); c.Play(); clipEnd = new DispatcherTimer(TimeSpan.FromSeconds(seconds), DispatcherPriority.Normal, (t, _) => { ((DispatcherTimer)t!).Stop(); if (clip == c) c.Stop(); }, Dispatcher); };
        c.Open(new Uri(file));
    }
    static void StopClip()
    {
        clipEnd?.Stop(); clip?.Close(); clip = null;
        if (pausedMusic) { pausedMusic = false; Player.Shared.Resume(); }
    }
}

// MARK: - Desktop widgets

/// Small floating widgets: a clock, what's playing (play/pause, next), up next, and an edge light that makes the
/// screen's edges glow with the music. Each is on or off in Settings; drag one to move it, right-click to close it.
static class DesktopWidgets
{
    public static readonly (string Key, string Name)[] Kinds = [("clock", "Clock"), ("playing", "What's playing"), ("upnext", "Up next"), ("playlist", "Playlist"), ("player", "Desktop player"), ("edge", "Edge light")];
    static readonly Dictionary<string, Window[]> open = [];

    public static void Apply()
    {
        if (!watching) { watching = true; Microsoft.Win32.SystemEvents.DisplaySettingsChanged += (_, _) => Application.Current?.Dispatcher.BeginInvoke(ReopenEdge); }
        foreach (var (key, _) in Kinds)
        {
            bool on = Store.Shared.Me.Widgets.Contains(key);
            if (on && !open.ContainsKey(key)) open[key] = key == "edge" ? EdgeLight.Open() : [Widget(key)];
            if (!on && open.Remove(key, out var ws)) foreach (var w in ws) w.Close();
        }
    }
    static bool watching;
    /// A screen plugged in or out (or "every screen" changed): the edge light goes round the screens there are now.
    public static void ReopenEdge()
    {
        if (!open.Remove("edge", out var ws)) return;
        foreach (var w in ws) w.Close();
        open["edge"] = EdgeLight.Open();
    }
    public static void Set(string key, bool on)
    {
        var list = Store.Shared.Me.Widgets; list.Remove(key); if (on) list.Add(key);
        Store.Shared.SavePersonal(); Apply();
    }

    static Window Widget(string key)
    {
        var (content, w, h) = key switch { "clock" => (Clock(), 260.0, 130.0), "playing" => (Playing(), 340.0, 96.0), "playlist" => (PlaylistList(), 290.0, 300.0),
                                            "player" => (DesktopPlayer(), 320.0, Store.Shared.Me.PlayerFolded ? 76.0 : 330.0), _ => (UpNext(), 280.0, 220.0) };
        var box = new Border { CornerRadius = new CornerRadius(18), Padding = new Thickness(14), Background = JT.Brush(Color.FromArgb(200, 15, 8, 33)),
                               BorderBrush = JT.Brush(Color.FromArgb(36, 255, 255, 255)), BorderThickness = new Thickness(1), Child = content };
        var win = new Window
        {
            Width = w, Height = h, WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent, Topmost = true,
            ShowInTaskbar = false, ResizeMode = ResizeMode.NoResize, Content = box, Foreground = JT.Brush(JT.Mist), ShowActivated = false,
        };
        System.Windows.Documents.TextElement.SetFontFamily(win, JT.Body);
        var spots = Store.Shared.Me.WidgetSpots;
        var screen = SystemParameters.WorkArea; int k = Array.FindIndex(Kinds, x => x.Key == key);
        var at = spots.TryGetValue(key, out var p) && p.Length == 2 ? p : [screen.Right - w - 30, Math.Min(screen.Bottom - h - 20, screen.Top + 30 + k * 150)];
        win.Left = Math.Clamp(at[0], SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - w);
        win.Top = Math.Clamp(at[1], SystemParameters.VirtualScreenTop, SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - h);
        // DragMove returns when the mouse is let go: save the spot once, not on every pixel
        var locked = Store.Shared.Me.WidgetLocked;
        win.MouseLeftButtonDown += (_, _) => { if (locked.Contains(key)) return; try { win.DragMove(); } catch (InvalidOperationException) { return; } spots[key] = [win.Left, win.Top]; Store.Shared.SavePersonal(); };
        var menu = new ContextMenu();
        var lockItem = new MenuItem(); menu.Opened += (_, _) => lockItem.Header = locked.Contains(key) ? "Unlock position" : "Lock position";
        lockItem.Click += (_, _) => { if (!locked.Remove(key)) locked.Add(key); Store.Shared.SavePersonal(); };
        var close = new MenuItem { Header = "Close this widget" }; close.Click += (_, _) => Set(key, false);
        menu.Items.Add(lockItem); menu.Items.Add(close);
        box.ContextMenu = menu;
        win.Show();
        return win;
    }

    static FrameworkElement Clock()
    {
        var date = UI.Text("", 13, JT.Lavender, FontWeights.SemiBold);
        var time = new TextBlock { FontSize = 60, FontWeight = FontWeights.Bold, FontFamily = new FontFamily("Bahnschrift"), Effect = new DropShadowEffect { Color = JT.Lavender, BlurRadius = 18, ShadowDepth = 0, Opacity = 0.6 } };
        void Tick() { var now = DateTime.Now; date.Text = now.ToString("dddd, MMM d"); time.Text = now.ToString("h:mm"); }
        Tick();
        var timer = new DispatcherTimer(TimeSpan.FromSeconds(10), DispatcherPriority.Background, (_, _) => Tick(), Dispatcher.CurrentDispatcher);
        var col = UI.Column(0, date, time);
        // takes the cover's color while a song plays
        var tint = new SolidColorBrush(JT.Lavender); date.Foreground = tint;
        string? tintFor = "\0";
        async void Tint()
        {
            var p = Player.Shared; var f = p.IsPlaying ? p.CurrentFile : null;
            if (f == tintFor) return; tintFor = f;
            var c = JT.Lavender; var i = f is null ? -1 : Store.Shared.SongForFile(f);
            if (i >= 0 && await Art.For(Store.Shared.Catalog[i]) is { } pic) try { if (PlayerPage.Hues(pic) is [var hue, ..]) c = hue; } catch (Exception) { }
            if (tintFor != f) return;
            var fade = new System.Windows.Media.Animation.ColorAnimation(c, TimeSpan.FromSeconds(1.2));
            tint.BeginAnimation(SolidColorBrush.ColorProperty, fade); time.Effect?.BeginAnimation(DropShadowEffect.ColorProperty, fade);
        }
        void Changed() => col.Dispatcher.BeginInvoke(Tint);
        col.Loaded += (_, _) => { Player.Shared.Changed += Changed; Tint(); };
        col.Unloaded += (_, _) => { timer.Stop(); Player.Shared.Changed -= Changed; };
        return col;
    }

    static FrameworkElement Playing()
    {
        var p = Player.Shared;
        var img = new Image { Width = 60, Height = 60, Stretch = Stretch.UniformToFill };
        var art = new Border { Width = 60, Height = 60, CornerRadius = new CornerRadius(10), ClipToBounds = true, Child = img, Background = JT.Brush(Color.FromArgb(30, 255, 255, 255)) };
        var title = UI.Text("", 14, weight: FontWeights.Bold).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis);
        var era = UI.Text("", 13, JT.Muted).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis);
        var play = UI.IconButton("", "Play or pause", () => p.TogglePause(), 15);
        var next = UI.IconButton("", "Next song", () => p.Skip(), 15);
        string? shown = null;
        async void Draw()
        {
            title.Text = p.Title ?? "Nothing playing";
            ((TextBlock)play.Content).Text = p.IsPlaying ? "" : "";
            if (p.CurrentFile == shown) return;
            shown = p.CurrentFile;
            var i = shown is null ? -1 : Store.Shared.SongForFile(shown);
            era.Text = i >= 0 ? Engine.EraName(Store.Shared.Catalog[i]) : "Juice Tracker";
            img.Source = JT.Image("jt-logo"); img.Stretch = Stretch.Uniform;
            if (i >= 0 && await Art.For(Store.Shared.Catalog[i]) is { } pic && shown == p.CurrentFile) { img.Source = pic; img.Stretch = Stretch.UniformToFill; }
        }
        var text = UI.Column(3, title, era, UI.Row(14, play, next));
        text.Margin = new Thickness(12, 0, 0, 0);
        var row = new DockPanel(); DockPanel.SetDock(art, Dock.Left); row.Children.Add(art); row.Children.Add(text);
        void Changed() => row.Dispatcher.BeginInvoke(Draw);
        row.Loaded += (_, _) => { p.Changed += Changed; Draw(); };
        row.Unloaded += (_, _) => p.Changed -= Changed;
        return row;
    }

    /// A playlist (or the songs you rated 4 or 5 hearts) on the desktop; click a song to play from it.
    static FrameworkElement PlaylistList()
    {
        var store = Store.Shared; var col = new StackPanel();
        var pick = new ComboBox { MinWidth = 160, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 0, 0, 6) };
        var rows = new StackPanel();
        void Draw()
        {
            var me = store.Me; var list = me.Playlists.FirstOrDefault(p => p.Id == me.WidgetPlaylist);
            var ids = list?.Songs ?? me.Ratings.Where(r => r.Value >= 4).Select(r => r.Key).ToList();
            var byId = store.Songs.GroupBy(s => s.S.Id).ToDictionary(g => g.Key, g => g.First());
            var songs = ids.Select(id => byId.GetValueOrDefault(id)).OfType<Song>().Where(s => s.Owned).ToList();
            rows.Children.Clear();
            if (songs.Count == 0) rows.Children.Add(UI.Muted(list is null ? "Rate songs 4 or 5 hearts to see them here." : "No songs you have in this playlist.", 13).Also(t => t.TextWrapping = TextWrapping.Wrap));
            for (int k = 0; k < songs.Count; k++)
            {
                int from = k;
                var t = UI.Text($"{k + 1}. {songs[k].Name}", 13, Player.Shared.Title == songs[k].Name ? JT.Lavender : JT.Mist).Also(x => { x.TextTrimming = TextTrimming.CharacterEllipsis; x.Margin = new Thickness(0, 2, 0, 0); x.Cursor = Cursors.Hand; });
                // on the press: a press the widget doesn't take starts dragging it, and the release never comes
                t.MouseLeftButtonDown += (_, e) => { Listen.PlayInOrder(songs.Skip(from).Select(s => s.I)); e.Handled = true; };
                rows.Children.Add(t);
            }
        }
        var names = new List<(string Id, string Name)> { ("", "Liked songs") }; names.AddRange(store.Me.Playlists.Select(p => (p.Id, p.Name)));
        pick.ItemsSource = names.Select(n => n.Name).ToList();
        pick.SelectedIndex = Math.Max(0, names.FindIndex(n => n.Id == store.Me.WidgetPlaylist));
        pick.SelectionChanged += (_, _) => { if (pick.SelectedIndex >= 0) { store.Me.WidgetPlaylist = names[pick.SelectedIndex].Id; store.SavePersonal(); Draw(); } };
        UI.AutomationName(pick, "Which playlist");
        col.Children.Add(pick); col.Children.Add(new ScrollViewer { Content = rows, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = 220 });
        void Changed() => col.Dispatcher.BeginInvoke(Draw);
        col.Loaded += (_, _) => { Player.Shared.Changed += Changed; Draw(); };
        col.Unloaded += (_, _) => Player.Shared.Changed -= Changed;
        return col;
    }

    /// What's playing and what's next as glass cards with a control bar; folds down to a capsule.
    static FrameworkElement DesktopPlayer()
    {
        var p = Player.Shared; var me = Store.Shared.Me;
        var col = new StackPanel();
        var img = new Image { Stretch = Stretch.UniformToFill };
        string? shown = null;
        async void Art()
        {
            if (p.CurrentFile == shown) return;
            shown = p.CurrentFile; img.Source = JT.Image("jt-logo");
            var i = shown is null ? -1 : Store.Shared.SongForFile(shown);
            if (i >= 0 && await JuiceTracker.App.Art.For(Store.Shared.Catalog[i]) is { } pic && shown == p.CurrentFile) img.Source = pic;
        }
        Button Icon(string glyph, string name, Action click) => UI.IconButton(glyph, name, click, 16);
        StackPanel Controls() => UI.Row(16, Icon("\uE892", "Start the song again", () => p.Seek(TimeSpan.Zero)),
                                        Icon(p.IsPlaying ? "\uE769" : "\uE768", "Play or pause", () => { if (p.CurrentFile is null) { p.SetOn(true); p.Resume(); } else p.TogglePause(); }),
                                        Icon("\uE893", "Next song", () => p.Skip()));
        void Draw()
        {
            Art(); col.Children.Clear();
            bool folded = me.PlayerFolded;
            var art = new Border { Width = folded ? 40 : 56, Height = folded ? 40 : 56, CornerRadius = new CornerRadius(10), ClipToBounds = true, Child = img };
            var text = UI.Column(2, UI.Text(p.Title ?? "Nothing playing", 14, weight: FontWeights.Bold).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis));
            if (!folded) text.Children.Add(UI.Muted(p.CurrentFile is { } f && Store.Shared.SongForFile(f) is var k and >= 0 ? Engine.EraName(Store.Shared.Catalog[k]) : "Juice Tracker", 13));
            text.Margin = new Thickness(10, 0, 6, 0); text.VerticalAlignment = VerticalAlignment.Center;
            var fold = Icon(folded ? "\uE70D" : "\uE70E", folded ? "Show the queue" : "Fold into a capsule", () =>
            {
                me.PlayerFolded = !me.PlayerFolded; Store.Shared.SavePersonal();
                if (Window.GetWindow(col) is { } w) w.Height = me.PlayerFolded ? 76 : 330;
                Draw();
            });
            var head = new DockPanel(); DockPanel.SetDock(art, Dock.Left); DockPanel.SetDock(fold, Dock.Right); head.Children.Add(art); head.Children.Add(fold);
            if (folded) { var c = Controls(); DockPanel.SetDock(c, Dock.Right); c.Margin = new Thickness(0, 0, 10, 0); head.Children.Add(c); }
            head.Children.Add(text);
            col.Children.Add(head);
            if (folded) return;
            for (int n = 0; n < Math.Min(4, p.UpNext.Count); n++)
                col.Children.Add(new Border { Margin = new Thickness(0, 8, 0, 0), Padding = new Thickness(10, 7, 10, 7), CornerRadius = new CornerRadius(10),
                                              Background = JT.Brush(Color.FromArgb(18, 255, 255, 255)), BorderBrush = JT.Brush(Color.FromArgb(26, 255, 255, 255)), BorderThickness = new Thickness(1),
                                              Child = UI.Text($"{n + 1}. {p.UpNext[n].Title}", 13).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis) });
            if (p.UpNext.Count == 0) col.Children.Add(UI.Muted(me.AmbientEra.Length == 0 ? "Shuffle after this" : $"{me.AmbientEra} after this", 13).Also(t => t.Margin = new Thickness(0, 8, 0, 0)));
            var bar = Controls(); bar.HorizontalAlignment = HorizontalAlignment.Center; bar.Margin = new Thickness(0, 14, 0, 0);
            col.Children.Add(bar);
        }
        string key = "";
        void Changed() => col.Dispatcher.BeginInvoke(() =>
        {
            var k = $"{p.CurrentFile}|{p.IsPlaying}|{string.Join("|", p.UpNext.Take(4).Select(x => x.Title))}"; // the player ticks 4 times a second: redraw only on a change
            if (k != key) { key = k; Draw(); }
        });
        col.Loaded += (_, _) => { p.Changed += Changed; Draw(); };
        col.Unloaded += (_, _) => p.Changed -= Changed;
        return col;
    }

    static FrameworkElement UpNext()
    {
        var p = Player.Shared; var col = new StackPanel();
        void Draw()
        {
            col.Children.Clear();
            col.Children.Add(UI.Marker("Up next", 18).Also(t => t.Foreground = JT.Brush(JT.Lavender)));
            if (p.Title is { } t) col.Children.Add(UI.Text($"♪ {t}", 13, weight: FontWeights.Bold).Also(x => { x.TextTrimming = TextTrimming.CharacterEllipsis; x.Margin = new Thickness(0, 4, 0, 4); }));
            if (p.UpNext.Count == 0) col.Children.Add(UI.Muted(Store.Shared.Me.AmbientEra.Length == 0 ? "Shuffle after this" : $"{Store.Shared.Me.AmbientEra} after this", 13));
            for (int k = 0; k < Math.Min(6, p.UpNext.Count); k++)
                col.Children.Add(UI.Text($"{k + 1}. {p.UpNext[k].Title}", 13).Also(x => { x.TextTrimming = TextTrimming.CharacterEllipsis; x.Margin = new Thickness(0, 2, 0, 0); }));
        }
        void Changed() => col.Dispatcher.BeginInvoke(Draw);
        col.Loaded += (_, _) => { p.Changed += Changed; Draw(); };
        col.Unloaded += (_, _) => p.Changed -= Changed;
        return col;
    }
}

/// A glow along the screen's edges in the song's colours, brighter on the beat. Four thin click-through strips
/// (not one full-screen see-through window, which Windows would redraw whole on every change).
static class EdgeLight
{
    static double Thick => Store.Shared.Me.EdgeWidth;
    public static Window[] Open()
    {
        var glow = new SolidColorBrush(JT.Lavender);
        Window Strip(double x, double y, double w, double h, Point from, Point to)
        {
            var brush = new LinearGradientBrush { StartPoint = from, EndPoint = to };
            brush.GradientStops.Add(new GradientStop(Colors.White, 0)); brush.GradientStops.Add(new GradientStop(Colors.Transparent, 1));
            var fill = new Border { Background = glow, OpacityMask = brush };
            var win = new Window { Left = x, Top = y, Width = w, Height = h, WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent,
                                   Topmost = true, ShowInTaskbar = false, ResizeMode = ResizeMode.NoResize, ShowActivated = false, Focusable = false, IsHitTestVisible = false, Content = fill, Opacity = 0 };
            win.SourceInitialized += (_, _) => { var h2 = new WindowInteropHelper(win).Handle; SetWindowLong(h2, -20, GetWindowLong(h2, -20) | 0x20 | 0x80000 | 0x80); }; // click-through, layered, no Alt+Tab
            win.Show();
            return win;
        }
        // round every screen (Settings), or only the main one; screen pixels to WPF's units at the main window's scale
        double scale = Application.Current.MainWindow is { } mw && PresentationSource.FromVisual(mw)?.CompositionTarget is { } ct ? ct.TransformFromDevice.M11 : 1;
        var screens = System.Windows.Forms.Screen.AllScreens.Where(s => s.Primary || Store.Shared.Me.EdgeAll).Select(s => s.Bounds);
        var strips = screens.SelectMany(r =>
        {
            double x = r.X * scale, y = r.Y * scale, a = r.Width * scale, b = r.Height * scale;
            return new[]
            {
                Strip(x, y, a, Thick, new Point(0, 0), new Point(0, 1)), Strip(x, y + b - Thick, a, Thick, new Point(0, 1), new Point(0, 0)),
                Strip(x, y + Thick, Thick, b - 2 * Thick, new Point(0, 0), new Point(1, 0)), Strip(x + a - Thick, y + Thick, Thick, b - 2 * Thick, new Point(1, 0), new Point(0, 0)),
            };
        }).ToArray();
        // follow the music: loudness 15 times a second (off the UI thread), colour from the song's picture
        var meter = new LevelMeter(); var boost = new LevelBoost(); bool measuring = false; string? colourFor = null;
        var timer = new DispatcherTimer(TimeSpan.FromMilliseconds(66), DispatcherPriority.Background, async (_, _) =>
        {
            var p = Player.Shared;
            // the cover's strongest color, or your own (Settings)
            var own = Themes.Hex(Store.Shared.Me.EdgeColor);
            if ($"{p.CurrentFile}|{own}" != colourFor)
            {
                colourFor = $"{p.CurrentFile}|{own}";
                var i = p.CurrentFile is null ? -1 : Store.Shared.SongForFile(p.CurrentFile);
                var c = own ?? JT.Lavender;
                if (own is null && i >= 0 && await Art.For(Store.Shared.Catalog[i]) is { } pic) try { var hues = PlayerPage.Hues(pic); if (hues.Length > 0) c = hues[0]; } catch (Exception) { }
                glow.BeginAnimation(SolidColorBrush.ColorProperty, new System.Windows.Media.Animation.ColorAnimation(c, TimeSpan.FromSeconds(1.2)));
            }
            if (measuring) return;
            // fades out when the music stops
            if (!p.IsPlaying || p.CurrentFile is not { } f) { foreach (var s in strips) s.Opacity = Math.Max(0, s.Opacity - 0.05); return; }
            measuring = true; var at = p.Position;
            var level = boost.Apply(await Task.Run(() => meter.Level(f, at))); measuring = false;
            // hidden while another app is full screen; Settings' glow sets how bright
            double bright = FullScreenApp() ? 0 : Math.Clamp((0.2 + level * 0.8) * Store.Shared.Me.EdgeGlow, 0, 1);
            foreach (var s in strips) s.Opacity = bright;
        }, Dispatcher.CurrentDispatcher);
        timer.Start();
        strips[0].Closed += (_, _) => timer.Stop();
        return strips;
    }
    /// Another app's window in front, covering its whole screen (a game, a video, a presentation).
    static bool FullScreenApp()
    {
        var hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero || hwnd == GetShellWindow() || hwnd == GetDesktopWindow()) return false;
        GetWindowThreadProcessId(hwnd, out var pid);
        if (pid == Environment.ProcessId || !GetWindowRect(hwnd, out var r)) return false;
        var screen = System.Windows.Forms.Screen.FromHandle(hwnd).Bounds;
        return r.Left <= screen.Left && r.Top <= screen.Top && r.Right >= screen.Right && r.Bottom >= screen.Bottom;
    }
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect r);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hwnd, int index, int value);
}

// MARK: - Song share picture

/// A song as a picture (1080 × 1350): the era's art, the title, the era and dates, and whether you have it.
static class SongPicture
{
    public static async Task<BitmapSource> Make(Song s)
    {
        var json = await Store.Shared.DetailsAsync(s.S);
        var full = json is not null ? Engine.CleanSong(json) : s.S;
        var art = await Art.For(s.S);
        var card = new Grid { Width = 1080, Height = 1350, Background = Games.Night, ClipToBounds = true };
        if (art is not null) card.Children.Add(new Image { Source = art, Stretch = Stretch.UniformToFill, Opacity = 0.18 });
        var col = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(80, 0, 80, 0) };
        col.Children.Add(new Border { Width = 420, Height = 420, CornerRadius = new CornerRadius(30), ClipToBounds = true, Margin = new Thickness(0, 0, 0, 34),
                                      Background = new ImageBrush(art ?? JT.Image("jt-logo")) { Stretch = art is null ? Stretch.Uniform : Stretch.UniformToFill } });
        col.Children.Add(new TextBlock { Text = s.Name, FontFamily = JT.Marker, FontSize = 64, Foreground = Brushes.White, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap });
        col.Children.Add(new TextBlock { Text = $"Juice WRLD · {s.Era} · {s.Category}", FontSize = 28, FontWeight = FontWeights.SemiBold, Foreground = JT.Brush(JT.Lavender), TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 14, 0, 26) });
        var facts = new Grid { Width = 820 }; facts.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(220) }); facts.ColumnDefinitions.Add(new ColumnDefinition());
        foreach (var (k, v) in new[] { ("Recorded", full.RecordDates), ("Released", full.Release), ("Surfaced", full.LeakDate), ("Length", full.Length), ("Produced by", full.Producers) }.Where(x => x.Item2.Trim().Length > 0))
        {
            facts.RowDefinitions.Add(new RowDefinition());
            var key = new TextBlock { Text = k, FontSize = 26, Foreground = JT.Brush(Color.FromArgb(140, 255, 255, 255)), Margin = new Thickness(0, 0, 0, 10) };
            var val = new TextBlock { Text = v, FontSize = 26, Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap, MaxHeight = 70 };
            Grid.SetRow(key, facts.RowDefinitions.Count - 1); Grid.SetRow(val, facts.RowDefinitions.Count - 1); Grid.SetColumn(val, 1);
            facts.Children.Add(key); facts.Children.Add(val);
        }
        col.Children.Add(facts);
        col.Children.Add(new Border { CornerRadius = new CornerRadius(30), Padding = new Thickness(26, 12, 26, 12), Margin = new Thickness(0, 26, 0, 0), HorizontalAlignment = HorizontalAlignment.Center,
                                      Background = JT.Brush(Color.FromArgb(20, 255, 255, 255)),
                                      Child = new TextBlock { Text = s.Owned ? "✓ In my library" : "Still hunting for this one", FontSize = 28, FontWeight = FontWeights.Bold, Foreground = JT.Brush(s.Owned ? JT.Have : JT.New) } });
        card.Children.Add(col);
        card.Children.Add(new TextBlock { Text = "Juice Tracker", FontFamily = JT.Marker, FontSize = 22, Foreground = JT.Brush(Color.FromArgb(89, 255, 255, 255)), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 36) });
        var bmp = Games.Render(card, 1080, 1350);
        return bmp;
    }

    /// The song card's "Share picture" menu: save it or copy it.
    public static ContextMenu Menu(Song s)
    {
        var menu = new ContextMenu();
        var save = new MenuItem { Header = "Save picture…" };
        save.Click += async (_, _) =>
        {
            var d = new Microsoft.Win32.SaveFileDialog { FileName = $"{Engine.SafeName(s.Name)}.png", Filter = "PNG image|*.png" };
            if (d.ShowDialog() != true) return;
            Games.SavePng(await Make(s), d.FileName);
        };
        var copy = new MenuItem { Header = "Copy picture" };
        copy.Click += async (_, _) => Clipboard.SetImage(await Make(s));
        menu.Items.Add(save); menu.Items.Add(copy);
        return menu;
    }
}
