using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;

namespace JuiceTracker.App;

public partial class App : Application
{
    /// Where the details of an error go (the message box shows the short version).
    static string CrashLog => Path.Combine(Store.DataDir, "error.log");

    protected override void OnStartup(StartupEventArgs e)
    {
        // animations at 30 frames a second, not 60: the slow sky and disc look the same and cost half as much
        System.Windows.Media.Animation.Timeline.DesiredFrameRateProperty.OverrideMetadata(typeof(System.Windows.Media.Animation.Timeline),
            new FrameworkPropertyMetadata { DefaultValue = 30 });
        base.OnStartup(e);
        if (e.Args.Contains("--smoke-test")) { SmokeTest(); return; }
        // CI: --rtmp-selftest <server> <key> streams six seconds and quits
        if (Array.IndexOf(e.Args, "--rtmp-selftest") is var k and >= 0 && e.Args.Length > k + 2)
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            Dispatcher.BeginInvoke(async () => Shutdown(await LiveStream.SelfTest(e.Args[k + 1], e.Args[k + 2])));
            return;
        }
        // A bug in one screen shouldn't close the app (and lose a download in progress): say what happened instead.
        DispatcherUnhandledException += (_, args) =>
        {
            Log(args.Exception);
            MessageBox.Show($"Something went wrong: {Innermost(args.Exception).Message}\n\nThe details are in {CrashLog}.", "Juice Tracker", MessageBoxButton.OK, MessageBoxImage.Warning);
            args.Handled = true;
        };
        try
        {
            var window = new MainWindow();
            MainWindow = window;
            window.Show();
        }
        catch (Exception ex) // without its window the app can't do anything: explain, then quit
        {
            Log(ex);
            MessageBox.Show($"Juice Tracker couldn't open its window: {Innermost(ex).Message}\n\nThe details are in {CrashLog}.", "Juice Tracker", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
            return;
        }
        _ = Store.Shared.StartAsync();
        StartExtras();
    }

    /// The notification-area icon, new-song alerts, the daily catalog check, updates and Discord.
    static void StartExtras()
    {
        Tray.Start();
        Current.Exit += (_, _) => Tray.Stop();
        Store.Shared.CatalogChecked += async () =>
        {
            var store = Store.Shared; var wished = store.WishedReleasedNames; var fresh = store.NewSongNames;
            if (wished.Count > 0) Tray.Notify("From your wishlist", $"{string.Join(", ", wished.Take(3))}{(wished.Count > 3 ? $" and {wished.Count - 3} more" : "")} can be downloaded now.");
            else if (fresh.Count > 0) Tray.Notify(fresh.Count == 1 ? "A new song" : $"{fresh.Count:N0} new songs", string.Join(", ", fresh.Take(4)));
            if (wished.Count > 0) Inbox.Add("From your wishlist", $"{string.Join(", ", wished.Take(6))} can be downloaded now.");
            if (fresh.Count > 0) Inbox.Add(fresh.Count == 1 ? "A new song in the catalog" : $"{fresh.Count:N0} new songs in the catalog", string.Join(", ", fresh.Take(6)) + (fresh.Count > 6 ? $" and {fresh.Count - 6} more" : ""), store.NewSongIds);
            if (store.Me.AutoDownload && store.NewSongIds.Count > 0)
            {
                // after the await this runs on its own, outside the catalog load's error handling: a failure here is noted, not a crash
                try { var root = store.Root; store.AutoDownload(store.NewSongIds, await Task.Run(() => Disk.Free(root))); }
                catch (Exception e)
                {
                    Log(e);
                    try { Inbox.Add("New songs couldn't be queued to download", e.Message); } catch (IOException) { } // the notice needs the same settings file
                }
            }
        };
        // hourly: if the daily check is on and the catalog is over 12 hours old, load it again (and alert)
        var hourly = new DispatcherTimer { Interval = TimeSpan.FromHours(1) };
        hourly.Tick += (_, _) => { var s = Store.Shared; if (s.Me.DailyCheck && s.FetchedAt is { } f && (DateTime.UtcNow - f).TotalHours > 12) _ = s.ReloadCatalogAsync(); };
        hourly.Start();
        Updater.StartDailyChecks();
        MediaKeys.Apply();
        Discord.Start();
        Task.Delay(TimeSpan.FromSeconds(20)).ContinueWith(_ => Current.Dispatcher.Invoke(() => _ = Plex.LoadCounts()));
    }

    static Exception Innermost(Exception e) { while (e.InnerException is not null) e = e.InnerException; return e; }
    static void Log(Exception e)
    {
        try { Directory.CreateDirectory(Store.DataDir); File.AppendAllText(CrashLog, $"{DateTime.Now:u}\n{e}\n\n"); } catch (IOException) { }
    }

    /// Settings: ask before quitting while a song plays. True to go ahead.
    public static bool ConfirmQuit() =>
        !Store.Shared.Me.AskQuitPlaying || !Player.Shared.IsPlaying ||
        MessageBox.Show("A song is playing. Quit Juice Tracker and stop the music?", "Juice Tracker", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes;

    /// CI runs the built exe with --smoke-test: it opens the window and every screen, then quits with 0, or with 1 and
    /// the error in %TEMP%\juicetracker-smoke.txt. A layout or resource that fails to load fails the build.
    void SmokeTest()
    {
        var report = Path.Combine(Path.GetTempPath(), "juicetracker-smoke.txt");
        void Fail(Exception ex) { File.WriteAllText(report, ex.ToString()); Shutdown(1); }
        DispatcherUnhandledException += (_, args) => { args.Handled = true; Fail(args.Exception); };
        try
        {
            var window = new MainWindow();
            MainWindow = window;
            window.ContentRendered += (_, _) =>
            {
                try
                {
                    Store.Shared.FillForSmokeTest(); // the window now shows Collection with songs, eras and notices
                    var song = Store.Shared.Songs.First(s => s.Owned);
                    UIElement[] screens = [new CollectionPage(), new FixerPage(), new SetupPage(), new SongCard(song), new SongRow(song), new PlayerPanel(), new PlayerPage(stream: true) { Width = 540, Height = 960 }, new PlayerPage(stream: true) { Width = 960, Height = 540 }];
                    foreach (var s in screens) { s.Measure(new Size(1000, 800)); s.Arrange(new Rect(0, 0, 1000, 800)); }
                    // screens redraw in place whenever something changes: do that twice, like a download finishing
                    foreach (var s in screens.OfType<IRefresh>()) { s.Refresh(); s.Refresh(); }
                    Store.Shared.Notify(); Store.Shared.Notify();
                    // every page in the sidebar, each drawn and then redrawn twice
                    foreach (var p in JuiceTracker.App.MainWindow.AvailablePages)
                    {
                        window.Show(p);
                        window.CurrentPage?.Measure(new Size(1000, 800)); window.CurrentPage?.Arrange(new Rect(0, 0, 1000, 800));
                        (window.CurrentPage as IRefresh)?.Refresh(); (window.CurrentPage as IRefresh)?.Refresh();
                    }
                    window.Show(Page.Collection);
                    window.ShowOverlay(new SongCard(song));
                    window.ShowOverlay(new SongCard(Store.Shared.Songs.First(s => !s.Owned && s.HasFile)));
                    SettingsWindow.Open();
                    // every Player look draws and moves, and the looks gallery opens
                    foreach (var (id, _) in PlayerLooks.All)
                    {
                        var look = new PlayerLook(); look.Build(id, 120, [Colors.Red, Colors.Blue, Colors.Purple], null);
                        look.Measure(new Size(400, 400)); look.Arrange(new Rect(0, 0, 400, 400)); look.Pulse(0.8); look.Pulse(0);
                    }
                    PlayerLooksWindow.Open([Colors.Red, Colors.Blue, Colors.Purple], null);
                    // the equalizer's filters run over some audio (on and off), and turning it on and off is safe with nothing playing
                    Equalizer.Set(true, [6, 0, 1]);
                    var eq = new EqStage(new NAudio.Wave.SampleProviders.SignalGenerator(44100, 2) { Frequency = 440, Gain = 0.5 });
                    var samples = new float[4096];
                    if (eq.Read(samples, 0, samples.Length) != samples.Length || samples.Any(float.IsNaN)) throw new Exception("The equalizer's filters came out wrong.");
                    Equalizer.Set(false, [0, 0, 0]);
                    // a notice goes in the list, and a dropped file is identified (a second of silence: it reads, matches, and doesn't crash)
                    Inbox.Add("Smoke test", "A notice", []);
                    var wav = Path.Combine(Path.GetTempPath(), "jt-identify.wav");
                    using (var w = new NAudio.Wave.WaveFileWriter(wav, new NAudio.Wave.WaveFormat(44100, 16, 2))) w.Write(new byte[44100 * 4], 0, 44100 * 4);
                    Identify.Find(wav, Store.Shared.Catalog);
                    // Windows' media controls take the song (or, without them, nothing breaks)
                    MediaKeys.Apply();
                    // the lyrics windows open
                    LyricsMakerWindow.Open(); LyricsCardWindow.Open(null);
                    // every desktop widget opens and closes
                    foreach (var (k, _) in DesktopWidgets.Kinds) DesktopWidgets.Set(k, true);
                    foreach (var (k, _) in DesktopWidgets.Kinds) DesktopWidgets.Set(k, false);
                    // every theme and compact mode redraw the whole window; celebrations draw over it
                    foreach (var t in Themes.All.Select(t => t.Id).Append("custom")) { Store.Shared.Me.Theme = t; Themes.Apply(); window.Restyle(); }
                    Store.Shared.Me.Compact = true; window.Restyle(); Store.Shared.Me.Compact = false; window.Restyle();
                    // the Player tab's colors come from the art: a red picture must give red
                    var red = System.Windows.Media.Imaging.BitmapSource.Create(4, 4, 96, 96, System.Windows.Media.PixelFormats.Bgra32, null, Enumerable.Repeat(new byte[] { 20, 20, 200, 255 }, 16).SelectMany(x => x).ToArray(), 16);
                    if (PlayerPage.Hues(red) is not [var hue, ..] || hue.R < 200 || hue.G > 100) throw new Exception("The Player tab's colors from the art came out wrong.");
                    Fx.Confetti(); Fx.Shower999(); window.Toast("3 songs landed in your library");
                    Dispatcher.BeginInvoke(() => { File.WriteAllText(report, "ok"); Shutdown(0); }, DispatcherPriority.ApplicationIdle);
                }
                catch (Exception ex) { Fail(ex); }
            };
            window.Show();
        }
        catch (Exception ex) { Fail(ex); }
    }
}
