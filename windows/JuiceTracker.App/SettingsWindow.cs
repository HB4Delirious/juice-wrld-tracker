using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace JuiceTracker.App;

/// Settings (Ctrl+,): the music folder, which files count, the catalog, and where your data lives.
public sealed class SettingsWindow : Window
{
    static SettingsWindow? open;
    public static void Open()
    {
        if (open is not null) { open.Activate(); return; }
        open = new SettingsWindow { Owner = MainWindow.Current };
        open.Closed += (_, _) => open = null;
        open.Show();
    }

    readonly StackPanel body = new() { Margin = new Thickness(24) };

    SettingsWindow()
    {
        Title = "Juice Tracker Settings"; Width = 600; Height = 560; ResizeMode = ResizeMode.CanResize;
        Background = JT.Brush(Color.FromRgb(20, 10, 44)); WindowStartupLocation = WindowStartupLocation.CenterOwner;
        System.Windows.Documents.TextElement.SetFontFamily(this, JT.Body);
        Content = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Store.Shared.Changed += Build;
        Closed += (_, _) => Store.Shared.Changed -= Build;
        Build();
    }

    void Build()
    {
        var store = Store.Shared;
        body.Children.Clear();
        Section("Music folder");
        body.Children.Add(UI.Text(store.Root ?? "Not chosen yet", 14, store.Root is null ? JT.Muted : JT.Mist, wrap: true));
        var folderButtons = UI.Row(10,
            UI.Button("Choose another folder…", () =>
            {
                var d = new Microsoft.Win32.OpenFolderDialog { Title = "Choose your music folder" };
                if (d.ShowDialog(this) == true) _ = store.UseFolderAsync(d.FolderName);
            }),
            UI.Button(store.Scanning ? "Scanning…" : "Rescan folder", () => _ = store.ScanAsync(reread: true)));
        ((Button)folderButtons.Children[1]).IsEnabled = store.Root is not null && !store.Scanning;
        folderButtons.Margin = new Thickness(0, 10, 0, 6); body.Children.Add(folderButtons);
        if (store.FolderStatus.Length > 0) body.Children.Add(UI.Muted(store.FolderStatus, 12));
        var only = new CheckBox { Content = "Only count Juice WRLD files (by folder name or artist tag)", IsChecked = store.Me.OnlyJuice, Margin = new Thickness(0, 10, 0, 0) };
        only.Click += (_, _) => { store.Me.OnlyJuice = only.IsChecked == true; store.SavePersonal(); _ = store.ScanAsync(reread: false); };
        body.Children.Add(only);

        Section("Song catalog");
        body.Children.Add(UI.Text(store.FetchedAt is { } f ? $"{store.Catalog.Count:N0} songs, loaded {f.ToLocalTime():MMM d, h:mm tt}. It refreshes itself when it's over 12 hours old." : "Not loaded yet.", 14, wrap: true));
        var reload = UI.Button(store.LoadingCatalog ? "Loading…" : "Load the catalog again", () => _ = store.ReloadCatalogAsync());
        reload.IsEnabled = !store.LoadingCatalog; reload.HorizontalAlignment = HorizontalAlignment.Left; reload.Margin = new Thickness(0, 10, 0, 0);
        body.Children.Add(reload);
        if (store.LoadingCatalog && store.CatalogStatus.Length > 0) body.Children.Add(UI.Muted(store.CatalogStatus, 12));

        Section("Playback");
        var fade = new Slider { Minimum = 0, Maximum = 12, Value = store.Me.Crossfade, Width = 220, IsSnapToTickEnabled = true, TickFrequency = 1 };
        var fadeLabel = UI.Text(Crossfade(store.Me.Crossfade), 14);
        fade.ValueChanged += (_, e) => { store.Me.Crossfade = e.NewValue; fadeLabel.Text = Crossfade(e.NewValue); };
        fade.LostMouseCapture += (_, _) => store.SavePersonal();
        UI.AutomationName(fade, "Crossfade seconds");
        body.Children.Add(UI.Row(12, UI.Text("Crossfade", 14, JT.Muted), fade, fadeLabel));
        Check("Match volume between songs (measures each song's loudness the first time it plays)", store.Me.MatchVolume, v => store.Me.MatchVolume = v);

        Section("New songs");
        Check("Check the catalog for new songs every day, and say when a wished song can be downloaded", store.Me.DailyCheck, v => store.Me.DailyCheck = v);
        Check("Keep running in the notification area when the window is closed", store.Me.KeepRunning, v => store.Me.KeepRunning = v);

        Section("Look");
        var theme = new ComboBox { Width = 340, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var t in Themes.All) theme.Items.Add(new ComboBoxItem { Content = t.Name, Tag = t.Id });
        theme.Items.Add(new ComboBoxItem { Content = "Your own colors", Tag = "custom" });
        theme.SelectedItem = theme.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == store.Me.Theme) ?? theme.Items[0];
        theme.SelectionChanged += (_, _) => { store.Me.Theme = (string)((ComboBoxItem)theme.SelectedItem).Tag; Restyle(); };
        UI.AutomationName(theme, "Theme");
        body.Children.Add(UI.Row(12, UI.Text("Theme", 14, JT.Muted), theme));
        if (store.Me.Theme == "custom")
        {
            var row = UI.Row(10);
            foreach (var (label, get, set) in new (string, Func<string>, Action<string>)[]
            {
                ("Accent", () => store.Me.CustomAccent, v => store.Me.CustomAccent = v), ("Sky 1", () => store.Me.CustomSky1, v => store.Me.CustomSky1 = v), ("Sky 2", () => store.Me.CustomSky2, v => store.Me.CustomSky2 = v),
            })
            {
                var swatch = new Border { Width = 22, Height = 22, CornerRadius = new CornerRadius(11), BorderBrush = JT.Brush(JT.Line2), BorderThickness = new Thickness(1), Background = JT.Brush(Themes.Hex(get()) ?? Colors.Gray) };
                var pick = UI.Button(label, () =>
                {
                    var d = new System.Windows.Forms.ColorDialog { FullOpen = true, Color = Themes.Hex(get()) is { } c ? System.Drawing.Color.FromArgb(c.R, c.G, c.B) : System.Drawing.Color.HotPink };
                    if (d.ShowDialog() == System.Windows.Forms.DialogResult.OK) { set($"{d.Color.R:x2}{d.Color.G:x2}{d.Color.B:x2}"); Restyle(); }
                });
                row.Children.Add(UI.Row(6, swatch, pick));
            }
            row.Margin = new Thickness(0, 8, 0, 0); body.Children.Add(row);
        }
        Check("Compact (smaller text and spacing, for small screens)", store.Me.Compact, v => { store.Me.Compact = v; MainWindow.Current?.Restyle(); });
        Check("Play a chime when songs land in your library", store.Me.Chime, v => { store.Me.Chime = v; if (v) Chime.Play(); });
        Check("Fade the music when pausing and resuming", store.Me.FadePause, v => store.Me.FadePause = v);
        Check("Ask before quitting while a song plays", store.Me.AskQuitPlaying, v => store.Me.AskQuitPlaying = v);
        Check("Show download progress on the taskbar button", store.Me.TaskbarProgress, v => store.Me.TaskbarProgress = v);
        body.Children.Add(UI.Muted("Desktop widgets (drag to move, right-click to close)", 12).Also(t => t.Margin = new Thickness(0, 10, 0, 0)));
        foreach (var (key, name) in DesktopWidgets.Kinds) Check(name, store.Me.Widgets.Contains(key), v => DesktopWidgets.Set(key, v));
        var edgeSwatch = new Border { Width = 22, Height = 22, CornerRadius = new CornerRadius(11), BorderBrush = JT.Brush(JT.Line2), BorderThickness = new Thickness(1),
                                      Background = JT.Brush(Themes.Hex(store.Me.EdgeColor) ?? JT.Lavender), VerticalAlignment = VerticalAlignment.Center };
        var edgePick = UI.Button("Edge light color…", () =>
        {
            var c0 = Themes.Hex(store.Me.EdgeColor) ?? JT.Lavender;
            var d = new System.Windows.Forms.ColorDialog { FullOpen = true, Color = System.Drawing.Color.FromArgb(c0.R, c0.G, c0.B) };
            if (d.ShowDialog() != System.Windows.Forms.DialogResult.OK) return;
            store.Me.EdgeColor = $"{d.Color.R:x2}{d.Color.G:x2}{d.Color.B:x2}"; store.SavePersonal(); edgeSwatch.Background = JT.Brush(Color.FromRgb(d.Color.R, d.Color.G, d.Color.B));
        });
        var edgeCover = UI.Link("Use the cover's colors", () => { store.Me.EdgeColor = ""; store.SavePersonal(); edgeSwatch.Background = JT.Brush(JT.Lavender); }, 13);
        body.Children.Add(UI.Row(10, edgePick, edgeSwatch, edgeCover).Also(r => r.Margin = new Thickness(0, 8, 0, 0)));
        var style = new ComboBox { Width = 260, ItemsSource = new[] { "The line being sung, word by word", "The scrolling list" }, SelectedIndex = store.Me.LyricStyle == "list" ? 1 : 0 };
        style.SelectionChanged += (_, _) => { store.Me.LyricStyle = style.SelectedIndex == 1 ? "list" : "line"; store.SavePersonal(); };
        UI.AutomationName(style, "Player lyrics");
        body.Children.Add(UI.Row(12, UI.Text("Player lyrics", 14, JT.Muted), style).Also(r => r.Margin = new Thickness(0, 10, 0, 0)));
        Check("Blur the lines not being sung (scrolling list)", store.Me.LyricBlur, v => store.Me.LyricBlur = v);
        Check("Edge light on every screen", store.Me.EdgeAll, v => { store.Me.EdgeAll = v; Dispatcher.BeginInvoke(DesktopWidgets.ReopenEdge); });
        Check("A different Player look for every song", store.Me.PlayerStyleAuto, v => store.Me.PlayerStyleAuto = v);
        Check("Lift quiet songs so the visuals still move", store.Me.VisualBoost, v => store.Me.VisualBoost = v);
        Check("Play a song's music video on the Player tab (a video with its name in its folder)", store.Me.MusicVideos, v => store.Me.MusicVideos = v);

        Section("Equalizer");
        {
            var me = store.Me; bool setting = false;
            var on = new CheckBox { Content = "Equalizer", IsChecked = me.EqOn, Margin = new Thickness(0, 6, 0, 0) };
            var preset = new ComboBox { Width = 150, ItemsSource = Engine.EqPresets.Select(p => p.Name).Append("Custom").ToList() };
            var sliders = new List<(Slider S, TextBlock V)>();
            void Show()
            {
                setting = true;
                var b = Equalizer.Bands;
                for (int k = 0; k < 3; k++) { sliders[k].S.Value = b[k]; sliders[k].V.Text = $"{b[k]:+0;-0;0} dB"; sliders[k].S.IsEnabled = me.EqOn; }
                preset.SelectedItem = Engine.EqPreset(b); preset.IsEnabled = me.EqOn;
                setting = false;
            }
            foreach (var name in new[] { "Bass", "Mids", "Treble" })
            {
                var s = new Slider { Minimum = -12, Maximum = 12, TickFrequency = 1, IsSnapToTickEnabled = true, Width = 260, VerticalAlignment = VerticalAlignment.Center };
                var v = UI.Text("", 12, JT.Muted).Also(t => { t.Width = 50; t.VerticalAlignment = VerticalAlignment.Center; });
                UI.AutomationName(s, name);
                s.ValueChanged += (_, _) => { if (!setting) { Equalizer.Set(me.EqOn, [.. sliders.Select(x => x.S.Value)]); Show(); } };
                sliders.Add((s, v));
                body.Children.Add(UI.Row(10, UI.Text(name, 14).Also(t => { t.Width = 60; t.VerticalAlignment = VerticalAlignment.Center; }), s, v).Also(r => r.Margin = new Thickness(0, 6, 0, 0)));
            }
            on.Click += (_, _) => { Equalizer.Set(on.IsChecked == true, Equalizer.Bands); Show(); };
            preset.SelectionChanged += (_, _) => { if (!setting && preset.SelectedItem is string n && Engine.EqPresets.FirstOrDefault(p => p.Name == n).Bands is { } b) { Equalizer.Set(me.EqOn, b); Show(); } };
            UI.AutomationName(preset, "Equalizer preset");
            body.Children.Insert(body.Children.Count - 3, UI.Row(14, on, preset));
            body.Children.Add(UI.Muted("Shapes the music's sound. Your files don't change.", 12));
            Show();
        }

        Section("Keyboard shortcuts");
        foreach (var (id, name) in Shortcuts.Actions)
        {
            var keyButton = UI.Button(Shortcuts.Label(Shortcuts.Get(id)), () => { });
            keyButton.MinWidth = 150;
            keyButton.Click += (_, _) => { Shortcuts.Recording = true; keyButton.Content = "Press the keys…"; keyButton.Tag = id; };
            keyButton.PreviewKeyDown += (_, e) =>
            {
                if (!Shortcuts.Recording || !id.Equals(keyButton.Tag)) return;
                e.Handled = true;
                var key = e.Key == Key.System ? e.SystemKey : e.Key;
                if (key == Key.Escape) { }
                else if (key is Key.Back or Key.Delete) Shortcuts.Set(id, null);
                else if (Shortcuts.From(e) is { } k) Shortcuts.Set(id, k);
                else return; // a modifier on its own, or a plain key: keep listening
                Shortcuts.Recording = false; keyButton.Tag = null; keyButton.Content = Shortcuts.Label(Shortcuts.Get(id));
            };
            keyButton.LostKeyboardFocus += (_, _) => { if (id.Equals(keyButton.Tag)) { Shortcuts.Recording = false; keyButton.Tag = null; keyButton.Content = Shortcuts.Label(Shortcuts.Get(id)); } };
            body.Children.Add(UI.Row(12, UI.Text(name, 14).Also(t => { t.Width = 170; t.VerticalAlignment = VerticalAlignment.Center; }), keyButton).Also(r => r.Margin = new Thickness(0, 6, 0, 0)));
        }
        Check("Also when Juice Tracker is in the background (global)", store.Me.ShortcutsGlobal, v => { store.Me.ShortcutsGlobal = v; Dispatcher.BeginInvoke(Shortcuts.Apply); });
        body.Children.Add(UI.Muted("Click a shortcut, then press the keys: they need Ctrl, Alt or Win, or a function key. Esc cancels, Backspace clears.", 12));

        Section("Updates");
        Check("Check for a new version every day", store.Me.AutoUpdate, v => store.Me.AutoUpdate = v);
        var check = UI.Button("Check for updates now", () => _ = Updater.Check(true)); check.HorizontalAlignment = HorizontalAlignment.Left; check.Margin = new Thickness(0, 8, 0, 0);
        body.Children.Add(check);

        Section("Discord");
        Check("Show the song you're listening to in your Discord status", store.Me.DiscordOn, v => store.Me.DiscordOn = v);
        body.Children.Add(UI.Muted("Needs the Discord app open on this PC and an application ID from discord.com/developers (create an application named Juice Tracker, copy its ID).", 12));
        body.Children.Add(Field("Application ID", store.Me.DiscordAppId, v => { store.Me.DiscordAppId = v; store.SavePersonal(); }));

        Section("Plex");
        body.Children.Add(UI.Muted("If Plex plays this music folder: it rescans after downloads, Stats can use its play counts, and playlists can be sent to it. The token is stored encrypted for your Windows account.", 12, wrap: true));
        body.Children.Add(Field("Server address", store.Me.PlexServer ?? "", v => { store.Me.PlexServer = v.Trim().Length > 0 ? v.Trim() : null; store.SavePersonal(); }, "http://192.168.1.10:32400"));
        var token = new PasswordBox { Width = 300 }; UI.AutomationName(token, "Plex token");
        var tokenStatus = UI.Muted(Plex.Configured ? "Connected details saved." : "", 12);
        var saveToken = UI.Button("Save token", () => { try { Plex.SaveToken(token.Password); token.Clear(); tokenStatus.Text = "Saved."; } catch (Exception e) { tokenStatus.Text = e.Message; } });
        var test = UI.Button("Test", async () =>
        {
            tokenStatus.Text = "Connecting…";
            try { var s = await Plex.MusicSections(); tokenStatus.Text = s.Count == 0 ? "Connected, but Plex has no music library." : $"Connected: {string.Join(", ", s.Select(x => x.Title))}."; }
            catch (Exception e) { tokenStatus.Text = e.Message; }
        });
        var tokenRow = UI.Row(10, UI.Text("Token", 14, JT.Muted), token, saveToken, test); tokenRow.Margin = new Thickness(0, 8, 0, 0);
        body.Children.Add(tokenRow); body.Children.Add(tokenStatus);

        Section("Live");
        body.Children.Add(UI.Muted("Stream straight from Juice Tracker to TikTok LIVE: in TikTok LIVE Studio or LIVE Center, set up a LIVE and copy its Server URL and Stream Key here (TikTok gives new ones for each LIVE). The stream is the Player's stream window and this PC's sound. The first time, the app fetches its streaming engine (FFmpeg, about 115 MB). The key is stored encrypted for your Windows account.", 12, wrap: true));
        body.Children.Add(Field("Server URL", store.Me.LiveServer ?? "", v => { store.Me.LiveServer = v.Trim().Length > 0 ? v.Trim() : null; store.SavePersonal(); }, "rtmp://push-rtmp-….tiktokcdn.com/game/"));
        var liveKey = new PasswordBox { Width = 300 }; UI.AutomationName(liveKey, "Stream Key");
        var liveStatus = UI.Muted(LiveStream.HasKey ? "A Stream Key is saved." : "", 12);
        var saveKey = UI.Button("Save key", () => { try { LiveStream.SaveKey(liveKey.Password); liveKey.Clear(); liveStatus.Text = LiveStream.HasKey ? "Saved. Go live from the Player tab's stream button." : "Removed."; } catch (Exception e) { liveStatus.Text = e.Message; } });
        var keyRow = UI.Row(10, UI.Text("Stream Key", 14, JT.Muted), liveKey, saveKey); keyRow.Margin = new Thickness(0, 8, 0, 0);
        body.Children.Add(keyRow); body.Children.Add(liveStatus);

        Section("Your data");
        body.Children.Add(UI.Muted("Your wishlist, notes, ratings, matches and settings are saved on this computer, in:", 13));
        var path = UI.Link(Store.DataDir, () => Process.Start(new ProcessStartInfo("explorer.exe", Store.DataDir) { UseShellExecute = true }), 13);
        path.HorizontalAlignment = HorizontalAlignment.Left; path.Margin = new Thickness(0, 4, 0, 0);
        body.Children.Add(path);

        Section("About");
        body.Children.Add(UI.Muted($"Juice Tracker for Windows {typeof(SettingsWindow).Assembly.GetName().Version?.ToString(3)}. Song information comes from juicewrldapi.com; your files never leave this computer.", 13));
    }

    static string Crossfade(double s) => s == 0 ? "Off" : $"{s:0} seconds";
    void Restyle() { Store.Shared.SavePersonal(); Themes.Apply(); MainWindow.Current?.Restyle(); Background = JT.Brush(Color.FromRgb(20, 10, 44)); }

    void Check(string label, bool value, Action<bool> set)
    {
        var c = new CheckBox { Content = new TextBlock { Text = label, TextWrapping = TextWrapping.Wrap }, IsChecked = value, Margin = new Thickness(0, 6, 0, 0) };
        c.Click += (_, _) => { set(c.IsChecked == true); Store.Shared.SavePersonal(); };
        body.Children.Add(c);
    }

    static FrameworkElement Field(string label, string value, Action<string> save, string hint = "")
    {
        var box = new TextBox { Text = value, Width = 300, ToolTip = hint.Length > 0 ? hint : null };
        box.LostFocus += (_, _) => { if (box.Text != value) { value = box.Text; save(box.Text); } };
        UI.AutomationName(box, label);
        var row = UI.Row(10, UI.Text(label, 14, JT.Muted), box); row.Margin = new Thickness(0, 8, 0, 0);
        return row;
    }

    void Section(string title)
    {
        var t = UI.Text(title, 16, weight: FontWeights.SemiBold);
        t.Margin = new Thickness(0, body.Children.Count == 0 ? 0 : 22, 0, 8);
        body.Children.Add(t);
    }
}
