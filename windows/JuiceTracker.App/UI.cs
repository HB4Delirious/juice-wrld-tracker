using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;

namespace JuiceTracker.App;

/// Small builders for the screens, so each screen reads like the Mac app's SwiftUI.
public static class UI
{
    public static TextBlock Text(string s, double size = 15, Color? color = null, FontWeight? weight = null, bool wrap = false) => new()
    {
        Text = s, FontSize = size, Foreground = JT.Brush(color ?? JT.Mist), FontWeight = weight ?? FontWeights.Normal,
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
    };
    public static TextBlock Muted(string s, double size = 13, bool wrap = true) => Text(s, size, JT.Muted, wrap: wrap);
    public static TextBlock Marker(string s, double size) => new() { Text = s, FontFamily = JT.Marker, FontSize = size, Foreground = JT.Brush(JT.Mist) };
    public static TextBlock Icon(string glyph, double size = 15, Color? color = null) => new()
    {
        Text = glyph, FontFamily = JT.Icons, FontSize = size, Foreground = JT.Brush(color ?? JT.Mist), VerticalAlignment = VerticalAlignment.Center,
    };

    /// A page title: marker lettering, tilted a touch, with the rainbow squiggle drawing in underneath.
    public static FrameworkElement Title(string s, double size = 40)
    {
        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Left, RenderTransform = new RotateTransform(-1) };
        stack.Children.Add(Marker(s, size));
        var squiggle = new Image { Source = JT.Image("jt-squiggle"), Width = size * 3, Height = size * 0.27, Stretch = Stretch.Fill, HorizontalAlignment = HorizontalAlignment.Left };
        var clip = new RectangleGeometry(new Rect(0, 0, 0, size * 0.27));
        squiggle.Clip = clip;
        clip.BeginAnimation(RectangleGeometry.RectProperty, new RectAnimation(new Rect(0, 0, 0, size * 0.27), new Rect(0, 0, size * 3, size * 0.27), TimeSpan.FromSeconds(0.8))
        { BeginTime = TimeSpan.FromSeconds(0.15), EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut } });
        stack.Children.Add(squiggle);
        return stack;
    }

    /// A frosted panel with a hand-drawn outline.
    public static DoodleBorder Panel(UIElement child, int seed = 0, double pad = 16, Color? stroke = null) =>
        new() { Child = child, Seed = seed, Padding = new Thickness(pad), Stroke = JT.Brush(stroke ?? JT.Line2) };

    public static Button Button(string label, Action click, string? icon = null, bool big = false)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal };
        if (icon is not null) content.Children.Add(new TextBlock { Text = icon, FontFamily = JT.Icons, FontSize = big ? 15 : 13, Margin = new Thickness(0, 0, 7, 0), VerticalAlignment = VerticalAlignment.Center });
        content.Children.Add(new TextBlock { Text = label, FontSize = big ? 15 : 13.5, VerticalAlignment = VerticalAlignment.Center });
        var b = new Button { Content = content, Padding = big ? new Thickness(16, 8, 16, 8) : new Thickness(12, 5, 12, 5) };
        b.Click += (_, _) => click();
        AutomationName(b, label);
        return b;
    }
    public static Button Link(string label, Action click, double size = 14)
    {
        var b = new Button { Content = new TextBlock { Text = label, FontSize = size, Foreground = JT.Brush(JT.Lavender) }, Style = (Style)Application.Current.FindResource("Link") };
        b.Click += (_, _) => click();
        return b;
    }
    /// A button that's just an icon, with a name for screen readers and a tooltip.
    public static Button IconButton(string glyph, string name, Action click, double size = 14, Color? color = null)
    {
        var b = new Button { Content = Icon(glyph, size, color), Style = (Style)Application.Current.FindResource("Plain"), ToolTip = name, Padding = new Thickness(2) };
        b.Click += (_, _) => click();
        AutomationName(b, name);
        return b;
    }
    public static void AutomationName(UIElement e, string name) => System.Windows.Automation.AutomationProperties.SetName(e, name);

    public static StackPanel Row(double spacing, params UIElement[] items)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal };
        for (int i = 0; i < items.Length; i++)
        {
            if (items[i] is FrameworkElement fe) { fe.VerticalAlignment = VerticalAlignment.Center; if (i > 0) fe.Margin = new Thickness(spacing, fe.Margin.Top, fe.Margin.Right, fe.Margin.Bottom); }
            p.Children.Add(items[i]);
        }
        return p;
    }
    public static StackPanel Column(double spacing, params UIElement[] items)
    {
        var p = new StackPanel();
        for (int i = 0; i < items.Length; i++)
        {
            if (i > 0 && items[i] is FrameworkElement fe) fe.Margin = new Thickness(fe.Margin.Left, spacing, fe.Margin.Right, fe.Margin.Bottom);
            p.Children.Add(items[i]);
        }
        return p;
    }

    /// A thin bar that fills to a fraction, growing in when it appears.
    public static FrameworkElement Bar(double fraction, Brush fill, double height = 4, double delay = 0)
    {
        var track = new Grid { Height = height };
        track.Children.Add(new Border { Background = JT.Brush(JT.Line), CornerRadius = new CornerRadius(height / 2) });
        var bar = new Border { Background = fill, CornerRadius = new CornerRadius(height / 2), HorizontalAlignment = HorizontalAlignment.Left, RenderTransformOrigin = new Point(0, 0.5) };
        var scale = new ScaleTransform(0, 1); bar.RenderTransform = scale;
        track.Children.Add(bar);
        track.SizeChanged += (_, e) => bar.Width = Math.Max(fraction > 0 ? height : 0, e.NewSize.Width * Math.Clamp(fraction, 0, 1));
        scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.9)) { BeginTime = TimeSpan.FromSeconds(delay), EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut } });
        return track;
    }

    public static Effect Glow(Color c, double radius = 14, double opacity = 0.45) => new DropShadowEffect { Color = c, BlurRadius = radius * 2, ShadowDepth = 0, Opacity = opacity };

    /// Fades a new screen in and lifts it a little (the Mac app's page transition).
    public static void FadeIn(FrameworkElement e)
    {
        e.Opacity = 0;
        var t = new TranslateTransform(0, 16); e.RenderTransform = t;
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        e.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.3)) { EasingFunction = ease });
        t.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(16, 0, TimeSpan.FromSeconds(0.38)) { EasingFunction = ease });
    }
}
