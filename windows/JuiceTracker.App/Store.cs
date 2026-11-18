using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;

namespace JuiceTracker.App;

/// A song as the screens show it: the catalog song plus whether you have it and whether it's on your wishlist.
public sealed record Song(int I, EngineSong S, bool Owned, bool Wished)
{
    public string Name => S.Name;
    public string Era => Engine.EraName(S);
    public string Category => Engine.Capital(S.Category);
    public string Length => S.Length;
    public bool HasFile => S.FilePath.Length > 0;
}

/// Everything the app knows and does: the catalog (12-hour cache), your saved data, the music folder (scan, tag
/// cache, matching), downloads and tag writes. Ported from the Mac app's EngineState, EngineLibrary, EngineDownloads
/// and EngineFixer. Lives on the UI thread; slow work runs on the thread pool and comes back here.
public sealed partial class Store
{
    public static Store Shared { get; } = new();
    public event Action? Changed;
    public int Version { get; private set; }

    public static string DataDir { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "JuiceTracker");
    static string FilePath(string name) => Path.Combine(DataDir, name);
    static readonly JsonSerializerOptions Json = new(Engine.Json) { WriteIndented = false };

    // The catalog
    public List<EngineSong> Catalog { get; private set; } = [];
    public Dictionary<string, EraInfo> Eras { get; private set; } = [];
    public DateTime? FetchedAt { get; private set; }
    public bool LoadingCatalog { get; private set; }
    public string CatalogStatus { get; private set; } = "";
    public const double CacheHours = 12;
    sealed class Saved
    {
        public List<string>? KnownIds { get; set; }
        public Dictionary<string, int>? ReleaseSnap { get; set; }
        public List<string> NewIds { get; set; } = [];
        public List<string> ReleasedIds { get; set; } = [];
        public DateTime? PrevCheck { get; set; }
        public DateTime? LastCheck { get; set; }
        public bool? FirstCheck { get; set; }
    }
    Saved saved = new();
    sealed record CatalogFile(DateTime FetchedAt, List<EngineSong> Songs, Dictionary<string, EraInfo> Eras);

    // Your saved data (personal.json)
    public sealed class Personal
    {
        public Dictionary<string, string> Wish { get; set; } = [];          // song id → when added (ISO)
        public Dictionary<string, string> Notes { get; set; } = [];
        public Dictionary<string, int> Ratings { get; set; } = [];
        public Dictionary<string, string> MatchOverrides { get; set; } = []; // path → song id, or "none"
        public List<string>? FixFields { get; set; }
        public bool FixBlanks { get; set; }
        public bool AutoTag { get; set; } = true;
        public string FixGenre { get; set; } = "";
        public string? BackupDir { get; set; }
        public string? MusicFolder { get; set; }
        public bool OnlyJuice { get; set; } = true;
        public bool AmbientOn { get; set; }
        public string AmbientEra { get; set; } = "";
        public double Volume { get; set; } = 6;
        // later stages
        public List<Playlist> Playlists { get; set; } = [];
        public List<string> WishOrder { get; set; } = [];
        public Dictionary<string, int> Trivia { get; set; } = [];
        public Dictionary<string, string> Opened { get; set; } = [];
        public Dictionary<string, string> Downloaded { get; set; } = [];
        public string? Inbox { get; set; }
        public string OrganizePattern { get; set; } = "{era}/{song}";
        public double Crossfade { get; set; } = 4;
        public bool MatchVolume { get; set; } = true;
        public bool InOrder { get; set; }
        public bool DailyCheck { get; set; } = true;
        public bool AutoUpdate { get; set; } = true;
        public string? SkippedVersion { get; set; }
        public string Theme { get; set; } = "cosmic";
        public string CustomAccent { get; set; } = "ff6ad5";
        public string CustomSky1 { get; set; } = "d6308c";
        public string CustomSky2 { get; set; } = "5082ff";
        public bool Compact { get; set; }
        public bool Chime { get; set; }
        public bool TaskbarProgress { get; set; } = true;
        public bool DiscordOn { get; set; }
        public string DiscordAppId { get; set; } = "";
        public string? PlexServer { get; set; }
        public bool KeepRunning { get; set; }
        public string? LiveServer { get; set; }
        public bool WordleDaily { get; set; } = true;
        public string WordleEra { get; set; } = "";
        public string WordleSaved { get; set; } = "";     // today's daily round: "date|era|GUESS,GUESS"
        public string WordleStats { get; set; } = "0,0,0,0"; // daily rounds: played, won, streak, best
        public string WordleCounted { get; set; } = "";   // the last daily round counted in the stats
        public List<TierList> TierLists { get; set; } = [];
        public string TierListPick { get; set; } = "";
        public bool HeardleDaily { get; set; } = true;
        public string HeardleEra { get; set; } = "";
        public bool HeardleIntro { get; set; } = true;
        public string HeardleSaved { get; set; } = "";     // today's daily round: "date|era|intro|id,id,-" (- is a skip)
        public string HeardleStats { get; set; } = "0,0,0,0"; // daily rounds: played, won, streak, best
        public string HeardleCounted { get; set; } = "";
        public List<string> Widgets { get; set; } = [];    // desktop widgets that are on: clock, playing, upnext, edge
        public Dictionary<string, double[]> WidgetSpots { get; set; } = []; // where each widget was left (left, top)
        public List<string> WidgetLocked { get; set; } = []; // widgets that stay put when dragged
        public string WidgetPlaylist { get; set; } = "";   // the playlist widget's playlist id, or "" for liked songs
        public string EdgeColor { get; set; } = "";        // the edge light's color as hex, or "" for the cover's
        public string LyricStyle { get; set; } = "line";   // the Player's lyrics: "line" (word by word) or "list" (scrolling)
        public bool LyricBlur { get; set; } = true;        // blur the lines not being sung (list style)
        public bool FadePause { get; set; } = true;        // fade the music when pausing and resuming
        public bool AskQuitPlaying { get; set; }           // ask before quitting while a song plays
        public bool TimelineWeeks { get; set; }            // Stats' listening timeline by week instead of by day
        public string PlayerStyle { get; set; } = "hole";  // the Player's look: hole, rings, bars or disc
        public Dictionary<string, string> Shortcuts { get; set; } = []; // action → "modifiers|key" (WPF enum numbers)
        public bool ShortcutsGlobal { get; set; }          // shortcuts also work while another app is in front
    }
    public sealed record Playlist(string Id, string Name, List<string> Songs);
    public Personal Me { get; private set; } = new();
    public List<string> FixFields => Me.FixFields ?? ["title", "artist", "albumartist", "album", "year", "producer"];
    public string Genre => Me.FixGenre.Trim().Length > 0 ? Me.FixGenre.Trim() : Engine.DefaultGenre;

    // The music folder
    public string? Root { get; private set; }
    public List<LibraryFile> Files { get; private set; } = [];
    public Engine.Match Match { get; private set; } = new();
    public Engine.Layout Layout { get; private set; } = new();
    public bool Scanning { get; private set; }
    public string FolderStatus { get; private set; } = "";
    Dictionary<string, Engine.CachedTags> cache = [];
    public HashSet<int> Owned => Match.Owned.Keys.ToHashSet();

    // What the screens show
    public List<Song> Songs { get; private set; } = [];
    public List<Engine.EraStat> EraList { get; private set; } = [];
    public List<(string Name, int Have, int Total)> Cats { get; private set; } = [];
    public List<(string Head, List<int> Songs, int More)> Today { get; private set; } = [];
    public List<(string Text, bool Released)> Notices { get; private set; } = [];
    public HashSet<int> Fresh { get; private set; } = [];
    public HashSet<int> NowReleased { get; private set; } = [];
    public bool Ready => Catalog.Count > 0 && Root is not null;

    public void Notify() { Version++; Changed?.Invoke(); }
    void OnUi(Action a) { if (Application.Current?.Dispatcher is { } d && !d.CheckAccess()) d.Invoke(a); else a(); }

    // MARK: Starting up

    /// For the smoke test (App --smoke-test): a made-up library of 60 songs in four eras, some owned and some dated
    /// today, so every screen is drawn with data in it. Nothing is read from or written to disk.
    internal void FillForSmokeTest()
    {
        string[] eras = ["DRFL", "GB&GR", "LND", "WOD"];
        Catalog = Enumerable.Range(0, 60).Select(i => new EngineSong
        {
            Id = $"{i}", Name = i % 10 == 0 ? $"Song {i / 10} (v2)" : $"Song {i}", Era = eras[i % 4], Category = i % 3 == 0 ? "released" : "unreleased",
            Length = "3:00", RecordDates = $"{DateTime.Now:MMMM d}, {2015 + i % 5}", FilePath = i % 2 == 0 ? $"Juice WRLD/Song {i}.mp3" : "",
            Producers = "Nick Mira & Dre Moon", Alt = i % 7 == 0 ? [$"Alt {i}"] : [],
        }).ToList();
        Eras = new() { ["DRFL"] = new(1, "Death Race For Love", "2018 - 2019"), ["GB&GR"] = new(2, "Goodbye & Good Riddance", "2017 - 2018"), ["LND"] = new(3, "Legends Never Die", "2020") };
        Root = Path.Combine(Path.GetTempPath(), "JT Smoke");
        Files = Enumerable.Range(0, 25).Select(i =>
        {
            var tags = new Dictionary<string, string> { ["title"] = $"Song {i}", ["artist"] = "Juice WRLD" };
            return new LibraryFile($"JT Smoke/GB&GR/Song {i}.mp3", "mp3", tags, $"Song {i}", Engine.Normalize($"Song {i}"), $"song {i}", true, 4_000_000);
        }).ToList();
        saved = new Saved { FirstCheck = true, NewIds = ["3", "5"], ReleasedIds = ["9"] };
        Me.Wish["2"] = DateTime.UtcNow.ToString("o"); Me.Ratings["4"] = 5;
        FolderStatus = "25 Juice WRLD files found.";
        Rematch();
    }

    public async Task StartAsync()
    {
        // Off the UI thread: the catalog and tag cache are megabytes, and a sleeping network drive can take seconds to
        // say whether the music folder is there. Done on the UI thread, the window froze at every launch.
        var (me, sv, cf, tags, q) = await Task.Run(() =>
        {
            Directory.CreateDirectory(DataDir);
            return (Read<Personal>("personal.json") ?? new(), Read<Saved>("saved.json") ?? new(), Read<CatalogFile>("catalog.json"),
                    Read<Dictionary<string, Engine.CachedTags>>("tags.json") ?? [], Read<List<QueueItem>>("queue.json") ?? []);
        });
        Me = me;
        Themes.Apply(); MainWindow.Current?.Restyle();
        DesktopWidgets.Apply(); // the widgets you had on
        saved = sv;
        if (cf is not null) { Catalog = cf.Songs; Eras = cf.Eras; FetchedAt = cf.FetchedAt; }
        cache = tags; queue = q;
        loaded = true;
        if (Me.MusicFolder is { } folder && await Task.Run(() => Directory.Exists(folder)))
        {
            Root = folder;
            Files = await Task.Run(() => (Read<List<string>>("items.json") ?? []).Where(tags.ContainsKey).Select(p => LibraryFile(p, tags[p])).OfType<LibraryFile>()
                                                .OrderBy(f => f.Path, StringComparer.CurrentCultureIgnoreCase).ToList());
        }
        Rebuild();
        if (Catalog.Count > 0 && (FetchedAt is null || (DateTime.UtcNow - FetchedAt.Value).TotalHours > CacheHours)) _ = ReloadCatalogAsync();
        if (Root is not null) await ScanAsync(reread: false);
        RunQueue();
        WatchInbox();
    }

    T? Read<T>(string name) where T : class
    {
        try { return File.Exists(FilePath(name)) ? JsonSerializer.Deserialize<T>(File.ReadAllText(FilePath(name)), Json) : null; }
        catch (Exception) { return null; }
    }
    /// Saved atomically: written next to the old copy, then swapped in, so a crash never leaves half a file.
    /// Set once the saved files are read. Until then nothing is written: saving the blank defaults at launch would
    /// replace your wishlist, notes and ratings.
    static bool loaded;
    static void Write<T>(string name, T value)
    {
        if (!loaded) return;
        Directory.CreateDirectory(DataDir);
        var tmp = FilePath(name + ".tmp");
        File.WriteAllText(tmp, JsonSerializer.Serialize(value, Json));
        File.Move(tmp, FilePath(name), true);
    }
    public void SavePersonal() { Write("personal.json", Me); Rebuild(); }

    // MARK: The catalog

    /// Downloads the catalog, notes which songs are new or newly released since the last time, and saves it.
    /// Names of the songs added to the catalog at the last check (for the tray menu).
    public List<string> NewSongNames { get { var n = saved.NewIds.ToHashSet(); return Catalog.Where(s => n.Contains(s.Id)).Select(s => s.Name).ToList(); } }
    /// Wished songs that were released or got a file at the last check (for the alert).
    public List<string> WishedReleasedNames { get { var r = saved.ReleasedIds.Concat(saved.NewIds).ToHashSet(); return Catalog.Where(s => r.Contains(s.Id) && Me.Wish.ContainsKey(s.Id)).Select(s => s.Name).ToList(); } }
    public event Action? CatalogChecked;
    /// Songs saved by a finished download run (confetti, the chime, a Plex rescan).
    public event Action<int>? Landed;

    public async Task ReloadCatalogAsync()
    {
        if (LoadingCatalog) return;
        LoadingCatalog = true; CatalogStatus = "Connecting to juicewrldapi.com…"; Notify();
        try
        {
            var fetched = await Engine.FetchCatalogAsync((n, total) => OnUi(() =>
            {
                CatalogStatus = total is { } t ? $"Loaded {n:N0} of {t:N0} songs…" : $"Loaded {n:N0} songs…";
                Notify();
            }));
            var songs = fetched.Songs; var now = DateTime.UtcNow;
            var ids = songs.Select(s => s.Id).ToList();
            var snap = new Dictionary<string, int>(); foreach (var s in songs) snap.TryAdd(s.Id, Engine.IsReleased(s) ? 1 : 0);
            if (saved.KnownIds is { } known)
            {
                var k = known.ToHashSet();
                saved.NewIds = ids.Where(id => !k.Contains(id)).ToList(); saved.PrevCheck = saved.LastCheck; saved.FirstCheck = false;
            }
            else { saved.NewIds = []; saved.PrevCheck = null; saved.FirstCheck = true; }
            saved.ReleasedIds = saved.ReleaseSnap is { } old ? songs.Where(s => old.GetValueOrDefault(s.Id, -1) == 0 && snap[s.Id] == 1).Select(s => s.Id).ToList() : [];
            saved.ReleaseSnap = snap; saved.KnownIds = ids; saved.LastCheck = now;
            Write("saved.json", saved);
            Catalog = songs; Eras = fetched.Eras; FetchedAt = now;
            Write("catalog.json", new CatalogFile(now, songs, fetched.Eras));
            CatalogStatus = $"{songs.Count:N0} songs loaded.";
            Rematch();
            CatalogChecked?.Invoke();
        }
        catch (Exception e) { CatalogStatus = $"{e.Message} Try again in a minute."; }
        finally { LoadingCatalog = false; Notify(); }
    }

    // MARK: The music folder

    public async Task UseFolderAsync(string folder)
    {
        Root = folder; Me.MusicFolder = folder; Files = []; Write("personal.json", Me);
        await ScanAsync(reread: false);
    }

    /// Lists the folder, reads new or changed files' tags (cached ones are reused), and matches them to songs.
    public async Task ScanAsync(bool reread)
    {
        if (Root is not { } root || Scanning) return;
        Scanning = true; // before the wait below, so a second scan can't start meanwhile
        if (!await Task.Run(() => Directory.Exists(root))) // a sleeping network drive can take seconds to answer
        {
            Scanning = false; FolderStatus = $"Your music folder ({root}) isn't available. If it's on a network drive, reconnect it."; Notify(); return;
        }
        FolderStatus = "Looking through your music folder…"; Notify();
        try
        {
            // a file changed since its tags were cached (size or date) is read again
            var fresh = new Dictionary<string, Engine.CachedTags>(cache);
            // checking every cached file's size and date means a network round trip each: off the UI thread
            var valid = await Task.Run(() => Valid(root, fresh));
            var result = await Engine.ScanAsync(root, Me.OnlyJuice, valid, reread, (n, total) => OnUi(() => { FolderStatus = $"Reading {n:N0} of {total:N0} files…"; Notify(); }));
            foreach (var (k, v) in result.Fresh) cache[k] = v;
            var present = result.Paths.ToHashSet();
            foreach (var k in cache.Keys.Where(k => !present.Contains(k)).ToList()) cache.Remove(k);
            Write("tags.json", cache); Write("items.json", result.Paths);
            Files = result.Files;
            FolderStatus = $"{Files.Count:N0} Juice WRLD files found out of {result.AudioCount:N0} audio files.";
            Rematch();
        }
        catch (Exception e) { FolderStatus = $"Couldn't read the folder: {e.Message}"; }
        finally { Scanning = false; Notify(); }
    }
    static Dictionary<string, Engine.CachedTags> Valid(string root, Dictionary<string, Engine.CachedTags> c)
    {
        var parent = Path.GetDirectoryName(root.TrimEnd('\\', '/')) ?? root;
        var output = new Dictionary<string, Engine.CachedTags>();
        foreach (var (path, tags) in c)
        {
            var file = new FileInfo(Path.Combine(parent, path.Replace('/', Path.DirectorySeparatorChar)));
            if (file.Exists && file.Length == tags.Size && Math.Abs(new DateTimeOffset(file.LastWriteTimeUtc).ToUnixTimeMilliseconds() - tags.Mtime) < 2000) output[path] = tags;
        }
        return output;
    }

    LibraryFile? LibraryFile(string path, Engine.CachedTags c)
    {
        if (Me.OnlyJuice && !Engine.CountsAsJuice(path, c.Tags)) return null;
        var title = c.Tags.GetValueOrDefault("title", "") is { Length: > 0 } t ? t : Engine.TitleFromFilename(path);
        return new LibraryFile(path, Engine.ExtOf(path), c.Tags, title, Engine.Normalize(title), Engine.StemOf(path), c.Tags.GetValueOrDefault("title", "").Length > 0, c.Size);
    }

    /// Where a library file is on disk (library paths start with the music folder's own name).
    public string? FullPath(string path)
    {
        if (Root is not { } root) return null;
        var inner = string.Join(Path.DirectorySeparatorChar, path.Split('/').Skip(1));
        var full = Path.GetFullPath(Path.Combine(root, inner));
        return full.StartsWith(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ? full : null;
    }

    /// A file written or downloaded here: into the cache and the library, and matched again.
    public void UpdateFile(string path, Dictionary<string, string> tags, long size)
    {
        cache[path] = new Engine.CachedTags(size, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), tags);
        if (FullPath(path) is { } full && File.Exists(full)) cache[path] = cache[path] with { Mtime = new DateTimeOffset(File.GetLastWriteTimeUtc(full)).ToUnixTimeMilliseconds() };
        Write("tags.json", cache);
        var items = Read<List<string>>("items.json") ?? [];
        if (!items.Contains(path)) { items.Add(path); Write("items.json", items); }
        if (LibraryFile(path, cache[path]) is { } f)
        {
            var n = Files.FindIndex(x => x.Path == path);
            if (n >= 0) Files[n] = f; else { Files.Add(f); Files = Files.OrderBy(x => x.Path, StringComparer.CurrentCultureIgnoreCase).ToList(); }
        }
        Rematch();
    }

    public void SetOverride(string path, string? songId)
    {
        if (songId is null) Me.MatchOverrides.Remove(path); else Me.MatchOverrides[path] = songId;
        Write("personal.json", Me);
        Rematch();
    }

    public void Rematch()
    {
        Match = Engine.MatchFiles(Catalog, Files, Me.MatchOverrides);
        Layout = Engine.LearnLayout(Catalog, Files, Match);
        Rebuild();
        Player.Shared.Sync();
    }

    // MARK: What the screens show

    public void Rebuild()
    {
        var owned = Owned;
        Songs = Catalog.Select((s, i) => new Song(i, s, owned.Contains(i), Me.Wish.ContainsKey(s.Id))).ToList();
        var catOrder = new List<string>(); var cats = new Dictionary<string, (int Have, int Total)>();
        for (int i = 0; i < Catalog.Count; i++)
        {
            var c = Catalog[i].Category;
            if (!cats.ContainsKey(c)) { catOrder.Add(c); cats[c] = (0, 0); }
            cats[c] = (cats[c].Have + (owned.Contains(i) ? 1 : 0), cats[c].Total + 1);
        }
        Cats = catOrder.Select((c, n) => (c, n)).OrderByDescending(x => cats[x.c].Total).ThenBy(x => x.n).Select(x => (Engine.Capital(x.c), cats[x.c].Have, cats[x.c].Total)).ToList();
        EraList = Engine.EraStats(Catalog, owned, Eras);
        var newIds = saved.NewIds.ToHashSet(); var relIds = saved.ReleasedIds.ToHashSet();
        Fresh = Enumerable.Range(0, Catalog.Count).Where(i => newIds.Contains(Catalog[i].Id)).ToHashSet();
        NowReleased = Enumerable.Range(0, Catalog.Count).Where(i => relIds.Contains(Catalog[i].Id)).ToHashSet();
        Notices = BuildNotices();
        Today = BuildToday(DateTime.Now);
        Notify();
    }

    List<(string, bool)> BuildNotices()
    {
        var output = new List<(string, bool)>();
        var since = saved.PrevCheck is { } p ? $" since your last check on {p.ToLocalTime():MMM d}" : "";
        var released = saved.ReleasedIds.ToHashSet(); var names = Catalog.Where(s => released.Contains(s.Id)).Select(s => s.Name).ToList();
        if (names.Count > 0)
            output.Add(($"Now officially released{since}: {string.Join(", ", names.Take(4))}{(names.Count > 4 ? $", and {names.Count - 4:N0} more" : "")}.", true));
        if (saved.NewIds.Count > 0) output.Add(($"{saved.NewIds.Count:N0} {(saved.NewIds.Count == 1 ? "song was" : "songs were")} added to the catalog{since}.", false));
        if (saved.FirstCheck == true) output.Add(("This is your first check. Next time you load the catalog, newly added songs and songs that get officially released will be flagged here.", false));
        else if (saved.PrevCheck is not null && saved.NewIds.Count == 0 && released.Count == 0) output.Add(($"No new songs or releases{since}.", false));
        return output;
    }

    /// Songs recorded, previewed, surfaced or released on today's date in other years (up to 14 names).
    List<(string, List<int>, int)> BuildToday(DateTime now)
    {
        int m = now.Month - 1, d = now.Day;
        var groups = new SortedDictionary<string, List<int>>(StringComparer.Ordinal);
        for (int i = 0; i < Catalog.Count; i++)
        {
            var s = Catalog[i];
            foreach (var (text, label) in new[] { (s.RecordDates, "Recorded"), (s.PreviewDate, "Previewed"), (s.LeakDate, "Surfaced"), (s.Release, "Released") })
                foreach (var x in Engine.DatesIn(text).Where(x => x.M == m && x.D == d))
                {
                    var key = $"{x.Y}|{label}";
                    if (!groups.TryGetValue(key, out var l)) groups[key] = l = [];
                    if (!l.Contains(i)) l.Add(i);
                }
        }
        int shown = 0; var rows = new List<(string, List<int>, int)>();
        foreach (var (key, set) in groups)
        {
            if (shown >= 14) break;
            var parts = key.Split('|'); var list = set.Take(14 - shown).ToList();
            shown += list.Count;
            rows.Add(($"{parts[1]} in {parts[0]}:", list, set.Count - list.Count));
        }
        return rows;
    }

    // MARK: Wishlist, notes and ratings

    public void ToggleWish(string id) { if (!Me.Wish.Remove(id)) Me.Wish[id] = DateTime.UtcNow.ToString("o"); SavePersonal(); }
    public void SetNote(string id, string text) { if (text.Trim().Length == 0) Me.Notes.Remove(id); else Me.Notes[id] = text; Write("personal.json", Me); }
    public void SetRating(string id, int hearts) { if (hearts <= 0) Me.Ratings.Remove(id); else Me.Ratings[id] = Math.Min(hearts, 5); SavePersonal(); }

    // MARK: Song details (fetched from the site on first open)

    readonly Dictionary<string, JsonObject> details = [];
    public async Task<JsonObject?> DetailsAsync(EngineSong s)
    {
        if (details.TryGetValue(s.Id, out var hit)) return hit;
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
            var json = JsonNode.Parse(await http.GetStringAsync($"https://juicewrldapi.com/juicewrld/songs/{s.Id}/")) as JsonObject;
            if (json is not null) details[s.Id] = json;
            return json;
        }
        catch (Exception) { return null; }
    }

    // MARK: Downloads (one at a time; failed songs go to the back of the line, 3 tries)

    public sealed record QueueItem(string Id, int Tries = 0);
    List<QueueItem> queue = [];
    public (int Done, int Total, string Current, bool Waiting)? Job { get; private set; }
    bool running, stopping;
    public string DownloadNote { get; private set; } = "";

    public int AddDownloads(IEnumerable<string> ids)
    {
        int added = 0;
        foreach (var id in ids) if (!queue.Any(q => q.Id == id)) { queue.Add(new QueueItem(id)); added++; }
        Write("queue.json", queue);
        if (Job is { } j) Job = j with { Total = j.Total + added };
        RunQueue();
        Notify();
        return added;
    }
    public void StopDownloads() { if (running) stopping = true; }

    async void RunQueue()
    {
        if (running || Root is null || Catalog.Count == 0 || queue.Count == 0) return;
        running = true; stopping = false;
        int done = 0, saved = 0; var failed = new List<string>();
        Job = (0, queue.Count, "", false); Notify();
        while (!stopping && queue.Count > 0)
        {
            var item = queue[0];
            int i = Catalog.FindIndex(s => s.Id == item.Id);
            if (i < 0 || Catalog[i].FilePath.Length == 0) { queue.RemoveAt(0); Write("queue.json", queue); done++; continue; }
            Job = (done, Job!.Value.Total, Catalog[i].Name, false); Notify();
            try
            {
                var r = await DownloadSongAsync(i);
                if (!r.Existed) saved++;
                if (r.Note.Length > 0) failed.Add($"{Catalog[i].Name} ({r.Note})");
                queue.RemoveAll(q => q.Id == item.Id); Write("queue.json", queue);
                done++;
            }
            catch (Exception e)
            {
                if (e.Message.Contains("isn't available")) // the music drive dropped: wait for it
                {
                    Job = Job!.Value with { Waiting = true }; Notify();
                    for (int s = 0; s < 30 && !stopping; s++) await Task.Delay(1000);
                    continue;
                }
                queue.RemoveAll(q => q.Id == item.Id);
                if (item.Tries + 1 >= 3) { failed.Add($"{Catalog[i].Name} ({e.Message})"); done++; }
                else queue.Add(item with { Tries = item.Tries + 1 }); // back of the line
                Write("queue.json", queue);
                if (item.Tries + 1 < 3) await Task.Delay(4000 * (item.Tries + 1));
            }
            Job = Job!.Value with { Done = done }; Notify();
        }
        if (stopping) { queue = []; Write("queue.json", queue); }
        DownloadNote = saved > 0 ? $"Saved {saved:N0} {(saved == 1 ? "song" : "songs")}." + (failed.Count > 0 ? $" {failed.Count} didn't work: {string.Join("; ", failed.Take(3))}." : "") : failed.Count > 0 ? $"Couldn't download {string.Join("; ", failed.Take(3))}." : "";
        Job = null; running = false; Notify();
        if (saved > 0) { Landed?.Invoke(saved); Plex.ScheduleRefresh(); }
    }

    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(10) };

    /// Saves one song into the folder its era's songs live in, adds it to the library and auto-tags it. Downloads to a
    /// temporary file and moves it into place only when complete; never overwrites, never leaves the music folder.
    public async Task<(bool Existed, string Note)> DownloadSongAsync(int i)
    {
        var song = Catalog[i];
        if (Root is not { } root) throw new EngineError("Choose your music folder first");
        var url = Engine.FileUrl(song);
        if (!url.StartsWith("https://juicewrldapi.com/juicewrld/files/download")) throw new EngineError("Only song files from juicewrldapi.com can be downloaded.");
        var rel = $"{Engine.SaveFolder(song, Layout)}/{Engine.SaveFileName(song)}";
        if (FullPath(rel) is not { } dest) throw new EngineError("can't be saved there");
        if (!Engine.AudioExts.Contains(Engine.ExtOf(dest))) throw new EngineError("Only audio files can be saved there.");
        if (!Directory.Exists(root)) throw new EngineError($"Your music folder ({root}) isn't available. If it's on a network drive, reconnect it and try again.");
        if (File.Exists(dest)) return (true, "");
        var tmp = Path.Combine(Path.GetTempPath(), $"jt-{Guid.NewGuid():N}.part");
        try
        {
            using (var r = await Http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead))
            {
                if (!r.IsSuccessStatusCode) throw new EngineError($"juicewrldapi.com answered {(int)r.StatusCode}.");
                var type = r.Content.Headers.ContentType?.MediaType?.ToLowerInvariant() ?? "";
                if (!type.StartsWith("audio/") && type != "application/octet-stream") throw new EngineError("juicewrldapi.com didn't send an audio file.");
                await using var fs = File.Create(tmp);
                await r.Content.CopyToAsync(fs);
            }
            Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
            if (File.Exists(dest)) return (true, "");
            File.Move(tmp, dest);
        }
        finally { if (File.Exists(tmp)) File.Delete(tmp); }
        // We know exactly which song this file is: a hand match, so it counts once and can be tagged.
        Me.MatchOverrides[rel] = song.Id; Write("personal.json", Me);
        var tags = await Task.Run(() => TagReader.Read(dest, Engine.ExtOf(rel)));
        UpdateFile(rel, tags, new FileInfo(dest).Length);
        var note = await AutoTagAsync(rel, i);
        return (false, note);
    }

    // MARK: The tag fixer

    /// After a download: tag it with the fixer's settings (when auto-tagging is on). Returns a note if it failed.
    /// `inbox`: a file from the inbox folder, tagged even when auto-tag is off and before the library lists it (with
    /// the artist always, so the library counts it as a Juice WRLD file).
    public async Task<string> AutoTagAsync(string path, int song, Dictionary<string, string>? inbox = null)
    {
        if ((!Me.AutoTag && inbox is null) || !Engine.EditableExts.Contains(Engine.ExtOf(path))) return "";
        if ((inbox ?? Files.FirstOrDefault(f => f.Path == path)?.Tags) is not { } current) return "";
        var fields = inbox is null || FixFields.Contains("artist") ? FixFields : [.. FixFields, "artist"];
        var it = Engine.FixFor(current, Catalog[song], fields, Me.FixBlanks, Genre);
        if (it.Changes.Count == 0) return "";
        try { await WriteTagsAsync(path, it.Desired); return ""; }
        catch (Exception e) { return $"Its tags weren't updated: {e.Message}."; }
    }

    /// Rewrites one file's tags: build the new file in memory, run the safety check, back up the original (when a
    /// backup folder is set), save it atomically, read the tags back.
    public async Task WriteTagsAsync(string path, Dictionary<string, string> desired)
    {
        if (FullPath(path) is not { } full) throw new EngineError("isn't in your music folder");
        var ext = Engine.ExtOf(path);
        string? backup = Me.BackupDir is { } dir ? Path.Combine([dir, .. path.Split('/').Skip(1)]) : null;
        var (tags, size) = await Task.Run(() =>
        {
            var orig = File.ReadAllBytes(full);
            var output = TagWriter.Write(orig, ext, desired);
            if (backup is not null && !(File.Exists(backup) && new FileInfo(backup).Length > 0)) // the first backup is kept forever
            {
                Directory.CreateDirectory(Path.GetDirectoryName(backup)!);
                File.WriteAllBytes(backup, orig);
            }
            var tmp = full + ".jt-tmp";
            File.WriteAllBytes(tmp, output);
            File.Move(tmp, full, true);
            return (TagReader.Read(full, ext), (long)output.Length);
        });
        UpdateFile(path, tags, size);
    }
}
