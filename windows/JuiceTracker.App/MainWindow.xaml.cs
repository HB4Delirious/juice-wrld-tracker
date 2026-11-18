using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace JuiceTracker.App;

public enum Page { Collection, Player, Hunt, Playlists, Fixer, Duplicates, Health, Organize, Credits, Stats, Timeline, Badges, Trivia, Heardle, Wordle, Tiers, Export }

public partial class MainWindow : Window
{
    public static MainWindow? Current { get; private set; }
    Page page = Page.Collection;
    FrameworkElement? shownPage;
    bool pageNeedsSetup;

    public MainWindow()
    {
        InitializeComponent();
        Current = this;
        System.Windows.Documents.TextElement.SetFontFamily(this, JT.Body);
        Store.Shared.Changed += Refresh;
        Player.Shared.Changed += () => sidebar?.UpdatePlayer();
        KeyDown += OnKey;
        // drop an audio file anywhere: which song it is
        AllowDrop = true;
        Drop += (_, e) =>
        {
            if (e.Data.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } files && Identify.Kinds.Contains(Engine.ExtOf(files[0]))) Identify.Show(files[0]);
        };
        PreviewTextInput += (_, e) => { typed = (typed + e.Text)[^Math.Min(3, (typed + e.Text).Length)..]; if (typed == "999") { typed = ""; Fx.Shower999(); } };
        Fx.Attach(FxLayer);
        Store.Shared.Landed += n =>
        {
            Fx.Confetti();
            Toast(n == 1 ? "1 song landed in your library" : $"{n:N0} songs landed in your library");
            Inbox.Add(n == 1 ? "1 song landed in your library" : $"{n:N0} songs landed in your library", "");
            if (Store.Shared.Owned.Count.ToString().Contains("999")) Fx.Shower999();
        };
        // with "keep running" on, closing hides the window; the notification-area icon brings it back or quits
        Shortcuts.Start(this); // your keyboard shortcuts
        Closing += (_, e) =>
        {
            if (Store.Shared.Me.KeepRunning && !Tray.Quitting) { e.Cancel = true; Hide(); }
            else if (!Tray.Quitting && !App.ConfirmQuit()) e.Cancel = true;
        };
        Restyle();
    }
    string typed = "";

    /// Applies the look settings: theme colors (the whole window is drawn again with them) and compact mode.
    public void Restyle()
    {
        SkyLayer.Restyle();
        Body.LayoutTransform = Store.Shared.Me.Compact ? new ScaleTransform(0.88, 0.88) : Transform.Identity;
        sidebar = null; shownPage = null;
        Refresh();
    }

    /// A short note that slides in at the bottom and fades away.
    public void Toast(string text)
    {
        var t = new Border
        {
            Background = JT.Brush(Color.FromArgb(235, 30, 16, 60)), BorderBrush = JT.Brush(JT.Lavender), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(14),
            Padding = new Thickness(18, 10, 18, 10), Child = UI.Text(text, 15), Effect = UI.Glow(JT.Lavender),
        };
        FxLayer.Children.Add(t);
        t.Loaded += (_, _) => { Canvas.SetLeft(t, (FxLayer.ActualWidth - t.ActualWidth) / 2); };
        Canvas.SetTop(t, FxLayer.ActualHeight - 90);
        var fade = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(4), KeyFrames = { new LinearDoubleKeyFrame(0, KeyTime.FromPercent(0)), new LinearDoubleKeyFrame(1, KeyTime.FromPercent(0.08)), new LinearDoubleKeyFrame(1, KeyTime.FromPercent(0.8)), new LinearDoubleKeyFrame(0, KeyTime.FromPercent(1)) } };
        fade.Completed += (_, _) => FxLayer.Children.Remove(t);
        t.BeginAnimation(OpacityProperty, fade);
    }

    Sidebar? sidebar;

    /// Ctrl+K searches songs (⌘K on the Mac); Esc closes a song card.
    void OnKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.K && Keyboard.Modifiers == ModifierKeys.Control) { Show(Page.Collection); (shownPage as CollectionPage)?.FocusSearch(); e.Handled = true; }
        else if (e.Key == Key.Escape && Overlay.Visibility == Visibility.Visible) { CloseOverlay(); e.Handled = true; }
        else if (e.Key == Key.OemComma && Keyboard.Modifiers == ModifierKeys.Control) { SettingsWindow.Open(); e.Handled = true; }
    }

    public FrameworkElement? CurrentPage => shownPage;
    public static IEnumerable<Page> AvailablePages => Sidebar.Available;

    public void Show(Page p)
    {
        if (p == page && shownPage is not null) return;
        page = p; shownPage = null;
        Refresh();
    }

    /// Redraws what changed: the sidebar always (counts, queue), the page when the store changed.
    void Refresh()
    {
        sidebar ??= new Sidebar(this);
        SidebarHost.Content = sidebar;
        sidebar.Update(page);
        var store = Store.Shared;
        // download progress on the taskbar button
        if (TaskbarItemInfo is { } bar)
        {
            if (store.Me.TaskbarProgress && store.Job is { } job && job.Total > 0)
            { bar.ProgressState = job.Waiting ? System.Windows.Shell.TaskbarItemProgressState.Paused : System.Windows.Shell.TaskbarItemProgressState.Normal; bar.ProgressValue = (double)job.Done / job.Total; }
            else bar.ProgressState = System.Windows.Shell.TaskbarItemProgressState.None;
        }
        bool setup = store.Catalog.Count == 0 || store.Root is null || (store.Files.Count == 0 && store.Match.Owned.Count == 0 && !store.Scanning && store.FolderStatus.Length == 0);
        if (setup)
        {
            if (shownPage is not SetupPage) { shownPage = new SetupPage(); PageHost.Content = shownPage; UI.FadeIn(shownPage); SkyLayer.Visibility = Visibility.Visible; }
            else ((SetupPage)shownPage).Update();
            pageNeedsSetup = true;
            return;
        }
        if (shownPage is null || pageNeedsSetup || shownPage is SetupPage)
        {
            pageNeedsSetup = false;
            shownPage = page switch
            {
                Page.Fixer => new FixerPage(), Page.Duplicates => new DuplicatesPage(), Page.Health => new HealthPage(), Page.Organize => new OrganizePage(),
                Page.Export => new ExportPage(), _ => MorePages.Make(page) ?? new CollectionPage(),
            };
            PageHost.Content = shownPage;
            UI.FadeIn(shownPage);
            // the Player draws its own space over everything; WPF would still draw the animated sky hidden under it
            SkyLayer.Visibility = shownPage is PlayerPage ? Visibility.Hidden : Visibility.Visible;
        }
        else (shownPage as IRefresh)?.Refresh();
    }

    // MARK: Sheets over the window

    public void ShowOverlay(FrameworkElement sheet)
    {
        Overlay.Children.Clear();
        var catcher = new Border { Background = Brushes.Transparent };
        catcher.MouseLeftButtonDown += (_, _) => CloseOverlay();
        Overlay.Children.Add(catcher);
        sheet.HorizontalAlignment = HorizontalAlignment.Center; sheet.VerticalAlignment = VerticalAlignment.Center;
        Overlay.Children.Add(sheet);
        Overlay.Visibility = Visibility.Visible;
        sheet.RenderTransformOrigin = new Point(0.5, 0.5);
        var s = new ScaleTransform(0.96, 0.96); sheet.RenderTransform = s;
        var ease = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.3 };
        s.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.96, 1, TimeSpan.FromSeconds(0.25)) { EasingFunction = ease });
        s.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.96, 1, TimeSpan.FromSeconds(0.25)) { EasingFunction = ease });
        Overlay.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.18)));
    }
    public void CloseOverlay() { Overlay.Visibility = Visibility.Collapsed; Overlay.Children.Clear(); Keyboard.Focus(this); }
    public void OpenSong(Song s) => ShowOverlay(new SongCard(s));
}

/// A screen that can redraw itself in place when the store changes (keeping its scroll position and search).
public interface IRefresh { void Refresh(); }

/// The classic rail: logo, search, the pages, then downloads, the player and settings at the bottom.
public sealed class Sidebar : Grid
{
    readonly MainWindow window;
    readonly StackPanel nav = new();
    readonly StackPanel bottom = new();
    readonly PlayerPanel player = new();

    public Sidebar(MainWindow w)
    {
        window = w;
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Margin = new Thickness(16, 0, 14, 16);

        var top = new StackPanel();
        // logo: the butterfly and "Juice Tracker" in marker, wiggling on hover
        var logo = new Image { Source = JT.Image("jt-logo"), Width = 44, Height = 44, RenderTransformOrigin = new Point(0.5, 0.5) };
        var brand = UI.Marker("Juice\nTracker", 23); brand.LineHeight = 23; brand.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
        var head = UI.Row(10, logo, brand);
        head.Cursor = Cursors.Hand; head.Background = Brushes.Transparent;
        var rt = new TransformGroup { Children = { new RotateTransform(), new ScaleTransform(1, 1) } }; logo.RenderTransform = rt;
        head.MouseEnter += (_, _) => Wiggle(rt, true); head.MouseLeave += (_, _) => Wiggle(rt, false);
        head.MouseLeftButtonUp += (_, _) => window.Show(Page.Collection);
        var headRow = new DockPanel { Margin = new Thickness(8, 38, 4, 22) };
        var bell = Inbox.Bell(); DockPanel.SetDock(bell, Dock.Right); headRow.Children.Add(bell); headRow.Children.Add(head);
        top.Children.Add(headRow);

        // search: Ctrl+K
        var searchText = UI.Row(10, UI.Icon("", 13, JT.Muted), UI.Text("Search", 15, JT.Muted));
        var hint = new Border { BorderBrush = JT.Brush(JT.Line2), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6), Padding = new Thickness(6, 0, 6, 1), Child = UI.Text("Ctrl K", 11.5, JT.Muted) };
        var searchRow = new DockPanel(); DockPanel.SetDock(hint, Dock.Right); searchRow.Children.Add(hint); searchRow.Children.Add(searchText);
        var search = new Button { Content = new Border { Padding = new Thickness(12, 9, 12, 9), Child = searchRow }, Style = (Style)Application.Current.FindResource("Plain"), HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var searchBox = new Border { CornerRadius = new CornerRadius(12), BorderBrush = JT.Brush(JT.Line), BorderThickness = new Thickness(1), Background = JT.Brush(Color.FromArgb(8, 255, 255, 255)), Child = search, Margin = new Thickness(0, 0, 0, 22) };
        search.Click += (_, _) => { window.Show(Page.Collection); Dispatcher.BeginInvoke(() => (window.PageHost.Content as CollectionPage)?.FocusSearch()); };
        UI.AutomationName(search, "Search songs");
        top.Children.Add(searchBox);
        SetRow(top, 0); Children.Add(top);

        var navScroll = new ScrollViewer { Content = nav, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        SetRow(navScroll, 1); Children.Add(navScroll);
        SetRow(bottom, 2); Children.Add(bottom);
    }

    static void Wiggle(TransformGroup t, bool on)
    {
        var dur = TimeSpan.FromSeconds(0.3); var ease = new ElasticEase { Oscillations = 1, Springiness = 4 };
        ((RotateTransform)t.Children[0]).BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(on ? -14 : 0, dur) { EasingFunction = ease });
        var sc = (ScaleTransform)t.Children[1];
        sc.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(on ? 1.12 : 1, dur) { EasingFunction = ease });
        sc.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(on ? 1.12 : 1, dur) { EasingFunction = ease });
    }

    static readonly (Page Page, string Title, string Icon)[] AllPages =
    [
        (Page.Collection, "Collection", "\uE8D6"), (Page.Player, "Player", "\uE768"), (Page.Hunt, "Hunt", "\uE7B3"), (Page.Playlists, "Playlists", "\uE90B"), (Page.Fixer, "Tag fixer", "\uE8EC"),
        (Page.Duplicates, "Duplicates", "\uE8C8"), (Page.Health, "File health", "\uE9D9"), (Page.Organize, "Organize", "\uE8B7"), (Page.Credits, "Credits", "\uE716"),
        (Page.Stats, "Stats", "\uE9D2"), (Page.Timeline, "Timeline", "\uE81C"), (Page.Badges, "Badges", "\uE7C1"), (Page.Trivia, "Trivia", "\uE9CE"), (Page.Heardle, "Heardle", "\uE7F6"), (Page.Wordle, "Wordle", "\uE765"), (Page.Tiers, "Tier list", "\uE8FD"), (Page.Export, "Export & backup", "\uE7B8"),
    ];
    public static IEnumerable<Page> Available => Pages.Select(p => p.Page);
    /// The pages this build has (each stage adds its own).
    static IEnumerable<(Page Page, string Title, string Icon)> Pages => AllPages.Where(p => p.Page is Page.Collection or Page.Fixer or Page.Duplicates or Page.Health or Page.Organize or Page.Export || MorePages.Has(p.Page));

    public void Update(Page current)
    {
        nav.Children.Clear();
        foreach (var (p, title, icon) in Pages) nav.Children.Add(NavItem(p, title, icon, p == current));
        bottom.Children.Clear();
        var store = Store.Shared;
        if (store.Job is { } q)
        {
            var box = new StackPanel();
            var line = new DockPanel();
            var stop = UI.Link("Stop", store.StopDownloads, 12); DockPanel.SetDock(stop, Dock.Right); line.Children.Add(stop);
            line.Children.Add(UI.Text(q.Waiting ? "Waiting for the music drive…" : $"Downloading {Math.Min(q.Done + 1, q.Total)} of {q.Total}", 12));
            box.Children.Add(line);
            if (q.Current.Length > 0) box.Children.Add(UI.Text(q.Current, 11, JT.Muted));
            var bar = UI.Bar((double)q.Done / Math.Max(q.Total, 1), JT.Brush(JT.Have)); bar.Margin = new Thickness(0, 5, 0, 0); box.Children.Add(bar);
            bottom.Children.Add(new Border { Child = box, Padding = new Thickness(10), BorderBrush = JT.Brush(JT.Line), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Margin = new Thickness(0, 0, 0, 10) });
        }
        else if (store.DownloadNote.Length > 0) bottom.Children.Add(new TextBlock { Text = store.DownloadNote, FontSize = 11.5, Foreground = JT.Brush(JT.Muted), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(4, 0, 4, 10) });
        if (store.Root is { } root)
        {
            bool ok = System.IO.Directory.Exists(root);
            var dot = new Ellipse { Width = 8, Height = 8, Fill = JT.Brush(ok ? JT.Have : JT.Missing) };
            var pill = new Border { CornerRadius = new CornerRadius(10), BorderBrush = JT.Brush(JT.Line), BorderThickness = new Thickness(1), Padding = new Thickness(12, 5, 12, 5),
                                    HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 0, 0, 10), Child = UI.Row(8, dot, UI.Text(ok ? "Music drive connected" : "Music drive not found", 12.5, JT.Muted)) };
            bottom.Children.Add(pill);
        }
        bottom.Children.Add(player);
        player.Margin = new Thickness(0, 0, 0, 12);
        player.Update();
        var settings = UI.Button("Settings", SettingsWindow.Open, "");
        settings.HorizontalAlignment = HorizontalAlignment.Left; settings.Margin = new Thickness(0, 0, 0, 10);
        bottom.Children.Add(settings);
        // the Mac app's "Support this project" capsule: a heart and dark text on an orange gradient, opening Ko-fi
        var support = new Button
        {
            Style = (Style)Application.Current.FindResource("Plain"), Cursor = Cursors.Hand, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 0, 0, 10),
            Content = new Border
            {
                CornerRadius = new CornerRadius(18), Padding = new Thickness(16, 9, 16, 9),
                Background = new LinearGradientBrush(Color.FromRgb(255, 184, 89), JT.New, 90),
                Child = UI.Row(8, UI.Icon("", 14, JT.Missing), UI.Text("Support this project", 14, JT.Night, weight: FontWeights.SemiBold)),
            },
        };
        support.Click += (_, _) => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("https://ko-fi.com/hb4delirious") { UseShellExecute = true });
        UI.AutomationName(support, "Support this project on Ko-fi");
        bottom.Children.Add(support);
        bottom.Children.Add(new TextBlock { Text = "Your files stay on this computer. Only song info comes from juicewrldapi.com.", FontSize = 11, Foreground = JT.Brush(JT.Muted), TextWrapping = TextWrapping.Wrap });
    }
    public void UpdatePlayer() => player.Update();

    FrameworkElement NavItem(Page p, string title, string icon, bool current)
    {
        var glyph = UI.Icon(icon, 15, current ? JT.Lavender : JT.Muted); glyph.Width = 22; glyph.RenderTransformOrigin = new Point(0.5, 0.5);
        var label = UI.Text(title, 16, current ? JT.Mist : JT.Muted);
        var content = UI.Row(12, glyph, label);
        var bg = new Grid();
        var fill = new Border { CornerRadius = new CornerRadius(12), Background = current ? JT.Brush(JT.Raise) : Brushes.Transparent };
        bg.Children.Add(fill);
        if (current) bg.Children.Add(new Image { Source = JT.Image("jt-scribble"), Stretch = Stretch.Fill, Opacity = 0.9 });
        bg.Children.Add(new Border { Padding = new Thickness(12, 8, 12, 8), Child = content });
        if (current)
            bg.Children.Add(new Border { Width = 3, CornerRadius = new CornerRadius(1.5), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 7, 0, 7), Background = JT.Gradient(JT.Rainbow, vertical: true) });
        var b = new Button { Content = bg, Style = (Style)Application.Current.FindResource("Plain"), HorizontalContentAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(0, 0, 0, 2) };
        b.Click += (_, _) => window.Show(p);
        b.MouseEnter += (_, _) => { if (!current) { fill.Background = JT.Brush(Color.FromArgb(125, 58, 30, 108)); label.Foreground = JT.Brush(JT.Mist); } glyph.RenderTransform = new TransformGroup { Children = { new RotateTransform(-10), new ScaleTransform(1.15, 1.15) } }; };
        b.MouseLeave += (_, _) => { if (!current) { fill.Background = Brushes.Transparent; label.Foreground = JT.Brush(JT.Muted); } glyph.RenderTransform = current ? new TransformGroup { Children = { new RotateTransform(-10), new ScaleTransform(1.15, 1.15) } } : null; };
        if (current) glyph.RenderTransform = new TransformGroup { Children = { new RotateTransform(-10), new ScaleTransform(1.15, 1.15) } };
        UI.AutomationName(b, title);
        return b;
    }
}
