using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace JuiceTracker.App;

// Wordle (guess a song title letter by letter), Tier list (rank your songs in S–D rows, save a picture) and the Lyrics
// card (lines being sung as a picture to share). The Mac app's NativeGames.swift; the rules are in the engine.

public sealed class TierList
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "My tier list";
    public string Era { get; set; } = "";                                          // "" means all eras
    public List<List<string>> Rows { get; set; } = [.. Enumerable.Range(0, 5).Select(_ => new List<string>())]; // song ids, S to D
}

static class Games
{
    public static readonly Color Green = Color.FromRgb(92, 184, 92), Yellow = Color.FromRgb(219, 178, 51), Grey = Color.FromArgb(36, 255, 255, 255);
    public static readonly string[] Tiers = ["S", "A", "B", "C", "D"];
    public static readonly Color[] TierColors = [Color.FromRgb(255, 107, 115), Color.FromRgb(255, 168, 92), Color.FromRgb(255, 219, 97), Color.FromRgb(140, 219, 115), Color.FromRgb(107, 168, 255)];
    public static List<string> EraNames() => Store.Shared.Songs.Select(s => s.Era).Distinct().ToList();

    /// A visual drawn into a PNG at its own size.
    public static void SavePng(FrameworkElement visual, string file)
    {
        visual.Measure(new Size(visual.Width, double.PositiveInfinity));
        visual.Arrange(new Rect(visual.DesiredSize)); visual.UpdateLayout();
        var bmp = new RenderTargetBitmap((int)Math.Ceiling(visual.ActualWidth), (int)Math.Ceiling(visual.ActualHeight), 96, 96, PixelFormats.Pbgra32);
        bmp.Render(visual);
        var enc = new PngBitmapEncoder(); enc.Frames.Add(BitmapFrame.Create(bmp));
        using var fs = File.Create(file); enc.Save(fs);
    }
    public static Brush Night => new LinearGradientBrush(Color.FromRgb(7, 4, 15), Color.FromRgb(29, 11, 64), 90);
}

// MARK: - Wordle

public sealed class WordlePage : ToolPage
{
    readonly TextBox input = new() { Width = 320, FontSize = 15 };
    int unlimitedPick = Random.Shared.Next(10_000);
    List<string> unlimitedGuesses = [];
    string note = "";

    public WordlePage()
    {
        input.KeyDown += (_, e) => { if (e.Key == Key.Enter) { Guess(); e.Handled = true; } };
        input.TextChanged += (_, _) => DrawTiles(); // only the tiles: rebuilding the box would lose the cursor
        UI.AutomationName(input, "Your guess");
        Refresh();
    }

    static Store.Personal Me => Store.Shared.Me;
    static string Today => DateTime.Now.ToString("yyyy-MM-dd");
    static int DayNumber => (int)(DateTimeOffset.Now.ToUnixTimeSeconds() / 86400);

    /// Every title that makes a puzzle (4 to 14 letters), one song per title, in a fixed order.
    static List<(string Word, Song Song)> Pool()
    {
        var seen = new HashSet<string>(); var output = new List<(string, Song)>();
        foreach (var s in Store.Shared.Songs)
            if ((Me.WordleEra.Length == 0 || s.Era == Me.WordleEra) && Engine.WordleWord(s.Name) is { } w && seen.Add(w)) output.Add((w, s));
        return output.OrderBy(x => x.Item1, StringComparer.Ordinal).ToList();
    }
    List<string> Guesses
    {
        get
        {
            if (!Me.WordleDaily) return unlimitedGuesses;
            var parts = Me.WordleSaved.Split('|');
            return parts.Length == 3 && parts[0] == Today && parts[1] == Me.WordleEra ? [.. parts[2].Split(',', StringSplitOptions.RemoveEmptyEntries)] : [];
        }
        set { if (Me.WordleDaily) { Me.WordleSaved = $"{Today}|{Me.WordleEra}|{string.Join(',', value)}"; Store.Shared.SavePersonal(); } else unlimitedGuesses = value; }
    }
    static string Clean(string s) => new(s.ToUpperInvariant().Where(c => c is >= 'A' and <= 'Z' or >= '0' and <= '9').ToArray());

    (string Word, Song Song)? answer;
    readonly StackPanel tiles = new(), rest = new();

    public override void Refresh()
    {
        Start("Wordle", "Guess a Juice WRLD song title letter by letter. Green is the right letter in the right place, yellow is in the title somewhere else. Six tries.");
        var mode = new ComboBox { Width = 130, ItemsSource = new[] { "Daily", "Unlimited" }, SelectedIndex = Me.WordleDaily ? 0 : 1 };
        mode.SelectionChanged += (_, _) => { Me.WordleDaily = mode.SelectedIndex == 0; Store.Shared.SavePersonal(); note = ""; input.Clear(); Refresh(); };
        var eras = new List<string> { "All eras" }; eras.AddRange(Games.EraNames());
        var era = new ComboBox { MinWidth = 140, ItemsSource = eras, SelectedItem = Me.WordleEra.Length == 0 ? "All eras" : Me.WordleEra };
        era.SelectionChanged += (_, _) => { Me.WordleEra = era.SelectedItem as string is { } e && e != "All eras" ? e : ""; Store.Shared.SavePersonal(); unlimitedGuesses = []; Refresh(); };
        UI.AutomationName(mode, "Daily or unlimited"); UI.AutomationName(era, "Era");
        var st = (Me.WordleStats + ",0,0,0,0").Split(',').Select(x => int.TryParse(x, out var n) ? n : 0).ToArray();
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 14) };
        var stats = UI.Muted($"Daily: played {st[0]} · won {st[1]} · streak {st[2]} · best {st[3]}", 13); DockPanel.SetDock(stats, Dock.Right); stats.VerticalAlignment = VerticalAlignment.Center;
        head.Children.Add(stats); head.Children.Add(UI.Row(12, mode, era));
        Add(head);
        var pool = Pool();
        if (pool.Count == 0) { answer = null; Add(UI.Muted("No titles to play in this era.", 14)); return; }
        answer = Me.WordleDaily ? pool[DayNumber * 7919 % pool.Count] : pool[unlimitedPick % pool.Count];
        foreach (var part in new[] { tiles, rest }) { if (part.Parent is Panel old) old.Children.Remove(part); Add(part); }
        DrawTiles(); DrawRest();
    }

    void DrawTiles()
    {
        if (answer is not { } a) return;
        tiles.Children.Clear();
        var letters = a.Word.Replace(" ", ""); var list = Guesses;
        bool done = (list.Count > 0 && list[^1] == letters) || list.Count >= 6;
        for (int r = 0; r < 6; r++)
            tiles.Children.Add(Row(a.Word, r < list.Count ? list[r] : r == list.Count && !done ? Clean(input.Text) : "", r < list.Count));
    }

    void DrawRest()
    {
        if (answer is not { } a) return;
        var board = rest; board.Children.Clear();
        var letters = a.Word.Replace(" ", ""); var list = Guesses;
        bool won = list.Count > 0 && list[^1] == letters, done = won || list.Count >= 6;
        if (input.Parent is Panel holder) holder.Children.Remove(input);
        if (done)
        {
            board.Children.Add(UI.Text(won ? $"Got it in {list.Count}!" : "Out of tries. It was:", 18, weight: FontWeights.Bold).Also(t => t.Margin = new Thickness(0, 14, 0, 4)));
            board.Children.Add(UI.Marker(a.Song.Name, 28).Also(t => t.Foreground = JT.Brush(JT.Lavender)));
            board.Children.Add(UI.Muted(a.Song.Era, 14));
            var buttons = UI.Row(10, UI.Button("Open the song card", () => MainWindow.Current?.OpenSong(a.Song)));
            if (Me.WordleDaily) buttons.Children.Add(UI.Muted("A new title tomorrow.", 13).Also(t => t.VerticalAlignment = VerticalAlignment.Center));
            else buttons.Children.Add(UI.Button("Next title", () => { unlimitedPick = Random.Shared.Next(10_000); unlimitedGuesses = []; Refresh(); }));
            buttons.Margin = new Thickness(0, 10, 0, 0); board.Children.Add(buttons);
            Count(won);
            return;
        }
        input.ToolTip = $"{letters.Length} letters";
        var entry = UI.Row(10, input, UI.Button("Guess", Guess)); entry.Margin = new Thickness(0, 12, 0, 0);
        if (note.Length > 0) entry.Children.Add(UI.Text(note, 13, JT.Missing).Also(t => t.VerticalAlignment = VerticalAlignment.Center));
        board.Children.Add(entry);
        board.Children.Add(Keyboard(a.Word, list));
        Dispatcher.BeginInvoke(() => input.Focus());
    }

    void Guess()
    {
        if (answer is not { } a) return;
        var letters = a.Word.Replace(" ", ""); var g = Clean(input.Text);
        if (g.Length != letters.Length) { note = $"That's {g.Length} letters; the title has {letters.Length}."; DrawRest(); return; }
        note = "";
        Guesses = [.. Guesses, g];
        input.Clear();
        DrawTiles(); DrawRest();
    }

    /// One row of tiles: the answer's shape (gaps between words), filled with a guess.
    static StackPanel Row(string answer, string text, bool scored)
    {
        var score = scored ? Engine.WordleScore(text, answer) : [];
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 6) };
        int n = 0;
        foreach (var c in answer)
        {
            if (c == ' ') { row.Children.Add(new Border { Width = 14 }); continue; }
            var letter = n < text.Length ? text[n].ToString() : "";
            var fill = scored ? (score[n] switch { 2 => Games.Green, 1 => Games.Yellow, _ => Games.Grey }) : Color.FromArgb(13, 255, 255, 255);
            row.Children.Add(new Border
            {
                Width = 46, Height = 46, Margin = new Thickness(0, 0, 5, 0), CornerRadius = new CornerRadius(8), Background = JT.Brush(fill),
                BorderBrush = JT.Brush(Color.FromArgb((byte)(scored ? 0 : letter.Length == 0 ? 38 : 128), 255, 255, 255)), BorderThickness = new Thickness(1),
                Child = new TextBlock { Text = letter, FontSize = 22, FontWeight = FontWeights.Black, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
            });
            n++;
        }
        return row;
    }

    /// The letters seen so far, coloured by the best they've done; click one to type it.
    StackPanel Keyboard(string answer, List<string> list)
    {
        var best = new Dictionary<char, int>();
        foreach (var g in list) { var sc = Engine.WordleScore(g, answer); for (int k = 0; k < g.Length && k < sc.Length; k++) best[g[k]] = Math.Max(best.GetValueOrDefault(g[k], -1), sc[k]); }
        var keys = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
        foreach (var line in new[] { "QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM", "0123456789" })
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 4) };
            foreach (var c in line)
            {
                var color = best.TryGetValue(c, out var b) ? b switch { 2 => Games.Green, 1 => Games.Yellow, _ => Color.FromArgb(128, 0, 0, 0) } : Color.FromArgb(26, 255, 255, 255);
                var key = new Button
                {
                    Width = 30, Height = 34, Margin = new Thickness(0, 0, 4, 0), Style = (Style)Application.Current.FindResource("Plain"), Cursor = Cursors.Hand,
                    Content = new Border { Width = 30, Height = 34, CornerRadius = new CornerRadius(6), Background = JT.Brush(color),
                                           Child = new TextBlock { Text = c.ToString(), FontWeight = FontWeights.Bold, FontSize = 13, Foreground = JT.Brush(b == 0 && best.ContainsKey(c) ? JT.Muted : Colors.White), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } },
                };
                key.Click += (_, _) => { input.Text += c; input.CaretIndex = input.Text.Length; input.Focus(); };
                UI.AutomationName(key, $"Type {c}");
                row.Children.Add(key);
            }
            keys.Children.Add(row);
        }
        return keys;
    }

    /// Daily stats, once per round.
    static void Count(bool won)
    {
        if (!Me.WordleDaily || Me.WordleCounted == Today) return;
        var st = (Me.WordleStats + ",0,0,0,0").Split(',').Select(x => int.TryParse(x, out var n) ? n : 0).Take(4).ToArray();
        st[0]++;
        if (won) { st[1]++; st[2] = Me.WordleCounted == DateTime.Now.AddDays(-1).ToString("yyyy-MM-dd") ? st[2] + 1 : 1; st[3] = Math.Max(st[3], st[2]); } else st[2] = 0;
        Me.WordleStats = string.Join(',', st); Me.WordleCounted = Today; Store.Shared.SavePersonal();
    }
}

// MARK: - Tier list

public sealed class TierListPage : ToolPage
{
    readonly TextBox search = new() { Width = 200 };
    public TierListPage()
    {
        search.TextChanged += (_, _) => Refresh();
        UI.AutomationName(search, "Search your songs");
        Refresh();
    }

    static Store.Personal Me => Store.Shared.Me;
    static TierList Current
    {
        get
        {
            if (Me.TierLists.Count == 0) Me.TierLists.Add(new TierList());
            return Me.TierLists.FirstOrDefault(l => l.Id == Me.TierListPick) ?? Me.TierLists[0];
        }
    }

    public override void Refresh()
    {
        var store = Store.Shared; var list = Current;
        var byId = store.Songs.GroupBy(s => s.S.Id).ToDictionary(g => g.Key, g => g.First());
        Start("Tier list", "Rank your songs: drag one into a row (or right-click it), drag it back down to take it out. Save the list as a picture to share.");
        var lists = new ComboBox { MinWidth = 160, ItemsSource = Me.TierLists.Select(l => l.Name).ToList(), SelectedIndex = Me.TierLists.IndexOf(list) };
        lists.SelectionChanged += (_, _) => { if (lists.SelectedIndex >= 0) { Me.TierListPick = Me.TierLists[lists.SelectedIndex].Id; Store.Shared.SavePersonal(); } };
        var name = new TextBox { Text = list.Name, Width = 200 };
        name.LostFocus += (_, _) => { if (name.Text.Trim().Length > 0 && name.Text != list.Name) { list.Name = name.Text.Trim(); Store.Shared.SavePersonal(); } };
        var eras = new List<string> { "All eras" }; eras.AddRange(Games.EraNames());
        var era = new ComboBox { MinWidth = 140, ItemsSource = eras, SelectedItem = list.Era.Length == 0 ? "All eras" : list.Era };
        era.SelectionChanged += (_, _) => { list.Era = era.SelectedItem as string is { } e && e != "All eras" ? e : ""; Store.Shared.SavePersonal(); };
        UI.AutomationName(lists, "Tier list"); UI.AutomationName(name, "Name"); UI.AutomationName(era, "Era");
        var tools = UI.Row(10, lists, name, era,
            UI.Button("New list", () => { var n = new TierList { Name = $"Tier list {Me.TierLists.Count + 1}" }; Me.TierLists.Add(n); Me.TierListPick = n.Id; Store.Shared.SavePersonal(); }),
            UI.Button("Save as picture…", () => Export(list, byId)));
        if (Me.TierLists.Count > 1) tools.Children.Add(UI.Link("Delete", () => { if (Ask($"Delete “{list.Name}”?", "The songs stay in your library.")) { Me.TierLists.Remove(list); Me.TierListPick = ""; Store.Shared.SavePersonal(); } }, 13).Also(l => l.VerticalAlignment = VerticalAlignment.Center));
        tools.Margin = new Thickness(0, 0, 0, 14);
        Add(tools);
        for (int r = 0; r < 5; r++)
        {
            int row = r;
            var label = new Border { Width = 64, MinHeight = 58, CornerRadius = new CornerRadius(10), Background = JT.Brush(Games.TierColors[r]),
                                     Child = new TextBlock { Text = Games.Tiers[r], FontFamily = JT.Marker, FontSize = 30, Foreground = Brushes.Black, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } };
            var line = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
            DockPanel.SetDock(label, Dock.Left); line.Children.Add(label);
            line.Children.Add(DropZone(Chips(list.Rows[r].Where(byId.ContainsKey).Select(id => byId[id]), r), r, Color.FromArgb(13, 255, 255, 255)));
            Add(line);
        }
        var placed = list.Rows.SelectMany(x => x).ToHashSet(); var q = search.Text.Trim().ToLowerInvariant();
        var pool = store.Songs.Where(s => s.Owned && (list.Era.Length == 0 || s.Era == list.Era) && !placed.Contains(s.S.Id) && (q.Length == 0 || s.Name.ToLowerInvariant().Contains(q))).ToList();
        if (search.Parent is Panel holder) holder.Children.Remove(search);
        var poolHead = new DockPanel { Margin = new Thickness(0, 12, 0, 6) };
        DockPanel.SetDock(search, Dock.Right); poolHead.Children.Add(search);
        poolHead.Children.Add(UI.Text($"Your songs  {pool.Count:N0}", 15, weight: FontWeights.SemiBold));
        Add(poolHead);
        Add(DropZone(Chips(pool.Take(300), -1), -1, Colors.Transparent));
        if (pool.Count > 300) Add(UI.Muted($"Showing 300 of {pool.Count:N0}; search to find the rest.", 12));
    }

    /// A row (or the pool) that songs can be dropped on.
    Border DropZone(WrapPanel chips, int row, Color fill)
    {
        var box = new Border { Child = chips, MinHeight = row < 0 ? 80 : 58, Padding = new Thickness(6), CornerRadius = new CornerRadius(10), Background = JT.Brush(fill),
                               BorderBrush = JT.Brush(JT.Line), BorderThickness = new Thickness(row < 0 ? 1 : 0), AllowDrop = true, Margin = new Thickness(row < 0 ? 0 : 8, 0, 0, 0) };
        box.Drop += (_, e) => { if (e.Data.GetData(typeof(string)) is string id) Move(id, row); };
        return box;
    }

    WrapPanel Chips(IEnumerable<Song> songs, int row)
    {
        var panel = new WrapPanel();
        foreach (var s in songs)
        {
            var chip = new Border
            {
                Width = 150, Margin = new Thickness(0, 0, 6, 6), Padding = new Thickness(10, 7, 10, 7), CornerRadius = new CornerRadius(8), Cursor = Cursors.Hand,
                Background = JT.Brush(row >= 0 ? Color.FromArgb(56, Games.TierColors[row].R, Games.TierColors[row].G, Games.TierColors[row].B) : JT.Raise),
                Child = new TextBlock { Text = s.Name, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, TextTrimming = TextTrimming.CharacterEllipsis },
                ToolTip = $"{s.Name} · {s.Era}",
            };
            UI.AutomationName(chip, s.Name);
            chip.MouseMove += (_, e) => { if (e.LeftButton == MouseButtonState.Pressed) DragDrop.DoDragDrop(chip, s.S.Id, DragDropEffects.Move); };
            var menu = new ContextMenu();
            for (int r = 0; r < 5; r++) { int to = r; var item = new MenuItem { Header = $"Move to {Games.Tiers[r]}" }; item.Click += (_, _) => Move(s.S.Id, to); menu.Items.Add(item); }
            if (row >= 0) { var take = new MenuItem { Header = "Take out" }; take.Click += (_, _) => Move(s.S.Id, -1); menu.Items.Add(take); }
            var open = new MenuItem { Header = "Open the song card" }; open.Click += (_, _) => MainWindow.Current?.OpenSong(s); menu.Items.Add(open);
            chip.ContextMenu = menu;
            panel.Children.Add(chip);
        }
        return panel;
    }

    /// Takes a song out of every row, then (row 0-4) adds it to the end of that row.
    static void Move(string id, int row)
    {
        var list = Current;
        foreach (var r in list.Rows) r.Remove(id);
        if (row is >= 0 and < 5) list.Rows[row].Add(id);
        Store.Shared.SavePersonal();
    }

    void Export(TierList list, Dictionary<string, Song> byId)
    {
        if (SaveFile($"{Engine.SafeName(list.Name)}.png", "PNG image|*.png") is not { } file) return;
        var card = new StackPanel { Width = 1200, Background = Games.Night };
        var top = new DockPanel { Margin = new Thickness(48, 48, 48, 14) };
        var tag = new TextBlock { Text = list.Era.Length == 0 ? "Juice WRLD" : $"Juice WRLD · {list.Era}", FontSize = 24, FontWeight = FontWeights.SemiBold, Foreground = JT.Brush(JT.Lavender), VerticalAlignment = VerticalAlignment.Bottom };
        DockPanel.SetDock(tag, Dock.Right); top.Children.Add(tag);
        top.Children.Add(new TextBlock { Text = list.Name, FontFamily = JT.Marker, FontSize = 54, Foreground = Brushes.White });
        card.Children.Add(top);
        for (int r = 0; r < 5; r++)
        {
            var names = list.Rows[r].Where(byId.ContainsKey).Select(id => byId[id].Name).ToList();
            var line = new DockPanel { Margin = new Thickness(48, 0, 48, 12) };
            var label = new Border { Width = 96, MinHeight = 96, CornerRadius = new CornerRadius(14), Background = JT.Brush(Games.TierColors[r]),
                                     Child = new TextBlock { Text = Games.Tiers[r], FontFamily = JT.Marker, FontSize = 48, Foreground = Brushes.Black, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } };
            DockPanel.SetDock(label, Dock.Left); line.Children.Add(label);
            line.Children.Add(new Border { Margin = new Thickness(12, 0, 0, 0), MinHeight = 96, Padding = new Thickness(16), CornerRadius = new CornerRadius(14),
                                           Background = JT.Brush(Color.FromArgb(41, Games.TierColors[r].R, Games.TierColors[r].G, Games.TierColors[r].B)),
                                           Child = new TextBlock { Text = names.Count == 0 ? "—" : string.Join("  ·  ", names), FontSize = 26, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center } });
            card.Children.Add(line);
        }
        card.Children.Add(new TextBlock { Text = "Made with Juice Tracker", FontFamily = JT.Marker, FontSize = 20, Foreground = JT.Brush(Color.FromArgb(102, 255, 255, 255)), HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(48, 4, 48, 40) });
        Games.SavePng(card, file);
        Result = $"Saved “{list.Name}” as a picture."; ResultIsError = false; Refresh();
    }
}

// MARK: - Lyrics card

/// Pick up to four lines of the song playing and save them as a picture (1080 × 1350) with the cover and the title.
/// The lyrics come live from the site and aren't kept; the picture is only made when you save it.
public sealed class LyricsCardWindow : Window
{
    readonly ImageSource? cover;
    readonly Song? song;
    readonly List<string> lines = [];
    readonly SortedSet<int> picked = [];
    readonly StackPanel list = new();
    readonly Border preview = new() { Width = 324, Height = 405 };
    readonly TextBlock note = UI.Muted("", 12);

    public static void Open(ImageSource? cover) => new LyricsCardWindow(cover) { Owner = MainWindow.Current }.Show();

    LyricsCardWindow(ImageSource? cover)
    {
        this.cover = cover;
        Title = "Lyrics card"; Width = 780; Height = 600; Background = JT.Brush(Color.FromRgb(20, 10, 44)); WindowStartupLocation = WindowStartupLocation.CenterOwner;
        System.Windows.Documents.TextElement.SetFontFamily(this, JT.Body);
        var store = Store.Shared;
        if (Player.Shared.CurrentFile is { } f && store.SongForFile(f) is var i and >= 0) song = store.Songs[i];
        var left = new DockPanel { Width = 380 };
        var hint = UI.Muted("Pick up to four lines", 13); DockPanel.SetDock(hint, Dock.Top); left.Children.Add(hint);
        left.Children.Add(new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(0, 6, 0, 0) });
        var right = UI.Column(10, preview, UI.Row(10, UI.Button("Save image…", Save), UI.Button("Copy", CopyImage)), note);
        right.Margin = new Thickness(20, 0, 0, 0);
        var body = new DockPanel { Margin = new Thickness(22) };
        DockPanel.SetDock(right, Dock.Right); body.Children.Add(right); body.Children.Add(left);
        Content = body;
        Loaded += async (_, _) => await Load();
    }

    async Task Load()
    {
        if (song is null) { list.Children.Add(UI.Muted("Play a song first; its lyrics show up here.", 14)); return; }
        list.Children.Add(UI.Muted("Loading the lyrics…", 13));
        var json = await Store.Shared.DetailsAsync(song.S);
        list.Children.Clear();
        var synced = Listen.ParseSynced(json?["synced_lyrics"]?.GetValue<string>() ?? "");
        var source = synced.Count > 0 ? synced.Select(x => x.Line) : (json?["lyrics"]?.GetValue<string>() ?? "").Split('\n');
        lines.AddRange(source.Select(l => l.Trim()).Where(l => l.Length > 0));
        if (lines.Count == 0) { list.Children.Add(UI.Muted("The site has no lyrics for this song.", 14)); return; }
        // start on the line being sung
        if (synced.Count > 0 && synced.FindLastIndex(x => x.At <= Player.Shared.Position.TotalSeconds) is var now and >= 0)
        {
            var line = synced[now].Line.Trim(); var k = lines.IndexOf(line); if (k >= 0) picked.Add(k);
        }
        DrawList(); DrawPreview();
    }

    void DrawList()
    {
        list.Children.Clear();
        for (int k = 0; k < lines.Count; k++)
        {
            int n = k;
            var row = new Border { Padding = new Thickness(8, 5, 8, 5), CornerRadius = new CornerRadius(6), Cursor = Cursors.Hand,
                                   Background = picked.Contains(k) ? JT.Brush(Color.FromArgb(77, JT.Lavender.R, JT.Lavender.G, JT.Lavender.B)) : Brushes.Transparent,
                                   Child = UI.Text(lines[k], 14, wrap: true) };
            row.MouseLeftButtonUp += (_, _) => { if (!picked.Remove(n) && picked.Count < 4) picked.Add(n); DrawList(); DrawPreview(); };
            UI.AutomationName(row, lines[k]);
            list.Children.Add(row);
        }
    }

    List<string> Chosen => [.. picked.Select(k => lines[k])];
    void DrawPreview() => preview.Child = new Viewbox { Child = Card(Chosen.Count > 0 ? Chosen : ["Pick a line"]) };

    FrameworkElement Card(List<string> chosen)
    {
        var card = new Grid { Width = 1080, Height = 1350, Background = Games.Night, ClipToBounds = true };
        if (cover is not null) card.Children.Add(new Image { Source = cover, Stretch = Stretch.UniformToFill, Opacity = 0.22 });
        card.Children.Add(new Border { Background = new LinearGradientBrush(Colors.Transparent, Color.FromArgb(178, 0, 0, 0), 90) });
        var col = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(70, 0, 70, 0) };
        col.Children.Add(new Border { Width = 360, Height = 360, CornerRadius = new CornerRadius(28), ClipToBounds = true, Margin = new Thickness(0, 0, 0, 40),
                                      Background = new ImageBrush(cover ?? JT.Image("jt-logo")) { Stretch = cover is null ? Stretch.Uniform : Stretch.UniformToFill } });
        foreach (var l in chosen)
            col.Children.Add(new TextBlock { Text = l, FontSize = 54, FontWeight = FontWeights.Black, Foreground = Brushes.White, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 18) });
        col.Children.Add(new TextBlock { Text = song?.Name ?? "", FontFamily = JT.Marker, FontSize = 42, Foreground = JT.Brush(JT.Lavender), TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 22, 0, 6) });
        col.Children.Add(new TextBlock { Text = song is null ? "Juice WRLD" : $"Juice WRLD · {song.Era}", FontSize = 26, FontWeight = FontWeights.SemiBold, Foreground = JT.Brush(Color.FromArgb(178, 255, 255, 255)), TextAlignment = TextAlignment.Center });
        card.Children.Add(col);
        card.Children.Add(new TextBlock { Text = "Juice Tracker", FontFamily = JT.Marker, FontSize = 22, Foreground = JT.Brush(Color.FromArgb(89, 255, 255, 255)), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 36) });
        return card;
    }

    BitmapSource? Render()
    {
        if (Chosen.Count == 0) { note.Text = "Pick a line first."; return null; }
        var card = Card(Chosen);
        card.Measure(new Size(1080, 1350)); card.Arrange(new Rect(0, 0, 1080, 1350)); card.UpdateLayout();
        var bmp = new RenderTargetBitmap(1080, 1350, 96, 96, PixelFormats.Pbgra32); bmp.Render(card);
        return bmp;
    }
    void Save()
    {
        var d = new Microsoft.Win32.SaveFileDialog { FileName = $"{Engine.SafeName(song?.Name ?? "lyrics")} lyrics.png", Filter = "PNG image|*.png" };
        if (d.ShowDialog(this) != true || Render() is not { } bmp) return;
        var enc = new PngBitmapEncoder(); enc.Frames.Add(BitmapFrame.Create(bmp));
        using (var fs = File.Create(d.FileName)) enc.Save(fs);
        note.Text = "Saved.";
    }
    void CopyImage() { if (Render() is { } bmp) { Clipboard.SetImage(bmp); note.Text = "Copied: paste it anywhere."; } }
}
