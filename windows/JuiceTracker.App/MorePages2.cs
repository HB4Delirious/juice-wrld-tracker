using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Path = System.IO.Path;

namespace JuiceTracker.App;

public static partial class MorePages
{
    static MorePages()
    {
        Extra[Page.Credits] = () => new CreditsPage();
        Extra[Page.Timeline] = () => new TimelinePage();
        Extra[Page.Badges] = () => new BadgesPage();
        Extra[Page.Trivia] = () => new TriviaPage();
        Extra[Page.Heardle] = () => new HeardlePage();
        Extra[Page.Wordle] = () => new WordlePage();
        Extra[Page.Tiers] = () => new TierListPage();
    }
    /// A name on a song card opens Credits on that person.
    public static (string Role, string Name)? CreditsFocus;
}

// MARK: - Credits

public sealed class CreditsPage : ToolPage
{
    string role = "pr", query = ""; string? picked; int limit = 150;
    readonly TextBox search = new() { Width = 240 };
    public CreditsPage()
    {
        if (MorePages.CreditsFocus is { } f) { role = f.Role; picked = f.Name.ToLowerInvariant(); MorePages.CreditsFocus = null; }
        search.TextChanged += (_, _) => { query = search.Text.Trim().ToLowerInvariant(); limit = 150; Refresh(); };
        UI.AutomationName(search, "Search names");
        Refresh();
    }
    static List<string> Names(EngineSong s, string role) => role switch
    {
        "pr" => Engine.SplitNames(s.Producers), "ar" => Engine.SplitNames(s.Artists), "en" => Engine.SplitNames(s.Engineers), _ => Engine.SplitStudios(s.Locations),
    };
    public override void Refresh()
    {
        var store = Store.Shared;
        Start("Credits", "Everyone who worked on the songs: pick a name to see their songs, and what you have of them.");
        var people = new Dictionary<string, (string Name, List<Song> Songs)>();
        foreach (var s in store.Songs)
            foreach (var n in Names(s.S, role).Distinct(StringComparer.OrdinalIgnoreCase))
            {
                var key = n.ToLowerInvariant();
                if (role == "ar" && key == "juice wrld") continue; // he's on everything
                if (!people.TryGetValue(key, out var p)) people[key] = p = (n, []);
                p.Songs.Add(s);
            }
        var list = people.Where(kv => query.Length == 0 || kv.Key.Contains(query)).OrderByDescending(kv => kv.Value.Songs.Count).ThenBy(kv => kv.Value.Name).ToList();
        var tabs = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (key, label) in new[] { ("pr", "Producers"), ("ar", "Artists"), ("en", "Engineers"), ("st", "Studios") })
        {
            var r = new RadioButton { Content = label, Style = (Style)Application.Current.FindResource("Segment"), IsChecked = key == role, GroupName = "role" };
            r.Checked += (_, _) => { role = key; picked = null; limit = 150; Refresh(); };
            tabs.Children.Add(r);
        }
        if (search.Parent is Panel sp) sp.Children.Remove(search);
        Add(UI.Row(12, new Border { Background = JT.Brush(Color.FromArgb(30, 255, 255, 255)), CornerRadius = new CornerRadius(8), Padding = new Thickness(2), Child = tabs }, search));
        var grid = new Grid { Margin = new Thickness(0, 16, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(340) }); grid.ColumnDefinitions.Add(new ColumnDefinition());
        var names = new StackPanel();
        for (int n = 0; n < Math.Min(limit, list.Count); n++)
        {
            var (key, (name, songs)) = (list[n].Key, list[n].Value);
            var row = new DockPanel { Margin = new Thickness(10, 6, 10, 6) };
            var count = UI.Text($"{songs.Count(s => s.Owned)} / {songs.Count}", 12, JT.Muted); DockPanel.SetDock(count, Dock.Right); row.Children.Add(count);
            row.Children.Add(UI.Row(8, UI.Text($"{n + 1}", 12, JT.Muted).Also(t => t.Width = 28), UI.Text(name, 14)));
            var b = new Button { Content = new Border { Background = picked == key ? JT.Brush(Color.FromArgb(46, JT.Lavender.R, JT.Lavender.G, JT.Lavender.B)) : Brushes.Transparent, Child = row },
                                 Style = (Style)Application.Current.FindResource("Plain"), HorizontalContentAlignment = HorizontalAlignment.Stretch };
            b.Click += (_, _) => { picked = key; Refresh(); };
            names.Children.Add(b);
        }
        if (list.Count > limit) names.Children.Add(UI.Link("Show more", () => { limit += 200; Refresh(); }).Also(l => l.Margin = new Thickness(10)));
        if (list.Count == 0) names.Children.Add(UI.Muted("Nobody matches that name.", 13).Also(t => t.Margin = new Thickness(10)));
        grid.Children.Add(UI.Panel(names, 0, 0).Also(p => p.VerticalAlignment = VerticalAlignment.Top));
        var right = new StackPanel { Margin = new Thickness(16, 0, 0, 0) }; Grid.SetColumn(right, 1);
        if (picked is not null && people.TryGetValue(picked, out var who))
        {
            right.Children.Add(new TextBlock { Text = who.Name, FontFamily = JT.Marker, FontSize = 28 });
            var head = UI.Row(10, UI.Text($"{who.Songs.Count} songs, {who.Songs.Count(s => s.Owned)} in your library", 14, JT.Muted));
            var missing = who.Songs.Where(s => !s.Owned && s.HasFile).ToList();
            if (missing.Count > 0) head.Children.Add(UI.Button($"Download {missing.Count} missing", () => store.AddDownloads(missing.Select(s => s.S.Id))).Also(b => b.Margin = new Thickness(10, 0, 0, 0)));
            right.Children.Add(head);
            var rows = new StackPanel(); foreach (var s in who.Songs.OrderBy(s => s.Name)) rows.Children.Add(new SongRow(s));
            right.Children.Add(UI.Panel(rows, 1, 0).Also(p => p.Margin = new Thickness(0, 10, 0, 0)));
        }
        else right.Children.Add(UI.Muted("Pick a name to see their songs. The numbers show how many you have of how many they're credited on.", 14));
        grid.Children.Add(right);
        Add(grid);
    }
}

// MARK: - Timeline

public sealed class TimelinePage : ToolPage
{
    public TimelinePage() => Refresh();
    public override void Refresh()
    {
        var store = Store.Shared;
        var dated = store.Songs.Select(s => (Song: s, M: Engine.RecordMonth(s.S.RecordDates))).Where(x => x.M is not null).ToList();
        Start("Timeline", $"Every song with a recording date, as a dot in the month it was recorded. Yours are lit up: {dated.Count(x => x.Song.Owned):N0} of {dated.Count:N0}.");
        if (dated.Count == 0) { Add(UI.Muted("No recording dates in the catalog yet.", 14)); return; }
        int first = dated.Min(x => x.M!.Value), last = dated.Max(x => x.M!.Value);
        var byMonth = dated.GroupBy(x => x.M!.Value).ToDictionary(g => g.Key, g => g.Select(x => x.Song).ToList());
        var months = System.Globalization.CultureInfo.CurrentCulture.DateTimeFormat.AbbreviatedMonthNames;
        var col = new StackPanel();
        for (int m = first; m <= last; m++)
        {
            if (m % 12 == 0 || m == first) col.Children.Add(new TextBlock { Text = $"{m / 12}", FontFamily = JT.Marker, FontSize = 22, Margin = new Thickness(0, m == first ? 0 : 14, 0, 4) });
            var songs = byMonth.GetValueOrDefault(m) ?? [];
            var row = new DockPanel { Margin = new Thickness(0, 2, 0, 2) };
            row.Children.Add(UI.Text(months[m % 12], 12, JT.Muted).Also(t => { t.Width = 44; DockPanel.SetDock(t, Dock.Left); }));
            row.Children.Add(new DotRow(songs, $"{months[m % 12]} {m / 12}"));
            col.Children.Add(row);
        }
        Add(UI.Panel(col, 0, 18));
    }
}

/// One month's songs as dots, drawn in one go. (A separate element per dot, each owned one with its own glow effect,
/// made about 2,500 elements and 2,000 effects that WPF redrew whenever anything moved: the Timeline crawled.)
sealed class DotRow : FrameworkElement
{
    const double Dot = 10, Pitch = 14;
    static readonly Brush Have = JT.Brush(JT.Have), Halo = JT.Brush(Color.FromArgb(70, JT.Have.R, JT.Have.G, JT.Have.B)), Missing = JT.Brush(Color.FromArgb(60, 255, 255, 255));
    readonly List<Song> songs;
    public DotRow(List<Song> songs, string month)
    {
        this.songs = songs;
        Cursor = songs.Count > 0 ? Cursors.Hand : null;
        ToolTipService.SetInitialShowDelay(this, 150);
        UI.AutomationName(this, $"{month}: {songs.Count} songs, {songs.Count(s => s.Owned)} yours");
    }
    int PerRow(double width) => Math.Max(1, (int)((width + Pitch - Dot) / Pitch));
    protected override Size MeasureOverride(Size available)
    {
        double w = double.IsInfinity(available.Width) ? 600 : available.Width;
        int per = PerRow(w), rows = Math.Max(1, (songs.Count + per - 1) / per);
        return new Size(w, rows * Pitch);
    }
    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(RenderSize)); // the whole row answers the mouse
        int per = PerRow(ActualWidth);
        for (int k = 0; k < songs.Count; k++)
        {
            var c = new Point(k % per * Pitch + Dot / 2, k / per * Pitch + Pitch / 2);
            if (songs[k].Owned) dc.DrawEllipse(Halo, null, c, Dot * 0.75, Dot * 0.75); // a soft glow, without an effect
            dc.DrawEllipse(songs[k].Owned ? Have : Missing, null, c, Dot / 2, Dot / 2);
        }
    }
    Song? At(Point p)
    {
        int per = PerRow(ActualWidth), col = (int)(p.X / Pitch), k = (int)(p.Y / Pitch) * per + col;
        return col < per && k >= 0 && k < songs.Count ? songs[k] : null;
    }
    protected override void OnMouseMove(MouseEventArgs e) { var s = At(e.GetPosition(this)); if (!Equals(ToolTip, s?.Name)) ToolTip = s?.Name; }
    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e) { if (At(e.GetPosition(this)) is { } s) MainWindow.Current?.OpenSong(s); }
}

// MARK: - Badges

public sealed record Badge(string Id, string Image, string Title, string Detail, int Have, int Need) { public bool Earned => Have >= Need; }

public sealed class BadgesPage : ToolPage
{
    public BadgesPage() => Refresh();
    static List<Badge> All()
    {
        var store = Store.Shared; int have = store.Owned.Count;
        var released = store.Songs.Where(s => Engine.IsReleased(s.S)).ToList();
        var list = new List<Badge>
        {
            new("first", "jt-heart", "First song", "Your first song in the library.", have, 1),
            new("100", "jt-sticker1", "Hundred club", "100 songs in your library.", have, 100),
            new("500", "jt-sticker3", "Five hundred deep", "500 songs in your library.", have, 500),
            new("999", "jt-era-999", "999 club", "999 songs in your library.", have, 999),
            new("1500", "jt-sticker5", "Vault keeper", "1,500 songs in your library.", have, 1500),
            new("all", "jt-planet", "The whole WRLD", "Every song in the catalog.", have, Math.Max(1, store.Catalog.Count)),
            new("released", "jt-era-vinyl", "Every release", "All officially released songs.", released.Count(s => s.Owned), Math.Max(released.Count, 1)),
            new("wish", "jt-sticker4", "Wish granted", "10 songs from your wishlist found.", store.Songs.Count(s => s.Wished && s.Owned), 10),
            new("plays", "jt-era-mic", "On repeat", "100 songs played in the app.", Store.PlayLog().Count, 100),
        };
        for (int n = 0; n < store.EraList.Count; n++)
        {
            var e = store.EraList[n];
            if (e.Total >= 3 && e.Name != Engine.NoEra) list.Add(new($"era-{e.Name}", CollectionPage.EraSticker(e.Name, n), e.Name, "Every song from this era.", e.Have, e.Total));
        }
        return list;
    }
    public override void Refresh()
    {
        var list = All();
        Start("Badges", $"{list.Count(b => b.Earned)} of {list.Count} earned. Era badges come from having every song of the era.");
        var grid = new WrapPanel();
        for (int n = 0; n < list.Count; n++)
        {
            var b = list[n];
            var col = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
            var img = new Image { Source = JT.Image(b.Image), Width = 54, Height = 54, Opacity = b.Earned ? 1 : 0.4, RenderTransform = new RotateTransform(b.Earned ? -6 : 0), RenderTransformOrigin = new Point(0.5, 0.5) };
            if (b.Earned) img.Effect = UI.Glow(JT.Lavender, 10, 0.6);
            else img.Source = new FormatConvertedBitmap(JT.Image(b.Image), PixelFormats.Gray8, null, 0); // grey until earned
            col.Children.Add(img);
            col.Children.Add(new TextBlock { Text = b.Title, FontSize = 15, FontWeight = FontWeights.SemiBold, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) });
            col.Children.Add(new TextBlock { Text = b.Detail, FontSize = 12, Foreground = JT.Brush(JT.Muted), TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap });
            if (b.Earned)
            {
                col.Children.Add(UI.Row(6, UI.Icon("", 12, JT.Have), UI.Text("Earned", 12, JT.Have, FontWeights.SemiBold)).Also(r => { r.HorizontalAlignment = HorizontalAlignment.Center; r.Margin = new Thickness(0, 6, 0, 0); }));
                col.Children.Add(UI.Link("Save card…", () => SaveCard(b), 12).Also(l => { l.HorizontalAlignment = HorizontalAlignment.Center; l.Margin = new Thickness(0, 4, 0, 0); }));
            }
            else
            {
                col.Children.Add(UI.Bar((double)b.Have / Math.Max(b.Need, 1), JT.Brush(JT.Lavender), 4, 0.15 + Math.Min(n * 0.03, 0.4)).Also(x => x.Margin = new Thickness(0, 8, 0, 4)));
                col.Children.Add(new TextBlock { Text = $"{Math.Min(b.Have, b.Need):N0} of {b.Need:N0}", FontSize = 12, Foreground = JT.Brush(JT.Muted), TextAlignment = TextAlignment.Center });
            }
            var card = new DoodleBorder { Seed = n, Child = col, Padding = new Thickness(14), Width = 190, MinHeight = 190, Margin = new Thickness(0, 0, 14, 14), Stroke = JT.Brush(b.Earned ? Color.FromArgb(204, JT.Lavender.R, JT.Lavender.G, JT.Lavender.B) : JT.Line2) };
            grid.Children.Add(card);
        }
        Add(grid);
    }
    /// A picture of a badge you earned (1200 × 630, like the collection card), to post or keep.
    void SaveCard(Badge b)
    {
        if (SaveFile($"juice-wrld-badge-{b.Id}.png", "PNG image|*.png") is not { } file) return;
        var canvas = new Grid { Width = 1200, Height = 630, Background = new LinearGradientBrush(new GradientStopCollection { new(Color.FromRgb(7, 4, 15), 0), new(Color.FromRgb(29, 11, 64), 0.5), new(Color.FromRgb(74, 18, 80), 1) }, 45) };
        var row = UI.Row(60, new Image { Source = JT.Image(b.Image), Width = 300, Height = 300, RenderTransform = new RotateTransform(-8), Effect = UI.Glow(JT.Lavender, 30, 0.7) },
            UI.Column(14, new TextBlock { Text = "BADGE EARNED", FontFamily = JT.Body, FontSize = 26, FontWeight = FontWeights.SemiBold, Foreground = JT.Brush(JT.LavenderHi) },
                      new TextBlock { Text = b.Title, FontFamily = JT.Marker, FontSize = 80, Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap, MaxWidth = 700 },
                      new TextBlock { Text = b.Detail, FontFamily = JT.Body, FontSize = 30, Foreground = JT.Brush(JT.Muted) },
                      new TextBlock { Text = $"{Store.Shared.Owned.Count:N0} Juice WRLD songs · {DateTime.Now:MMMM d, yyyy}", FontFamily = JT.Body, FontSize = 22, Foreground = JT.Brush(Color.FromArgb(178, 255, 255, 255)), Margin = new Thickness(0, 20, 0, 0) }));
        row.Margin = new Thickness(70); canvas.Children.Add(row);
        var bmp = Games.Render(canvas, 1200, 630);
        Games.SavePng(bmp, file);
        Result = $"Saved the “{b.Title}” card."; ResultIsError = false; Refresh();
    }
}

// MARK: - Trivia

public sealed class TriviaPage : ToolPage
{
    static readonly (string Key, string Label)[] Types = [("mixed", "Mixed"), ("era", "Eras"), ("producer", "Producers"), ("year", "Recording years"), ("release", "Released or not"), ("listen", "Name that song (plays a clip)")];
    string type = "mixed", pool = "all";
    List<(string Prompt, string Answer, List<string> Options, int Song, string Clip)>? round; int at, score; string? chosen;
    public TriviaPage() => Refresh();

    public override void Refresh()
    {
        var store = Store.Shared;
        Start("Trivia", "Ten questions about the catalog: eras, producers, recording years, releases, or name the song from a clip of your own files.");
        if (round is null)
        {
            var types = new WrapPanel();
            foreach (var (key, label) in Types)
            {
                var best = store.Me.Trivia.GetValueOrDefault($"{key}:{pool}");
                var r = new RadioButton { Content = label + (best > 0 ? $"  (best {best}/10)" : ""), Style = (Style)Application.Current.FindResource("Segment"), IsChecked = key == type, GroupName = "type", Margin = new Thickness(0, 0, 6, 6) };
                r.Checked += (_, _) => { type = key; Refresh(); };
                types.Children.Add(r);
            }
            Add(types);
            var all = new RadioButton { Content = "The whole catalog", Style = (Style)Application.Current.FindResource("Segment"), IsChecked = pool == "all", GroupName = "pool" };
            var mine = new RadioButton { Content = "Only songs I have", Style = (Style)Application.Current.FindResource("Segment"), IsChecked = pool == "library", GroupName = "pool" };
            all.Checked += (_, _) => { pool = "all"; Refresh(); }; mine.Checked += (_, _) => { pool = "library"; Refresh(); };
            Add(UI.Row(6, all, mine), 6);
            Add(UI.Button("Start a round", () => { round = MakeRound(); at = 0; score = 0; chosen = null; Refresh(); }, "", big: true).Also(b => b.HorizontalAlignment = HorizontalAlignment.Left), 16);
            return;
        }
        if (round.Count == 0) { Add(UI.Muted("Not enough songs for this kind of question yet.", 14)); Add(UI.Button("Back", () => { round = null; Refresh(); }).Also(b => b.HorizontalAlignment = HorizontalAlignment.Left), 10); return; }
        if (at >= round.Count)
        {
            var key = $"{type}:{pool}"; bool newBest = score > store.Me.Trivia.GetValueOrDefault(key);
            if (newBest) { store.Me.Trivia[key] = score; store.SavePersonal(); }
            Player.Shared.Resume();
            Add(new TextBlock { Text = $"{score} of {round.Count}", FontFamily = JT.Marker, FontSize = 64, Foreground = JT.Gradient(JT.Count) });
            Add(UI.Text(newBest ? "A new best!" : score >= 8 ? "Big brain." : score >= 5 ? "Not bad." : "Keep listening.", 18), 4);
            Add(UI.Row(10, UI.Button("Play again", () => { round = MakeRound(); at = 0; score = 0; chosen = null; Refresh(); }, big: true), UI.Button("Change the questions", () => { round = null; Refresh(); }, big: true)), 16);
            return;
        }
        var q = round[at];
        Add(UI.Text($"Question {at + 1} of {round.Count} · {score} right", 13, JT.Muted));
        Add(new TextBlock { Text = q.Prompt, FontFamily = JT.Marker, FontSize = 30, TextWrapping = TextWrapping.Wrap }, 8);
        if (q.Clip.Length > 0) Add(UI.Button("Play the clip again", () => PlayClip(q.Clip), "").Also(b => b.HorizontalAlignment = HorizontalAlignment.Left), 8);
        var options = new StackPanel { Margin = new Thickness(0, 14, 0, 0), MaxWidth = 560, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var o in q.Options)
        {
            var bg = chosen is null ? Color.FromArgb(51, 255, 255, 255) : o == q.Answer ? Color.FromArgb(90, JT.Have.R, JT.Have.G, JT.Have.B) : o == chosen ? Color.FromArgb(90, JT.Missing.R, JT.Missing.G, JT.Missing.B) : Color.FromArgb(30, 255, 255, 255);
            var b = new Button { Content = new TextBlock { Text = o, FontSize = 15, TextWrapping = TextWrapping.Wrap }, Background = JT.Brush(bg), Padding = new Thickness(14, 10, 14, 10), Margin = new Thickness(0, 0, 0, 8), HorizontalContentAlignment = HorizontalAlignment.Left, IsEnabled = chosen is null || true };
            b.Click += (_, _) => { if (chosen is not null) return; chosen = o; if (o == q.Answer) score++; Refresh(); };
            options.Children.Add(b);
        }
        Add(options);
        if (chosen is not null)
        {
            var row = UI.Row(10, UI.Button(at + 1 < round.Count ? "Next question" : "See your score", () => { at++; chosen = null; if (at < round.Count && round[at].Clip.Length > 0) PlayClip(round[at].Clip); Refresh(); }, big: true),
                             UI.Link("Open the song card", () => MainWindow.Current?.OpenSong(Store.Shared.Songs[q.Song])));
            Add(row, 8);
        }
        else if (at == 0 && q.Clip.Length > 0 && !clipStarted) { clipStarted = true; PlayClip(q.Clip); }
    }
    bool clipStarted;

    static MediaPlayer? clip;
    /// Plays 15 seconds from somewhere in the song (the background music pauses for it, and comes back after the round).
    static void PlayClip(string file)
    {
        if (Player.Shared.IsPlaying) Player.Shared.Pause();
        clip?.Close(); clip = new MediaPlayer();
        clip.Open(new Uri(file)); clip.Volume = 0.7;
        clip.MediaOpened += (_, _) => { clip.Position = TimeSpan.FromSeconds(Math.Min(25 + Random.Shared.Next(40), Math.Max(0, (clip.NaturalDuration.HasTimeSpan ? clip.NaturalDuration.TimeSpan.TotalSeconds : 60) - 15))); };
        clip.Play();
        var c = clip;
        new System.Windows.Threading.DispatcherTimer(TimeSpan.FromSeconds(15), System.Windows.Threading.DispatcherPriority.Normal, (s, _) => { ((System.Windows.Threading.DispatcherTimer)s!).Stop(); if (clip == c) { c.Stop(); } }, System.Windows.Threading.Dispatcher.CurrentDispatcher).Start();
    }

    /// The same question types and rules as the Mac app: a round of 10, at most 2 yes/no questions in a mixed round,
    /// and never a right answer offered as a wrong one (a song name can be in several eras and years).
    List<(string, string, List<string>, int, string)> MakeRound()
    {
        var store = Store.Shared; var cat = store.Catalog; var owned = store.Match.Owned;
        var producersOf = cat.Select(s => Engine.SplitNames(s.Producers)).ToList(); var yearsOf = cat.Select(s => Engine.YearsIn(s.RecordDates)).ToList();
        var eraNames = Engine.EraStats(cat, new HashSet<int>(), new Dictionary<string, EraInfo>()).Select(e => e.Name).Where(n => n != Engine.NoEra).ToList();
        var producers = producersOf.SelectMany(x => x).GroupBy(n => n.ToLowerInvariant()).OrderByDescending(g => g.Count()).ThenBy(g => g.First()).Select(g => g.First()).ToList();
        var allYears = yearsOf.SelectMany(x => x).Distinct().Order().ToList();
        var erasOfName = new Dictionary<string, HashSet<string>>(); var yearsOfName = new Dictionary<string, HashSet<int>>();
        for (int i = 0; i < cat.Count; i++)
        {
            var k = cat[i].Name.ToLowerInvariant();
            (erasOfName.TryGetValue(k, out var e) ? e : erasOfName[k] = []).Add(cat[i].Era);
            (yearsOfName.TryGetValue(k, out var y) ? y : yearsOfName[k] = []).UnionWith(yearsOf[i]);
        }
        bool hasReleased = cat.Any(Engine.IsReleased), hasUnreleased = cat.Any(s => !Engine.IsReleased(s));
        static List<string> Shuffle(IEnumerable<string> x) => x.OrderBy(_ => Random.Shared.Next()).ToList();
        var builders = new Dictionary<string, (Func<int, bool> Ok, Func<int, (string, string, List<string>, string)> Make)>
        {
            ["era"] = (i => Engine.HasValue(cat[i].Era) && eraNames.Count >= 4, i =>
            {
                var also = erasOfName[cat[i].Name.ToLowerInvariant()];
                return ($"Which era is “{cat[i].Name}” from?", cat[i].Era, Shuffle(new[] { cat[i].Era }.Concat(Shuffle(eraNames.Where(e => !also.Contains(e))).Take(3))), "");
            }),
            ["producer"] = (i => producersOf[i].Count > 0 && producers.Count >= 6, i =>
            {
                var own = producersOf[i]; var keys = own.Select(x => x.ToLowerInvariant()).ToHashSet(); var answer = own[Random.Shared.Next(own.Count)];
                var poolP = producers.Where(p => !keys.Contains(p.ToLowerInvariant())).ToList();
                var decoys = Shuffle(poolP.Take(40)).Take(3).ToList(); if (decoys.Count < 3) decoys = Shuffle(poolP).Take(3).ToList();
                return (own.Count > 1 ? $"Which of these producers worked on “{cat[i].Name}”?" : $"Who produced “{cat[i].Name}”?", answer, Shuffle(decoys.Prepend(answer)), "");
            }),
            ["year"] = (i => yearsOf[i].Count == 1 && allYears.Count >= 2, i =>
            {
                int y = yearsOf[i][0]; var also = yearsOfName[cat[i].Name.ToLowerInvariant()];
                var near = new[] { y - 3, y - 2, y - 1, y + 1, y + 2, y + 3 }.Where(v => v >= allYears[0] - 1 && v <= allYears[^1] + 1 && !also.Contains(v)).OrderBy(_ => Random.Shared.Next()).Take(3);
                return ($"What year was “{cat[i].Name}” recorded?", $"{y}", Shuffle(near.Prepend(y).Select(v => $"{v}")), "");
            }),
            ["listen"] = (i => owned.Count >= 4 && Listen.FileFor(i) is not null, i =>
            {
                var key = Engine.Normalize(cat[i].Name); var decoys = new List<string>();
                foreach (var j in owned.Keys.OrderBy(_ => Random.Shared.Next())) { var n = cat[j].Name; if (Engine.Normalize(n) != key && !decoys.Contains(n)) decoys.Add(n); if (decoys.Count == 3) break; }
                return ("Which song is playing?", cat[i].Name, Shuffle(decoys.Prepend(cat[i].Name)), Listen.FileFor(i)!);
            }),
            ["release"] = (_ => hasReleased && hasUnreleased, i =>
            {
                const string yes = "Yes, it's officially released", no = "No, it hasn't been released";
                return ($"Has “{cat[i].Name}” been officially released?", Engine.IsReleased(cat[i]) ? yes : no, [yes, no], "");
            }),
        };
        var poolIdx = (pool == "library" || type == "listen" ? owned.Keys.ToList() : Enumerable.Range(0, cat.Count).ToList()).OrderBy(_ => Random.Shared.Next()).ToList();
        var kinds = type == "mixed" ? new[] { "era", "producer", "year", "release" } : [type];
        var output = new List<(string, string, List<string>, int, string)>(); var used = new HashSet<int>(); int yesNo = 0;
        for (int attempt = 0; attempt < poolIdx.Count * 2 && output.Count < 10; attempt++)
        {
            var i = poolIdx[attempt % poolIdx.Count];
            if (used.Contains(i)) continue;
            var t = kinds.Where(k => builders[k].Ok(i)).OrderBy(_ => Random.Shared.Next()).FirstOrDefault(k => k != "release" || type != "mixed" || yesNo < 2);
            if (t is null) continue;
            var q = builders[t].Make(i);
            if (q.Item3.Distinct().Count() != q.Item3.Count || q.Item3.Count < 2) continue;
            used.Add(i); if (t == "release") yesNo++;
            output.Add((q.Item1, q.Item2, q.Item3, i, q.Item4));
        }
        clipStarted = false;
        return output;
    }
}
