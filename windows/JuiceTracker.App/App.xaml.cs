using System.Windows;
using System.Windows.Threading;

namespace JuiceTracker.App;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // A bug in one screen shouldn't close the app (and lose a download in progress): say what happened instead.
        DispatcherUnhandledException += (_, args) =>
        {
            MessageBox.Show($"Something went wrong: {args.Exception.Message}", "Juice Tracker", MessageBoxButton.OK, MessageBoxImage.Warning);
            args.Handled = true;
        };
        var window = new MainWindow();
        MainWindow = window;
        window.Show();
        _ = Store.Shared.StartAsync();
    }
}
