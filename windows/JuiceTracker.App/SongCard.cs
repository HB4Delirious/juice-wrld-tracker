using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace JuiceTracker.App;

/// A song's card: its details from the site, your rating and note, your files, and what you can do with it.
public sealed class SongCard : Border
{
    readonly Song song;
    readonly StackPanel details = new();
    readonly StackPanel hearts = new() { Orientation = Orientation.Horizontal };

    public SongCard(Song s)
    {
        song = s;
        Width = 680; Height = 600;
        Background = JT.Brush(Color.FromRgb(20, 10, 44)); CornerRadius = new CornerRadius(14);
        BorderBrush = JT.Brush(JT.Line2); BorderThickness = new Thickness(1); Padding = new Thickness(24);
        var store = Store.Shared;

        var head = new DockPanel();
        var close = UI.Button("Close", () => MainWindow.Current?.CloseOverlay()); close.IsCancel = true; close.VerticalAlignment = VerticalAlignment.Top;
        DockPanel.SetDock(close, Dock.Right); head.Children.Add(close);
        var titles = new StackPanel();
        titles.Children.Add(new TextBlock { Text = s.Name, FontFamily = JT.Marker, FontSize = 30, TextWrapping = TextWrapping.Wrap });
        titles.Children.Add(UI.Text($"{s.Category} · {s.Era} era", 15, JT.Muted));
        if (s.S.Alt.Count > 0) titles.Children.Add(UI.Text("Also known as " + string.Join(", ", s.S.Alt), 12, JT.Muted, wrap: true));
        var chips = UI.Row(10, hearts);
        if (Engine.Rarity(s.S, s.Owned) is { } r)
            chips.Children.Add(new Border { CornerRadius = new CornerRadius(10), Padding = new Thickness(7, 2, 7, 2), Margin = new Thickness(10, 0, 0, 0),
                                            Background = JT.Brush(r == "Grail" ? JT.Gold : JT.Raise),
                                            ToolTip = r == "Grail" ? "Unreleased, no file on the site, and you have it" : "Unreleased, and the site has no file for it",
                                            Child = UI.Text(r.ToUpperInvariant(), 11, r == "Grail" ? JT.Night : JT.Mist, FontWeights.Bold) });
        chips.Margin = new Thickness(0, 6, 0, 0);
        titles.Children.Add(chips);
        head.Children.Add(titles);
        DrawHearts();

        var actions = new WrapPanel { Margin = new Thickness(0, 14, 0, 0) };
        actions.Children.Add(UI.Button(s.Wished ? "On your wishlist" : "Add to wishlist", () => { store.ToggleWish(s.S.Id); MainWindow.Current?.OpenSong(store.Songs[s.I]); }, s.Wished ? "" : ""));
        if (s.Owned) actions.Children.Add(Spaced(UI.Button("Play", () => Play(s), "")));
        if (!s.Owned && s.HasFile) actions.Children.Add(Spaced(UI.Button("Download", () => store.AddDownloads([s.S.Id]), "")));
        var site = $"https://juicewrldapi.com/juicewrld/songs/{s.S.Id}/";

        var scroll = new ScrollViewer { Content = details, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(0, 14, 0, 0) };
        var dock = new DockPanel();
        DockPanel.SetDock(head, Dock.Top); DockPanel.SetDock(actions, Dock.Bottom);
        dock.Children.Add(head); dock.Children.Add(actions); dock.Children.Add(scroll);
        Child = dock;
        details.Children.Add(UI.Muted("Loading the details…", 14));
        Loaded += async (_, _) => Fill(await store.DetailsAsync(s.S));
        // 1-5 rate the song, 0 clears (not while typing a note)
        PreviewKeyDown += (_, e) =>
        {
            if (Keyboard.FocusedElement is TextBox) return;
            int n = e.Key is >= Key.D0 and <= Key.D5 ? e.Key - Key.D0 : e.Key is >= Key.NumPad0 and <= Key.NumPad5 ? e.Key - Key.NumPad0 : -1;
            if (n >= 0) { store.SetRating(s.S.Id, n); DrawHearts(); e.Handled = true; }
        };
        Focusable = true;
        Loaded += (_, _) => Focus();
    }

    static FrameworkElement Spaced(FrameworkElement e) { e.Margin = new Thickness(10, 0, 0, 0); return e; }

    void DrawHearts()
    {
        hearts.Children.Clear();
        var rating = Store.Shared.Me.Ratings.GetValueOrDefault(song.S.Id);
        for (int n = 1; n <= 5; n++)
        {
            int k = n;
            var b = UI.IconButton(k <= rating ? "" : "", k == rating ? "Clear the rating" : $"{k} {(k == 1 ? "heart" : "hearts")}",
                                  () => { Store.Shared.SetRating(song.S.Id, k == rating ? 0 : k); DrawHearts(); }, 16, k <= rating ? JT.Missing : Color.FromArgb(153, JT.Muted.R, JT.Muted.G, JT.Muted.B));
            b.Margin = new Thickness(0, 0, 3, 0);
            hearts.Children.Add(b);
        }
        UI.AutomationName(hearts, rating == 0 ? "Not rated" : $"Rated {rating} of 5");
    }

    void Fill(JsonObject? json)
    {
        var store = Store.Shared; var s = song.S;
        var full = json is not null ? Engine.CleanSong(json) : s;
        details.Children.Clear();
        (string, string)[] facts =
        [
            ("Length", full.Length), ("Original key", full.Key), ("Recorded", full.RecordDates), ("Previewed", full.PreviewDate), ("Released", full.Release),
            ("Surfaced", string.Join(", ", new[] { full.LeakDate, full.LeakType }.Where(x => x.Length > 0))), ("Sessions", full.Sessions), ("Artists", full.Artists),
            ("Producers", full.Producers), ("Engineers", full.Engineers), ("Studios", full.Locations),
        ];
        foreach (var (k, v) in facts.Where(f => f.Item2.Trim().Length > 0))
        {
            var row = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
            var key = UI.Text(k, 14, JT.Muted); key.Width = 110; DockPanel.SetDock(key, Dock.Left); row.Children.Add(key);
            row.Children.Add(new TextBox { Text = v.Trim(), IsReadOnly = true, Background = Brushes.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(0), TextWrapping = TextWrapping.Wrap, FontSize = 14 });
            details.Children.Add(row);
        }
        var notes = string.Join("\n\n", new[] { full.Notes, full.Info }.Where(x => x.Length > 0));
        if (notes.Length > 0) { details.Children.Add(Heading("Notes")); details.Children.Add(UI.Text(notes, 14, JT.Muted, wrap: true)); }
        if (json?["image_url"]?.GetValue<string>() is { Length: > 0 } img && Uri.TryCreate(new Uri("https://juicewrldapi.com"), img, out var url))
        {
            var pic = new Image { Width = 64, Height = 64, Stretch = Stretch.UniformToFill, Margin = new Thickness(0, 10, 10, 0) };
            pic.Source = new BitmapImage(url);
            details.Children.Add(UI.Row(10, pic, UI.Text("Era artwork from juicewrldapi.com", 12, JT.Muted)));
        }
        // lyrics are shown live from the site and never saved
        if (json?["lyrics"]?.GetValue<string>() is { Length: > 0 } lyrics && lyrics.Trim().Length > 0)
        {
            details.Children.Add(Heading("Lyrics"));
            details.Children.Add(UI.Text(lyrics.Trim(), 14, JT.Muted, wrap: true));
        }
        details.Children.Add(Heading("Your note"));
        var note = new TextBox { Text = store.Me.Notes.GetValueOrDefault(s.Id, ""), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 54 };
        note.LostKeyboardFocus += (_, _) => store.SetNote(s.Id, note.Text);
        UI.AutomationName(note, "Your note");
        details.Children.Add(note);
        details.Children.Add(Heading("Your library"));
        var files = store.Match.Owned.GetValueOrDefault(song.I) ?? [];
        if (files.Count == 0) details.Children.Add(UI.Text("Not in your library.", 14, JT.Muted));
        foreach (var f in files) details.Children.Add(new TextBlock { Text = f, FontFamily = new FontFamily("Consolas"), FontSize = 12, Foreground = JT.Brush(JT.Muted), TextTrimming = TextTrimming.CharacterEllipsis });
        // other versions of this song, side by side
        var key0 = Engine.Normalize(s.Name);
        var others = store.Songs.Where(o => o.I != song.I && Engine.Normalize(o.Name) == key0).ToList();
        if (others.Count > 0)
        {
            details.Children.Add(Heading($"Other versions ({others.Count})"));
            foreach (var o in others)
            {
                var row = new DockPanel { Margin = new Thickness(0, 2, 0, 2) };
                var status = UI.Text(o.Owned ? "In library" : o.HasFile ? "On the site" : "No file", 13, o.Owned ? JT.Have : JT.Muted);
                DockPanel.SetDock(status, Dock.Right); row.Children.Add(status);
                row.Children.Add(UI.Row(8, UI.Link(o.Name, () => MainWindow.Current?.OpenSong(o), 13.5), UI.Text(o.Category, 13, JT.Muted)));
                details.Children.Add(row);
            }
        }
    }

    static FrameworkElement Heading(string s) { var t = UI.Text(s, 16, weight: FontWeights.SemiBold); t.Margin = new Thickness(0, 14, 0, 6); return t; }

    public static void Play(Song s)
    {
        var store = Store.Shared;
        foreach (var p in store.Match.Owned.GetValueOrDefault(s.I) ?? [])
            if (Player.Playable.Contains(Engine.ExtOf(p)) && store.FullPath(p) is { } full)
            {
                if (!store.Me.AmbientOn) { store.Me.AmbientOn = true; store.SavePersonal(); }
                Player.Shared.PlayNow(full, s.Name);
                return;
            }
    }
}
