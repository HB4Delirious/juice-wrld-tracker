using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;

namespace JuiceTracker.App;

/// The home screen, like the Mac app's: the counts, "You have N of M songs", the progress meter and categories,
/// notices and "On this day", the era cards, then the song list with its tabs and search.
public sealed class CollectionPage : ScrollViewer, IRefresh
{
    readonly StackPanel body = new() { Margin = new Thickness(40, 34, 40, 80), MaxWidth = 1240 };
    readonly StackPanel top = new(), list = new();
    readonly TextBox search = new() { Width = 260 };
    readonly StackPanel tabs = new() { Orientation = Orientation.Horizontal };
    string tab = "all";
    string? era;
    int limit = 200;
    int shownHave = -1;

    public CollectionPage()
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        Content = body;
        body.Children.Add(top);
        body.Children.Add(list);
        search.TextChanged += (_, _) => { limit = 200; BuildList(); };
        UI.AutomationName(search, "Search songs or eras");
        foreach (var (key, label) in new[] { ("all", "All"), ("have", "In your library"), ("missing", "Not in your library"), ("wish", "Wishlist"), ("rated", "Top rated") })
        {
            var r = new RadioButton { Content = label, Style = (Style)Application.Current.FindResource("Segment"), IsChecked = key == tab, GroupName = "tabs" };
            r.Checked += (_, _) => { tab = key; limit = 200; BuildList(); };
            tabs.Children.Add(r);
        }
        Refresh();
    }

    public void FocusSearch() { search.Focus(); search.SelectAll(); list.BringIntoView(); }

    public void Refresh() { BuildTop(); BuildList(); }

    void BuildTop()
    {
        var store = Store.Shared;
        top.Children.Clear();
        // the counts line
        var grails = store.Songs.Count(s => s.Owned && Engine.Rarity(s.S, true) == "Grail");
        var line = new DockPanel { Margin = new Thickness(0, 0, 0, 22) };
        var setup = UI.Link("Setup (show)", () => MainWindow.Current?.ShowOverlay(SetupSheet()), 15);
        DockPanel.SetDock(setup, Dock.Right); line.Children.Add(setup);
        var counts = new TextBlock { FontSize = 15.5 };
        Bold(counts, $"{store.Catalog.Count:N0}"); Plain(counts, " songs in the catalog      ");
        Bold(counts, $"{store.Files.Count:N0}"); Plain(counts, " files in your music folder");
        if (grails > 0) { Plain(counts, "      "); counts.Inlines.Add(new Run($"{grails:N0}") { FontWeight = FontWeights.Bold, Foreground = JT.Brush(JT.Gold) }); Plain(counts, grails == 1 ? " grail" : " grails"); }
        line.Children.Add(counts);
        top.Children.Add(line);

        // "You have N of M songs", the number in rainbow letters, rolling up
        var have = store.Owned.Count;
        var headline = new Grid();
        var text = new TextBlock { FontFamily = JT.Marker, FontSize = 64, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 200, 0), LineHeight = 70,
                                   RenderTransform = new RotateTransform(-1.2), Effect = UI.Glow(JT.Lavender, 14, 0.45) };
        var number = new Run($"{(shownHave < 0 ? 0 : shownHave):N0}") { Foreground = JT.Gradient(JT.Count) };
        text.Inlines.Add(new Run("You have ")); text.Inlines.Add(number); text.Inlines.Add(new Run($" of {store.Catalog.Count:N0} songs") { Foreground = JT.Brush(Color.FromArgb(242, JT.Muted.R, JT.Muted.G, JT.Muted.B)) });
        RollUp(number, shownHave < 0 ? 0 : shownHave, have);
        shownHave = have;
        headline.Children.Add(text);
        headline.Children.Add(Doodles());
        top.Children.Add(headline);

        // the meter, with the butterfly riding it
        var pct = (double)have / Math.Max(store.Catalog.Count, 1);
        var meter = new Grid { Height = 12, Margin = new Thickness(0, 26, 0, 0) };
        meter.Children.Add(new Border { CornerRadius = new CornerRadius(6), Background = JT.Brush(JT.Raise) });
        var fill = new Border { CornerRadius = new CornerRadius(6), Background = JT.Gradient(JT.Rainbow), HorizontalAlignment = HorizontalAlignment.Left };
        var fly = new Image { Source = JT.Image("jt-fly"), Width = 32, Height = 32, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, -20, 0, 0), VerticalAlignment = VerticalAlignment.Top };
        meter.Children.Add(fill); meter.Children.Add(fly);
        meter.SizeChanged += (_, e) => { var w = Math.Max(12, e.NewSize.Width * pct); fill.Width = w; fly.Margin = new Thickness(Math.Max(0, w - 16), -10, 0, 0); };
        var flap = new ScaleTransform(1, 1, 16, 16); fly.RenderTransform = flap;
        flap.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(1, 0.75, TimeSpan.FromSeconds(0.35)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever });
        top.Children.Add(meter);

        // the categories
        var cats = new UniformGrid { Rows = 1 };
        for (int n = 0; n < store.Cats.Count && n < 6; n++)
        {
            var c = store.Cats[n];
            var cell = new StackPanel { Margin = new Thickness(18, 16, 18, 16) };
            var head = new DockPanel();
            var num = UI.Text($"{c.Have:N0} / {c.Total:N0}", 15.5, JT.Muted); DockPanel.SetDock(num, Dock.Right); head.Children.Add(num);
            head.Children.Add(UI.Text(c.Name, 15.5));
            cell.Children.Add(head);
            var bar = UI.Bar((double)c.Have / Math.Max(c.Total, 1), JT.Brush(JT.Have), 4, 0.2 + n * 0.1); bar.Margin = new Thickness(0, 10, 0, 0);
            cell.Children.Add(bar);
            var wrap = new Grid(); wrap.Children.Add(cell);
            if (n > 0) wrap.Children.Add(new Rectangle { Width = 1, Fill = JT.Brush(JT.Line), HorizontalAlignment = HorizontalAlignment.Left });
            cats.Children.Add(wrap);
        }
        var catPanel = UI.Panel(cats, 1, 0); catPanel.Margin = new Thickness(0, 24, 0, 0);
        top.Children.Add(catPanel);

        // notices and "On this day"
        var notes = new StackPanel { Margin = new Thickness(0, 26, 0, 0) };
        foreach (var (msg, released) in store.Notices)
        {
            var row = new DockPanel { Margin = new Thickness(0, 8, 0, 8) };
            var bar = new Border { Width = 2.5, CornerRadius = new CornerRadius(1.25), Background = JT.Brush(released ? JT.Have : JT.New), Margin = new Thickness(0, 0, 18, 0) };
            DockPanel.SetDock(bar, Dock.Left); row.Children.Add(bar);
            row.Children.Add(UI.Text(msg, 16, wrap: true));
            notes.Children.Add(row);
        }
        if (store.Today.Count > 0)
        {
            var today = new StackPanel();
            var title = UI.Marker("On this day", 20); title.Margin = new Thickness(0, 0, 0, 4); today.Children.Add(title);
            foreach (var (head, songs, more) in store.Today)
            {
                var t = new TextBlock { FontSize = 15.5, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 4), Cursor = Cursors.Hand };
                t.Inlines.Add(new Run(head + " ") { FontWeight = FontWeights.Bold });
                for (int k = 0; k < songs.Count; k++)
                {
                    var s = store.Songs[songs[k]];
                    var link = new Hyperlink(new Run(s.Name)) { Foreground = JT.Brush(JT.Mist), TextDecorations = null };
                    link.Click += (_, _) => MainWindow.Current?.OpenSong(s);
                    t.Inlines.Add(link);
                    if (s.Owned) t.Inlines.Add(new Run(" ✓") { Foreground = JT.Brush(JT.Have) });
                    if (k < songs.Count - 1) t.Inlines.Add(new Run(", "));
                }
                if (more > 0) t.Inlines.Add(new Run($" and {more} more"));
                today.Children.Add(t);
            }
            notes.Children.Add(UI.Panel(today, 2, 18));
        }
        top.Children.Add(notes);

        // the eras
        var erasTitle = UI.Title("Eras", 34); erasTitle.Margin = new Thickness(0, 44, 0, 0);
        top.Children.Add(erasTitle);
        var pick = UI.Muted("Pick an era to see its songs below.", 16); pick.Margin = new Thickness(0, 10, 0, 20);
        top.Children.Add(pick);
        var grid = new WrapPanel();
        for (int n = 0; n < store.EraList.Count; n++) grid.Children.Add(EraCard(store.EraList[n], n));
        grid.SizeChanged += (_, e) =>
        {
            int cols = Math.Max(1, (int)((e.NewSize.Width + 16) / (230 + 16)));
            double w = (e.NewSize.Width - (cols - 1) * 16) / cols;
            foreach (FrameworkElement c in grid.Children) { c.Width = Math.Floor(w); }
        };
        top.Children.Add(grid);

        // the song list's header
        var header = new StackPanel { Margin = new Thickness(0, 34, 0, 12) };
        // the tabs and search box are kept across redraws (their state lives in them): out of the old row first
        var tabsBox = new Border { Background = JT.Brush(Color.FromArgb(30, 255, 255, 255)), CornerRadius = new CornerRadius(8), Padding = new Thickness(2) };
        if (tabs.Parent is Border old) old.Child = null;
        tabsBox.Child = tabs;
        if (search.Parent is Panel sp) sp.Children.Remove(search);
        var filters = UI.Row(12, tabsBox, search);
        if (era is { } e2) filters.Children.Add(Chip(e2));
        header.Children.Add(filters);
        top.Children.Add(header);
    }

    void BuildList()
    {
        var store = Store.Shared;
        list.Children.Clear();
        var songs = Filtered();
        var line = new DockPanel { Margin = new Thickness(0, 0, 0, 12) };
        var missing = songs.Where(s => !s.Owned && s.HasFile).ToList();
        if (missing.Count > 0)
        {
            var label = era is not null && tab == "all" && search.Text.Trim().Length == 0 ? $"Complete this era ({missing.Count})" : $"Download all {missing.Count} missing";
            var b = UI.Button(label, () => AskDownload(missing), "");
            DockPanel.SetDock(b, Dock.Right); line.Children.Add(b);
        }
        var countRow = UI.Row(12, UI.Text($"{songs.Count:N0} songs", 12.5, JT.Muted));
        if (tab == "wish" && songs.Count > 0) countRow.Children.Add(UI.Link("Rank wishlist…", () => MainWindow.Current?.ShowOverlay(new WishRankSheet()), 12.5).Also(l => l.Margin = new Thickness(12, 0, 0, 0)));
        line.Children.Add(countRow);
        list.Children.Add(line);
        var rows = new StackPanel();
        foreach (var s in songs.Take(limit)) rows.Children.Add(new SongRow(s));
        list.Children.Add(UI.Panel(rows, 0, 0));
        if (songs.Count > limit) { var more = UI.Link("Show more", () => { limit += 300; BuildList(); }); more.Margin = new Thickness(0, 12, 0, 0); list.Children.Add(more); }
    }

    List<Song> Filtered()
    {
        var store = Store.Shared; var q = search.Text.Trim().ToLowerInvariant(); var ratings = store.Me.Ratings;
        var output = store.Songs.Where(s =>
            (era is null || s.Era == era) &&
            (tab == "all" || (tab == "have" && s.Owned) || (tab == "missing" && !s.Owned) || (tab == "wish" && s.Wished) || (tab == "rated" && ratings.ContainsKey(s.S.Id))) &&
            (q.Length == 0 || s.Name.ToLowerInvariant().Contains(q) || s.Era.ToLowerInvariant().Contains(q) || s.S.Alt.Any(a => a.ToLowerInvariant().Contains(q)))).ToList();
        return tab == "rated" ? output.OrderByDescending(s => ratings.GetValueOrDefault(s.S.Id)).ToList() : output;
    }

    void AskDownload(List<Song> songs)
    {
        var ok = MessageBox.Show(Window.GetWindow(this), $"They download one at a time into the folders the tracker picks for each era, and carry on after a restart or if the drive drops.",
                                 $"Download {songs.Count} songs into your music folder?", MessageBoxButton.OKCancel, MessageBoxImage.Question);
        if (ok == MessageBoxResult.OK) Store.Shared.AddDownloads(songs.Select(s => s.S.Id));
    }

    FrameworkElement Chip(string name)
    {
        var b = UI.Button(name, () => { era = null; limit = 200; BuildTop(); BuildList(); }, "");
        b.ToolTip = "Show every era";
        return b;
    }

    FrameworkElement EraCard(Engine.EraStat e, int n)
    {
        bool picked = era == e.Name, complete = e.Total > 0 && e.Have >= e.Total;
        var col = new StackPanel();
        col.Children.Add(UI.Text(e.Name, 17, weight: FontWeights.SemiBold));
        if (Engine.HasValue(e.TimeFrame)) col.Children.Add(UI.Text(e.TimeFrame, 13.5, JT.Muted));
        if (Engine.HasValue(e.Description)) { var d = UI.Text(e.Description, 14, JT.Muted, wrap: true); d.MaxHeight = 40; d.TextTrimming = TextTrimming.CharacterEllipsis; d.Margin = new Thickness(0, 10, 0, 0); col.Children.Add(d); }
        var foot = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom };
        foot.Children.Add(UI.Bar(complete ? 1 : (double)e.Have / Math.Max(e.Total, 1), complete ? JT.Gradient(JT.Rainbow) : JT.Brush(JT.Have), complete ? 5 : 4, Math.Min(n * 0.035, 0.35) + 0.2));
        var count = UI.Text($"{e.Have:N0} of {e.Total:N0} {(e.Total == 1 ? "song" : "songs")}", 13.5, JT.Muted); count.Margin = new Thickness(0, 8, 0, 0);
        foot.Children.Add(count);
        var inner = new DockPanel { Margin = new Thickness(18, 16, 18, 16), LastChildFill = false };
        DockPanel.SetDock(col, Dock.Top); DockPanel.SetDock(foot, Dock.Bottom);
        inner.Children.Add(col); inner.Children.Add(foot);
        var card = new DoodleBorder { Seed = n, Child = inner, MinHeight = 168, Fill = JT.Brush(picked ? JT.Raise : JT.Dusk), Stroke = JT.Brush(picked ? JT.Lavender : JT.Line2) };
        var grid = new Grid { Margin = new Thickness(0, 0, 16, 16) };
        grid.Children.Add(card);
        if (complete)
        {
            var stamp = new Border { BorderBrush = JT.Brush(JT.Have), BorderThickness = new Thickness(2), CornerRadius = new CornerRadius(5), Padding = new Thickness(7, 1, 7, 1),
                                     Child = new TextBlock { Text = "COMPLETE", FontFamily = JT.Marker, FontSize = 15, Foreground = JT.Brush(JT.Have) },
                                     HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 14, 12),
                                     RenderTransform = new RotateTransform(-10), Opacity = 0.9 };
            grid.Children.Add(stamp);
        }
        var sticker = new Image { Source = JT.Image(EraSticker(e.Name, n)), Width = 30, Height = 30, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
                                  Margin = new Thickness(0, -12, -9, 0), RenderTransformOrigin = new Point(0.5, 0.5),
                                  Effect = new DropShadowEffect { Color = Colors.Black, Opacity = 0.45, BlurRadius = 8, ShadowDepth = 3, Direction = 270 } };
        var st = new TransformGroup { Children = { new RotateTransform(60), new ScaleTransform(0.1, 0.1) } }; sticker.RenderTransform = st; sticker.Opacity = 0;
        var delay = TimeSpan.FromSeconds(Math.Min(n * 0.035, 0.35) + 0.3); var slap = new BackEase { Amplitude = 0.6, EasingMode = EasingMode.EaseOut };
        ((RotateTransform)st.Children[0]).BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(60, 14, TimeSpan.FromSeconds(0.4)) { BeginTime = delay, EasingFunction = slap });
        ((ScaleTransform)st.Children[1]).BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.1, 1, TimeSpan.FromSeconds(0.4)) { BeginTime = delay, EasingFunction = slap });
        ((ScaleTransform)st.Children[1]).BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.1, 1, TimeSpan.FromSeconds(0.4)) { BeginTime = delay, EasingFunction = slap });
        sticker.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.2)) { BeginTime = delay });
        grid.Children.Add(sticker);
        var lift = new TranslateTransform(); grid.RenderTransform = lift;
        grid.Cursor = Cursors.Hand; grid.Background = Brushes.Transparent;
        grid.MouseEnter += (_, _) => { card.Fill = JT.Brush(JT.Raise); card.Stroke = JT.Brush(JT.Lavender); lift.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(-3, TimeSpan.FromSeconds(0.2))); };
        grid.MouseLeave += (_, _) => { card.Fill = JT.Brush(picked ? JT.Raise : JT.Dusk); card.Stroke = JT.Brush(picked ? JT.Lavender : JT.Line2); lift.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, TimeSpan.FromSeconds(0.2))); };
        grid.MouseLeftButtonUp += (_, _) => { era = picked ? null : e.Name; limit = 200; BuildTop(); BuildList(); if (era is not null) list.BringIntoView(); };
        UI.AutomationName(grid, $"{e.Name}: {e.Have} of {e.Total} songs");
        return grid;
    }

    /// The planet and the cracked heart, bobbing beside the headline.
    static FrameworkElement Doodles()
    {
        var c = new Canvas { Width = 240, Height = 230, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, -40, -24, 0), IsHitTestVisible = false };
        void Add(string name, double x, double y, double size, double rise, double turn, double delay)
        {
            var img = new Image { Source = JT.Image(name), Width = size, Height = size, RenderTransformOrigin = new Point(0.5, 0.5) };
            Canvas.SetLeft(img, x); Canvas.SetTop(img, y); c.Children.Add(img);
            var r = new RotateTransform(); var t = new TranslateTransform(); img.RenderTransform = new TransformGroup { Children = { r, t } };
            var dur = TimeSpan.FromSeconds(4.5); var ease = new SineEase { EasingMode = EasingMode.EaseInOut };
            t.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, -rise, dur) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = ease, BeginTime = TimeSpan.FromSeconds(delay) });
            r.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(0, turn, dur) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = ease, BeginTime = TimeSpan.FromSeconds(delay) });
        }
        Add("jt-planet", 70, 20, 150, 10, 6, 0);
        Add("jt-heart", 20, 130, 64, 8, -10, 1.2);
        return c;
    }

    static void Bold(TextBlock t, string s) => t.Inlines.Add(new Run(s) { FontWeight = FontWeights.Bold });
    static void Plain(TextBlock t, string s) => t.Inlines.Add(new Run(s) { Foreground = JT.Brush(JT.Muted) });

    static void RollUp(Run run, int from, int to)
    {
        if (from == to) { run.Text = $"{to:N0}"; return; }
        var start = DateTime.Now; var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(30) };
        double secs = from == 0 ? 1.4 : 0.9;
        timer.Tick += (_, _) =>
        {
            var p = Math.Min(1, (DateTime.Now - start).TotalSeconds / secs); p = 1 - Math.Pow(1 - p, 3);
            run.Text = $"{(int)Math.Round(from + (to - from) * p):N0}";
            if (p >= 1) timer.Stop();
        };
        timer.Start();
    }

    /// The sticker that fits an era: a race car for DRFL, a halo for LND, a demon for FD, balloons for the party eras,
    /// 999 flash for the 999 eras, and so on. Other eras get one of the tattoo-flash doodles.
    public static string EraSticker(string name, int n)
    {
        var k = name.ToLowerInvariant();
        (string Image, string[] Keys)[] rules =
        [
            ("jt-era-race", ["drfl", "death race"]), ("jt-era-halo", ["lnd", "legends"]), ("jt-era-demon", ["fd", "fighting demons"]),
            ("jt-era-party", ["tpne", "tpp", "party"]), ("jt-era-999", ["999"]), ("jt-sticker2", ["gb&gr", "goodbye"]),
            ("jt-era-globe", ["wod", "wrld on drugs"]), ("jt-era-vinyl", ["vinyl"]), ("jt-era-mic", ["soundcloud", "smule", "youtube", "session"]),
        ];
        var words = System.Text.RegularExpressions.Regex.Split(k, @"[^\p{L}\p{N}&]+");
        foreach (var (image, keys) in rules)
            if (keys.Any(key => key.Length <= 4 ? words.Contains(key) || k.StartsWith(key + " ") || k == key : k.Contains(key))) return image;
        return $"jt-sticker{n % 6 + 1}";
    }

    static FrameworkElement SetupSheet()
    {
        var page = new SetupPage { Width = 860, Height = 440 };
        var done = UI.Button("Done", () => MainWindow.Current?.CloseOverlay());
        done.HorizontalAlignment = HorizontalAlignment.Right; done.Margin = new Thickness(0, 0, 20, 16);
        var stack = new DockPanel();
        DockPanel.SetDock(done, Dock.Bottom); stack.Children.Add(done); stack.Children.Add(page);
        Store.Shared.Changed += page.Update;
        page.Unloaded += (_, _) => Store.Shared.Changed -= page.Update;
        return new Border { Child = stack, Background = JT.Brush(JT.Night), CornerRadius = new CornerRadius(14), BorderBrush = JT.Brush(JT.Line2), BorderThickness = new Thickness(1) };
    }
}

/// One song in the list: a wishlist star, the name (with bouncing bars when it's playing), era, category, length and
/// what you can do: "In library", "Download", or "No file".
public sealed class SongRow : Grid
{
    public SongRow(Song s)
    {
        var store = Store.Shared;
        Background = Brushes.Transparent;
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(110) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(50) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });
        Margin = new Thickness(14, 0, 14, 0);
        MinHeight = 36;

        var star = UI.IconButton(s.Wished ? "" : "", s.Wished ? "On your wishlist" : "Add to wishlist", () => store.ToggleWish(s.S.Id), 14, s.Wished ? JT.Gold : JT.Muted);
        Add(star, 0);
        var playing = Player.Shared.CurrentFile is { } f && store.Match.Owned.GetValueOrDefault(s.I)?.Any(p => store.FullPath(p) == f) == true;
        var name = UI.Text(s.Name, 14, playing ? JT.LavenderHi : JT.Mist);
        Add(playing ? UI.Row(8, UI.Icon("", 12, JT.Lavender), name) : name, 1);
        Add(UI.Text(s.Era, 14, JT.Muted), 2);
        Add(UI.Text(s.Category, 14, JT.Muted), 3);
        var len = UI.Text(s.Length, 14, JT.Muted); len.HorizontalAlignment = HorizontalAlignment.Right; len.Margin = new Thickness(0, 0, 14, 0); Add(len, 4);
        FrameworkElement status = s.Owned ? UI.Row(6, UI.Icon("", 12, JT.Have), UI.Text("In library", 14, JT.Have))
            : s.HasFile ? UI.Link("Download", () => store.AddDownloads([s.S.Id]))
            : UI.Text("No file", 14, Color.FromArgb(178, JT.Muted.R, JT.Muted.G, JT.Muted.B));
        Add(status, 5);
        Children.Add(new Rectangle { Height = 0.5, Fill = JT.Brush(JT.Line), VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(-14, 0, -14, 0) });
        SetColumnSpan(Children[^1], 6);

        var accent = new Border { Width = 3, CornerRadius = new CornerRadius(1.5), Background = JT.Brush(JT.Lavender), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(-14, 6, 0, 6), Visibility = Visibility.Hidden };
        Children.Add(accent);
        var nudge = new TranslateTransform(); RenderTransform = nudge;
        Cursor = Cursors.Hand;
        MouseEnter += (_, _) => { Background = JT.Brush(Color.FromArgb(13, 255, 255, 255)); accent.Visibility = Visibility.Visible; nudge.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(4, TimeSpan.FromSeconds(0.15))); };
        MouseLeave += (_, _) => { Background = Brushes.Transparent; accent.Visibility = Visibility.Hidden; nudge.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(0, TimeSpan.FromSeconds(0.15))); };
        MouseLeftButtonUp += (_, e) => { if (e.OriginalSource is not DependencyObject d || FindButton(d) is null) MainWindow.Current?.OpenSong(s); };
        var menu = new ContextMenu();
        var open = new MenuItem { Header = "Open song card" }; open.Click += (_, _) => MainWindow.Current?.OpenSong(s); menu.Items.Add(open);
        if (s.Owned)
        {
            var play = new MenuItem { Header = "Play" }; play.Click += (_, _) => SongCard.Play(s); menu.Items.Add(play);
            var next = new MenuItem { Header = "Play next" }; next.Click += (_, _) => Listen.PlayNext(s); menu.Items.Add(next);
        }
        var add = new MenuItem { Header = "Add to playlist…" };
        add.Click += (_, _) => { var m = Listen.PlaylistMenu([s.S.Id]); m.PlacementTarget = this; m.IsOpen = true; };
        menu.Items.Add(add);
        ContextMenu = menu;
        UI.AutomationName(this, $"{s.Name}, {s.Era}, {(s.Owned ? "in your library" : s.HasFile ? "can be downloaded" : "no file")}");
    }

    void Add(FrameworkElement e, int col) { e.VerticalAlignment = VerticalAlignment.Center; SetColumn(e, col); Children.Add(e); }
    static Button? FindButton(DependencyObject d)
    {
        for (var x = d; x is not null; x = x is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(x) : LogicalTreeHelper.GetParent(x)) if (x is Button b) return b;
        return null;
    }
}

/// Put your wishlist in order; "Download wishlist" and wishlist alerts download the top songs first.
public sealed class WishRankSheet : Border
{
    readonly StackPanel rows = new();
    public WishRankSheet()
    {
        Width = 560; Height = 560; Background = JT.Brush(Color.FromRgb(20, 10, 44)); CornerRadius = new CornerRadius(14);
        BorderBrush = JT.Brush(JT.Line2); BorderThickness = new Thickness(1); Padding = new Thickness(24);
        var bottom = new DockPanel { Margin = new Thickness(0, 12, 0, 0) };
        var done = UI.Button("Done", () => MainWindow.Current?.CloseOverlay()); done.IsCancel = true; DockPanel.SetDock(done, Dock.Right); bottom.Children.Add(done);
        bottom.Children.Add(UI.Button("Download wishlist", () => Store.Shared.DownloadWishlist()).Also(b => b.HorizontalAlignment = HorizontalAlignment.Left));
        var dock = new DockPanel();
        var head = UI.Column(6, new TextBlock { Text = "Rank your wishlist", FontFamily = JT.Marker, FontSize = 28 }, UI.Muted("Move the songs you want most to the top. Wishlist downloads go in this order.", 13));
        DockPanel.SetDock(head, Dock.Top); DockPanel.SetDock(bottom, Dock.Bottom);
        dock.Children.Add(head); dock.Children.Add(bottom);
        dock.Children.Add(new ScrollViewer { Content = rows, Margin = new Thickness(0, 12, 0, 0), VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Child = dock;
        Draw();
    }
    void Draw()
    {
        var store = Store.Shared; var ids = store.WishRanked; var byId = store.Songs.GroupBy(s => s.S.Id).ToDictionary(g => g.Key, g => g.First());
        rows.Children.Clear();
        for (int n = 0; n < ids.Count; n++)
        {
            int k = n; var row = new DockPanel { Margin = new Thickness(0, 4, 0, 4) };
            var tools = UI.Row(4, UI.IconButton("\uE70E", "Move up", () => Move(ids, k, -1), 12), UI.IconButton("\uE70D", "Move down", () => Move(ids, k, 1), 12));
            DockPanel.SetDock(tools, Dock.Right); row.Children.Add(tools);
            var s = byId.GetValueOrDefault(ids[n]);
            row.Children.Add(UI.Row(10, UI.Text($"{n + 1}", 13, JT.Muted), UI.Text(s?.Name ?? $"Song {ids[n]}", 14),
                UI.Text(s is null ? "" : s.Owned ? "In library" : s.HasFile ? "On the site" : "No file yet", 12, JT.Muted)));
            rows.Children.Add(row);
        }
    }
    void Move(List<string> ids, int at, int by)
    {
        int to = at + by; if (to < 0 || to >= ids.Count) return;
        (ids[at], ids[to]) = (ids[to], ids[at]);
        Store.Shared.Me.WishOrder = ids; Store.Shared.SavePersonal(); Draw();
    }
}
