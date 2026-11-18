using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;

namespace JuiceTracker.App;

public sealed record InboxItem(string Title, string Body, DateTime At, List<string> Ids);

/// The app's recent alerts (new songs, downloads that landed, updates, a full drive), kept so you can see what you
/// missed: the bell at the top of the sidebar. The newest 50, on this PC.
static class Inbox
{
    public static event Action? Changed;
    public static int Unread => Store.Shared.Me.Notices.Count(i => i.At > Store.Shared.Me.NoticesSeen);
    public static void Add(string title, string body, IEnumerable<string>? ids = null)
    {
        var me = Store.Shared.Me;
        me.Notices.Insert(0, new InboxItem(title, body, DateTime.Now, ids?.ToList() ?? []));
        if (me.Notices.Count > 50) me.Notices.RemoveRange(50, me.Notices.Count - 50);
        Store.Shared.SavePersonal(); Changed?.Invoke();
    }
    public static void MarkSeen() { Store.Shared.Me.NoticesSeen = DateTime.Now; Store.Shared.SavePersonal(); Changed?.Invoke(); }
    public static void Clear() { Store.Shared.Me.Notices.Clear(); Store.Shared.SavePersonal(); Changed?.Invoke(); }

    /// The bell: a dot when there's something new; click for the list.
    public static FrameworkElement Bell()
    {
        var icon = UI.Icon("", 15);
        var bell = new Button { Content = icon, Style = (Style)Application.Current.FindResource("Plain"), Cursor = Cursors.Hand, Width = 30, Height = 30, VerticalAlignment = VerticalAlignment.Center };
        var dot = new Border { Width = 8, Height = 8, CornerRadius = new CornerRadius(4), Background = JT.Brush(JT.Lavender), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 4, 4, 0), IsHitTestVisible = false };
        var popup = new Popup { PlacementTarget = bell, Placement = PlacementMode.Right, StaysOpen = false, AllowsTransparency = true };
        void Draw()
        {
            int n = Unread;
            dot.Visibility = n > 0 ? Visibility.Visible : Visibility.Collapsed;
            icon.Foreground = JT.Brush(n > 0 ? JT.Lavender : JT.Muted);
            UI.AutomationName(bell, n > 0 ? $"{n} new notifications" : "Notifications"); bell.ToolTip = n > 0 ? $"{n} new" : "Notifications";
        }
        bell.Click += (_, _) => { popup.Child = List(() => popup.IsOpen = false); popup.IsOpen = true; MarkSeen(); };
        Changed += () => bell.Dispatcher.BeginInvoke(Draw);
        Draw();
        return new Grid { Children = { bell, dot }, VerticalAlignment = VerticalAlignment.Center };
    }

    static FrameworkElement List(Action close)
    {
        var items = Store.Shared.Me.Notices;
        var col = new StackPanel();
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        if (items.Count > 0) { var clear = UI.Link("Clear", () => { Clear(); close(); }, 13); DockPanel.SetDock(clear, Dock.Right); head.Children.Add(clear); }
        head.Children.Add(UI.Marker("Notifications", 20));
        col.Children.Add(head);
        if (items.Count == 0) col.Children.Add(UI.Muted("New songs, downloads that land and updates show up here.", 13).Also(t => t.TextWrapping = TextWrapping.Wrap));
        var list = new StackPanel();
        foreach (var item in items)
        {
            var row = new StackPanel();
            var top = new DockPanel(); var when = UI.Text(Ago(item.At), 11, JT.Muted); DockPanel.SetDock(when, Dock.Right); top.Children.Add(when);
            top.Children.Add(UI.Text(item.Title, 13, weight: FontWeights.SemiBold).Also(t => t.TextWrapping = TextWrapping.Wrap));
            row.Children.Add(top);
            if (item.Body.Length > 0) row.Children.Add(UI.Text(item.Body, 12, JT.Muted, wrap: true));
            var card = new Border { Padding = new Thickness(8), Margin = new Thickness(0, 0, 0, 8), CornerRadius = new CornerRadius(8), Background = JT.Brush(Color.FromArgb(13, 255, 255, 255)), Child = row, Cursor = item.Ids.Count > 0 ? Cursors.Hand : null };
            card.MouseLeftButtonUp += (_, _) =>
            {
                if (item.Ids.FirstOrDefault() is { } id && Store.Shared.Songs.FirstOrDefault(s => s.S.Id == id) is { } s) { close(); MainWindow.Current?.OpenSong(s); }
            };
            list.Children.Add(card);
        }
        col.Children.Add(new ScrollViewer { Content = list, MaxHeight = 400, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        return new Border { Width = 340, Padding = new Thickness(16), CornerRadius = new CornerRadius(14), Background = JT.Brush(Color.FromRgb(20, 10, 44)), BorderBrush = JT.Brush(JT.Line2), BorderThickness = new Thickness(1), Child = col };
    }
    static string Ago(DateTime at)
    {
        var d = DateTime.Now - at;
        return d.TotalMinutes < 1 ? "just now" : d.TotalHours < 1 ? $"{(int)d.TotalMinutes} min ago" : d.TotalDays < 1 ? $"{(int)d.TotalHours} h ago" : $"{(int)d.TotalDays} d ago";
    }
}

/// Bytes free on a drive (local or a network share), or null when it can't be told.
static class Disk
{
    public static long? Free(string? folder)
    {
        if (folder is null) return null;
        try { return GetDiskFreeSpaceEx(folder, out var free, out _, out _) ? (long)free : null; } catch (Exception) { return null; }
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool GetDiskFreeSpaceEx(string dir, out ulong freeToCaller, out ulong total, out ulong totalFree);
}

/// Which catalog song an audio file is: read like a library file (its tags, else its name), matched the same way,
/// and of versions sharing a title, the one closest to the file's length.
static class Identify
{
    public static readonly HashSet<string> Kinds = ["mp3", "m4a", "m4b", "aac", "flac", "wav", "wma", "ogg", "opus", "aif", "aiff"];
    /// Off the UI thread: it reads the file.
    public static (int? Song, string How) Find(string file, List<EngineSong> catalog)
    {
        var ext = Engine.ExtOf(file); var tags = TagReader.Read(file, ext);
        bool fromTags = tags.GetValueOrDefault("title", "").Length > 0;
        var title = fromTags ? tags["title"] : Engine.TitleFromFilename(file);
        var path = "dropped/" + Path.GetFileName(file);
        var f = new LibraryFile(path, ext, tags, title, Engine.Normalize(title), Engine.StemOf(path), fromTags, 0);
        var m = Engine.MatchFiles(catalog, [f], new Dictionary<string, string>());
        double? seconds = null;
        try { using var r = new NAudio.Wave.MediaFoundationReader(file); seconds = r.TotalTime.TotalSeconds; } catch (Exception) { }
        var pick = Engine.ClosestByLength(m.SongsFor.GetValueOrDefault(path) ?? [], catalog, seconds);
        var how = m.How.GetValueOrDefault(path) switch { "title" => fromTags ? "by its title tag" : "by its file name", "file" => "by the site's file name", "close" => "by a close title", _ => "" };
        return (pick, how);
    }

    public static async void Show(string file)
    {
        var catalog = Store.Shared.Catalog;
        var (song, how) = await Task.Run(() => Find(file, catalog));
        var col = UI.Column(10, UI.Marker("What song is this?", 24), UI.Muted(Path.GetFileName(file), 13));
        var w = new Window { Title = "What song is this?", Width = 460, SizeToContent = SizeToContent.Height, Background = JT.Brush(Color.FromRgb(20, 10, 44)), Owner = MainWindow.Current, WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize };
        System.Windows.Documents.TextElement.SetFontFamily(w, JT.Body);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0) };
        if (song is { } i && Store.Shared.Songs.FirstOrDefault(s => s.I == i) is { } s)
        {
            col.Children.Add(UI.Text(s.Name, 22, weight: FontWeights.Bold).Also(t => t.TextWrapping = TextWrapping.Wrap));
            col.Children.Add(UI.Muted($"{s.Era} · {s.Category}{(how.Length > 0 ? $" · matched {how}" : "")}", 13));
            col.Children.Add(UI.Text(s.Owned ? "✓ You have it" : "You don't have it yet", 14, s.Owned ? JT.Have : JT.Missing, FontWeights.SemiBold));
            buttons.Children.Add(UI.Button("Open the song card", () => { w.Close(); MainWindow.Current?.OpenSong(s); }).Also(b => b.Margin = new Thickness(0, 0, 10, 0)));
        }
        else
        {
            col.Children.Add(UI.Text("No song in the catalog matches this file.", 16, weight: FontWeights.SemiBold));
            col.Children.Add(UI.Muted("It may not be Juice WRLD, or its title and file name are too different from the site's.", 13).Also(t => t.TextWrapping = TextWrapping.Wrap));
        }
        buttons.Children.Add(UI.Button("Close", w.Close).Also(b => b.IsCancel = true));
        col.Children.Add(buttons);
        w.Content = new Border { Padding = new Thickness(24), Child = col };
        w.Show();
    }
}
