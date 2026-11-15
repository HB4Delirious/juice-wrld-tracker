using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace JuiceTracker.App;

public enum Page { Collection, Fixer }

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
        Refresh();
    }

    Sidebar? sidebar;

    /// Ctrl+K searches songs (⌘K on the Mac); Esc closes a song card.
    void OnKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.K && Keyboard.Modifiers == ModifierKeys.Control) { Show(Page.Collection); (shownPage as CollectionPage)?.FocusSearch(); e.Handled = true; }
        else if (e.Key == Key.Escape && Overlay.Visibility == Visibility.Visible) { CloseOverlay(); e.Handled = true; }
        else if (e.Key == Key.OemComma && Keyboard.Modifiers == ModifierKeys.Control) { SettingsWindow.Open(); e.Handled = true; }
    }

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
        bool setup = store.Catalog.Count == 0 || store.Root is null || (store.Files.Count == 0 && store.Match.Owned.Count == 0 && !store.Scanning && store.FolderStatus.Length == 0);
        if (setup)
        {
            if (shownPage is not SetupPage) { shownPage = new SetupPage(); PageHost.Content = shownPage; UI.FadeIn(shownPage); }
            else ((SetupPage)shownPage).Update();
            pageNeedsSetup = true;
            return;
        }
        if (shownPage is null || pageNeedsSetup || shownPage is SetupPage)
        {
            pageNeedsSetup = false;
            shownPage = page switch { Page.Fixer => new FixerPage(), _ => new CollectionPage() };
            PageHost.Content = shownPage;
            UI.FadeIn(shownPage);
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
        head.Margin = new Thickness(8, 38, 8, 22); head.Cursor = Cursors.Hand; head.Background = Brushes.Transparent;
        var rt = new TransformGroup { Children = { new RotateTransform(), new ScaleTransform(1, 1) } }; logo.RenderTransform = rt;
        head.MouseEnter += (_, _) => Wiggle(rt, true); head.MouseLeave += (_, _) => Wiggle(rt, false);
        head.MouseLeftButtonUp += (_, _) => window.Show(Page.Collection);
        top.Children.Add(head);

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

    static readonly (Page Page, string Title, string Icon)[] Pages = [(Page.Collection, "Collection", ""), (Page.Fixer, "Tag fixer", "")];

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
