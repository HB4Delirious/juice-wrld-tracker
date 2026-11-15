using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace JuiceTracker;

/// One audio file in the music folder, with what matching needs.
public sealed record LibraryFile(string Path, string Ext, Dictionary<string, string> Tags, string Title, string Key, string Stem, bool FromTags, long Size);

public static partial class Engine
{
    public sealed record CachedTags(long Size, double Mtime, Dictionary<string, string> Tags);

    /// Every audio file under `root` (skipping hidden files and folders), named like the page names them:
    /// "<folder name>/<path inside it>" with forward slashes.
    public static List<(string Path, string File)> ListAudio(string root)
    {
        var prefix = System.IO.Path.GetFileName(root.TrimEnd('\\', '/')) + "/";
        var output = new List<(string, string)>();
        var stack = new Stack<string>([root]);
        while (stack.Count > 0)
        {
            var dir = stack.Pop();
            IEnumerable<string> entries;
            try { entries = Directory.EnumerateFileSystemEntries(dir); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { continue; }
            foreach (var e in entries)
            {
                var name = System.IO.Path.GetFileName(e);
                if (name.StartsWith('.')) continue;
                FileAttributes a;
                try { a = File.GetAttributes(e); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { continue; }
                if ((a & (FileAttributes.Hidden | FileAttributes.System)) != 0) continue;
                if ((a & FileAttributes.Directory) != 0) { if ((a & FileAttributes.ReparsePoint) == 0) stack.Push(e); continue; }
                if (!AudioExts.Contains(ExtOf(name))) continue;
                output.Add((prefix + System.IO.Path.GetRelativePath(root, e).Replace('\\', '/'), e));
            }
        }
        return output;
    }

    public sealed record ScanResult(List<LibraryFile> Files, int AudioCount, Dictionary<string, CachedTags> Fresh, List<string> Paths);

    /// Reads the tags of every audio file (cached tags are reused unless `reread`) and keeps the Juice WRLD ones (by
    /// folder name or artist tag) unless `onlyJuice` is off. A network drive answers each read slowly but can serve
    /// many at once, so 16 files are read in parallel there (8 on a local disk).
    public static async Task<ScanResult> ScanAsync(string root, bool onlyJuice, IReadOnlyDictionary<string, CachedTags> cache, bool reread,
                                                   Action<int, int>? progress = null, CancellationToken ct = default)
    {
        var audio = await Task.Run(() => ListAudio(root), ct);
        bool network = root.StartsWith(@"\\") || (System.IO.Path.GetPathRoot(root) is { } dr && SafeDriveType(dr) == DriveType.Network);
        var fresh = new System.Collections.Concurrent.ConcurrentDictionary<string, CachedTags>();
        var found = new System.Collections.Concurrent.ConcurrentBag<LibraryFile>();
        int done = 0;
        await Parallel.ForEachAsync(audio, new ParallelOptions { MaxDegreeOfParallelism = network ? 16 : 8, CancellationToken = ct }, (item, _) =>
        {
            var (path, file) = item;
            var ext = ExtOf(path);
            Dictionary<string, string> tags; long size;
            if (!reread && cache.TryGetValue(path, out var hit)) { tags = hit.Tags; size = hit.Size; }
            else
            {
                var info = new FileInfo(file);
                size = info.Exists ? info.Length : 0;
                tags = TagReader.Read(file, ext);
                fresh[path] = new CachedTags(size, info.Exists ? new DateTimeOffset(info.LastWriteTimeUtc).ToUnixTimeMilliseconds() : 0, tags);
            }
            if (!onlyJuice || CountsAsJuice(path, tags))
            {
                var title = tags.GetValueOrDefault("title", "") is { Length: > 0 } t ? t : TitleFromFilename(path);
                found.Add(new LibraryFile(path, ext, tags, title, Normalize(title), StemOf(path), tags.GetValueOrDefault("title", "").Length > 0, size));
            }
            var n = Interlocked.Increment(ref done);
            if (n % 20 == 0) progress?.Invoke(n, audio.Count);
            return ValueTask.CompletedTask;
        });
        progress?.Invoke(audio.Count, audio.Count);
        return new ScanResult(found.OrderBy(f => f.Path, StringComparer.CurrentCultureIgnoreCase).ToList(), audio.Count,
                              new Dictionary<string, CachedTags>(fresh), audio.Select(a => a.Path).ToList());
    }
    static DriveType SafeDriveType(string root) { try { return new DriveInfo(root).DriveType; } catch { return DriveType.Unknown; } }

    // MARK: Matching

    public static double Similarity(byte[] a, byte[] b)
    {
        int la = a.Length, lb = b.Length;
        if (la == 0 && lb == 0) return 1;
        var prev = Enumerable.Range(0, lb + 1).ToArray(); var cur = new int[lb + 1];
        for (int i = 1; i <= la; i++)
        {
            cur[0] = i;
            for (int j = 1; j <= lb; j++) cur[j] = Math.Min(Math.Min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 2));
            (prev, cur) = (cur, prev);
        }
        return (double)(la + lb - prev[lb]) / (la + lb);
    }

    /// The closest title key at or above the cutoff (the later of equally close keys, as the page does).
    public static string? ClosestKey(string key, List<byte[]> keys, List<string> names, double cutoff)
    {
        var k = Encoding.UTF8.GetBytes(key);
        string? best = null; double bestScore = cutoff;
        for (int n = 0; n < keys.Count; n++)
        {
            var c = keys[n];
            if (Math.Abs(c.Length - k.Length) > Math.Max(c.Length, k.Length) * 0.25) continue;
            var score = Similarity(k, c);
            if (score >= bestScore) { bestScore = score; best = names[n]; }
        }
        return best;
    }

    public sealed class Match
    {
        public Dictionary<int, List<string>> Owned { get; } = [];      // song index → paths of its files
        public Dictionary<string, List<int>> SongsFor { get; } = [];   // path → song indexes
        public Dictionary<string, string> How { get; } = [];           // path → manual, title, file or close
        public List<string> Unmatched { get; } = [];
    }

    /// Matches files to catalog songs: a match set by hand, the exact title, the exact file name of the site's file
    /// (for files saved straight from juicewrldapi.com), then a close title.
    public static Match MatchFiles(List<EngineSong> catalog, IEnumerable<LibraryFile> files, IReadOnlyDictionary<string, string> overrides)
    {
        var index = new Dictionary<string, List<int>>(); var keyOrder = new List<string>(); var stems = new Dictionary<string, List<int>>(); var byId = new Dictionary<string, int>();
        for (int i = 0; i < catalog.Count; i++)
        {
            var song = catalog[i];
            byId[song.Id] = i;
            foreach (var t in new[] { song.Name }.Concat(song.Alt))
            {
                var k = Normalize(t);
                if (k.Length == 0) continue;
                if (!index.TryGetValue(k, out var list)) { index[k] = list = []; keyOrder.Add(k); }
                if (!list.Contains(i)) list.Add(i);
            }
            if (song.FilePath.Length > 0)
            {
                var st = StemOf(song.FilePath);
                if (st.Length > 0) { if (!stems.TryGetValue(st, out var l)) stems[st] = l = []; if (!l.Contains(i)) l.Add(i); }
            }
        }
        var keyBytes = keyOrder.Select(Encoding.UTF8.GetBytes).ToList();
        var fuzzy = new Dictionary<string, string?>(); var m = new Match();
        foreach (var f in files)
        {
            overrides.TryGetValue(f.Path, out var o);
            if (o == "none") { m.Unmatched.Add(f.Path); continue; }
            List<int>? hits = null; string how = "";
            if (o is not null && byId.TryGetValue(o, out var oi)) { hits = [oi]; how = "manual"; }
            if (hits is null && f.Key.Length > 0 && index.TryGetValue(f.Key, out var h1)) { hits = h1; how = "title"; }
            if (hits is null && f.Stem.Length > 0 && stems.TryGetValue(f.Stem, out var h2)) { hits = h2; how = "file"; }
            if (hits is null && f.Key.Length > 0)
            {
                if (!fuzzy.TryGetValue(f.Key, out var ck)) fuzzy[f.Key] = ck = ClosestKey(f.Key, keyBytes, keyOrder, FuzzyCutoff);
                if (ck is not null && index.TryGetValue(ck, out var h3)) { hits = h3; how = "close"; }
            }
            if (hits is null) { m.Unmatched.Add(f.Path); continue; }
            m.How[f.Path] = how;
            m.SongsFor[f.Path] = hits;
            foreach (var i in hits) { if (!m.Owned.TryGetValue(i, out var l)) m.Owned[i] = l = []; l.Add(f.Path); }
        }
        return m;
    }

    // MARK: What the screens show about songs and eras

    public const string NoEra = "No era listed";
    static readonly Dictionary<string, int> Months = new() { ["jan"] = 0, ["feb"] = 1, ["mar"] = 2, ["apr"] = 3, ["may"] = 4, ["jun"] = 5, ["jul"] = 6, ["aug"] = 7, ["sep"] = 8, ["oct"] = 9, ["nov"] = 10, ["dec"] = 11 };

    public static bool IsReleased(EngineSong s) => s.Category.Trim().ToLowerInvariant() == "released" || HasValue(s.Release);
    public static string EraName(EngineSong s) => HasValue(s.Era) ? s.Era : NoEra;
    /// "recording_session" → "Recording session".
    public static string Capital(string c) => (c.Length > 0 ? char.ToUpperInvariant(c[0]) + c[1..] : c).Replace("_", " ");

    static List<string> UniqueIgnoringCase(IEnumerable<string> list)
    {
        var seen = new HashSet<string>();
        return list.Where(x => seen.Add(x.ToLowerInvariant())).ToList();
    }
    /// "Nick Mira & Dre Moon, Taz Taylor" → the names.
    public static List<string> SplitNames(string text)
    {
        var t = Regex.Replace(text, @"\((?:feat|ft|prod)\.?(?:\s*by)?\s*", ",", RegexOptions.IgnoreCase);
        t = Regex.Replace(t, "[()]", ",");
        return UniqueIgnoringCase(Regex.Split(t, @"\s*(?:,|;|/|&|\+|\band\b|\bfeat\.?|\bft\.)\s*", RegexOptions.IgnoreCase)
            .Select(x => x.Trim()).Where(x => HasValue(x) && x.Length > 1));
    }
    public static List<string> SplitStudios(string text) =>
        UniqueIgnoringCase(Regex.Split(text, @"\s*(?:;|\n|\||/)\s*").Select(x => x.Trim()).Where(HasValue));
    /// The years a text mentions, with short ranges ("2017-2019") filled in, in the page's order.
    public static List<int> YearsIn(string text)
    {
        var output = new List<int>();
        void Add(int y) { if (!output.Contains(y)) output.Add(y); }
        foreach (System.Text.RegularExpressions.Match m in Regex.Matches(text, @"\b(?:19|20)\d{2}\b")) Add(int.Parse(m.Value));
        foreach (System.Text.RegularExpressions.Match m in Regex.Matches(text, @"\b((?:19|20)\d{2})\s*(?:-|–|—|to)\s*((?:19|20)\d{2})\b"))
        {
            int a = int.Parse(m.Groups[1].Value), b = int.Parse(m.Groups[2].Value);
            if (b > a && b - a <= 6) for (int y = a; y <= b; y++) Add(y);
        }
        return output;
    }
    /// The month a song was recorded, as year * 12 + month (0-11).
    public static int? RecordMonth(string text)
    {
        var g = Regex.Match(text, @"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(?:\d{1,2}(?:st|nd|rd|th)?,?\s+)?((?:19|20)\d{2})\b", RegexOptions.IgnoreCase);
        if (g.Success) return int.Parse(g.Groups[2].Value) * 12 + Months[g.Groups[1].Value.ToLowerInvariant()];
        var d = Regex.Match(text, @"\b((?:19|20)\d{2})-(\d{2})-\d{2}\b");
        if (d.Success && int.Parse(d.Groups[2].Value) is var mo and >= 1 and <= 12) return int.Parse(d.Groups[1].Value) * 12 + mo - 1;
        return null;
    }
    /// For sorting eras: year * 12 + month (January when there's no month).
    public static int? TimeKey(string text)
    {
        var g = Regex.Match(text, @"(?:\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?,?\s+)?\b((?:19|20)\d{2})\b", RegexOptions.IgnoreCase);
        if (!g.Success) return null;
        return int.Parse(g.Groups[2].Value) * 12 + (g.Groups[1].Success ? Months[g.Groups[1].Value.ToLowerInvariant()] : 0);
    }
    /// Every "Month D, YYYY" in a text.
    public static List<(int Y, int M, int D)> DatesIn(string text) =>
        Regex.Matches(text, @"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+((?:19|20)\d{2})\b", RegexOptions.IgnoreCase)
            .Select(m => (int.Parse(m.Groups[3].Value), Months[m.Groups[1].Value.ToLowerInvariant()], int.Parse(m.Groups[2].Value))).ToList();

    public sealed record EraStat(string Name, int Have, int Total, string TimeFrame, string Description);

    /// The eras in time order (by the era's time frame, else its earliest song), with how many songs you have.
    public static List<EraStat> EraStats(List<EngineSong> catalog, ISet<int> owned, IReadOnlyDictionary<string, EraInfo> eras)
    {
        var order = new List<string>(); var stats = new Dictionary<string, (int Total, int Have, int? Earliest)>();
        for (int i = 0; i < catalog.Count; i++)
        {
            var s = catalog[i]; var name = EraName(s);
            if (!stats.ContainsKey(name)) { order.Add(name); stats[name] = (0, 0, null); }
            var st = stats[name];
            st.Total++;
            if (owned.Contains(i)) st.Have++;
            if ((TimeKey(s.RecordDates) ?? TimeKey(s.Release)) is { } k && (st.Earliest is null || k < st.Earliest)) st.Earliest = k;
            stats[name] = st;
        }
        var list = order.Select(name =>
        {
            var st = stats[name]; eras.TryGetValue(name, out var info);
            double key = name == NoEra ? double.PositiveInfinity : (info is not null && TimeKey(info.TimeFrame) is { } tk ? tk : st.Earliest ?? double.PositiveInfinity);
            return (Stat: new EraStat(name, st.Have, st.Total, info?.TimeFrame ?? "", info?.Description ?? ""), Key: key, Id: info?.Id ?? 1_000_000_000);
        }).ToList();
        list.Sort((a, b) => a.Key != b.Key ? a.Key.CompareTo(b.Key) : a.Id != b.Id ? a.Id.CompareTo(b.Id) : string.Compare(a.Stat.Name, b.Stat.Name, CultureInfo.CurrentCulture, CompareOptions.IgnoreCase));
        return list.Select(x => x.Stat).ToList();
    }

    // MARK: Export helpers

    /// JavaScript's encodeURIComponent.
    public static string EncodeUriComponent(string s)
    {
        const string keep = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()";
        var sb = new StringBuilder();
        foreach (var b in Encoding.UTF8.GetBytes(s))
        {
            if (b < 128 && keep.Contains((char)b)) sb.Append((char)b); else sb.Append('%').Append(b.ToString("X2"));
        }
        return sb.ToString();
    }
    public static string FileUrl(EngineSong s) => s.FilePath.Length == 0 ? "" : $"https://juicewrldapi.com/juicewrld/files/download/?path={EncodeUriComponent(s.FilePath)}";
    /// Spreadsheet text: a byte order mark (so Excel reads UTF-8), every cell quoted, Windows line ends.
    public static string CsvText(IEnumerable<IEnumerable<string>> lines) =>
        "﻿" + string.Join("\r\n", lines.Select(l => string.Join(",", l.Select(c => "\"" + c.Replace("\"", "\"\"") + "\""))));

    /// A CSV file's rows (quotes, doubled quotes, commas and line breaks inside quotes).
    public static List<List<string>> ParseCsv(string text)
    {
        var rows = new List<List<string>>(); var row = new List<string>(); var cell = new StringBuilder(); bool quoted = false;
        var t = text.StartsWith('﻿') ? text[1..] : text;
        for (int n = 0; n < t.Length; n++)
        {
            char c = t[n];
            if (quoted)
            {
                if (c != '"') cell.Append(c);
                else if (n + 1 < t.Length && t[n + 1] == '"') { cell.Append('"'); n++; }
                else quoted = false;
            }
            else if (c == '"') quoted = true;
            else if (c == ',') { row.Add(cell.ToString()); cell.Clear(); }
            else if (c is '\n' or '\r')
            {
                if (c == '\r' && n + 1 < t.Length && t[n + 1] == '\n') n++;
                row.Add(cell.ToString()); rows.Add(row); row = []; cell.Clear();
            }
            else cell.Append(c);
        }
        if (cell.Length > 0 || row.Count > 0) { row.Add(cell.ToString()); rows.Add(row); }
        return rows;
    }
}
