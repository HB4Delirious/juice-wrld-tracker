using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace JuiceTracker.App;

/// The Player tab, made to sit and watch: a ringed black hole in deep space whose glow takes its colors from the
/// song's art, the time above it, the lyrics lighting up word by word, the cover on a tilted card, the queue floating
/// at the left and a control bar at the bottom. Your songs open from the search button. All drawn in code. The layout
/// is built once; the player's 4-times-a-second updates only touch the parts that move.
public sealed class PlayerPage : Grid, IRefresh
{
    // the song's colors: every brush that glows holds stops tied to one of the three, animated when the song changes
    static readonly Color[] Fallback = [Color.FromRgb(255, 106, 213), Color.FromRgb(80, 130, 255), Color.FromRgb(140, 40, 190)];
    readonly List<(GradientStop Stop, int Slot, double Alpha)> tinted = [];
    Color[] palette = Fallback;

    readonly Canvas stage = new() { ClipToBounds = true };
    readonly Grid hole = new(), clock = new(), backDisc = new(), frontDisc = new();
    readonly RotateTransform spinBack = new(), spinFront = new();
    readonly TextBlock date = new() { FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = JT.Brush(Color.FromArgb(217, 255, 246, 251)), HorizontalAlignment = HorizontalAlignment.Center };
    readonly TextBlock time = new() { FontFamily = new FontFamily("Bahnschrift Condensed, Bahnschrift, Segoe UI"), FontStretch = FontStretches.Condensed, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center,
                                      Foreground = new LinearGradientBrush(Color.FromArgb(235, 255, 255, 255), Color.FromArgb(30, 255, 255, 255), 90) };
    readonly TextBlock karaoke = new() { FontSize = 30, FontWeight = FontWeights.Black, TextWrapping = TextWrapping.Wrap, Foreground = Brushes.White, IsHitTestVisible = false,
                                         Effect = new DropShadowEffect { Color = Colors.Black, BlurRadius = 16, ShadowDepth = 0, Opacity = 0.7 } };
    readonly Image cover = new() { Stretch = Stretch.UniformToFill }, barThumb = new() { Stretch = Stretch.UniformToFill }, queueThumb = new() { Stretch = Stretch.UniformToFill };
    readonly TextBlock cardTitle = UI.Text("Nothing playing", 14, weight: FontWeights.SemiBold), cardEra = UI.Text("Juice WRLD", 11.5, Color.FromArgb(180, 255, 246, 251));
    readonly TextBlock barTitle = UI.Text("Nothing playing", 12, weight: FontWeights.SemiBold), barEra = UI.Text("Juice WRLD", 10, JT.Muted), queueSub = UI.Text("", 11, JT.Muted);
    readonly Border card, queueBox, bar, songsPanel;
    readonly StackPanel queue = new();
    readonly Rectangle progress = new() { Height = 3, RadiusX = 1.5, RadiusY = 1.5, HorizontalAlignment = HorizontalAlignment.Left };
    readonly Grid progressTrack = new() { Height = 10, Background = Brushes.Transparent, Cursor = Cursors.Hand };
    readonly Button play, heart, repeat, search;
    readonly DropShadowEffect playGlow;
    readonly Slider volume = new() { Minimum = 0, Maximum = 100, Width = 70, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock empty = UI.Muted("Songs you have that this PC can play show up here.", 15);
    // the songs panel
    readonly StackPanel rows = new();
    readonly TextBox find = new() { Width = 170 };
    readonly ComboBox eraPick = new() { MinWidth = 140 };
    readonly StackPanel eraButtons = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
    readonly DispatcherTimer minute = new() { Interval = TimeSpan.FromSeconds(10) };
    readonly DispatcherTimer shooter = new() { Interval = TimeSpan.FromSeconds(6.5) };
    readonly DispatcherTimer listen = new() { Interval = TimeSpan.FromMilliseconds(80) };
    readonly Canvas swirl = new() { IsHitTestVisible = false };   // icons circling the hole
    readonly List<AnimationClock> swirlClocks = [];
    readonly LevelMeter meter = new();
    double pace = 1; bool measuring;
    readonly Canvas sky = new() { IsHitTestVisible = false, ClipToBounds = true }; // twinkles and shooting stars
    readonly Ellipse wave = new() { StrokeThickness = 3, Opacity = 0, IsHitTestVisible = false, RenderTransformOrigin = new Point(0.5, 0.5) }; // rolls out when a song starts
    readonly List<RotateTransform> sparkSpins = [];
    double holeSize;

    string? file, upNextKey, artFor; List<(double At, string Line)> synced = []; int line = -2, lit = -1, limit = 250; bool updating;

    public PlayerPage()
    {
        Background = Brushes.Black;
        Children.Add(Space());
        Children.Add(sky);
        Children.Add(stage);
        wave.Stroke = Ring((0, 1), (1, 1), (2, 1), (0, 1)); wave.Effect = new BlurEffect { Radius = 2 };
        stage.Children.Add(wave);
        stage.Children.Add(BuildHole());
        stage.Children.Add(swirl);
        clock.Children.Add(UI.Column(0, date, time)); clock.IsHitTestVisible = false; stage.Children.Add(clock);
        stage.Children.Add(karaoke);

        // the cover on a glassy card, turned toward the hole; click opens the song card
        var art = new Border { CornerRadius = new CornerRadius(10), ClipToBounds = true, Child = cover, Background = JT.Brush(Color.FromArgb(30, 255, 255, 255)) };
        art.SizeChanged += (_, e) => { art.Height = e.NewSize.Width; art.Clip = new RectangleGeometry(new Rect(0, 0, e.NewSize.Width, e.NewSize.Width), 10, 10); };
        cardTitle.HorizontalAlignment = HorizontalAlignment.Center; cardEra.HorizontalAlignment = HorizontalAlignment.Center; cardTitle.TextTrimming = TextTrimming.CharacterEllipsis;
        cardTitle.Margin = new Thickness(0, 6, 0, 0);
        card = new Border
        {
            Padding = new Thickness(10), CornerRadius = new CornerRadius(14), BorderBrush = JT.Brush(Color.FromArgb(77, 255, 255, 255)), BorderThickness = new Thickness(1),
            Background = new LinearGradientBrush(Color.FromArgb(61, 255, 255, 255), Color.FromArgb(20, 255, 255, 255), 45), Child = UI.Column(0, art, cardTitle, cardEra),
            RenderTransform = new TransformGroup { Children = { new SkewTransform(0, -7), new ScaleTransform(1, 1) } }, RenderTransformOrigin = new Point(0.5, 0.5),
            Cursor = Cursors.Hand, ToolTip = "Open the song card",
            Effect = new DropShadowEffect { Color = Colors.Black, BlurRadius = 30, ShadowDepth = 10, Direction = 270, Opacity = 0.6 },
        };
        // straightens up and comes closer under the pointer
        card.MouseEnter += (_, _) => Lift(true); card.MouseLeave += (_, _) => Lift(false);
        card.MouseLeftButtonUp += (_, _) => { if (Player.Shared.CurrentFile is { } f && Store.Shared.SongForFile(f) is var i and >= 0) MainWindow.Current?.OpenSong(Store.Shared.Songs[i]); };
        stage.Children.Add(card);

        // the queue, on a panel turned toward the middle
        queueBox = new Border { Padding = new Thickness(12), Width = 230, Child = queue, RenderTransform = new SkewTransform(0, 7) };
        stage.Children.Add(queueBox);

        // the control bar
        play = UI.IconButton("", "Play", Toggle, 18, Colors.White);
        // the play button glows in the song's colors
        var playDisc = new Border { Width = 36, Height = 36, CornerRadius = new CornerRadius(18), Background = Ring((0, 1), (1, 1)), Child = play,
                                    Effect = new DropShadowEffect { BlurRadius = 18, ShadowDepth = 0, Opacity = 0.8 } };
        playGlow = (DropShadowEffect)playDisc.Effect;
        heart = UI.IconButton("", "Rate 5 hearts", Love, 15);
        repeat = UI.IconButton("", "Era radio", () => Player.Shared.SetInOrder(!Store.Shared.Me.InOrder), 15);
        repeat.ToolTip = "Era radio: play the era in the order it was recorded";
        Button? shuffle = null, sleep = null;
        shuffle = UI.IconButton("", "Which era to shuffle", () => { var m = EraMenu(); m.PlacementTarget = shuffle; m.Placement = PlacementMode.Top; m.IsOpen = true; }, 15);
        sleep = UI.IconButton("", "Sleep timer", () => { var m = Listen.SleepMenu(); m.PlacementTarget = sleep; m.Placement = PlacementMode.Top; m.IsOpen = true; }, 15);
        var restart = UI.IconButton("", "Start this song again", () => Player.Shared.Seek(TimeSpan.Zero), 15);
        restart.ToolTip = "Start this song again";
        progressTrack.Children.Add(new Rectangle { Height = 3, RadiusX = 1.5, RadiusY = 1.5, Fill = JT.Brush(Color.FromArgb(38, 255, 255, 255)) });
        progress.Fill = Ring((0, 1), (1, 1));
        progressTrack.Children.Add(progress);
        progressTrack.MouseLeftButtonDown += (_, e) => { var p = Player.Shared; if (p.Duration.TotalSeconds > 0) p.Seek(p.Duration * Math.Clamp(e.GetPosition(progressTrack).X / progressTrack.ActualWidth, 0, 1)); };
        UI.AutomationName(progressTrack, "Position in the song");
        volume.ValueChanged += (_, e) => { if (!updating) Player.Shared.Volume = e.NewValue; };
        volume.PreviewMouseUp += (_, _) => Store.Shared.SavePersonal();
        UI.AutomationName(volume, "Volume");
        barTitle.TextTrimming = TextTrimming.CharacterEllipsis; barEra.TextTrimming = TextTrimming.CharacterEllipsis;
        var left = UI.Row(14, shuffle, restart, playDisc, UI.IconButton("", "Next song", Player.Shared.Skip, 15), repeat);
        var right = UI.Row(12, heart, sleep, UI.IconButton("", "Big lyrics window", LyricsWindow.Open, 15), UI.IconButton("", "Mini player", MiniPlayer.Open, 15),
                           UI.Icon("", 14, JT.Muted), volume);
        var middle = new DockPanel { Margin = new Thickness(16, 0, 16, 0) };
        var thumb = Thumb(barThumb, 30); DockPanel.SetDock(thumb, Dock.Left); middle.Children.Add(thumb);
        var words = UI.Column(2, barTitle, barEra, progressTrack); words.Margin = new Thickness(8, 0, 0, 0); words.VerticalAlignment = VerticalAlignment.Center; middle.Children.Add(words);
        var row = new DockPanel(); DockPanel.SetDock(left, Dock.Left); DockPanel.SetDock(right, Dock.Right);
        row.Children.Add(left); row.Children.Add(right); row.Children.Add(middle);
        bar = new Border { CornerRadius = new CornerRadius(30), Padding = new Thickness(18, 9, 18, 9), Background = JT.Brush(Color.FromArgb(230, 28, 28, 28)),
                           BorderBrush = JT.Brush(Color.FromArgb(46, 255, 255, 255)), BorderThickness = new Thickness(1), Child = row };
        stage.Children.Add(bar);

        // the round search button opens your songs on the right
        search = UI.IconButton("", "Your songs", ToggleSongs, 14);
        var searchRing = new Border { Width = 32, Height = 32, CornerRadius = new CornerRadius(16), Background = JT.Brush(Color.FromArgb(26, 255, 255, 255)),
                                      BorderBrush = JT.Brush(Color.FromArgb(51, 255, 255, 255)), BorderThickness = new Thickness(1), Child = search, Tag = "search" };
        stage.Children.Add(searchRing);
        find.TextChanged += (_, _) => { limit = 250; BuildRows(); };
        UI.AutomationName(find, "Search your songs");
        eraPick.SelectionChanged += (_, _) => { if (!updating) { limit = 250; BuildRows(); } };
        UI.AutomationName(eraPick, "Show songs from");
        var head = new DockPanel();
        var filters = UI.Row(8, find, eraPick); DockPanel.SetDock(filters, Dock.Right); head.Children.Add(filters);
        head.Children.Add(UI.Text("Your songs", 15, weight: FontWeights.SemiBold));
        var list = new ScrollViewer { Content = rows, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(0, 10, 0, 0) };
        var panel = new DockPanel(); DockPanel.SetDock(head, Dock.Top); DockPanel.SetDock(eraButtons, Dock.Top);
        panel.Children.Add(head); panel.Children.Add(eraButtons); panel.Children.Add(list);
        songsPanel = new Border { Width = 460, CornerRadius = new CornerRadius(18), Padding = new Thickness(16), Background = JT.Brush(Color.FromArgb(224, 0, 0, 0)),
                                  BorderBrush = JT.Brush(Color.FromArgb(46, 255, 255, 255)), BorderThickness = new Thickness(1), Child = panel, Visibility = Visibility.Collapsed };
        stage.Children.Add(songsPanel);
        stage.Children.Add(empty);

        stage.SizeChanged += (_, _) => Place();
        minute.Tick += (_, _) => Clock();
        shooter.Tick += (_, _) => Shoot();
        listen.Tick += (_, _) => Hear();
        sky.SizeChanged += (_, _) => Twinkles();
        Loaded += (_, _) => { Player.Shared.Changed += Tick; minute.Start(); shooter.Start(); listen.Start(); Spin(true); Tick(); };
        Unloaded += (_, _) => { Player.Shared.Changed -= Tick; minute.Stop(); shooter.Stop(); listen.Stop(); Spin(false); };
        Clock();
        Refresh();
    }

    // MARK: Drawing

    /// Black, faint glows in the song's colors, and stars (the same ones every time).
    UIElement Space()
    {
        var grid = new Grid { IsHitTestVisible = false };
        foreach (var (slot, x, y) in new[] { (1, 0.82, 0.12), (0, 0.12, 0.88) })
        {
            var g = new RadialGradientBrush { Center = new Point(x, y), GradientOrigin = new Point(x, y), RadiusX = 0.55, RadiusY = 0.7 };
            g.GradientStops.Add(Tint(slot, 0.16, 0)); g.GradientStops.Add(new GradientStop(Colors.Transparent, 1));
            grid.Children.Add(new Rectangle { Fill = g });
        }
        var stars = new DrawingGroup(); var rng = new Random(999);
        stars.Children.Add(new GeometryDrawing(Brushes.Transparent, null, new RectangleGeometry(new Rect(0, 0, 1000, 1000))));
        for (int n = 0; n < 320; n++)
        {
            double r = 0.4 + rng.NextDouble() * 1.2;
            var b = new SolidColorBrush(Color.FromArgb((byte)(64 + rng.Next(150)), 255, 255, 255)); b.Freeze();
            stars.Children.Add(new GeometryDrawing(b, null, new EllipseGeometry(new Point(rng.NextDouble() * 1000, rng.NextDouble() * 1000), r, r)));
        }
        stars.Freeze();
        grid.Children.Add(new Image { Source = new DrawingImage(stars), Stretch = Stretch.Fill });
        return grid;
    }

    /// A stop whose color follows one of the song's three colors.
    GradientStop Tint(int slot, double alpha, double offset)
    {
        var c = palette[slot]; var s = new GradientStop(Color.FromArgb((byte)(alpha * 255), c.R, c.G, c.B), offset);
        tinted.Add((s, slot, alpha));
        return s;
    }
    Brush Ring(params (int Slot, double Alpha)[] stops)
    {
        var b = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1) };
        for (int k = 0; k < stops.Length; k++)
            b.GradientStops.Add(stops[k].Slot < 0 ? new GradientStop(Color.FromArgb((byte)(stops[k].Alpha * 255), 255, 255, 255), (double)k / (stops.Length - 1)) : Tint(stops[k].Slot, stops[k].Alpha, (double)k / (stops.Length - 1)));
        return b;
    }

    /// The ringed black hole: a glowing disc in the song's colors, slowly turning, passing behind the hole at the top
    /// and in front of it at the bottom.
    UIElement BuildHole()
    {
        hole.IsHitTestVisible = false;
        hole.Children.Add(backDisc);
        var glow = new Ellipse { StrokeThickness = 18, Stroke = Ring((0, 1), (1, 1), (2, 1), (0, 1)), Opacity = 0.75, Effect = new BlurEffect { Radius = 22 }, Tag = 1.1 };
        // breathes slowly
        glow.BeginAnimation(OpacityProperty, new DoubleAnimation(0.55, 0.95, TimeSpan.FromSeconds(2.6)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase() });
        hole.Children.Add(glow);
        var ball = new Ellipse { Fill = Brushes.Black, Stroke = JT.Brush(Color.FromArgb(242, 255, 255, 255)), StrokeThickness = 3, Tag = 1.0,
                                 Effect = new DropShadowEffect { Color = Colors.White, BlurRadius = 22, ShadowDepth = 0, Opacity = 0.75 } };
        hole.Children.Add(ball);
        hole.Children.Add(frontDisc);
        return hole;
    }
    Grid Disc(RotateTransform spin, double size)
    {
        var turning = new Grid { RenderTransform = spin, RenderTransformOrigin = new Point(0.5, 0.5) };
        void Add(double scale, double thickness, Brush stroke, double blur, double opacity = 1, DoubleCollection? dash = null)
        {
            var e = new Ellipse { Width = size * scale, Height = size * scale, StrokeThickness = thickness, Stroke = stroke, Opacity = opacity, StrokeDashArray = dash,
                                  Effect = blur > 0 ? new BlurEffect { Radius = blur } : null };
            turning.Children.Add(e);
        }
        Add(1.95, size * 0.2, Ring((0, 1), (1, 0.35), (2, 1), (0, 0.3), (1, 1), (0, 1)), size * 0.14, 0.9);
        Add(1.55, size * 0.04, Ring((-1, 0.8), (0, 0.2), (-1, 0.55), (1, 0.2), (-1, 0.8)), size * 0.04);
        Add(2.35, 1.5, Ring((2, 0.6), (2, 0.6)), 0, 1, [1, 8]);
        var flat = new Grid { RenderTransformOrigin = new Point(0.5, 0.5), Width = size * 2.5, Height = size * 2.5,
                              RenderTransform = new TransformGroup { Children = { new ScaleTransform(1, 0.24), new RotateTransform(-8) } } };
        flat.Children.Add(turning);
        // specks of light through the disc, orbiting faster than it turns
        var sparkSpin = new RotateTransform(); sparkSpins.Add(sparkSpin);
        flat.Children.Add(new Image { Source = Sparks(size * 2.4), Width = size * 2.4, Height = size * 2.4, RenderTransform = sparkSpin, RenderTransformOrigin = new Point(0.5, 0.5) });
        // the side turning toward you is brighter
        flat.OpacityMask = new LinearGradientBrush(Colors.White, Color.FromArgb(128, 255, 255, 255), 0);
        return flat;
    }
    void Spin(bool on)
    {
        foreach (var s in new[] { spinBack, spinFront })
            s.BeginAnimation(RotateTransform.AngleProperty, on ? new DoubleAnimation(0, 360, TimeSpan.FromSeconds(90)) { RepeatBehavior = RepeatBehavior.Forever } : null);
        foreach (var s in sparkSpins)
            s.BeginAnimation(RotateTransform.AngleProperty, on ? new DoubleAnimation(0, 360, TimeSpan.FromSeconds(41)) { RepeatBehavior = RepeatBehavior.Forever } : null);
    }

    /// Specks of light in the song's colors and white, drawn once (the same ones every time).
    ImageSource Sparks(double side)
    {
        var g = new DrawingGroup(); var rng = new Random(1998); double c = side / 2;
        g.Children.Add(new GeometryDrawing(Brushes.Transparent, null, new RectangleGeometry(new Rect(0, 0, side, side))));
        for (int k = 0; k < 90; k++)
        {
            double angle = rng.NextDouble() * Math.PI * 2, r = c * (0.6 + rng.NextDouble() * 0.36), d = 1 + rng.NextDouble() * 2.4;
            var col = k % 3 == 2 ? Colors.White : palette[k % 3];
            var b = new SolidColorBrush(Color.FromArgb((byte)(128 + rng.Next(127)), col.R, col.G, col.B)); b.Freeze();
            g.Children.Add(new GeometryDrawing(b, null, new EllipseGeometry(new Point(c + Math.Cos(angle) * r, c + Math.Sin(angle) * r), d / 2, d / 2)));
        }
        g.Freeze();
        return new DrawingImage(g);
    }

    /// Bigger stars that twinkle, each on its own beat (an original four-pointed shape).
    void Twinkles()
    {
        foreach (var old in sky.Children.OfType<Path>().ToList()) sky.Children.Remove(old);
        double w = sky.ActualWidth, h = sky.ActualHeight;
        if (w == 0) return;
        var rng = new Random(2018);
        for (int k = 0; k < 16; k++)
        {
            double side = 7 + rng.NextDouble() * 10, c = side / 2, q = side * 0.12;
            var shape = Geometry.Parse(FormattableString.Invariant($"M {c},0 Q {c + q},{c - q} {side},{c} Q {c + q},{c + q} {c},{side} Q {c - q},{c + q} 0,{c} Q {c - q},{c - q} {c},0 Z"));
            var scale = new ScaleTransform(0.4, 0.4);
            var star = new Path { Data = shape, Fill = Brushes.White, Opacity = 0.1, RenderTransform = scale, RenderTransformOrigin = new Point(0.5, 0.5),
                                  Effect = new DropShadowEffect { Color = Colors.White, BlurRadius = 6, ShadowDepth = 0, Opacity = 0.8 } };
            At(star, rng.NextDouble() * w, rng.NextDouble() * h * 0.8);
            var beat = TimeSpan.FromSeconds(1.8 + k % 5 * 0.6); var begin = TimeSpan.FromSeconds(k * 0.41);
            star.BeginAnimation(OpacityProperty, new DoubleAnimation(0.1, 0.9, beat) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, BeginTime = begin, EasingFunction = new SineEase() });
            var grow = new DoubleAnimation(0.4, 1, beat) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, BeginTime = begin, EasingFunction = new SineEase() };
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, grow); scale.BeginAnimation(ScaleTransform.ScaleYProperty, grow);
            sky.Children.Add(star);
        }
        Doodles();
    }

    /// Now and then a shooting star crosses the sky, from upper right toward lower left.
    void Shoot()
    {
        double w = sky.ActualWidth, h = sky.ActualHeight;
        if (w == 0 || Random.Shared.NextDouble() > 0.7) return; // not like clockwork
        var from = new Point(w * (0.35 + Random.Shared.NextDouble() * 0.7), -20 + Random.Shared.NextDouble() * h * 0.25);
        var to = new Point(from.X - w * (0.3 + Random.Shared.NextDouble() * 0.25), from.Y + h * (0.2 + Random.Shared.NextDouble() * 0.2));
        double angle = Math.Atan2(to.Y - from.Y, to.X - from.X) * 180 / Math.PI;
        // the bright head (the right end) leads; it turns around that end
        var streak = new Rectangle { Width = 140, Height = 2, RadiusX = 1, RadiusY = 1, Fill = new LinearGradientBrush(Colors.Transparent, Colors.White, 0),
                                     RenderTransform = new RotateTransform(angle, 140, 1), Effect = new DropShadowEffect { Color = Colors.White, BlurRadius = 8, ShadowDepth = 0 } };
        sky.Children.Add(streak);
        var time = TimeSpan.FromSeconds(1.1); var ease = new QuadraticEase { EasingMode = EasingMode.EaseIn };
        var fly = new DoubleAnimation(from.X - 140, to.X - 140, time) { EasingFunction = ease };
        fly.Completed += (_, _) => sky.Children.Remove(streak);
        streak.BeginAnimation(Canvas.LeftProperty, fly);
        streak.BeginAnimation(Canvas.TopProperty, new DoubleAnimation(from.Y, to.Y, time) { EasingFunction = ease });
        streak.BeginAnimation(OpacityProperty, new DoubleAnimation(1, 0, time) { EasingFunction = ease });
    }

    /// A new song: a ring in its colors rolls out from the hole.
    void Wave()
    {
        if (holeSize == 0) return;
        var ease = new QuadraticEase { EasingMode = EasingMode.EaseOut }; var time = TimeSpan.FromSeconds(1.6);
        var scale = new ScaleTransform(); wave.RenderTransform = scale;
        var grow = new DoubleAnimation(1, 2.8, time) { EasingFunction = ease };
        scale.BeginAnimation(ScaleTransform.ScaleXProperty, grow); scale.BeginAnimation(ScaleTransform.ScaleYProperty, grow);
        wave.BeginAnimation(OpacityProperty, new DoubleAnimation(0.9, 0, time) { EasingFunction = ease });
    }

    /// The cover card straightens up and comes closer under the pointer.
    void Lift(bool up)
    {
        if (card.RenderTransform is not TransformGroup { Children: [SkewTransform skew, ScaleTransform scale] }) return;
        var time = TimeSpan.FromSeconds(0.3); var ease = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.4 };
        skew.BeginAnimation(SkewTransform.AngleYProperty, new DoubleAnimation(up ? -2 : -7, time) { EasingFunction = ease });
        scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(up ? 1.05 : 1, time) { EasingFunction = ease });
        scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(up ? 1.05 : 1, time) { EasingFunction = ease });
    }

    static Border Thumb(Image img, double side) => new()
    {
        Width = side, Height = side, CornerRadius = new CornerRadius(side * 0.18), ClipToBounds = true, Background = JT.Brush(Color.FromArgb(30, 255, 255, 255)),
        Clip = new RectangleGeometry(new Rect(0, 0, side, side), side * 0.18, side * 0.18), Child = img,
    };

    /// Puts everything in place for this size (the hole scales with the page).
    void Place()
    {
        double w = stage.ActualWidth, h = stage.ActualHeight;
        if (w == 0) return;
        double size = Math.Max(160, Math.Min(Math.Min(w * 0.34, h * 0.4), 360)), cx = w / 2, cy = h * 0.44, span = size * 2.5;
        hole.Width = hole.Height = span;
        backDisc.Children.Clear(); frontDisc.Children.Clear(); sparkSpins.Clear(); holeSize = size;
        wave.Width = wave.Height = size; At(wave, cx - size / 2, cy - size / 2);
        backDisc.Children.Add(Disc(spinBack, size)); frontDisc.Children.Add(Disc(spinFront, size));
        backDisc.Clip = new RectangleGeometry(new Rect(0, 0, span, span / 2));
        frontDisc.Clip = new RectangleGeometry(new Rect(0, span / 2, span, span / 2));
        foreach (var e in hole.Children.OfType<Ellipse>()) { e.Width = e.Height = size * (double)e.Tag; }
        At(hole, cx - span / 2, cy - span / 2);
        Swirl(size, new Point(cx, cy));
        time.FontSize = size * 0.34;
        clock.Width = 400; At(clock, cx - 200, cy - size * 0.62 - size * 0.34 * 0.75);
        double words = Math.Min(w * 0.42, 460);
        karaoke.Width = words; At(karaoke, cx - size * 0.08, cy + size * 0.24 - 30);
        card.Width = size * 0.44; At(card, cx - size * 0.58, cy + size * 0.36 - size * 0.32);
        At(queueBox, Math.Max(20, cx - size * 1.3 - 115), cy - 60);
        bar.Width = Math.Min(w - 40, 820); At(bar, cx - bar.Width / 2, h - 82);
        var ring = stage.Children.OfType<Border>().First(b => "search".Equals(b.Tag));
        At(ring, cx + bar.Width / 2 - 34, h - 126);
        songsPanel.Width = Math.Min(460, w - 40); songsPanel.Height = Math.Max(240, h - 170); At(songsPanel, w - songsPanel.Width - 20, 20);
        empty.Width = 420; empty.TextAlignment = TextAlignment.Center; At(empty, cx - 210, cy - 10);
        Spin(IsLoaded);
    }
    static void At(UIElement e, double x, double y) { Canvas.SetLeft(e, x); Canvas.SetTop(e, y); }

    void Clock()
    {
        var now = DateTime.Now;
        date.Text = now.ToString("ddd, MMM d");
        var pattern = System.Globalization.CultureInfo.CurrentCulture.DateTimeFormat.ShortTimePattern.Replace("tt", "").Replace("t", "").Trim();
        time.Text = now.ToString(pattern);
    }

    // MARK: Colors from the art

    /// Three glowing colors from the art: pixels binned by hue, each weighted by how colorful and bright it is,
    /// brightened so they glow on black.
    public static Color[] Hues(BitmapSource src)
    {
        const int n = 24;
        var small = new TransformedBitmap(new FormatConvertedBitmap(src, PixelFormats.Bgra32, null, 0), new ScaleTransform((double)n / src.PixelWidth, (double)n / src.PixelHeight));
        int w = small.PixelWidth, h = small.PixelHeight; var px = new byte[w * h * 4];
        small.CopyPixels(px, w * 4, 0);
        var bins = new (double W, double R, double G, double B)[12];
        for (int k = 0; k < px.Length; k += 4)
        {
            double b = px[k] / 255.0, g = px[k + 1] / 255.0, r = px[k + 2] / 255.0;
            double mx = Math.Max(r, Math.Max(g, b)), mn = Math.Min(r, Math.Min(g, b)), s = mx == 0 ? 0 : (mx - mn) / mx;
            if (mx <= 0.15 || s <= 0.25) continue; // greys and near-black say nothing about the color
            double d = mx - mn, hue = mx == r ? (g - b) / d : mx == g ? 2 + (b - r) / d : 4 + (r - g) / d;
            hue = (hue / 6) % 1; if (hue < 0) hue += 1;
            int bin = Math.Min(11, (int)(hue * 12)); double wt = s * mx;
            bins[bin] = (bins[bin].W + wt, bins[bin].R + r * wt, bins[bin].G + g * wt, bins[bin].B + b * wt);
        }
        return bins.Where(x => x.W > 0.5).OrderByDescending(x => x.W).Take(3).Select(x => Glowing(x.R / x.W, x.G / x.W, x.B / x.W)).ToArray();
    }
    static Color Glowing(double r, double g, double b)
    {
        double mx = Math.Max(r, Math.Max(g, b)), mn = Math.Min(r, Math.Min(g, b)), d = mx - mn;
        double hue = d == 0 ? 0 : mx == r ? ((g - b) / d + 6) % 6 : mx == g ? (b - r) / d + 2 : (r - g) / d + 4;
        double s = Math.Max(mx == 0 ? 0 : d / mx, 0.55), v = Math.Max(mx, 0.9), c = v * s, x = c * (1 - Math.Abs(hue % 2 - 1)), m = v - c;
        var (r1, g1, b1) = (int)hue switch { 0 => (c, x, 0.0), 1 => (x, c, 0.0), 2 => (0.0, c, x), 3 => (0.0, x, c), 4 => (x, 0.0, c), _ => (c, 0.0, x) };
        return Color.FromRgb((byte)((r1 + m) * 255), (byte)((g1 + m) * 255), (byte)((b1 + m) * 255));
    }
    void UsePalette(Color[] found)
    {
        palette = [found.Length > 0 ? found[0] : Fallback[0], found.Length > 1 ? found[1] : found.Length > 0 ? found[0] : Fallback[1], found.Length > 2 ? found[2] : Fallback[2]];
        playGlow.BeginAnimation(DropShadowEffect.ColorProperty, new ColorAnimation(palette[0], TimeSpan.FromSeconds(1.2)));
        foreach (var (stop, slot, alpha) in tinted)
        {
            var c = palette[slot];
            stop.BeginAnimation(GradientStop.ColorProperty, new ColorAnimation(Color.FromArgb((byte)(alpha * 255), c.R, c.G, c.B), TimeSpan.FromSeconds(1.2)));
        }
    }
    void ShowArt(BitmapSource? art, string forFile)
    {
        foreach (var img in new[] { cover, barThumb, queueThumb }) { img.Source = art ?? JT.Image("jt-logo"); img.Stretch = art is null ? Stretch.Uniform : Stretch.UniformToFill; }
        if (art is null) { UsePalette([]); return; }
        void Use() { if (artFor == forFile) try { UsePalette(Hues(art)); } catch (Exception) { UsePalette([]); } }
        if (art is BitmapImage { IsDownloading: true } web) { web.DownloadCompleted += (_, _) => Use(); web.DownloadFailed += (_, _) => UsePalette([]); }
        else Use();
    }

    // MARK: Updates

    static List<Song> Mine() => Store.Shared.Songs.Where(s => s.Owned && Listen.FileFor(s.I) is not null).ToList();

    /// The library changed: the era lists, the songs panel and the empty note.
    public void Refresh()
    {
        var mine = Mine();
        empty.Visibility = mine.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        updating = true;
        var eras = mine.Select(s => s.Era).Distinct().ToList();
        var picked = eraPick.SelectedItem as string ?? "All eras";
        eraPick.Items.Clear(); eraPick.Items.Add("All eras"); foreach (var e in eras) eraPick.Items.Add(e);
        eraPick.SelectedItem = eras.Contains(picked) ? picked : "All eras";
        updating = false;
        if (songsPanel.Visibility == Visibility.Visible) BuildRows();
        upNextKey = null; Tick();
    }

    void ToggleSongs()
    {
        bool open = songsPanel.Visibility != Visibility.Visible;
        songsPanel.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        ((TextBlock)search.Content).Text = open ? "" : "";
        UI.AutomationName(search, open ? "Close your songs" : "Your songs");
        if (open) { BuildRows(); UI.FadeIn(songsPanel); find.Focus(); }
    }

    ContextMenu EraMenu()
    {
        var m = new ContextMenu(); var current = Store.Shared.Me.AmbientEra;
        void Item(string label, string era) { var i = new MenuItem { Header = label, IsCheckable = true, IsChecked = current == era }; i.Click += (_, _) => Player.Shared.SetEra(era); m.Items.Add(i); }
        Item("All eras", ""); m.Items.Add(new Separator());
        foreach (var e in Player.Shared.Eras) Item(e, e);
        return m;
    }

    void BuildRows()
    {
        var p = Player.Shared; var q = find.Text.Trim().ToLowerInvariant(); var picked = eraPick.SelectedItem as string ?? "All eras";
        var shown = Mine().Where(s => (picked == "All eras" || s.Era == picked) && (q.Length == 0 || s.Name.ToLowerInvariant().Contains(q))).ToList();
        eraButtons.Children.Clear();
        if (picked != "All eras")
        {
            var inEra = shown.OrderBy(s => Engine.RecordMonth(s.S.RecordDates) ?? int.MaxValue).ThenBy(s => s.Name).Select(s => s.I).ToList();
            eraButtons.Children.Add(UI.Row(10, UI.Button($"Play {picked} in order", () => Listen.PlayInOrder(inEra), ""), UI.Button($"Shuffle {picked}", () => p.SetEra(picked), "")));
        }
        rows.Children.Clear();
        foreach (var s in shown.Take(limit))
        {
            var f = Listen.FileFor(s.I)!; bool on = string.Equals(f, p.CurrentFile, StringComparison.OrdinalIgnoreCase);
            var row = new DockPanel { Background = Brushes.Transparent, ToolTip = "Double-click to play" };
            var tools = UI.Row(4, UI.IconButton("", $"Play {s.Name}", () => p.PlaySong(f, s.Name), 12), UI.IconButton("", $"Play {s.Name} next", () => Listen.PlayNext(s), 12));
            DockPanel.SetDock(tools, Dock.Right); row.Children.Add(tools);
            var text = UI.Column(1, UI.Text(s.Name, 14, on ? JT.Lavender : JT.Mist));
            if (picked == "All eras") text.Children.Add(UI.Text(s.Era, 12, JT.Muted));
            row.Children.Add(UI.Row(10, UI.Icon(on ? "" : "", 13, on ? JT.Lavender : JT.Muted), text));
            row.MouseLeftButtonDown += (_, e) => { if (e.ClickCount == 2) p.PlaySong(f, s.Name); };
            rows.Children.Add(new Border { Padding = new Thickness(8, 6, 8, 6), BorderBrush = JT.Brush(JT.Line), BorderThickness = new Thickness(0, 0, 0, 1), Child = row });
        }
        if (shown.Count == 0) rows.Children.Add(UI.Muted("No songs match.", 13));
        if (shown.Count > limit) rows.Children.Add(UI.Link($"Show {Math.Min(250, shown.Count - limit)} more", () => { limit += 250; BuildRows(); }, 13).Also(l => l.Margin = new Thickness(0, 8, 0, 0)));
    }

    void Toggle()
    {
        var p = Player.Shared;
        if (p.CurrentFile is null && !Store.Shared.Me.AmbientOn) p.SetOn(true); else p.TogglePause();
    }

    string? SongId => Player.Shared.CurrentFile is { } f && Store.Shared.SongForFile(f) is var i and >= 0 ? Store.Shared.Catalog[i].Id : null;
    void Love() { if (SongId is { } id) Store.Shared.SetRating(id, Store.Shared.Me.Ratings.ContainsKey(id) ? 0 : 5); }

    /// The parts that move with the music.
    async void Tick()
    {
        var p = Player.Shared; var store = Store.Shared;
        updating = true;
        ((TextBlock)play.Content).Text = p.IsPlaying ? "" : "";
        UI.AutomationName(play, p.IsPlaying ? "Pause" : "Play");
        var dur = p.Duration.TotalSeconds;
        progress.Width = dur > 0 && progressTrack.ActualWidth > 0 ? progressTrack.ActualWidth * Math.Min(1, p.Position.TotalSeconds / dur) : 0;
        if (!volume.IsMouseCaptureWithin) volume.Value = p.Volume;
        ((TextBlock)repeat.Content).Foreground = JT.Brush(store.Me.InOrder ? JT.Lavender : JT.Mist);
        var loved = SongId is { } id && store.Me.Ratings.ContainsKey(id);
        ((TextBlock)heart.Content).Text = loved ? "" : ""; ((TextBlock)heart.Content).Foreground = JT.Brush(loved ? JT.Missing : JT.Mist);
        UI.AutomationName(heart, loved ? "Clear the rating" : "Rate 5 hearts"); heart.IsEnabled = SongId is not null;
        updating = false;

        var key = $"{p.Title}\n{store.Me.AmbientEra}\n" + string.Join("\n", p.UpNext.Select(x => x.Title));
        if (key != upNextKey) { upNextKey = key; DrawQueue(); }

        if (p.CurrentFile != file)
        {
            file = p.CurrentFile; synced = []; line = -2; lit = -1; artFor = file;
            if (file is not null) Wave();
            var i = file is null ? -1 : store.SongForFile(file);
            var era = i >= 0 ? Engine.EraName(store.Catalog[i]) : "Juice WRLD";
            cardTitle.Text = barTitle.Text = p.Title ?? "Nothing playing"; cardEra.Text = barEra.Text = era;
            ShowArt(null, file ?? "");
            var playing = file;
            // lyrics and the era's art come live from the site, never saved
            if (i >= 0 && await store.DetailsAsync(store.Catalog[i]) is { } json && playing == file)
            {
                synced = Listen.ParseSynced(json["synced_lyrics"]?.GetValue<string>() ?? "");
                if (json["image_url"]?.GetValue<string>() is { Length: > 0 } img && Uri.TryCreate(new Uri("https://juicewrldapi.com"), img, out var url))
                    try { ShowArt(new BitmapImage(url), playing ?? ""); } catch (Exception) { }
            }
            line = -2;
        }
        Karaoke(p.Position.TotalSeconds);
    }

    /// The line being sung, its words lighting up as the song gets to them. Shown live from the site, never saved.
    void Karaoke(double at)
    {
        int n = synced.FindLastIndex(x => x.At <= at + 0.15);
        if (n < 0)
        {
            if (line == n && lit == -1) return;
            line = n; lit = -1; karaoke.Inlines.Clear();
            if (Player.Shared.CurrentFile is null) karaoke.Inlines.Add(new System.Windows.Documents.Run("Press play") { Foreground = JT.Brush(Color.FromArgb(128, 255, 255, 255)) });
            return;
        }
        double start = synced[n].At, end = n + 1 < synced.Count ? synced[n + 1].At : start + 4;
        var words = synced[n].Line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        int on = (int)Math.Ceiling(words.Length * Math.Clamp((at - start) / Math.Max(0.5, (end - start) * 0.85), 0, 1));
        if (n == line && on == lit) return;
        if (n != line) karaoke.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.3)));
        line = n; lit = on; karaoke.Inlines.Clear();
        if (words.Length == 0) { karaoke.Inlines.Add(new System.Windows.Documents.Run("♪")); return; }
        for (int k = 0; k < words.Length; k++)
            karaoke.Inlines.Add(new System.Windows.Documents.Run((k == 0 ? "" : " ") + words[k])
            {
                // the word being sung right now takes the song's color
                Foreground = k == on - 1 && on < words.Length ? JT.Brush(palette[0]) : k < on ? Brushes.White : JT.Brush(Color.FromArgb(71, 255, 255, 255)),
            });
    }

    /// The song playing, then Up next. Click plays one now; right-click to move it or take it out.
    void DrawQueue()
    {
        var p = Player.Shared; var store = Store.Shared;
        queue.Children.Clear();
        queueSub.Text = p.UpNext.Count > 0 ? $"{p.UpNext.Count} up next" : store.Me.AmbientEra.Length == 0 ? "Shuffle after this" : $"{store.Me.AmbientEra} after this";
        if (queueThumb.Parent is Border old) old.Child = null; // the thumb and its note move into the rebuilt head
        if (queueSub.Parent is Panel holder) holder.Children.Remove(queueSub);
        var head = UI.Row(8, Thumb(queueThumb, 30), UI.Column(0, UI.Text("Queue", 14, weight: FontWeights.Bold), queueSub));
        head.Margin = new Thickness(0, 0, 0, 8); queue.Children.Add(head);
        if (p.Title is { } t)
            queue.Children.Add(new Border
            {
                Padding = new Thickness(6), CornerRadius = new CornerRadius(9), Background = JT.Brush(Color.FromArgb(36, 255, 255, 255)),
                BorderBrush = JT.Brush(Color.FromArgb(153, 255, 255, 255)), BorderThickness = new Thickness(1.5), Margin = new Thickness(0, 0, 0, 4),
                Child = Row(t, cardEra.Text),
            });
        for (int k = 0; k < Math.Min(8, p.UpNext.Count); k++)
        {
            int n = k; var item = p.UpNext[k];
            var row = new Border { Padding = new Thickness(6, 3, 6, 3), Background = Brushes.Transparent, Cursor = Cursors.Hand, Child = Row(item.Title, "Up next"), ToolTip = "Click to play now" };
            row.MouseLeftButtonUp += (_, _) => { p.RemoveUpNext(n); p.PlaySong(item.File, item.Title); };
            var menu = new ContextMenu();
            void Add(string label, Action act, bool enabled = true) { var i = new MenuItem { Header = label, IsEnabled = enabled }; i.Click += (_, _) => act(); menu.Items.Add(i); }
            Add("Play now", () => { p.RemoveUpNext(n); p.PlaySong(item.File, item.Title); });
            Add("Move up", () => p.MoveUpNext(n, -1), n > 0);
            Add("Move down", () => p.MoveUpNext(n, 1), n < p.UpNext.Count - 1);
            menu.Items.Add(new Separator());
            Add("Remove from queue", () => p.RemoveUpNext(n));
            row.ContextMenu = menu;
            queue.Children.Add(row);
        }
        if (p.UpNext.Count > 8) queue.Children.Add(UI.Text($"+{p.UpNext.Count - 8} more", 11, JT.Muted).Also(x => x.Margin = new Thickness(6, 2, 0, 0)));
        if (p.UpNext.Count > 0) queue.Children.Add(UI.Link("Clear", p.ClearUpNext, 11).Also(x => { x.HorizontalAlignment = HorizontalAlignment.Left; x.Margin = new Thickness(6, 4, 0, 0); }));
    }
    static FrameworkElement Row(string title, string sub)
    {
        var t = UI.Text(title, 12, weight: FontWeights.SemiBold); t.TextTrimming = TextTrimming.CharacterEllipsis;
        var s = UI.Text(sub, 10, JT.Muted); s.TextTrimming = TextTrimming.CharacterEllipsis;
        return UI.Row(8, new Border { Width = 26, Height = 26, CornerRadius = new CornerRadius(5), Background = JT.Brush(Color.FromArgb(30, 255, 255, 255)), Child = UI.Icon("", 11, JT.Muted) },
                      UI.Column(0, t, s));
    }

    // MARK: Icons swirling around the hole, faster with the beat

    static readonly string[] SwirlArt = ["jt-heart", "jt-era-999", "jt-fly", "jt-sparkles", "jt-sticker1", "jt-sticker2", "jt-sticker3", "jt-sticker4",
                                         "jt-sticker5", "jt-sticker6", "jt-era-halo", "jt-era-race", "jt-era-demon", "jt-era-globe", "jt-planet", "jt-heart"];

    /// Little icons circling the hole on tilted orbits that pass around it, never across it.
    void Swirl(double size, Point c)
    {
        swirl.Children.Clear(); swirlClocks.Clear();
        var rng = new Random(999);
        for (int k = 0; k < SwirlArt.Length; k++)
        {
            double side = 20 + rng.NextDouble() * 20, rx = size * (0.85 + rng.NextDouble() * 0.65), ry = size * (0.6 + rng.NextDouble() * 0.22);
            var holder = new Canvas { IsHitTestVisible = false };
            var spin = new RotateTransform(0, side / 2, side / 2);
            var icon = new Image { Source = JT.Image(SwirlArt[k]), Width = side, Height = side, Opacity = 0.7 + rng.NextDouble() * 0.3, RenderTransform = spin,
                                   Effect = new DropShadowEffect { Color = Colors.White, BlurRadius = 8, ShadowDepth = 0, Opacity = 0.5 } };
            Canvas.SetLeft(icon, -side / 2); Canvas.SetTop(icon, -side / 2);
            holder.Children.Add(icon);
            // a third go the other way round
            var orbit = new EllipseGeometry(c, rx, ry) { Transform = new TransformGroup { Children = { new ScaleTransform(k % 3 == 0 ? -1 : 1, 1, c.X, c.Y), new RotateTransform((rng.NextDouble() - 0.5) * 23, c.X, c.Y) } } };
            var move = new MatrixTransform(); holder.RenderTransform = move;
            double seconds = 26 + rng.NextDouble() * 30;
            var go = new MatrixAnimationUsingPath { PathGeometry = PathGeometry.CreateFromGeometry(orbit), Duration = TimeSpan.FromSeconds(seconds), RepeatBehavior = RepeatBehavior.Forever,
                                                    BeginTime = TimeSpan.FromSeconds(-rng.NextDouble() * seconds) }; // spread around the orbit
            var twirl = new DoubleAnimation(0, k % 2 == 0 ? 360 : -360, TimeSpan.FromSeconds(9 + rng.NextDouble() * 9)) { RepeatBehavior = RepeatBehavior.Forever };
            var a = go.CreateClock(); var b = twirl.CreateClock();
            move.ApplyAnimationClock(MatrixTransform.MatrixProperty, a); spin.ApplyAnimationClock(RotateTransform.AngleProperty, b);
            swirlClocks.Add(a); swirlClocks.Add(b);
            swirl.Children.Add(holder);
        }
        pace = 1;
    }

    /// Louder means faster: the swirl runs up to four times as fast on a strong beat, easing back between.
    void Pace(double level)
    {
        double target = 1 + level * 3, next = pace + (target - pace) * (target > pace ? 0.5 : 0.12); // quick to jump, slow to settle
        if (Math.Abs(next - pace) < 0.02) return;
        pace = next;
        foreach (var c in swirlClocks) if (c.Controller is { } ctl) ctl.SpeedRatio = pace;
    }

    /// Measures the music's loudness where it's playing, from the same file, about 12 times a second.
    void Hear()
    {
        if (measuring || !IsLoaded) return;
        var p = Player.Shared;
        if (!p.IsPlaying || p.CurrentFile is not { } f) { Pace(0); return; }
        measuring = true; var at = p.Position;
        Task.Run(() => meter.Level(f, at)).ContinueWith(t => { measuring = false; Pace(t.Result); }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    /// Faint doodles drifting slowly across the sky: hearts, butterflies, stickers, 999s, a planet.
    void Doodles()
    {
        foreach (var old in sky.Children.OfType<Image>().Where(i => "doodle".Equals(i.Tag)).ToList()) sky.Children.Remove(old);
        double w = sky.ActualWidth, h = sky.ActualHeight;
        if (w == 0) return;
        var rng = new Random(2019);
        string[] art = ["jt-heart", "jt-fly", "jt-sparkles", "jt-sticker1", "jt-sticker2", "jt-sticker3", "jt-sticker4", "jt-sticker5",
                        "jt-sticker6", "jt-era-999", "jt-planet", "jt-era-vinyl", "jt-era-mic", "jt-era-party", "jt-fly", "jt-heart", "jt-sparkles", "jt-era-globe"];
        foreach (var name in art)
        {
            double side = 28 + rng.NextDouble() * 46;
            var move = new TranslateTransform(); var turn = new RotateTransform();
            var bit = new Image { Source = JT.Image(name), Width = side, Height = side, Opacity = 0.1 + rng.NextDouble() * 0.16, Tag = "doodle", IsHitTestVisible = false,
                                  RenderTransform = new TransformGroup { Children = { turn, move } }, RenderTransformOrigin = new Point(0.5, 0.5) };
            At(bit, rng.NextDouble() * w, rng.NextDouble() * h);
            var drift = TimeSpan.FromSeconds(30 + rng.NextDouble() * 40);
            move.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(0, (rng.NextDouble() - 0.5) * 240, drift) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase() });
            move.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, (rng.NextDouble() - 0.5) * 160, drift) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase() });
            turn.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(-23, 23, TimeSpan.FromSeconds(14 + rng.NextDouble() * 16)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase() });
            sky.Children.Insert(0, bit); // behind the twinkling stars
        }
    }
}

/// The loudness of a file at a point in it (0...1), read with its own reader so the player is untouched.
sealed class LevelMeter
{
    readonly object gate = new();
    NAudio.Wave.MediaFoundationReader? reader; NAudio.Wave.ISampleProvider? samples; string? file;
    readonly float[] buffer = new float[2048];

    public double Level(string path, TimeSpan at)
    {
        lock (gate)
        {
            try
            {
                if (path != file)
                {
                    reader?.Dispose(); reader = null; file = path;
                    reader = new NAudio.Wave.MediaFoundationReader(path);
                    samples = NAudio.Wave.WaveExtensionMethods.ToSampleProvider(reader);
                }
                if (reader is null || samples is null || at >= reader.TotalTime) return 0;
                reader.CurrentTime = at;
                int n = samples.Read(buffer, 0, buffer.Length);
                double sum = 0; for (int k = 0; k < n; k++) sum += buffer[k] * buffer[k];
                double db = 20 * Math.Log10(Math.Max(Math.Sqrt(sum / Math.Max(n, 1)), 1e-6));
                return Math.Clamp((db + 50) / 50, 0, 1); // the same scale as the Mac app's meter
            }
            catch (Exception) { reader?.Dispose(); reader = null; samples = null; return 0; }
        }
    }
}
