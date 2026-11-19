using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace JuiceTracker.App;

/// Lyrics timing you made yourself (Time the lyrics on the Player tab), by song id, as LRC text. Kept on this PC only.
static class MyLyrics
{
    static readonly string file = Path.Combine(Store.DataDir, "mylyrics.json");
    static Dictionary<string, string>? all;
    public static event Action? Changed;
    static Dictionary<string, string> All
    {
        get
        {
            if (all is null) try { all = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(file)) ?? []; } catch (Exception) { all = []; }
            return all;
        }
    }
    public static string? Lrc(string id) => All.GetValueOrDefault(id);
    /// A song's timed lyrics: your own timing when you made one, else the site's. Everything that sings uses this.
    public static List<Engine.LrcLine> Synced(EngineSong s, System.Text.Json.Nodes.JsonObject? json) =>
        Engine.ParseLrc(Lrc(s.Id) ?? json?["synced_lyrics"]?.GetValue<string>() ?? "");
    /// Saves (or with null removes) your timing, and the Player picks it up right away.
    public static void Set(string id, string? lrc)
    {
        if (lrc is null) All.Remove(id); else All[id] = lrc;
        Directory.CreateDirectory(Store.DataDir);
        var tmp = file + ".tmp"; File.WriteAllText(tmp, JsonSerializer.Serialize(All)); File.Move(tmp, file, true);
        Changed?.Invoke();
    }
}

/// Make synced lyrics for the song playing: play it, and press Space as each line starts (or each word, word by
/// word). The Player then sings your timing. Saved on this PC; export it as an .lrc file.
public sealed class LyricsMakerWindow : Window
{
    readonly Song? song;
    readonly List<string> lines = [];
    List<List<double>> marks = [];
    readonly StackPanel list = new();
    readonly ScrollViewer scroll;
    readonly TextBlock clock = UI.Muted("", 13), note = UI.Muted("", 12);
    readonly ComboBox mode = new() { Width = 150, ItemsSource = new[] { "By line", "Word by word" }, SelectedIndex = 0 };
    readonly StackPanel buttons = new() { Orientation = Orientation.Horizontal };
    readonly DispatcherTimer timer;

    public static void Open() => new LyricsMakerWindow { Owner = MainWindow.Current }.Show();

    LyricsMakerWindow()
    {
        Title = "Time the lyrics"; Width = 780; Height = 640; Background = JT.Brush(Color.FromRgb(20, 10, 44)); WindowStartupLocation = WindowStartupLocation.CenterOwner;
        System.Windows.Documents.TextElement.SetFontFamily(this, JT.Body);
        var store = Store.Shared;
        if (Player.Shared.CurrentFile is { } f && store.SongForFile(f) is var i and >= 0) song = store.Songs[i];
        scroll = new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(0, 10, 0, 10) };
        mode.SelectionChanged += (_, _) => { marks = lines.Select(_ => new List<double>()).ToList(); Draw(); };
        UI.AutomationName(mode, "Time by line or word by word");
        var body = new DockPanel { Margin = new Thickness(22) };
        var head = UI.Column(8, UI.Marker("Time the lyrics", 26),
                             UI.Muted(song is null ? "Play a song first; its lyrics show up here." : $"“{song.Name}”: press Space as each line (or word) starts. Backspace takes the last tap back and plays from just before it.", 13).Also(t => t.TextWrapping = TextWrapping.Wrap),
                             UI.Row(12, mode, UI.Button("Start from the top", Restart), clock));
        DockPanel.SetDock(head, Dock.Top); body.Children.Add(head);
        var foot = UI.Column(6, buttons, note); DockPanel.SetDock(foot, Dock.Bottom); body.Children.Add(foot);
        body.Children.Add(scroll);
        Content = body;
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Space) { Tap(); e.Handled = true; }
            else if (e.Key is Key.Back or Key.Delete) { Undo(); e.Handled = true; }
        };
        timer = new DispatcherTimer(TimeSpan.FromMilliseconds(250), DispatcherPriority.Background, (_, _) => clock.Text = Engine.LrcStamp(Player.Shared.Position.TotalSeconds), Dispatcher);
        Closed += (_, _) => timer.Stop();
        Loaded += async (_, _) => await Load();
    }

    bool ByWord => mode.SelectedIndex == 1;
    int Need(int k) => ByWord ? Math.Max(1, lines[k].Split(' ', StringSplitOptions.RemoveEmptyEntries).Length) : 1;
    int Cursor => Enumerable.Range(0, lines.Count).FirstOrDefault(k => marks[k].Count < Need(k), -1);
    bool SameSong => song is not null && Player.Shared.CurrentFile is { } f && Store.Shared.SongForFile(f) == song.I;

    async Task Load()
    {
        if (song is null) return;
        var json = await Store.Shared.DetailsAsync(song.S);
        var plain = (json?["lyrics"]?.GetValue<string>() ?? "").Trim();
        var source = plain.Length > 0 ? plain.Split('\n') : Engine.ParseLrc(json?["synced_lyrics"]?.GetValue<string>() ?? "").Select(l => l.Line);
        lines.AddRange(source.Select(l => l.Trim()).Where(l => l.Length > 0));
        marks = lines.Select(_ => new List<double>()).ToList();
        if (lines.Count == 0) note.Text = "The site has no lyrics for this song to time.";
        Draw();
    }

    void Draw()
    {
        list.Children.Clear(); buttons.Children.Clear();
        int cur = Cursor; FrameworkElement? at = null;
        for (int k = 0; k < lines.Count; k++)
        {
            var words = lines[k].Split(' ', StringSplitOptions.RemoveEmptyEntries);
            int lit = ByWord ? marks[k].Count : marks[k].Count > 0 ? words.Length : 0;
            var text = new TextBlock { FontSize = 15, FontWeight = k == cur ? FontWeights.Bold : FontWeights.Normal, TextWrapping = TextWrapping.Wrap };
            for (int w = 0; w < words.Length; w++) text.Inlines.Add(new System.Windows.Documents.Run((w == 0 ? "" : " ") + words[w]) { Foreground = w < lit ? Brushes.White : JT.Brush(JT.Muted) });
            var stamp = UI.Text(marks[k].Count > 0 ? Engine.LrcStamp(marks[k][0]) : "--:--.--", 12, JT.Muted).Also(t => { t.Width = 70; t.FontFamily = new FontFamily("Consolas"); });
            var row = new Border { Padding = new Thickness(8, 4, 8, 4), CornerRadius = new CornerRadius(6), Child = UI.Row(10, stamp, text),
                                   Background = k == cur ? JT.Brush(Color.FromArgb(64, JT.Lavender.R, JT.Lavender.G, JT.Lavender.B)) : Brushes.Transparent };
            list.Children.Add(row);
            if (k == cur) at = row;
        }
        if (at is not null) Dispatcher.BeginInvoke(() => at.BringIntoView(new Rect(0, -120, 10, 280)), DispatcherPriority.Loaded);
        mode.IsEnabled = marks.All(m => m.Count == 0);
        if (song is null || lines.Count == 0) return;
        var tap = UI.Button(cur < 0 ? "All timed" : "Tap (Space)", Tap); tap.IsEnabled = cur >= 0 && SameSong;
        var undo = UI.Button("Take back (Backspace)", Undo); undo.IsEnabled = marks.Any(m => m.Count > 0);
        var lrc = Timed();
        var export = UI.Button("Export .lrc…", () =>
        {
            var d = new Microsoft.Win32.SaveFileDialog { FileName = $"{Engine.SafeName(song.Name)}.lrc", Filter = "Lyrics (LRC)|*.lrc" };
            if (Timed() is { } text && d.ShowDialog(this) == true) File.WriteAllText(d.FileName, text);
        });
        var save = UI.Button("Save", () => { if (Timed() is { } text) { MyLyrics.Set(song.S.Id, text); note.Text = "Saved: the Player sings your timing."; } });
        export.IsEnabled = save.IsEnabled = lrc is not null;
        foreach (var b in new[] { tap, undo, export, save }) { b.Margin = new Thickness(0, 0, 10, 0); buttons.Children.Add(b); }
        if (MyLyrics.Lrc(song.S.Id) is not null) buttons.Children.Add(UI.Link("Remove my timing", () => { MyLyrics.Set(song.S.Id, null); note.Text = "Removed: the site's timing is back."; Draw(); }, 13).Also(l => l.VerticalAlignment = VerticalAlignment.Center));
        if (!SameSong) note.Text = $"The song changed: play “{song.Name}” again to keep timing it.";
    }

    void Restart()
    {
        marks = lines.Select(_ => new List<double>()).ToList(); note.Text = "";
        Player.Shared.Seek(TimeSpan.Zero);
        if (!Player.Shared.IsPlaying) Player.Shared.Resume();
        Draw();
    }
    void Tap()
    {
        int k = Cursor;
        if (k < 0 || !SameSong) return;
        marks[k].Add(Player.Shared.Position.TotalSeconds);
        Draw();
    }
    void Undo()
    {
        int k = marks.FindLastIndex(m => m.Count > 0);
        if (k < 0) return;
        var t = marks[k][^1]; marks[k].RemoveAt(marks[k].Count - 1);
        Player.Shared.Seek(TimeSpan.FromSeconds(Math.Max(0, t - 3)));
        Draw();
    }
    /// The lines timed so far as LRC, or null before the first tap.
    string? Timed()
    {
        var done = Enumerable.Range(0, lines.Count).Where(k => marks[k].Count == Need(k)).ToList();
        return done.Count == 0 ? null : Engine.FormatLrc(done.Select(k => new Engine.LrcLine(marks[k][0], lines[k], ByWord ? [.. marks[k]] : [])));
    }
}
