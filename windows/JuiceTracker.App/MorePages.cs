using System.Windows;

namespace JuiceTracker.App;

/// The screens beyond the library tools.
public static partial class MorePages
{
    static readonly HashSet<Page> Built = [Page.Player, Page.Hunt, Page.Playlists, Page.Stats];
    public static bool Has(Page p) => Built.Contains(p) || Extra.ContainsKey(p);
    public static FrameworkElement? Make(Page p) => p switch
    {
        Page.Player => new PlayerPage(), Page.Hunt => new HuntPage(), Page.Playlists => new PlaylistsPage(), Page.Stats => new StatsPage(),
        _ => Extra.TryGetValue(p, out var make) ? make() : null,
    };
    /// Screens added by the last stage (Credits, Timeline, Badges, Trivia).
    static readonly Dictionary<Page, Func<FrameworkElement>> Extra = [];
}
