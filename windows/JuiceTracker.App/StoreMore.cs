using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using NAudio.Wave;

namespace JuiceTracker.App;

/// The rest of what the store does (stages 2-4): the Recycle Bin, moving files, the inbox, file health, cover art,
/// backups, the spreadsheet, drive compare, play history, playlists and the wishlist order.
public sealed partial class Store
{
    // MARK: The Recycle Bin (files are never deleted outright)

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEOPSTRUCT { public IntPtr hwnd; public uint wFunc; public string pFrom; public string? pTo; public ushort fFlags; public bool fAnyOperationsAborted; public IntPtr hNameMappings; public string? lpszProgressTitle; }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHFileOperation(ref SHFILEOPSTRUCT op);

    /// Moves a file to the Recycle Bin, where you can restore it.
    public static void Recycle(string file)
    {
        if (!File.Exists(file)) throw new EngineError("isn't there any more");
        var op = new SHFILEOPSTRUCT { wFunc = 3 /* delete */, pFrom = file + "\0\0", fFlags = 0x0040 | 0x0010 | 0x0004 | 0x0400 /* undo, no confirm, silent, no error UI */ };
        if (SHFileOperation(ref op) != 0 || op.fAnyOperationsAborted || File.Exists(file)) throw new EngineError("couldn't be moved to the Recycle Bin");
    }
    public async Task RecycleAsync(string path)
    {
        if (FullPath(path) is not { } full) throw new EngineError("That file isn't in your music folder");
        await Task.Run(() => Recycle(full));
        RemoveFiles([path]);
    }

    /// Files gone from the library (moved to the Recycle Bin, or not there any more).
    public void RemoveFiles(IEnumerable<string> paths)
    {
        var gone = paths.ToHashSet();
        if (gone.Count == 0) return;
        Files.RemoveAll(f => gone.Contains(f.Path));
        foreach (var p in gone) cache.Remove(p);
        Write("tags.json", cache);
        Write("items.json", (Read<List<string>>("items.json") ?? []).Where(p => !gone.Contains(p)).ToList());
        Rematch();
    }

    // MARK: Moving files (the organizer, with undo, and the inbox)

    /// Moves files inside the music folder. Never overwrites, and never moves a file somewhere the library would stop
    /// counting it. The tag cache and hand matches follow each file; a folder a move empties is removed if it's empty.
    public async Task<(List<(string From, string To)> Done, List<string> Failed)> MoveAsync(List<(string From, string To)> moves)
    {
        var done = new List<(string, string)>(); var failed = new List<string>();
        foreach (var m in moves)
        {
            if (FullPath(m.From) is not { } src || FullPath(m.To) is not { } dst) { failed.Add($"{Engine.BaseName(m.From)}: outside the music folder"); continue; }
            if (Me.OnlyJuice && !Engine.CountsAsJuice(m.To, cache.GetValueOrDefault(m.From)?.Tags ?? [])) { failed.Add($"{Engine.BaseName(m.From)}: it would no longer count as a Juice WRLD file there"); continue; }
            var error = await Task.Run(() =>
            {
                if (!File.Exists(src)) return "isn't there any more";
                if (File.Exists(dst)) return $"a file is already at {Path.GetFileName(dst)}";
                try
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
                    File.Move(src, dst);
                    var dir = Path.GetDirectoryName(src)!;
                    if (Directory.Exists(dir) && !Directory.EnumerateFileSystemEntries(dir).Any()) Directory.Delete(dir); // only an empty folder
                    return null;
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return e.Message; }
            });
            if (error is not null) { failed.Add($"{Engine.BaseName(m.From)}: {error}"); continue; }
            done.Add(m);
            if (cache.Remove(m.From, out var c)) cache[m.To] = c;
            if (Me.MatchOverrides.Remove(m.From, out var o)) Me.MatchOverrides[m.To] = o;
            var n = Files.FindIndex(f => f.Path == m.From);
            if (n >= 0 && cache.TryGetValue(m.To, out var cc) && LibraryFile(m.To, cc) is { } f) Files[n] = f;
        }
        if (done.Count > 0)
        {
            Files = Files.OrderBy(f => f.Path, StringComparer.CurrentCultureIgnoreCase).ToList();
            var renamed = done.ToDictionary(x => x.Item1, x => x.Item2);
            Write("items.json", (Read<List<string>>("items.json") ?? []).Select(p => renamed.GetValueOrDefault(p, p)).ToList());
            Write("tags.json", cache); Write("personal.json", Me);
            Rematch();
        }
        return (done, failed);
    }
    public List<(string From, string To)> LastOrganize => (Read<List<string[]>>("lastOrganize.json") ?? []).Where(x => x.Length == 2).Select(x => (x[0], x[1])).ToList();
    public async Task<string> OrganizeAsync(List<(string From, string To)> plan)
    {
        var r = await MoveAsync(plan);
        Write("lastOrganize.json", r.Done.Select(x => new[] { x.From, x.To }).ToList());
        return $"Moved {Plural(r.Done.Count, "file", "files")}." + (r.Failed.Count > 0 ? $" Left {r.Failed.Count} where they were: {string.Join("; ", r.Failed.Take(3))}." : "");
    }
    public async Task<string> UndoOrganizeAsync()
    {
        var r = await MoveAsync(LastOrganize.AsEnumerable().Reverse().Select(x => (x.To, x.From)).ToList());
        Write("lastOrganize.json", new List<string[]>());
        return $"Put {Plural(r.Done.Count, "file", "files")} back." + (r.Failed.Count > 0 ? $" Couldn't move {r.Failed.Count}: {string.Join("; ", r.Failed.Take(3))}." : "");
    }
    public static string Plural(int n, string one, string many) => $"{n:N0} {(n == 1 ? one : many)}";

    // The inbox: a folder outside the library; songs dropped there move into their era's folder and get tagged.
    FileSystemWatcher? inboxWatcher;
    bool sorting, sortAgain;
    readonly HashSet<string> untaggable = [];
    public string InboxNote { get; private set; } = "";
    public void WatchInbox()
    {
        inboxWatcher?.Dispose(); inboxWatcher = null;
        if (Me.Inbox is not { } inbox || !Directory.Exists(inbox)) return;
        inboxWatcher = new FileSystemWatcher(inbox) { IncludeSubdirectories = false, EnableRaisingEvents = true };
        void Poke(object? s, FileSystemEventArgs e) => Application.Current?.Dispatcher.BeginInvoke(() => _ = SortInboxAsync());
        inboxWatcher.Created += Poke; inboxWatcher.Changed += Poke; inboxWatcher.Renamed += (s, e) => Poke(s, e);
        _ = SortInboxAsync();
    }
    public async Task SortInboxAsync()
    {
        if (Me.Inbox is not { } inbox || Root is null || Catalog.Count == 0) return;
        if (sorting) { sortAgain = true; return; }
        sorting = true;
        try
        {
            // only files that finished arriving: the same size a few seconds apart, untouched for 10 seconds
            var (found, waiting) = await Task.Run(() =>
            {
                Dictionary<string, (long, DateTime)> Look() => Directory.Exists(inbox)
                    ? Directory.EnumerateFiles(inbox).Where(f => Engine.AudioExts.Contains(Engine.ExtOf(f)) && !Path.GetFileName(f).StartsWith('.'))
                        .ToDictionary(f => f, f => { var i = new FileInfo(f); return (i.Length, i.LastWriteTimeUtc); })
                    : [];
                var before = Look();
                if (before.Count == 0) return (new List<(string, Dictionary<string, string>, long)>(), false);
                Thread.Sleep(3000);
                var now = Look(); var date = DateTime.UtcNow;
                var ready = now.Where(kv => Engine.Settled(before.TryGetValue(kv.Key, out var b) ? b.Item1 : -1, kv.Value.Item1, kv.Value.Item2, date)).ToList();
                var arriving = now.Any(kv => !ready.Any(r => r.Key == kv.Key) && kv.Value.Item1 > 0);
                return (ready.Select(kv => (kv.Key, TagReader.Read(kv.Key, Engine.ExtOf(kv.Key)), kv.Value.Item1)).ToList(), arriving);
            });
            if (waiting) _ = Task.Delay(8000).ContinueWith(_ => Application.Current?.Dispatcher.BeginInvoke(() => _ = SortInboxAsync()));
            if (found.Count == 0) return;
            int moved = 0; var left = new List<string>(); var putBack = new List<string>();
            foreach (var (file, tags, size) in found)
            {
                var name = Path.GetFileName(file); var tmp = $"inbox/{name}";
                if (untaggable.Contains($"{name}|{size}")) { putBack.Add(name); continue; }
                var title = tags.GetValueOrDefault("title", "") is { Length: > 0 } t ? t : Engine.TitleFromFilename(tmp);
                var lf = new LibraryFile(tmp, Engine.ExtOf(name), tags, title, Engine.Normalize(title), Engine.StemOf(tmp), tags.GetValueOrDefault("title", "").Length > 0, size);
                var m = Engine.MatchFiles(Catalog, [lf], new Dictionary<string, string>());
                if (!m.SongsFor.TryGetValue(tmp, out var songs) || m.How.GetValueOrDefault(tmp) == "close" || Engine.PrimarySong(songs, Catalog) is not { } primary) { left.Add(name); continue; }
                var rel = $"{Engine.SaveFolder(Catalog[primary], Layout)}/{name}";
                if (FullPath(rel) is not { } dst || !(Engine.CountsAsJuice(rel, tags) || Engine.EditableExts.Contains(Engine.ExtOf(name)))) { left.Add(name); continue; }
                var ok = await Task.Run(() =>
                {
                    if (File.Exists(dst)) return false;
                    try { Directory.CreateDirectory(Path.GetDirectoryName(dst)!); File.Move(file, dst); return true; } catch (IOException) { return false; }
                });
                if (!ok) { left.Add(name); continue; }
                UpdateFile(rel, tags, size);
                // the versions primarySong chose between share one name, so its tags are right for the title either way
                await AutoTagAsync(rel, primary, inbox: tags);
                if (Me.OnlyJuice && !Engine.CountsAsJuice(rel, cache.GetValueOrDefault(rel)?.Tags ?? tags))
                {
                    untaggable.Add($"{name}|{size}");
                    if (!File.Exists(file)) { try { File.Move(dst, file); RemoveFiles([rel]); putBack.Add(name); continue; } catch (IOException) { } }
                }
                moved++;
            }
            InboxNote = $"Inbox: moved {Plural(moved, "song", "songs")} into your library" + (left.Count > 0 ? $"; {left.Count} left in the inbox (not recognized, or already in the library)" : "")
                + (putBack.Count > 0 ? $"; {putBack.Count} left because their tags can't be set to Juice WRLD ({string.Join(", ", putBack.Take(3))}). Tag them as Juice WRLD, or put them in the music folder yourself." : ".");
            Notify();
        }
        finally
        {
            sorting = false;
            if (sortAgain) { sortAgain = false; _ = SortInboxAsync(); }
        }
    }

    // MARK: File health: does it play, how long, how loud, does it have cover art

    public Dictionary<string, Engine.Probe> Probes { get; } = [];
    public static Engine.Probe? ProbeFile(string file)
    {
        if (!File.Exists(file)) return null;
        var ext = Engine.ExtOf(file); long size = new FileInfo(file).Length;
        bool? art = Engine.EditableExts.Contains(ext) ? CoverArt.HasArt(file, ext) : null;
        try
        {
            using var reader = new MediaFoundationReader(file);
            var seconds = reader.TotalTime.TotalSeconds;
            return new Engine.Probe(seconds > 0, double.IsFinite(seconds) ? seconds : 0, size, Loudness(reader), art);
        }
        catch (Exception) { return new Engine.Probe(false, 0, size, null, art); }
    }
    /// The average level (RMS, dBFS) of three 3-second samples at a quarter, half and three quarters of the way in.
    public static double? Loudness(MediaFoundationReader reader)
    {
        try
        {
            var samples = reader.ToSampleProvider(); var fmt = samples.WaveFormat;
            var buf = new float[fmt.SampleRate * fmt.Channels * 3];
            double sum = 0; long count = 0;
            foreach (var at in new[] { 0.25, 0.5, 0.75 })
            {
                reader.CurrentTime = TimeSpan.FromSeconds(reader.TotalTime.TotalSeconds * at);
                int n = samples.Read(buf, 0, buf.Length);
                for (int i = 0; i < n; i++) sum += buf[i] * (double)buf[i];
                count += n;
            }
            return count == 0 || sum <= 0 ? null : 10 * Math.Log10(sum / count);
        }
        catch (Exception) { return null; }
    }
    public static double? Loudness(string file) { try { using var r = new MediaFoundationReader(file); return Loudness(r); } catch (Exception) { return null; } }

    /// The song's picture from the site as a JPEG, at most 600 px across.
    public async Task<(byte[] Jpeg, int Width, int Height)> ArtworkAsync(EngineSong song)
    {
        var json = await DetailsAsync(song);
        if (json?["image_url"]?.GetValue<string>() is not { Length: > 0 } img || !Uri.TryCreate(new Uri("https://juicewrldapi.com"), img, out var url)) throw new EngineError($"The site has no picture for “{song.Name}”");
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        var bytes = await http.GetByteArrayAsync(url);
        var src = new BitmapImage(); src.BeginInit(); src.StreamSource = new MemoryStream(bytes); src.CacheOption = BitmapCacheOption.OnLoad; src.EndInit(); src.Freeze();
        double scale = Math.Min(1, 600.0 / Math.Max(src.PixelWidth, src.PixelHeight));
        var small = new TransformedBitmap(src, new ScaleTransform(scale, scale)); small.Freeze();
        var enc = new JpegBitmapEncoder { QualityLevel = 85 }; enc.Frames.Add(BitmapFrame.Create(small));
        using var ms = new MemoryStream(); enc.Save(ms);
        return (ms.ToArray(), small.PixelWidth, small.PixelHeight);
    }
    /// Adds cover art with the same safety check, backup and atomic save as a tag write.
    public async Task AddArtAsync(string path)
    {
        if (FullPath(path) is not { } full) throw new EngineError("isn't in your music folder");
        if (Match.SongsFor.GetValueOrDefault(path)?.FirstOrDefault() is not { } i) throw new EngineError("That file isn't matched to a song");
        var art = await ArtworkAsync(Catalog[i]);
        var ext = Engine.ExtOf(path);
        string? backup = Me.BackupDir is { } dir ? Path.Combine([dir, .. path.Split('/').Skip(1)]) : null;
        var (tags, size) = await Task.Run(() =>
        {
            var orig = File.ReadAllBytes(full);
            var output = CoverArt.AddArt(orig, ext, art.Jpeg, art.Width, art.Height);
            if (backup is not null && !(File.Exists(backup) && new FileInfo(backup).Length > 0)) { Directory.CreateDirectory(Path.GetDirectoryName(backup)!); File.WriteAllBytes(backup, orig); }
            var tmp = full + ".jt-tmp"; File.WriteAllBytes(tmp, output); File.Move(tmp, full, true);
            return (TagReader.Read(full, ext), (long)output.Length);
        });
        if (Probes.TryGetValue(path, out var p)) Probes[path] = p with { Art = true };
        UpdateFile(path, tags, size);
    }

    // MARK: Play history (plays.tsv: time, file)

    public static List<(DateTime At, string File)> PlayLog()
    {
        try
        {
            return File.ReadLines(Path.Combine(DataDir, "plays.tsv")).Select(l => l.Split('\t')).Where(p => p.Length == 2 && long.TryParse(p[0], out _))
                .Select(p => (DateTimeOffset.FromUnixTimeSeconds(long.Parse(p[0])).LocalDateTime, p[1])).ToList();
        }
        catch (IOException) { return []; }
    }
    /// The catalog song a file on disk is (the first song it matched), or -1.
    public int SongForFile(string file)
    {
        foreach (var (path, songs) in Match.SongsFor) if (songs.Count > 0 && FullPath(path) is { } full && string.Equals(full, file, StringComparison.OrdinalIgnoreCase)) return songs[0];
        return -1;
    }
    public Dictionary<int, int> PlayCounts()
    {
        var byFile = PlayLog().GroupBy(e => e.File, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.Count(), StringComparer.OrdinalIgnoreCase);
        var output = new Dictionary<int, int>();
        foreach (var (i, paths) in Match.Owned) output[i] = paths.Select(FullPath).OfType<string>().Sum(f => byFile.GetValueOrDefault(f)) + Plex.Counts.GetValueOrDefault(i);
        return output;
    }

    // MARK: Wishlist order and playlists

    /// Wishlist song ids, most wanted first: your drag order, then songs not ranked yet, oldest first.
    public List<string> WishRanked
    {
        get
        {
            var order = Me.WishOrder.Where(Me.Wish.ContainsKey).ToList(); var ranked = order.ToHashSet();
            return [.. order, .. Me.Wish.Where(kv => !ranked.Contains(kv.Key)).OrderBy(kv => kv.Value).Select(kv => kv.Key)];
        }
    }
    public int DownloadWishlist()
    {
        var owned = Owned;
        var wanted = Catalog.Select((s, i) => (s, i)).Where(x => Me.Wish.ContainsKey(x.s.Id) && !owned.Contains(x.i) && x.s.FilePath.Length > 0).Select(x => x.s.Id).ToHashSet();
        return AddDownloads(WishRanked.Where(wanted.Contains));
    }

    /// Settings: new songs with a file download on their own when the catalog check finds them, as many as fit with
    /// room to spare (2 GB, at about 12 MB a song). Returns how many were queued.
    public int AutoDownload(IEnumerable<string> ids)
    {
        var owned = Owned; var byId = Catalog.Select((s, i) => (s, i)).GroupBy(x => x.s.Id).ToDictionary(g => g.Key, g => g.First());
        var wanted = ids.Where(id => byId.TryGetValue(id, out var x) && !owned.Contains(x.i) && x.s.FilePath.Length > 0).ToList();
        if (wanted.Count == 0) return 0;
        int room = Disk.Free(Root) is { } free ? (int)(Math.Max(0, free - 2_000_000_000) / 12_000_000) : wanted.Count;
        var fits = wanted.Take(room).ToList();
        if (fits.Count < wanted.Count) Inbox.Add("Not everything fits on the music drive", $"{wanted.Count - fits.Count} new song{(wanted.Count - fits.Count == 1 ? "" : "s")} weren't downloaded, to keep 2 GB free.");
        if (fits.Count == 0) return 0;
        var names = fits.Select(id => byId[id].s.Name).ToList();
        Inbox.Add($"Downloading {fits.Count} new song{(fits.Count == 1 ? "" : "s")}", string.Join(", ", names.Take(6)) + (names.Count > 6 ? $" and {names.Count - 6} more" : ""), fits);
        return AddDownloads(fits);
    }
    public void AddToPlaylist(string playlistId, IEnumerable<string> ids)
    {
        var n = Me.Playlists.FindIndex(p => p.Id == playlistId);
        if (n < 0) return;
        var songs = Me.Playlists[n].Songs; foreach (var id in ids) if (!songs.Contains(id)) songs.Add(id);
        SavePersonal();
    }

    // MARK: Backup and restore (the same file as the Mac app's, so either can read the other's)

    public string BackupJson()
    {
        var names = Catalog.GroupBy(s => s.Id).ToDictionary(g => g.Key, g => g.First().Name);
        var backup = new JsonObject
        {
            ["app"] = "juice-wrld-collection-tracker", ["version"] = 1, ["exportedAt"] = DateTime.UtcNow.ToString("o"),
            ["wishlist"] = new JsonArray(Me.Wish.OrderBy(kv => kv.Value).Select(kv => (JsonNode)new JsonObject { ["id"] = kv.Key, ["name"] = names.GetValueOrDefault(kv.Key, ""), ["added"] = kv.Value }).ToArray()),
            ["notes"] = new JsonArray(Me.Notes.OrderBy(kv => kv.Key).Select(kv => (JsonNode)new JsonObject { ["id"] = kv.Key, ["name"] = names.GetValueOrDefault(kv.Key, ""), ["text"] = kv.Value }).ToArray()),
            ["ratings"] = JsonSerializer.SerializeToNode(Me.Ratings), ["wishOrder"] = JsonSerializer.SerializeToNode(WishRanked),
            ["playlists"] = new JsonArray(Me.Playlists.Select(p => (JsonNode)new JsonObject { ["id"] = p.Id, ["name"] = p.Name, ["songs"] = JsonSerializer.SerializeToNode(p.Songs) }).ToArray()),
            ["trivia"] = JsonSerializer.SerializeToNode(Me.Trivia), ["matchOverrides"] = JsonSerializer.SerializeToNode(Me.MatchOverrides),
            ["opened"] = JsonSerializer.SerializeToNode(Me.Opened), ["fixGenre"] = Me.FixGenre,
        };
        return backup.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }
    /// Merges a backup into what's here (nothing is overwritten). Throws if the file isn't a backup.
    public string Restore(string text)
    {
        JsonObject? data;
        try { data = JsonNode.Parse(text) as JsonObject; } catch (JsonException) { data = null; }
        if (data?["app"]?.GetValue<string>() != "juice-wrld-collection-tracker") throw new EngineError("That file isn't a backup from this tracker.");
        static string Id(JsonNode? n) => n is JsonValue v ? (v.TryGetValue<string>(out var s) ? s : v.ToString()) : "";
        int wishes = 0, notes = 0;
        foreach (var x in data["wishlist"] as JsonArray ?? [])
            if (Id(x?["id"]) is { Length: > 0 } id && !Me.Wish.ContainsKey(id)) { Me.Wish[id] = x?["added"]?.GetValue<string>() is { Length: > 0 } a ? a : DateTime.UtcNow.ToString("o"); wishes++; }
        foreach (var x in data["notes"] as JsonArray ?? [])
            if (Id(x?["id"]) is { Length: > 0 } id && x?["text"]?.GetValue<string>() is { Length: > 0 } t && !Me.Notes.ContainsKey(id)) { Me.Notes[id] = t; notes++; }
        foreach (var (k, v) in data["ratings"] as JsonObject ?? []) if (!Me.Ratings.ContainsKey(k) && v is JsonValue jv && jv.TryGetValue<int>(out var r)) Me.Ratings[k] = r;
        if (Me.WishOrder.Count == 0 && data["wishOrder"] is JsonArray wo) Me.WishOrder = wo.Select(Id).ToList();
        var mine = Me.Playlists.Select(p => p.Id).ToHashSet();
        foreach (var p in data["playlists"] as JsonArray ?? [])
            if (Id(p?["id"]) is { Length: > 0 } pid && !mine.Contains(pid)) Me.Playlists.Add(new Playlist(pid, p?["name"]?.GetValue<string>() ?? "Playlist", (p?["songs"] as JsonArray ?? []).Select(Id).ToList()));
        foreach (var (k, v) in data["trivia"] as JsonObject ?? []) if (v is JsonValue jv && jv.TryGetValue<int>(out var best)) Me.Trivia[k] = Math.Max(Me.Trivia.GetValueOrDefault(k), best);
        foreach (var (k, v) in data["opened"] as JsonObject ?? []) if (!Me.Opened.ContainsKey(k) && v is JsonValue jv && jv.TryGetValue<string>(out var s)) Me.Opened[k] = s;
        if (Me.FixGenre.Length == 0 && data["fixGenre"]?.GetValue<string>() is { Length: > 0 } g) Me.FixGenre = g;
        foreach (var (k, v) in data["matchOverrides"] as JsonObject ?? []) if (!Me.MatchOverrides.ContainsKey(k) && v is JsonValue jv && jv.TryGetValue<string>(out var s)) Me.MatchOverrides[k] = s;
        SavePersonal(); Rematch();
        return $"Restored {Plural(wishes, "wishlist song", "wishlist songs")} and {Plural(notes, "note", "notes")} (nothing here was replaced).";
    }

    /// The whole catalog as a spreadsheet, with what you have.
    public string CatalogCsv()
    {
        var owned = Owned;
        var lines = new List<List<string>> { new() { "id", "name", "era", "category", "length", "recorded", "released", "producers", "artists", "in_library", "wishlist", "rating", "note", "file_on_site" } };
        for (int i = 0; i < Catalog.Count; i++)
        {
            var s = Catalog[i];
            lines.Add([s.Id, s.Name, Engine.EraName(s), Engine.Capital(s.Category), s.Length, s.RecordDates, s.Release, s.Producers, s.Artists, owned.Contains(i) ? "yes" : "no",
                       Me.Wish.ContainsKey(s.Id) ? "yes" : "", Me.Ratings.TryGetValue(s.Id, out var r) ? $"{r}" : "", Me.Notes.GetValueOrDefault(s.Id, ""), Engine.FileUrl(s)]);
        }
        return Engine.CsvText(lines);
    }
    public string SnapshotCsv() => Engine.SnapshotCsv(Files, Match, Catalog);

    /// Scans another folder (a backup drive) and compares: songs only here, only there, or on both. Reads only.
    public async Task<(string Drive, List<int> OnlyHere, List<int> OnlyThere, int Both)> CompareAsync(string other, Action<int, int>? progress = null)
    {
        var scan = await Engine.ScanAsync(other, Me.OnlyJuice, new Dictionary<string, Engine.CachedTags>(), true, progress);
        var there = Engine.MatchFiles(Catalog, scan.Files, new Dictionary<string, string>()).Owned.Keys.ToHashSet(); var here = Owned;
        return (Path.GetFileName(other.TrimEnd('\\', '/')), here.Except(there).Order().ToList(), there.Except(here).Order().ToList(), here.Intersect(there).Count());
    }
}
