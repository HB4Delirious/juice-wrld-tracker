using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;

namespace JuiceTracker.App;

/// The Mac app's look: its colors, fonts and hand-drawn outlines (NativeUI.swift `JT`).
public static class JT
{
    static Color C(byte r, byte g, byte b, double a = 1) => Color.FromArgb((byte)Math.Round(a * 255), r, g, b);
    public static readonly Color Night = C(10, 6, 24), Mist = C(255, 246, 251), Muted = C(195, 178, 227);
    public static readonly Color Dusk = C(24, 12, 52, 0.82), Raise = C(58, 30, 108, 0.82), Line = C(190, 150, 255, 0.2), Line2 = C(210, 170, 255, 0.38);
    public static readonly Color Lavender = C(255, 106, 213), LavenderHi = C(255, 148, 226);
    public static readonly Color Have = C(201, 242, 74), New = C(255, 160, 74), Missing = C(255, 93, 108), Gold = C(255, 217, 77);
    public static readonly Color[] Rainbow = [C(255, 93, 108), C(255, 160, 74), C(255, 225, 74), C(201, 242, 74), C(79, 216, 255), C(106, 168, 255), C(183, 123, 255), C(255, 106, 213)];
    public static readonly Color[] Count = [C(255, 160, 74), C(255, 225, 74), C(201, 242, 74), C(79, 216, 255), C(255, 106, 213)];

    public static SolidColorBrush Brush(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }
    public static LinearGradientBrush Gradient(Color[] colors, bool vertical = false)
    {
        var g = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = vertical ? new Point(0, 1) : new Point(1, 0) };
        for (int i = 0; i < colors.Length; i++) g.GradientStops.Add(new GradientStop(colors[i], colors.Length == 1 ? 0 : (double)i / (colors.Length - 1)));
        g.Freeze();
        return g;
    }
    public static readonly FontFamily Marker = new(new Uri("pack://application:,,,/"), "./Assets/Fonts/#Permanent Marker");
    public static readonly FontFamily Body = new(new Uri("pack://application:,,,/"), "./Assets/Fonts/#Figtree");
    /// Windows' own icon font (the Mac app uses SF Symbols).
    public static readonly FontFamily Icons = new("Segoe Fluent Icons, Segoe MDL2 Assets");
    public static BitmapImage Image(string name)
    {
        var b = new BitmapImage(new Uri($"pack://application:,,,/Assets/{name}.png"));
        b.Freeze();
        return b;
    }
}

/// A rounded box drawn by hand: each corner a different size, each side bowing a little (DoodleRect in the Mac app).
public class DoodleBorder : Decorator
{
    public static readonly DependencyProperty SeedProperty = DependencyProperty.Register(nameof(Seed), typeof(int), typeof(DoodleBorder), new FrameworkPropertyMetadata(0, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty StrokeProperty = DependencyProperty.Register(nameof(Stroke), typeof(Brush), typeof(DoodleBorder), new FrameworkPropertyMetadata(JT.Brush(JT.Line2), FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty FillProperty = DependencyProperty.Register(nameof(Fill), typeof(Brush), typeof(DoodleBorder), new FrameworkPropertyMetadata(JT.Brush(JT.Dusk), FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty PaddingProperty = DependencyProperty.Register(nameof(Padding), typeof(Thickness), typeof(DoodleBorder), new FrameworkPropertyMetadata(new Thickness(0), FrameworkPropertyMetadataOptions.AffectsMeasure));
    public int Seed { get => (int)GetValue(SeedProperty); set => SetValue(SeedProperty, value); }
    public Brush Stroke { get => (Brush)GetValue(StrokeProperty); set => SetValue(StrokeProperty, value); }
    public Brush Fill { get => (Brush)GetValue(FillProperty); set => SetValue(FillProperty, value); }
    public Thickness Padding { get => (Thickness)GetValue(PaddingProperty); set => SetValue(PaddingProperty, value); }

    public static Geometry Shape(Rect r, int seed)
    {
        double[][] shapes = [[20, 30, 18, 26], [14, 22, 12, 20], [22, 15, 20, 17], [26, 18, 24, 16]];
        double scale = Math.Min(1, Math.Min(r.Width, r.Height) / 90);
        var c = shapes[Math.Abs(seed) % 4].Select(x => Math.Min(x * scale, Math.Min(r.Width, r.Height) / 2)).ToArray();
        double[] bows = [1.4, -1.1, 1.2, -1.3];
        var b = Enumerable.Range(0, 4).Select(i => bows[(i + Math.Abs(seed)) % 4]).ToArray();
        // WPF's y grows downward like SwiftUI's, so the Mac path carries over as is.
        double minX = r.Left, minY = r.Top, maxX = r.Right, maxY = r.Bottom, midX = (minX + maxX) / 2, midY = (minY + maxY) / 2;
        var g = new StreamGeometry();
        using (var ctx = g.Open())
        {
            ctx.BeginFigure(new Point(minX + c[0], minY), true, true);
            ctx.QuadraticBezierTo(new Point(midX, minY + b[0]), new Point(maxX - c[1], minY), true, true);
            ctx.QuadraticBezierTo(new Point(maxX, minY), new Point(maxX, minY + c[1]), true, true);
            ctx.QuadraticBezierTo(new Point(maxX + b[1], midY), new Point(maxX, maxY - c[2]), true, true);
            ctx.QuadraticBezierTo(new Point(maxX, maxY), new Point(maxX - c[2], maxY), true, true);
            ctx.QuadraticBezierTo(new Point(midX, maxY + b[2]), new Point(minX + c[3], maxY), true, true);
            ctx.QuadraticBezierTo(new Point(minX, maxY), new Point(minX, maxY - c[3]), true, true);
            ctx.QuadraticBezierTo(new Point(minX + b[3], midY), new Point(minX, minY + c[0]), true, true);
            ctx.QuadraticBezierTo(new Point(minX, minY), new Point(minX + c[0], minY), true, true);
        }
        g.Freeze();
        return g;
    }

    protected override Size MeasureOverride(Size available)
    {
        var p = Padding;
        if (Child is null) return new Size(p.Left + p.Right, p.Top + p.Bottom);
        Child.Measure(new Size(Math.Max(0, available.Width - p.Left - p.Right), Math.Max(0, available.Height - p.Top - p.Bottom)));
        return new Size(Child.DesiredSize.Width + p.Left + p.Right, Child.DesiredSize.Height + p.Top + p.Bottom);
    }
    protected override Size ArrangeOverride(Size size)
    {
        var p = Padding;
        Child?.Arrange(new Rect(p.Left, p.Top, Math.Max(0, size.Width - p.Left - p.Right), Math.Max(0, size.Height - p.Top - p.Bottom)));
        return size;
    }
    protected override void OnRender(DrawingContext dc)
    {
        var geo = Shape(new Rect(0.8, 0.8, Math.Max(0, ActualWidth - 1.6), Math.Max(0, ActualHeight - 1.6)), Seed);
        dc.DrawGeometry(Fill, new Pen(Stroke, 1.6), geo);
    }
}

/// The night sky, drawn once and animated by WPF's compositor (the Mac app does the same with Core Animation):
/// a gradient, four nebula glows that breathe, two star fields drifting at different speeds, the faint tattoo-flash
/// doodles, the Juice tattoo flash, twinkling sparkles and a shooting star. A soft pink glow pulses with the music.
public sealed class Sky : Canvas
{
    readonly Rectangle glow = new() { IsHitTestVisible = false, Opacity = 0 };
    Size builtFor;
    public static Sky? Current { get; private set; }

    public Sky()
    {
        ClipToBounds = true;
        Background = JT.Brush(JT.Night);
        SizeChanged += (_, e) => { if (Math.Abs(e.NewSize.Width - builtFor.Width) > 40 || Math.Abs(e.NewSize.Height - builtFor.Height) > 40) Build(e.NewSize); };
        Current = this;
    }

    /// Brightens the glow with the music's loudness (0...1).
    public void SetGlow(double level) => glow.Opacity = level * 0.55;

    void Build(Size b)
    {
        builtFor = b;
        Children.Clear();
        Add(new Rectangle
        {
            Width = b.Width, Height = b.Height,
            Fill = new LinearGradientBrush(new GradientStopCollection
            {
                new(Color.FromRgb(42, 12, 62), 0), new(Color.FromRgb(22, 10, 51), 0.45), new(Color.FromRgb(7, 4, 15), 1),
            }, new Point(0, 0), new Point(0, 1)),
        }, 0, 0);

        // nebula glows that breathe slowly
        (double X, double Y, double S, Color C)[] glows =
            [(0.52, 0.34, 0.42, Color.FromArgb(77, 232, 110, 70)), (0.06, 0.70, 0.50, Color.FromArgb(107, 214, 48, 140)),
             (0.88, 0.14, 0.45, Color.FromArgb(82, 80, 130, 255)), (0.70, 0.90, 0.60, Color.FromArgb(92, 140, 40, 190))];
        for (int n = 0; n < glows.Length; n++)
        {
            var g = glows[n]; double size = Math.Max(b.Width, b.Height) * g.S;
            var e = new Ellipse
            {
                Width = size, Height = size, IsHitTestVisible = false,
                Fill = new RadialGradientBrush(g.C, Color.FromArgb(0, g.C.R, g.C.G, g.C.B)),
                RenderTransformOrigin = new Point(0.5, 0.5),
            };
            var t = new TransformGroup(); var sc = new ScaleTransform(); var tr = new TranslateTransform(); t.Children.Add(sc); t.Children.Add(tr);
            e.RenderTransform = t;
            Add(e, b.Width * g.X - size / 2, b.Height * g.Y - size / 2);
            var secs = TimeSpan.FromSeconds(40 + n * 6);
            Loop(sc, ScaleTransform.ScaleXProperty, 1, 1.12, secs, true); Loop(sc, ScaleTransform.ScaleYProperty, 1, 1.12, secs, true);
            Loop(tr, TranslateTransform.XProperty, 0, n % 2 == 0 ? -30 : 30, secs, true); Loop(tr, TranslateTransform.YProperty, 0, -18, secs, true);
        }

        // two star fields drifting at different speeds; each moves exactly one tile per loop, so it's seamless
        StarField(b, 420, 70, 7, 260, 0.8);
        StarField(b, 690, 55, 21, 190, 1);
        Drifting(b, JT.Image("jt-flash"), 560, -1, 1, 150, 1);           // faint tattoo-flash doodles
        var sparkles = Tiled(b, JT.Image("jt-sparkles"), 520, 0, 0);     // twinkling sparkles
        Loop(sparkles, OpacityProperty, 0.15, 1, TimeSpan.FromSeconds(3.8), true);
        Drifting(b, JT.Image("jt-juiceflash"), 640, 1, -1, 220, 1);       // the Juice tattoo flash, slower and the other way

        // the glow that pulses with the music
        glow.Width = b.Width * 0.9; glow.Height = b.Height * 0.9;
        glow.Fill = new RadialGradientBrush(Color.FromArgb(89, JT.Lavender.R, JT.Lavender.G, JT.Lavender.B), Color.FromArgb(0, JT.Lavender.R, JT.Lavender.G, JT.Lavender.B));
        Add(glow, b.Width * 0.2, b.Height * 0.3);

        ShootingStar(b);
    }

    void Add(UIElement e, double x, double y) { SetLeft(e, x); SetTop(e, y); Children.Add(e); }

    static void Loop(DependencyObject target, DependencyProperty p, double from, double to, TimeSpan secs, bool reverse)
    {
        var a = new DoubleAnimation(from, to, secs) { AutoReverse = reverse, RepeatBehavior = RepeatBehavior.Forever };
        if (reverse) a.EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut };
        if (target is Animatable an) an.BeginAnimation(p, a);
        else if (target is UIElement u) u.BeginAnimation(p, a);
    }

    Canvas Tiled(Size b, ImageSource img, double tile, double extraX, double extraY)
    {
        var c = new Canvas { IsHitTestVisible = false, Width = b.Width + tile, Height = b.Height + tile };
        c.Background = new ImageBrush(img) { TileMode = TileMode.Tile, Viewport = new Rect(0, 0, tile, tile), ViewportUnits = BrushMappingMode.Absolute, Stretch = Stretch.Fill };
        Add(c, extraX, extraY);
        return c;
    }
    void Drifting(Size b, ImageSource img, double tile, int dx, int dy, double seconds, double opacity)
    {
        var c = Tiled(b, img, tile, dx < 0 ? 0 : -tile, dy < 0 ? 0 : -tile);
        c.Opacity = opacity;
        var tr = new TranslateTransform(); c.RenderTransform = tr;
        var dur = TimeSpan.FromSeconds(seconds);
        tr.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(0, dx * tile, dur) { RepeatBehavior = RepeatBehavior.Forever });
        tr.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, dy * tile, dur) { RepeatBehavior = RepeatBehavior.Forever });
    }
    void StarField(Size b, double tile, int count, ulong seed, double seconds, double alpha)
    {
        var state = seed;
        double Rand() { state = state * 6364136223846793005UL + 1442695040888963407UL; return (state >> 33) % 10_000 / 10_000.0; }
        var dg = new DrawingGroup();
        using (var dc = dg.Open())
        {
            dc.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, tile, tile));
            for (int i = 0; i < count; i++)
            {
                double r = 0.4 + Rand() * 0.9;
                var brush = new SolidColorBrush(Color.FromArgb((byte)(255 * alpha * (0.4 + Rand() * 0.6)), 255, 255, 255));
                dc.DrawEllipse(brush, null, new Point(Rand() * tile, Rand() * tile), r, r);
            }
        }
        dg.Freeze();
        var img = new DrawingImage(dg); img.Freeze();
        Drifting(b, img, tile, -1, 0, seconds, 1);
    }
    void ShootingStar(Size b)
    {
        var streak = new Rectangle
        {
            Width = 170, Height = 2, RadiusX = 1, RadiusY = 1, Opacity = 0, IsHitTestVisible = false,
            Fill = new LinearGradientBrush(Color.FromArgb(0, 255, 255, 255), Color.FromArgb(242, 255, 255, 255), 0),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { Color = Colors.White, BlurRadius = 8, ShadowDepth = 0, Opacity = 0.9 },
            RenderTransform = new RotateTransform(20),
        };
        Add(streak, 0, 0);
        var move = new TranslateTransform();
        streak.RenderTransform = new TransformGroup { Children = { new RotateTransform(20), move } };
        var sb = new Storyboard { RepeatBehavior = RepeatBehavior.Forever, Duration = TimeSpan.FromSeconds(14), BeginTime = TimeSpan.FromSeconds(3) };
        var x = new DoubleAnimationUsingKeyFrames();
        x.KeyFrames.Add(new LinearDoubleKeyFrame(-b.Width * 0.1, KeyTime.FromTimeSpan(TimeSpan.Zero)));
        x.KeyFrames.Add(new LinearDoubleKeyFrame(b.Width * 0.6, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.84))));
        var y = new DoubleAnimationUsingKeyFrames();
        y.KeyFrames.Add(new LinearDoubleKeyFrame(b.Height * 0.1, KeyTime.FromTimeSpan(TimeSpan.Zero)));
        y.KeyFrames.Add(new LinearDoubleKeyFrame(b.Height * 0.1 + b.Width * 0.26, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.84))));
        var fade = new DoubleAnimationUsingKeyFrames();
        fade.KeyFrames.Add(new LinearDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.Zero)));
        fade.KeyFrames.Add(new LinearDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.14))));
        fade.KeyFrames.Add(new LinearDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.84))));
        Storyboard.SetTarget(x, streak); Storyboard.SetTargetProperty(x, new PropertyPath("RenderTransform.Children[1].X"));
        Storyboard.SetTarget(y, streak); Storyboard.SetTargetProperty(y, new PropertyPath("RenderTransform.Children[1].Y"));
        Storyboard.SetTarget(fade, streak); Storyboard.SetTargetProperty(fade, new PropertyPath(OpacityProperty));
        sb.Children.Add(x); sb.Children.Add(y); sb.Children.Add(fade);
        sb.Begin();
    }
}
