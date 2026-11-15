using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;

namespace JuiceTracker.App;

/// The sidebar player: on/off, play/pause, next, volume, a seek bar and the era to play from.
public sealed class PlayerPanel : DoodleBorder
{
    readonly TextBlock title = UI.Text("Off", 12, JT.Muted);
    readonly ToggleButton onOff = new() { Width = 34, Height = 18, Cursor = System.Windows.Input.Cursors.Hand };
    readonly Button playPause, next;
    readonly Slider volume = new() { Minimum = 0, Maximum = 100, Width = 90, VerticalAlignment = VerticalAlignment.Center };
    readonly Slider seek = new() { Minimum = 0, Maximum = 1, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock time = UI.Text("0:00", 10.5, JT.Muted), length = UI.Text("0:00", 10.5, JT.Muted);
    readonly ComboBox era = new() { FontSize = 12, Margin = new Thickness(0, 6, 0, 0) };
    readonly StackPanel controls = new();
    readonly CheckBox inOrder = new() { Content = "Play an era in recording order", FontSize = 11.5, Margin = new Thickness(0, 6, 0, 0) };
    readonly DockPanel upNext = new() { Margin = new Thickness(0, 6, 0, 0) };
    readonly TextBlock upNextText = UI.Text("", 11, JT.Muted);
    readonly Button sleep;
    bool updating, dragging;

    public PlayerPanel()
    {
        Seed = 3; Padding = new Thickness(10);
        onOff.Template = SwitchTemplate();
        onOff.Click += (_, _) => Player.Shared.SetOn(onOff.IsChecked == true);
        UI.AutomationName(onOff, "Ambient music on or off");
        playPause = UI.IconButton("", "Pause", Player.Shared.TogglePause, 13);
        next = UI.IconButton("", "Next song", Player.Shared.Skip, 13);
        volume.ValueChanged += (_, e) => { if (!updating) Player.Shared.Volume = e.NewValue; };
        UI.AutomationName(volume, "Volume");
        seek.AddHandler(Thumb.DragStartedEvent, new DragStartedEventHandler((_, _) => dragging = true));
        seek.AddHandler(Thumb.DragCompletedEvent, new DragCompletedEventHandler((_, _) => { dragging = false; Player.Shared.Seek(TimeSpan.FromSeconds(seek.Value)); }));
        seek.PreviewMouseLeftButtonUp += (_, _) => { if (!dragging) Player.Shared.Seek(TimeSpan.FromSeconds(seek.Value)); };
        UI.AutomationName(seek, "Position in the song");
        inOrder.Click += (_, _) => Player.Shared.SetInOrder(inOrder.IsChecked == true);
        sleep = UI.IconButton("\uE708", "Sleep timer", () => { var m = Listen.SleepMenu(); m.PlacementTarget = sleep; m.IsOpen = true; }, 13);
        var clear = UI.IconButton("\uE711", "Clear up next", Player.Shared.ClearUpNext, 11); DockPanel.SetDock(clear, Dock.Right);
        upNext.Children.Add(clear); upNext.Children.Add(upNextText);
        era.SelectionChanged += (_, _) => { if (!updating && era.SelectedItem is string e) Player.Shared.SetEra(e == "All eras" ? "" : e); };
        UI.AutomationName(era, "Which era the background music plays from");

        var head = new DockPanel();
        DockPanel.SetDock(onOff, Dock.Right); head.Children.Add(onOff);
        head.Children.Add(UI.Row(8, UI.Icon("", 13, JT.Lavender), UI.Column(1, UI.Text("Ambient music", 12, weight: FontWeights.Bold), title)));
        var buttons = UI.Row(8, playPause, next, volume, UI.IconButton("\uE8BD", "Lyrics", LyricsWindow.Open, 13), UI.IconButton("\uE8A7", "Mini player", MiniPlayer.Open, 13), sleep);
        var seekRow = new DockPanel { Margin = new Thickness(0, 6, 0, 0) };
        DockPanel.SetDock(time, Dock.Left); DockPanel.SetDock(length, Dock.Right);
        time.Margin = new Thickness(0, 0, 6, 0); length.Margin = new Thickness(6, 0, 0, 0);
        seekRow.Children.Add(time); seekRow.Children.Add(length); seekRow.Children.Add(seek);
        controls.Children.Add(buttons); controls.Children.Add(seekRow); controls.Children.Add(era); controls.Children.Add(inOrder); controls.Children.Add(upNext);
        controls.Margin = new Thickness(0, 8, 0, 0);
        Child = UI.Column(0, head, controls);
    }

    public void Update()
    {
        var p = Player.Shared; var store = Store.Shared;
        updating = true;
        var eras = p.Eras;
        Visibility = eras.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        onOff.IsChecked = store.Me.AmbientOn;
        title.Text = store.Me.AmbientOn ? p.Title ?? "Starting…" : "Off";
        controls.Visibility = store.Me.AmbientOn ? Visibility.Visible : Visibility.Collapsed;
        ((TextBlock)playPause.Content).Text = p.IsPlaying ? "" : "";
        System.Windows.Automation.AutomationProperties.SetName(playPause, p.IsPlaying ? "Pause" : "Play");
        volume.Value = p.Volume;
        var dur = p.Duration.TotalSeconds;
        seek.Maximum = Math.Max(dur, 1);
        if (!dragging) seek.Value = Math.Min(p.Position.TotalSeconds, seek.Maximum);
        time.Text = Engine.FmtTime(p.Position.TotalSeconds); length.Text = Engine.FmtTime(dur);
        var items = new List<string> { "All eras" }; items.AddRange(eras);
        if (!era.Items.Cast<string>().SequenceEqual(items)) { era.Items.Clear(); foreach (var e in items) era.Items.Add(e); }
        era.SelectedItem = eras.Contains(store.Me.AmbientEra) ? store.Me.AmbientEra : "All eras";
        inOrder.IsChecked = store.Me.InOrder;
        upNext.Visibility = p.UpNext.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        upNextText.Text = "Up next: " + string.Join(", ", p.UpNext.Take(2).Select(x => x.Title)) + (p.UpNext.Count > 2 ? $" +{p.UpNext.Count - 2}" : "");
        ((TextBlock)sleep.Content).Foreground = JT.Brush(p.SleepAt is not null || p.SleepAtEnd ? JT.Lavender : JT.Mist);
        sleep.ToolTip = p.SleepAt is { } at ? $"Sleep timer: stops at {at:t}" : p.SleepAtEnd ? "Sleep timer: stops after this song" : "Sleep timer";
        Sky.Current?.SetGlow(p.IsPlaying ? 0.35 + 0.15 * Math.Sin(DateTime.Now.TimeOfDay.TotalSeconds * 2) : 0);
        updating = false;
    }

    /// A small on/off switch like the Mac's.
    public static ControlTemplate SwitchTemplate()
    {
        var t = new ControlTemplate(typeof(ToggleButton));
        var track = new FrameworkElementFactory(typeof(Border), "Track");
        track.SetValue(Border.CornerRadiusProperty, new CornerRadius(9));
        track.SetValue(Border.BackgroundProperty, JT.Brush(Color.FromArgb(70, 255, 255, 255)));
        var knob = new FrameworkElementFactory(typeof(Border), "Knob");
        knob.SetValue(Border.WidthProperty, 14.0); knob.SetValue(Border.HeightProperty, 14.0);
        knob.SetValue(Border.CornerRadiusProperty, new CornerRadius(7));
        knob.SetValue(Border.BackgroundProperty, Brushes.White);
        knob.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Left);
        knob.SetValue(FrameworkElement.MarginProperty, new Thickness(2, 0, 2, 0));
        track.AppendChild(knob);
        t.VisualTree = track;
        var on = new Trigger { Property = ToggleButton.IsCheckedProperty, Value = true };
        on.Setters.Add(new Setter(Border.BackgroundProperty, JT.Brush(JT.Lavender), "Track"));
        on.Setters.Add(new Setter(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Right, "Knob"));
        t.Triggers.Add(on);
        return t;
    }
}

/// The two steps before anything else: load the catalog, choose your music folder.
public sealed class SetupPage : ScrollViewer
{
    readonly StackPanel body = new() { Margin = new Thickness(40, 40, 40, 60), MaxWidth = 1080, HorizontalAlignment = HorizontalAlignment.Left };
    public SetupPage() { Content = body; VerticalScrollBarVisibility = ScrollBarVisibility.Auto; Update(); }

    public void Update()
    {
        var store = Store.Shared;
        body.Children.Clear();
        body.Children.Add(UI.Title("Welcome"));
        var intro = UI.Muted("Two steps and your collection shows up here: load the song catalog from juicewrldapi.com, and choose your music folder. Your files stay on this computer.", 15);
        intro.Margin = new Thickness(0, 14, 0, 18); intro.MaxWidth = 640; intro.HorizontalAlignment = HorizontalAlignment.Left;
        body.Children.Add(intro);
        var grid = new UniformGrid { Columns = 2 };
        grid.Children.Add(Step(0, store.Catalog.Count > 0, "Load the song catalog",
            store.Catalog.Count > 0 ? (store.CatalogStatus.Length > 0 ? store.CatalogStatus : $"{store.Catalog.Count:N0} songs loaded.") : store.CatalogStatus,
            store.LoadingCatalog ? "Loading…" : store.Catalog.Count > 0 ? "Load again" : "Load catalog", () => _ = store.ReloadCatalogAsync(), !store.LoadingCatalog));
        grid.Children.Add(Step(1, store.Root is not null && store.FolderStatus.Length > 0, "Choose your music folder", store.FolderStatus,
            store.Root is null ? "Choose folder…" : "Choose another folder", Choose, !store.Scanning,
            store.Root is not null ? (store.Scanning ? "Scanning…" : "Rescan folder", () => _ = store.ScanAsync(reread: true)) : null));
        body.Children.Add(grid);
        var hint = UI.Muted("Loading the catalog takes about a minute the first time. After that it's saved and loads instantly.", 12.5);
        hint.Margin = new Thickness(0, 14, 0, 0);
        body.Children.Add(hint);
    }

    static void Choose()
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = "Choose your music folder" };
        if (dialog.ShowDialog() == true) _ = Store.Shared.UseFolderAsync(dialog.FolderName);
    }

    static FrameworkElement Step(int seed, bool done, string title, string status, string button, Action run, bool enabled, (string Label, Action Run)? extra = null)
    {
        var col = new StackPanel();
        col.Children.Add(UI.Row(8, UI.Icon(done ? "" : "", 14, done ? JT.Have : JT.Lavender), UI.Text(title, 15.5, weight: FontWeights.SemiBold)));
        if (status.Length > 0) { var s = UI.Muted(status, 13); s.Margin = new Thickness(0, 6, 0, 0); col.Children.Add(s); }
        var b = UI.Button(button, run, big: true); b.IsEnabled = enabled;
        var row = UI.Row(10, b);
        if (extra is { } x) { var e = UI.Button(x.Label, x.Run, big: true); e.IsEnabled = enabled; row.Children.Add(e); e.Margin = new Thickness(10, 0, 0, 0); }
        row.Margin = new Thickness(0, 14, 0, 0);
        col.Children.Add(row);
        var p = UI.Panel(col, seed, 18);
        p.Margin = new Thickness(0, 0, 14, 0); p.MinHeight = 150;
        return p;
    }
}
