using System.Windows;

namespace JuiceTracker.App;

/// The screens beyond the library tools (Hunt, Playlists, Credits, Stats, Timeline, Badges, Trivia).
public static partial class MorePages
{
    public static bool Has(Page p) => p is Page.Hunt or Page.Playlists or Page.Credits or Page.Stats or Page.Timeline or Page.Badges or Page.Trivia && Make(p) is not null;
    public static FrameworkElement? Make(Page p) => null;
}
