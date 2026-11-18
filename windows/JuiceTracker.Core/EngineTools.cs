using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace JuiceTracker;

public static partial class Engine
{
    // MARK: Where a missing song is saved: learned from where your matched files already live

    public sealed class Layout
    {
        public List<(string Era, string Folder)> ByEra { get; set; } = [];
        public string? EraRoot { get; set; }       // the folder that holds era-named folders ("" for the top of the music folder)
        public string? TopParent { get; set; }     // where most Juice WRLD files sit
        public string Fallback { get; set; } = "Music/Juice WRLD";
    }

    public static string ParentOf(string path) => string.Join("/", path.Split('/').SkipLast(1));
    /// A name that's safe as a file or folder name.
    public static string SafeName(string s)
    {
        var t = new string(s.Where(c => !"\\/:*?\"<>|".Contains(c) && c > 0x1f).ToArray());
        t = Regex.Replace(t, @"\s+", " ").Trim();
        t = Regex.Replace(t, @"[. ]+$", "");
        return t.Length == 0 ? "Unknown" : t;
    }
    /// Counts in first-seen order; the most common (the first of equals).
    sealed class Counts
    {
        readonly List<string> order = []; readonly Dictionary<string, int> n = [];
        public void Bump(string k) { if (!n.ContainsKey(k)) order.Add(k); n[k] = n.GetValueOrDefault(k) + 1; }
        public string? MostCommon { get { string? best = null; int top = 0; foreach (var k in order) if (n[k] > top) { best = k; top = n[k]; } return best; } }
    }

    /// How the library is laid out: where each era's songs live, whether folders are named after eras, and where
    /// most Juice WRLD files sit. Only files matched to exactly one song, not by a close title, count.
    public static Layout LearnLayout(List<EngineSong> catalog, List<LibraryFile> files, Match match)
    {
        var songOrder = new List<int>(); var seen = new HashSet<int>(); var filesOf = new Dictionary<int, List<string>>();
        foreach (var f in files)
            foreach (var i in match.SongsFor.GetValueOrDefault(f.Path) ?? [])
            {
                if (seen.Add(i)) songOrder.Add(i);
                if (!filesOf.TryGetValue(i, out var l)) filesOf[i] = l = [];
                l.Add(f.Path);
            }
        var perEraOrder = new List<string>(); var perEra = new Dictionary<string, Counts>(); var parents = new Counts();
        foreach (var i in songOrder)
        {
            var era = EraName(catalog[i]);
            foreach (var path in filesOf[i])
            {
                if (match.SongsFor.GetValueOrDefault(path)?.Count != 1 || match.How.GetValueOrDefault(path) == "close") continue;
                var p = ParentOf(path);
                if (p.Length == 0) continue;
                if (!perEra.ContainsKey(era)) { perEraOrder.Add(era); perEra[era] = new Counts(); }
                perEra[era].Bump(p);
                parents.Bump(p);
            }
        }
        var output = new Layout { ByEra = perEraOrder.Select(e => (e, perEra[e].MostCommon!)).ToList() };
        var roots = new Counts(); int eraLike = 0;
        foreach (var (era, folder) in output.ByEra)
        {
            string a = Normalize(BaseName(folder)), b = Normalize(era);
            if (a.Length > 0 && b.Length > 0 && (a == b || a.Contains(b) || b.Contains(a))) { eraLike++; roots.Bump(ParentOf(folder)); }
        }
        var rootName = files.Count > 0 ? files[0].Path.Split('/')[0] : "";
        output.EraRoot = eraLike > 0 && eraLike >= output.ByEra.Count / 2.0 ? roots.MostCommon : null;
        output.TopParent = parents.MostCommon;
        output.Fallback = $"{(rootName.Length == 0 ? "Music" : rootName)}/Juice WRLD";
        return output;
    }
    /// The folder (library-style path, starting with the music folder's name) a missing song is saved into.
    public static string SaveFolder(EngineSong song, Layout l)
    {
        var era = EraName(song);
        foreach (var (e, folder) in l.ByEra) if (e == era) return folder;
        if (l.EraRoot is { } root) return root.Length == 0 ? SafeName(era) : $"{root}/{SafeName(era)}";
        if (l.TopParent is { } top) return top;
        return $"{l.Fallback}/{SafeName(era)}";
    }
    public static string SaveFileName(EngineSong song) => song.FilePath.Length == 0 ? $"{SafeName(song.Name)}.mp3" : BaseName(song.FilePath);

    /// The library snapshot: every file with its tags, size and the songs it matched.
    public static string SnapshotCsv(List<LibraryFile> files, Match match, List<EngineSong> catalog)
    {
        var lines = new List<List<string>> { new() { "path", "title", "artist", "album", "year", "format", "size_bytes", "song_ids", "song_names", "era" } };
        foreach (var f in files)
        {
            var songs = (match.SongsFor.GetValueOrDefault(f.Path) ?? []).Where(i => i >= 0 && i < catalog.Count).Select(i => catalog[i]).ToList();
            lines.Add([f.Path, f.Tags.GetValueOrDefault("title", ""), f.Tags.GetValueOrDefault("artist", ""), f.Tags.GetValueOrDefault("album", ""), f.Tags.GetValueOrDefault("year", ""),
                       f.Ext, f.Size.ToString(CultureInfo.InvariantCulture), string.Join(" ", songs.Select(s => s.Id)), string.Join(" / ", songs.Select(s => s.Name)),
                       songs.Count > 0 ? EraName(songs[0]) : ""]);
        }
        return CsvText(lines);
    }

    // MARK: The tag fixer, duplicates and file health: the page's rules

    public const string DefaultGenre = "Hip-Hop/Rap";
    public static readonly HashSet<string> EditableExts = ["mp3", "flac", "m4a"];
    public static readonly HashSet<string> Lossless = ["flac", "wav", "aiff", "aif", "alac"];

    static string StripLabel(string value, string label) => Regex.Replace(value, $@"^\s*{label}\s*[:\-–]?\s*", "", RegexOptions.IgnoreCase).Trim();
    /// A short comment like "Unreleased. Recorded March 2018."
    public static string CatalogComment(EngineSong s)
    {
        var cat = s.Category.Trim(); var parts = new List<string>();
        if (HasValue(cat) && cat.ToLowerInvariant() != "unknown") parts.Add(char.ToUpperInvariant(cat[0]) + cat[1..].Replace("_", " "));
        var rec = Regex.Replace(StripLabel(s.RecordDates, "Recorded"), @"\s+", " ");
        rec = Regex.Replace(rec, @"[.,;\s]+$", "");
        if (HasValue(rec)) parts.Add("Recorded " + (rec.Length > 120 ? rec[..120] + "…" : rec));
        return parts.Count == 0 ? "" : string.Join(". ", parts) + ".";
    }
    /// The tags the fixer would write for a catalog song.
    public static Dictionary<string, string> PlannedTags(EngineSong s, string genre = DefaultGenre)
    {
        var artist = "Juice WRLD";
        if (HasValue(s.Artists)) artist = HasArtist(s.Artists) ? s.Artists : $"Juice WRLD, {s.Artists}";
        var rel = IsReleased(s) ? YearOf(s.Release) : "";
        var year = rel.Length > 0 ? rel : YearOf(s.RecordDates).Length > 0 ? YearOf(s.RecordDates) : YearOf(s.Release);
        return new()
        {
            ["title"] = s.Name, ["artist"] = artist, ["albumartist"] = "Juice WRLD", ["album"] = HasValue(s.Era) ? s.Era : "", ["year"] = year,
            ["producer"] = HasValue(s.Producers) ? s.Producers : "", ["genre"] = genre, ["comment"] = CatalogComment(s),
        };
    }

    public sealed record FixChange(string Key, string From, string To);
    /// The changes the fixer would make to one file's tags: the fields chosen, skipping ones already right (and, with
    /// onlyBlanks, ones that have something in them).
    public static (List<FixChange> Changes, Dictionary<string, string> Desired) FixFor(Dictionary<string, string> tags, EngineSong song, IEnumerable<string> fields, bool onlyBlanks, string genre)
    {
        var want = PlannedTags(song, genre);
        var changes = new List<FixChange>(); var desired = new Dictionary<string, string>();
        foreach (var k in fields)
        {
            var to = want.GetValueOrDefault(k, "").Trim();
            if (to.Length == 0) continue;
            var from = tags.GetValueOrDefault(k, "").Trim();
            if ((onlyBlanks && from.Length > 0) || from == to) continue;
            changes.Add(new FixChange(k, from, to)); desired[k] = to;
        }
        return (changes, desired);
    }
    public sealed record FixItem(string Path, int Song, List<FixChange> Changes, Dictionary<string, string> Desired);
    /// Every matched file whose tags would change (files that fit several songs are picked by hand instead).
    public static (List<FixItem> Changes, List<(string Path, string Reason)> Skipped, int Same) BuildPlan(List<LibraryFile> files, Match match, List<EngineSong> catalog,
                                                                                                    IEnumerable<string> fields, bool onlyBlanks, string genre)
    {
        var changes = new List<FixItem>(); var skipped = new List<(string, string)>(); int same = 0; var fieldList = fields.ToList();
        foreach (var f in files)
        {
            if (match.SongsFor.GetValueOrDefault(f.Path) is not { Count: 1 } songs) continue;
            if (!EditableExts.Contains(f.Ext)) { skipped.Add((f.Path, $".{f.Ext} files can't be edited yet")); continue; }
            var it = FixFor(f.Tags, catalog[songs[0]], fieldList, onlyBlanks, genre);
            if (it.Changes.Count == 0) { same++; continue; }
            changes.Add(new FixItem(f.Path, songs[0], it.Changes, it.Desired));
        }
        return (changes, skipped, same);
    }

    /// "4:26" or "1:02:03" to seconds.
    /// A line of timed lyrics (LRC): when it starts, its text, and when each word starts (empty when only the line is timed).
    public sealed record LrcLine(double At, string Line, double[] Words);

    /// "[01:23.45] line" lines, with word times written "<01:23.80>word"; lines without a time (tags like [ar:…]) are
    /// skipped. Word times are kept only when there is one for every word.
    public static List<LrcLine> ParseLrc(string text)
    {
        static double Sec(Group m, Group s) => int.Parse(m.Value) * 60 + double.Parse(s.Value, System.Globalization.CultureInfo.InvariantCulture);
        var output = new List<LrcLine>();
        foreach (var raw in text.Split('\n'))
        {
            var g = Regex.Match(raw.Trim(), @"^\[(\d+):(\d+(?:\.\d+)?)\](.*)$");
            if (!g.Success) continue;
            var rest = g.Groups[3].Value;
            var words = Regex.Matches(rest, @"<(\d+):(\d+(?:\.\d+)?)>").Select(m => Sec(m.Groups[1], m.Groups[2])).ToArray();
            var line = string.Join(' ', Regex.Replace(rest, @"<\d+:\d+(?:\.\d+)?>", " ").Split(' ', StringSplitOptions.RemoveEmptyEntries));
            output.Add(new LrcLine(Sec(g.Groups[1], g.Groups[2]), line, words.Length == line.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length ? words : []));
        }
        return output.OrderBy(l => l.At).ToList();
    }
    /// 83.456 → "01:23.46".
    public static string LrcStamp(double t)
    {
        var cs = (int)Math.Round(Math.Max(0, t) * 100, MidpointRounding.AwayFromZero);
        return $"{cs / 6000:00}:{cs % 6000 / 100:00}.{cs % 100:00}";
    }
    public static string FormatLrc(IEnumerable<LrcLine> lines) => string.Join("\n", lines.Select(l =>
    {
        var words = l.Line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var text = l.Words.Length == words.Length && words.Length > 0 ? string.Join(' ', l.Words.Zip(words, (t, w) => $"<{LrcStamp(t)}>{w}")) : l.Line;
        return $"[{LrcStamp(l.At)}]{text}";
    }));
    /// How many words of line n are sung at `time`, and whether the last of them is still being sung. With word times
    /// it follows them; without, the line's time is spread over its words.
    public static (int Words, bool Singing) LitWords(IReadOnlyList<LrcLine> lines, int n, double time)
    {
        var l = lines[n]; double end = n + 1 < lines.Count ? lines[n + 1].At : l.At + 4;
        if (l.Words.Length > 0)
        {
            int on = l.Words.Count(t => t <= time + 0.05);
            return (on, on > 0 && time < (on < l.Words.Length ? l.Words[on] : end));
        }
        int count = l.Line.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length;
        double progress = Math.Clamp((time - l.At) / Math.Max(0.5, (end - l.At) * 0.85), 0, 1);
        return ((int)Math.Ceiling(count * progress), progress < 1);
    }

    /// Plays per bucket of `bucketDays` days, oldest first, the last bucket ending today (the listening timeline).
    public static int[] PlayTimeline(IEnumerable<DateTime> times, int buckets, int bucketDays, DateTime now)
    {
        var output = new int[buckets];
        foreach (var t in times)
        {
            int days = (int)(now.Date - t.Date).TotalDays;
            if (days < 0) continue;
            int b = buckets - 1 - days / bucketDays;
            if (b >= 0) output[b]++;
        }
        return output;
    }
    /// A playlist as an .m3u file other players open: each song's length, title and full path.
    public static string M3u(IEnumerable<(string Path, string Title, double? Seconds)> entries) =>
        "#EXTM3U\n" + string.Concat(entries.Select(e => $"#EXTINF:{(e.Seconds is { } s ? (int)s : -1)},Juice WRLD - {string.Join(' ', e.Title.Split('\n', '\r'))}\n{e.Path}\n"));

    public static double? LengthSeconds(string text)
    {
        var g = Regex.Match(text, @"^\s*(?:(\d+):)?(\d{1,2}):(\d{2})\s*$");
        if (!g.Success) return null;
        return (g.Groups[1].Success ? int.Parse(g.Groups[1].Value) : 0) * 3600 + int.Parse(g.Groups[2].Value) * 60 + int.Parse(g.Groups[3].Value);
    }
    /// The best bitrate the site lists for a format ("2117kbps (.wav)"), or 0.
    public static int SiteKbps(string text, string ext) =>
        Regex.Matches(text, @"(\d{2,5})\s*k[bp]{1,2}s\s*\(\.(\w+)\)", RegexOptions.IgnoreCase)
            .Where(m => ext.Length == 0 || m.Groups[2].Value.ToLowerInvariant() == ext).Select(m => int.Parse(m.Groups[1].Value)).DefaultIfEmpty(0).Max();
    public static string FormatSize(long bytes)
    {
        if (bytes >= 1_000_000_000) return (bytes / 1e9).ToString("0.00", CultureInfo.InvariantCulture) + " GB";
        if (bytes >= 1_000_000) return (bytes / 1e6).ToString("0.0", CultureInfo.InvariantCulture) + " MB";
        return $"{Math.Max(1, (long)Math.Round(bytes / 1e3, MidpointRounding.AwayFromZero))} KB";
    }
    public static string FmtTime(double s)
    {
        int secs = (int)Math.Round(s % 60, MidpointRounding.AwayFromZero);
        return $"{(int)(s / 60)}:{(secs < 10 ? "0" : "")}{secs}";
    }
    /// Lower case, no accents, words separated by single spaces (search keys; a duplicate's "same title").
    public static string CmdkKey(string text)
    {
        var t = NoMarks(text.ToLowerInvariant().Normalize(NormalizationForm.FormKD));
        return Regex.Replace(t, "[^a-z0-9]+", " ").Trim(' ');
    }

    // Duplicates
    public sealed record DupGroup(int? Song, string Title, List<LibraryFile> Files, long Extra);
    /// Lossless beats lossy; then the biggest file (the first of equals).
    public static LibraryFile BestCopy(List<LibraryFile> files)
    {
        var best = 0;
        for (int i = 1; i < files.Count; i++)
        {
            bool la = Lossless.Contains(files[i].Ext), lb = Lossless.Contains(files[best].Ext);
            if (la != lb) { if (la) best = i; continue; }
            if (files[i].Size > files[best].Size) best = i;
        }
        return files[best];
    }
    /// Only files that read as exactly the same title, so a remix or "v2" is never treated as a copy.
    public static bool IsExactDuplicate(DupGroup g) => g.Files.Select(f => CmdkKey(f.Title)).Distinct().Count() == 1;
    /// The files to move to the Recycle Bin: each extra copy once, never a kept one.
    public static List<LibraryFile> ExtraCopies(List<DupGroup> groups)
    {
        var kept = groups.Select(g => BestCopy(g.Files).Path).ToHashSet(); var seen = new HashSet<string>(); var output = new List<LibraryFile>();
        foreach (var g in groups) foreach (var f in g.Files) if (!kept.Contains(f.Path) && seen.Add(f.Path)) output.Add(f);
        return output;
    }
    /// Songs with more than one file, and unmatched files that share a title.
    public static List<DupGroup> DuplicateGroups(List<LibraryFile> files, Match match, List<EngineSong> catalog)
    {
        var byPath = new Dictionary<string, LibraryFile>(); foreach (var f in files) byPath.TryAdd(f.Path, f);
        var order = new List<int>(); var seen = new HashSet<int>(); var filesOf = new Dictionary<int, List<string>>();
        foreach (var f in files)
            foreach (var i in match.SongsFor.GetValueOrDefault(f.Path) ?? [])
            {
                if (seen.Add(i)) order.Add(i);
                if (!filesOf.TryGetValue(i, out var l)) filesOf[i] = l = [];
                if (!l.Contains(f.Path)) l.Add(f.Path);
            }
        var groups = order.Select(i => (i, fs: filesOf[i].Where(byPath.ContainsKey).Select(p => byPath[p]).ToList()))
            .Where(x => x.fs.Count > 1).Select(x => new DupGroup(x.i, catalog[x.i].Name, x.fs, 0)).ToList();
        var keyOrder = new List<string>(); var byKey = new Dictionary<string, List<LibraryFile>>();
        foreach (var p in match.Unmatched)
        {
            if (!byPath.TryGetValue(p, out var f) || f.Key.Length == 0) continue;
            if (!byKey.TryGetValue(f.Key, out var l)) { byKey[f.Key] = l = []; keyOrder.Add(f.Key); }
            l.Add(f);
        }
        foreach (var k in keyOrder) if (byKey[k].Count > 1) groups.Add(new DupGroup(null, byKey[k][0].Title, byKey[k], 0));
        groups = groups.Select(g =>
        {
            var sorted = g.Files.Select((f, n) => (f, n)).OrderByDescending(x => x.f.Size).ThenBy(x => x.n).Select(x => x.f).ToList();
            return g with { Files = sorted, Extra = sorted.Skip(1).Sum(f => f.Size) };
        }).ToList();
        return groups.Select((g, n) => (g, n)).OrderByDescending(x => x.g.Files.Count).ThenByDescending(x => x.g.Extra)
            .ThenBy(x => x.g.Title, StringComparer.CurrentCultureIgnoreCase).ThenBy(x => x.n).Select(x => x.g).ToList();
    }

    // File health
    public sealed record Probe(bool Ok, double Seconds, long Size, double? Loudness = null, bool? Art = null);
    public sealed record HealthIssue(string Path, string Group, string Text);
    /// What to look at: files that may be damaged or cut off, better copies on the site, and tags to fix.
    public static List<HealthIssue> HealthIssues(List<LibraryFile> files, Match match, List<EngineSong> catalog, IReadOnlyDictionary<string, Probe> probes)
    {
        var output = new List<HealthIssue>();
        foreach (var f in files)
        {
            var songs = match.SongsFor.GetValueOrDefault(f.Path) ?? [];
            var song = songs.Count == 1 ? catalog[songs[0]] : null;
            probes.TryGetValue(f.Path, out var p); int before = output.Count;
            long size = (p?.Size ?? 0) > 0 ? p!.Size : f.Size;
            if (p is { Ok: false }) output.Add(new(f.Path, "damaged", "Doesn't open as audio. It may be damaged."));
            else if (p is not null && (song is not null || p.Seconds < 5))
            {
                double want = song is not null && LengthSeconds(song.Length) is { } w ? w : 0; // 0: no length listed
                if ((want != 0 && want >= 45 && p.Seconds < want * 0.6) || p.Seconds < 5)
                    output.Add(new(f.Path, "damaged", $"Plays for {FmtTime(p.Seconds)}{(want != 0 ? $", but “{song!.Name}” is {song.Length}" : "")}. It may be cut off."));
            }
            if (output.Count == before && size < 300 * 1024) output.Add(new(f.Path, "damaged", $"Very small for a song ({FormatSize(size)})."));
            if (song is not null && output.Count == before && !Lossless.Contains(f.Ext) && song.FilePath.Length > 0)
            {
                var siteExt = ExtOf(song.FilePath); var want = LengthSeconds(song.Length); var site = SiteKbps(song.Bitrate, siteExt);
                double mine = (want ?? 0) != 0 && size > 0 ? size * 8.0 / 1000 / want!.Value : 0;
                if (Lossless.Contains(siteExt)) output.Add(new(f.Path, "upgrade", $"The site has a lossless copy ({siteExt.ToUpperInvariant()}); yours is {f.Ext.ToUpperInvariant()}."));
                else if (mine > 0 && site > 0 && mine < site * 0.7) output.Add(new(f.Path, "upgrade", $"Yours is about {(int)Math.Round(mine, MidpointRounding.AwayFromZero)} kbps; the site's copy is {site} kbps."));
            }
            if (!f.FromTags) output.Add(new(f.Path, "tags", "No title tag, so it's matched by its file name."));
            else if (songs.Count == 0) output.Add(new(f.Path, "tags", $"Its title, “{f.Title}”, isn't in the catalog."));
            else if (match.How.GetValueOrDefault(f.Path) == "close") output.Add(new(f.Path, "tags", $"Its title, “{f.Title}”, is close to “{catalog[songs[0]].Name}” but not exact."));
        }
        // Beyond the page: a file far from the library's typical level, and files with no cover art.
        var levels = files.Select(f => probes.GetValueOrDefault(f.Path)?.Loudness).OfType<double>().Order().ToList();
        if (levels.Count >= 5)
        {
            var typical = levels[levels.Count / 2];
            foreach (var f in files)
                if (probes.GetValueOrDefault(f.Path)?.Loudness is { } l && Math.Abs(l - typical) >= 6)
                    output.Add(new(f.Path, "loudness", $"About {(int)Math.Round(Math.Abs(l - typical), MidpointRounding.AwayFromZero)} dB {(l < typical ? "quieter" : "louder")} than the rest of your library."));
        }
        foreach (var f in files) if (probes.GetValueOrDefault(f.Path)?.Art == false) output.Add(new(f.Path, "art", "No cover art."));
        return output;
    }

    /// The songs a library snapshot had (one per file: the version whose name is the file's title).
    public static HashSet<string> SnapshotSongIds(string text)
    {
        var rows = ParseCsv(text);
        if (rows.Count == 0 || rows[0].IndexOf("song_ids") is var col && col < 0) throw new EngineError("That file isn't a Juice Tracker library snapshot.");
        var head = rows[0];
        int nameCol = head.IndexOf("song_names"), titleCol = head.IndexOf("title"), pathCol = head.IndexOf("path");
        static string At(List<string> r, int i) => i >= 0 && i < r.Count ? r[i] : "";
        var output = new HashSet<string>();
        foreach (var r in rows.Skip(1))
        {
            var list = At(r, col).Split(' ', StringSplitOptions.RemoveEmptyEntries); var names = At(r, nameCol).Split(" / ");
            var t = At(r, titleCol); var title = t.Length == 0 ? TitleFromFilename(At(r, pathCol)) : t;
            int k = Array.FindIndex(names, n => CmdkKey(n) == CmdkKey(title));
            if (k < 0) k = Array.FindIndex(names, n => Normalize(n) == Normalize(title));
            int pick = k >= 0 && k < list.Length ? k : 0;
            if (pick < list.Length) output.Add(list[pick]);
        }
        return output;
    }

    // MARK: Beyond the page (the Mac app's newer rules)

    /// Whether a file has finished arriving (a copy can take minutes): its size didn't change between two looks a few
    /// seconds apart, and it wasn't written to in the last 10 seconds (a date in the future doesn't count against it).
    public static bool Settled(long sizeBefore, long sizeNow, DateTime modified, DateTime now) =>
        sizeNow > 0 && sizeNow == sizeBefore && ((now - modified).TotalSeconds >= 10 || modified > now);

    /// How hard a song is to find: a grail is unreleased with no file on the site, and you have it anyway; rare is
    /// unreleased with no file on the site (yet). Released songs and ones the site has a file for are null (common).
    public static string? Rarity(EngineSong s, bool owned) => IsReleased(s) || s.FilePath.Length > 0 ? null : owned ? "Grail" : "Rare";

    /// A song title as a Wordle answer: bracketed parts ("(feat. …)", "[v2]") dropped, letters and digits upper-cased,
    /// spaces kept between words; null when it isn't 4 to 14 letters long.
    public static string? WordleWord(string title)
    {
        var bare = System.Text.RegularExpressions.Regex.Replace(title, @"\s*[\(\[][^\)\]]*[\)\]]", "");
        var plain = new string(bare.Normalize(System.Text.NormalizationForm.FormD).Where(c => System.Globalization.CharUnicodeInfo.GetUnicodeCategory(c) != System.Globalization.UnicodeCategory.NonSpacingMark).ToArray()).ToUpperInvariant();
        var words = System.Text.RegularExpressions.Regex.Split(plain.Replace("'", "").Replace("’", ""), @"[^A-Z0-9]+").Where(w => w.Length > 0).ToList();
        int letters = words.Sum(w => w.Length);
        return letters is >= 4 and <= 14 ? string.Join(' ', words) : null;
    }
    /// A Wordle guess against the answer, letter by letter (spaces ignored): 2 right place, 1 in the word elsewhere, 0
    /// not in it. A repeated letter is only yellow as many times as the answer still has it.
    public static int[] WordleScore(string guess, string answer)
    {
        var g = guess.Replace(" ", ""); var a = answer.Replace(" ", "");
        if (g.Length != a.Length) return [];
        var output = new int[g.Length]; var left = new Dictionary<char, int>();
        for (int k = 0; k < g.Length; k++) { if (g[k] == a[k]) output[k] = 2; else left[a[k]] = left.GetValueOrDefault(a[k]) + 1; }
        for (int k = 0; k < g.Length; k++) if (output[k] == 0 && left.GetValueOrDefault(g[k]) > 0) { output[k] = 1; left[g[k]]--; }
        return output;
    }

    /// The eras a spoken name fits, best first: the short name, then the full name, then names containing the words.
    public static List<string> ErasNamed(string spoken, IEnumerable<(string Name, string Full)> eras)
    {
        static string Plain(string s) => string.Join(" ", new string(s.ToLowerInvariant().Replace("&", " and ").Where(c => char.IsLetterOrDigit(c) || c == ' ').ToArray())
            .Split(' ', StringSplitOptions.RemoveEmptyEntries));
        var s = Plain(spoken); var list = eras.ToList();
        if (s.Length == 0) return [];
        foreach (var test in new Func<(string Name, string Full), bool>[] { e => Plain(e.Name) == s, e => Plain(e.Full) == s, e => Plain(e.Name).Contains(s) || Plain(e.Full).Contains(s) })
        {
            var hits = list.Where(test).Select(e => e.Name).ToList();
            if (hits.Count > 0) return hits;
        }
        return [];
    }

    /// The song a file most likely is when its title matches several versions: one match is that song; otherwise the
    /// plain-named versions (no "(Live)", "[v1]"…) must share one name, and the era most of them are from wins.
    public static int? PrimarySong(IEnumerable<int> songs, List<EngineSong> catalog)
    {
        var valid = songs.Where(i => i >= 0 && i < catalog.Count).ToList();
        if (valid.Count == 1) return valid[0];
        var plain = valid.Where(i => !catalog[i].Name.Contains('(') && !catalog[i].Name.Contains('[')).ToList();
        if (plain.Count == 0 || plain.Select(i => catalog[i].Name.ToLowerInvariant()).Distinct().Count() != 1) return null;
        var votes = plain.GroupBy(i => EraName(catalog[i])).OrderByDescending(g => g.Count()).ThenBy(g => g.Key, StringComparer.Ordinal).ToList();
        if (votes.Count > 1 && votes[0].Count() == votes[1].Count()) return null;
        return votes[0].Min();
    }

    /// Where each matched file would go under a pattern like "{era}/{song}" (also {category}, {year}). Never onto
    /// another file's place, and only where the library still counts the file as a Juice WRLD file.
    public static List<(string From, string To)> OrganizePlan(List<LibraryFile> files, Match match, List<EngineSong> catalog, string pattern)
    {
        var taken = files.Select(f => f.Path.ToLowerInvariant()).ToHashSet(); var output = new List<(string, string)>();
        foreach (var f in files)
        {
            if (!match.SongsFor.TryGetValue(f.Path, out var songs) || match.How.GetValueOrDefault(f.Path) == "close" || PrimarySong(songs, catalog) is not { } primary) continue;
            var s = catalog[primary]; var root = f.Path.Split('/')[0];
            var rel = pattern;
            foreach (var (k, v) in new[] { ("{era}", EraName(s)), ("{song}", s.Name), ("{category}", s.Category), ("{year}", YearOf(s.RecordDates)) })
                rel = rel.Replace(k, SafeName(v.Length == 0 ? "Unknown" : v));
            var parts = rel.Split('/', StringSplitOptions.RemoveEmptyEntries).Select(SafeName).ToList();
            if (parts.Count == 0) continue;
            var to = string.Join("/", new[] { root }.Concat(parts)) + "." + f.Ext;
            if (to == f.Path || taken.Contains(to.ToLowerInvariant()) || !CountsAsJuice(to, f.Tags)) continue;
            taken.Remove(f.Path.ToLowerInvariant()); taken.Add(to.ToLowerInvariant());
            output.Add((f.Path, to));
        }
        return output;
    }
}
