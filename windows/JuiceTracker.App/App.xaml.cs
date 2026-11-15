using System.IO;
using System.Windows;
using System.Windows.Threading;

namespace JuiceTracker.App;

public partial class App : Application
{
    /// Where the details of an error go (the message box shows the short version).
    static string CrashLog => Path.Combine(Store.DataDir, "error.log");

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args.Contains("--smoke-test")) { SmokeTest(); return; }
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
    }

    static Exception Innermost(Exception e) { while (e.InnerException is not null) e = e.InnerException; return e; }
    static void Log(Exception e)
    {
        try { Directory.CreateDirectory(Store.DataDir); File.AppendAllText(CrashLog, $"{DateTime.Now:u}\n{e}\n\n"); } catch (IOException) { }
    }

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
                    var song = new Song(0, new EngineSong { Id = "1", Name = "Smoke Test", Era = "DRFL", Category = "unreleased", Length = "3:00" }, false, false);
                    UIElement[] screens = [new CollectionPage(), new FixerPage(), new SetupPage(), new SongCard(song), new SongRow(song), new PlayerPanel()];
                    foreach (var s in screens) { s.Measure(new Size(1000, 800)); s.Arrange(new Rect(0, 0, 1000, 800)); }
                    // screens redraw in place whenever something changes: do that twice, like a download finishing
                    foreach (var s in screens.OfType<IRefresh>()) { s.Refresh(); s.Refresh(); }
                    Store.Shared.Notify(); Store.Shared.Notify();
                    window.ShowOverlay(new SongCard(song));
                    SettingsWindow.Open();
                    Dispatcher.BeginInvoke(() => { File.WriteAllText(report, "ok"); Shutdown(0); }, DispatcherPriority.ApplicationIdle);
                }
                catch (Exception ex) { Fail(ex); }
            };
            window.Show();
        }
        catch (Exception ex) { Fail(ex); }
    }
}
