using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
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

        Section("Your data");
        body.Children.Add(UI.Muted("Your wishlist, notes, ratings, matches and settings are saved on this computer, in:", 13));
        var path = UI.Link(Store.DataDir, () => Process.Start(new ProcessStartInfo("explorer.exe", Store.DataDir) { UseShellExecute = true }), 13);
        path.HorizontalAlignment = HorizontalAlignment.Left; path.Margin = new Thickness(0, 4, 0, 0);
        body.Children.Add(path);

        Section("About");
        body.Children.Add(UI.Muted($"Juice Tracker for Windows {typeof(SettingsWindow).Assembly.GetName().Version?.ToString(3)}. Song information comes from juicewrldapi.com; your files never leave this computer.", 13));
    }

    void Section(string title)
    {
        var t = UI.Text(title, 16, weight: FontWeights.SemiBold);
        t.Margin = new Thickness(0, body.Children.Count == 0 ? 0 : 22, 0, 8);
        body.Children.Add(t);
    }
}
