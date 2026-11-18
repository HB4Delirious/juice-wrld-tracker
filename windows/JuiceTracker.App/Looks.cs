using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;

namespace JuiceTracker.App;

/// The Player's lyrics font (Settings).
static class LyricFonts
{
    public static readonly (string Id, string Name)[] All = [("figtree", "Clean"), ("marker", "Marker"), ("rounded", "Rounded"), ("serif", "Serif"), ("mono", "Typewriter")];
    public static FontFamily Family(string id) => id switch
    {
        "marker" => JT.Marker, "rounded" => new FontFamily("Bahnschrift"), "serif" => new FontFamily("Georgia"), "mono" => new FontFamily("Consolas"), _ => JT.Body,
    };
}

/// A video of the song in its folder (an .mp4, .mov or .m4v with the file's name or the song's title).
static class MusicVideo
{
    static readonly string[] Kinds = [".mp4", ".mov", ".m4v"];
    /// Off the UI thread: it lists the song's folder, which can be slow on a network drive.
    public static string? Find(string audio, string title)
    {
        try
        {
            var folder = System.IO.Path.GetDirectoryName(audio)!; var b = System.IO.Path.GetFileNameWithoutExtension(audio); var want = Engine.Normalize(title);
            var videos = System.IO.Directory.EnumerateFiles(folder).Where(f => Kinds.Contains(System.IO.Path.GetExtension(f).ToLowerInvariant())).ToList();
            return videos.FirstOrDefault(f => System.IO.Path.GetFileNameWithoutExtension(f) == b)
                ?? videos.FirstOrDefault(f => want.Length > 0 && Engine.Normalize(System.IO.Path.GetFileNameWithoutExtension(f)) == want);
        }
        catch (Exception) { return null; }
    }
}

/// Quiet songs still move the visuals (Settings): each listener keeps its own recent loudest.
sealed class LevelBoost
{
    double peak;
    public double Apply(double level)
    {
        if (!Store.Shared.Me.VisualBoost) return level;
        (level, peak) = Engine.Boosted(level, peak);
        return level;
    }
}

/// The Player's looks: the ringed black hole (the default), and three more to pick from (Player looks).
static class PlayerLooks
{
    public static readonly (string Id, string Name)[] All = [("hole", "Black hole"), ("rings", "Rings"), ("bars", "Bars"), ("disc", "Record")];
    public static event Action? Changed;
    public static void Pick(string id) { Store.Shared.Me.PlayerStyle = id; Store.Shared.SavePersonal(); Changed?.Invoke(); }
    /// Another Player setting changed (lighter visuals): the open Player page redraws.
    public static void Refresh() => Changed?.Invoke();
}

/// Rings (circles in the song's colors turning at their own speeds, swelling with the beat), Bars (bars round a dark
/// center, longer on the beat) and Record (the cover on a spinning record). Spins are WPF animations on cached
/// layers, so the GPU turns them; the beat only changes a few scale values.
sealed class PlayerLook : Canvas
{
    readonly List<(ScaleTransform Scale, double Amount)> pulsing = [];
    readonly List<ScaleTransform> bars = [];
    string key = "";

    public PlayerLook() { IsHitTestVisible = false; }

    public void Build(string style, double size, Color[] colors, ImageSource? cover)
    {
        var k = $"{style}|{size:0}|{string.Join(",", colors)}|{cover?.GetHashCode()}";
        if (k == key || size <= 0) return;
        key = k; Children.Clear(); pulsing.Clear(); bars.Clear();
        double span = size * 2.6; Width = Height = span; double c = span / 2;
        FrameworkElement Center(FrameworkElement e, double side) { e.Width = e.Height = side; SetLeft(e, c - side / 2); SetTop(e, c - side / 2); e.RenderTransformOrigin = new Point(0.5, 0.5); return e; }
        void Spin(UIElement e, double seconds, bool reverse = false)
        {
            var r = new RotateTransform(); var s = new ScaleTransform(); e.RenderTransform = new TransformGroup { Children = { s, r } };
            r.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(0, reverse ? -360 : 360, TimeSpan.FromSeconds(seconds)) { RepeatBehavior = RepeatBehavior.Forever });
            e.CacheMode = new BitmapCache();
        }
        ScaleTransform Scaled(UIElement e) => e.RenderTransform is TransformGroup g ? g.Children.OfType<ScaleTransform>().First() : (ScaleTransform)(e.RenderTransform = new ScaleTransform());
        var hole = Center(new Ellipse { Fill = Brushes.Black, Effect = new DropShadowEffect { Color = colors[0], BlurRadius = size * 0.25, ShadowDepth = 0, Opacity = 0.9 } }, size);
        switch (style)
        {
            case "rings":
                for (int n = 0; n < 4; n++)
                {
                    var col = colors[n % 3];
                    var ring = Center(new Ellipse { Stroke = new SolidColorBrush(Color.FromArgb((byte)(217 - n * 38), col.R, col.G, col.B)), StrokeThickness = n == 0 ? 3 : 2,
                                                    StrokeDashArray = n == 0 ? null : [3 + n * 2, 4 + n * 1.5], Effect = new DropShadowEffect { Color = col, BlurRadius = 10, ShadowDepth = 0, Opacity = 0.8 } }, size * (1.12 + n * 0.32));
                    Spin(ring, 18 + n * 9, n % 2 == 1);
                    Children.Add(ring); pulsing.Add((Scaled(ring), 0.05 + n * 0.035));
                }
                Children.Add(hole); pulsing.Add((Scaled(hole), 0.03));
                break;
            case "bars":
                var wheel = new Canvas { Width = span, Height = span };
                const int count = 64;
                for (int n = 0; n < count; n++)
                {
                    double t = (double)n / count, angle = t * 360;
                    Color Mix(Color a, Color b, double f) => Color.FromRgb((byte)(a.R + (b.R - a.R) * f), (byte)(a.G + (b.G - a.G) * f), (byte)(a.B + (b.B - a.B) * f));
                    var bar = new Rectangle { Width = Math.Max(2, size * 0.022), Height = size * 0.42, RadiusX = 2, RadiusY = 2,
                                              Fill = new SolidColorBrush(t < 0.5 ? Mix(colors[0], colors[1], t * 2) : Mix(colors[1], colors[2], (t - 0.5) * 2)) };
                    var scale = new ScaleTransform(1, 0.12);
                    // grows outward from the edge of the center
                    bar.RenderTransformOrigin = new Point(0.5, 1);
                    bar.RenderTransform = new TransformGroup { Children = { scale, new TranslateTransform(0, -size * 0.54), new RotateTransform(angle) } }; // about the bar's foot (its render origin), the wheel's center
                    SetLeft(bar, c - bar.Width / 2); SetTop(bar, c - size * 0.42);
                    wheel.Children.Add(bar); bars.Add(scale);
                }
                wheel.RenderTransformOrigin = new Point(0.5, 0.5);
                wheel.RenderTransform = new RotateTransform();
                ((RotateTransform)wheel.RenderTransform).BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(0, 360, TimeSpan.FromSeconds(60)) { RepeatBehavior = RepeatBehavior.Forever });
                Children.Add(wheel); Children.Add(hole); pulsing.Add((Scaled(hole), 0.03));
                break;
            default: // "disc": the cover on a spinning record
                var disc = new Grid();
                disc.Children.Add(new Ellipse { Fill = new SolidColorBrush(Color.FromRgb(10, 10, 10)), Effect = new DropShadowEffect { Color = colors[0], BlurRadius = size * 0.28, ShadowDepth = 0, Opacity = 0.9 } });
                for (int g = 0; g < 7; g++)
                    disc.Children.Add(new Ellipse { Width = size * (0.64 + g * 0.084), Height = size * (0.64 + g * 0.084), Stroke = new SolidColorBrush(Color.FromArgb((byte)(g % 2 == 0 ? 18 : 10), 255, 255, 255)), StrokeThickness = 1 });
                disc.Children.Add(new Ellipse { Width = size * 0.56, Height = size * 0.56, Fill = cover is null ? new SolidColorBrush(colors[0]) : new ImageBrush(cover) { Stretch = Stretch.UniformToFill } });
                disc.Children.Add(new Ellipse { Width = size * 0.04, Height = size * 0.04, Fill = Brushes.Black });
                Center(disc, size * 1.24);
                Spin(disc, 8);
                Children.Add(disc); pulsing.Add((Scaled(disc), 0.04));
                break;
        }
    }

    public void Pulse(double level)
    {
        foreach (var (s, amount) in pulsing) s.ScaleX = s.ScaleY = 1 + level * amount * 2;
        for (int n = 0; n < bars.Count; n++)
        {
            double wobble = level > 0 ? 0.25 * ((n * 37 + (int)(level * 50)) % 5) / 4 : 0;
            bars[n].ScaleY = Math.Max(0.12, Math.Min(1, level * (0.7 + wobble)));
        }
    }
}

/// Every look at once: click one to use it.
sealed class PlayerLooksWindow : Window
{
    public static void Open(Color[] colors, ImageSource? cover) => new PlayerLooksWindow(colors, cover) { Owner = MainWindow.Current }.Show();

    PlayerLooksWindow(Color[] colors, ImageSource? cover)
    {
        Title = "Player looks"; Width = 560; Height = 560; Background = JT.Brush(Color.FromRgb(20, 10, 44)); WindowStartupLocation = WindowStartupLocation.CenterOwner;
        System.Windows.Documents.TextElement.SetFontFamily(this, JT.Body);
        var grid = new System.Windows.Controls.Primitives.UniformGrid { Columns = 2, Margin = new Thickness(0, 12, 0, 0) };
        var tiles = new List<(Border Frame, TextBlock Name, string Id)>();
        foreach (var (id, name) in PlayerLooks.All)
        {
            var look = new PlayerLook();
            FrameworkElement art;
            if (id == "hole")
                art = new Grid { Width = 182, Height = 182, Children = {
                    new Ellipse { Width = 120, Height = 120, StrokeThickness = 12, Stroke = new LinearGradientBrush(colors[0], colors[1], 0), Effect = new BlurEffect { Radius = 14 } },
                    new Ellipse { Width = 70, Height = 70, Fill = Brushes.Black, Stroke = Brushes.White, StrokeThickness = 2 },
                    new Ellipse { Width = 170, Height = 40, Stroke = new LinearGradientBrush(colors[1], colors[2], 0), StrokeThickness = 6, Opacity = 0.8 } } };
            else { look.Build(id, 70, colors, cover); art = look; }
            var frame = new Border { Height = 170, CornerRadius = new CornerRadius(12), ClipToBounds = true, Background = Brushes.Black, BorderThickness = new Thickness(2), Child = new Viewbox { Child = art, Stretch = Stretch.Uniform } };
            var label = UI.Text(name, 14);
            var tile = new Button { Style = (Style)Application.Current.FindResource("Plain"), Cursor = System.Windows.Input.Cursors.Hand, Margin = new Thickness(7), Content = UI.Column(6, frame, label) };
            tile.Click += (_, _) => { PlayerLooks.Pick(id); Mark(); };
            UI.AutomationName(tile, name);
            grid.Children.Add(tile); tiles.Add((frame, label, id));
            // the looks move a little here too, so you can see them playing
            if (id != "hole") { var t = 0.0; new System.Windows.Threading.DispatcherTimer(TimeSpan.FromMilliseconds(90), System.Windows.Threading.DispatcherPriority.Background, (s, _) => { if (!IsLoaded && t > 0) { ((System.Windows.Threading.DispatcherTimer)s!).Stop(); return; } t += 0.09; look.Pulse(0.45 + 0.35 * Math.Sin(t * 5) * Math.Sin(t * 1.7)); }, Dispatcher); }
        }
        void Mark() { foreach (var (f, l, id) in tiles) { bool on = Store.Shared.Me.PlayerStyle == id; f.BorderBrush = JT.Brush(on ? JT.Lavender : Color.FromArgb(31, 255, 255, 255)); l.FontWeight = on ? FontWeights.Bold : FontWeights.Normal; } }
        Mark();
        Content = new StackPanel { Margin = new Thickness(22), Children = { UI.Marker("Player looks", 26), grid } };
    }
}
