using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace JuiceTracker;

// The engine's pure logic, ported from the Mac app's Engine.swift (itself ported line for line from the old HTML page).
// tests/fixtures holds that page's answers for tricky inputs; JuiceTracker.Tests checks this code still gives them.

public sealed class EngineError(string message) : Exception(message);

/// A catalog song, cleaned the way the page's cleanSong does it.
public sealed record EngineSong
{
    public string Id { get; init; } = "";
    public string PublicId { get; init; } = "";
    public string Name { get; init; } = "";
    public List<string> Alt { get; init; } = [];
    public string Era { get; init; } = "";
    public string Category { get; init; } = "";
    public string Length { get; init; } = "";
    public string Release { get; init; } = "";
    public string Artists { get; init; } = "";
    public string Producers { get; init; } = "";
    public string RecordDates { get; init; } = "";
    public string Engineers { get; init; } = "";
    public string Locations { get; init; } = "";
    public string Key { get; init; } = "";
    public string Info { get; init; } = "";
    public string Notes { get; init; } = "";
    public string PreviewDate { get; init; } = "";
    public string LeakDate { get; init; } = "";
    public string LeakType { get; init; } = "";
    public string Sessions { get; init; } = "";
    public string Dates { get; init; } = "";
    public string Bitrate { get; init; } = "";
    public string FilePath { get; init; } = "";
    public bool HasDetails { get; init; }
}

public sealed record EraInfo(int? Id, string Description, string TimeFrame);

public static partial class Engine
{
    public const string Api = "https://juicewrldapi.com/juicewrld/songs/";
    public const double FuzzyCutoff = 0.88;
    public static readonly HashSet<string> AudioExts = ["mp3", "flac", "m4a", "m4b", "aac", "alac", "ogg", "opus", "wav", "aiff", "aif", "wma"];
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    // MARK: Text helpers (same rules as the page)

    /// The match key of a title: no accents, brackets, "feat ..." tails or punctuation; "&" becomes "and".
    public static string Normalize(string? title)
    {
        if (string.IsNullOrEmpty(title)) return "";
        var raw = NoMarks(title.Normalize(NormalizationForm.FormKD)).ToLowerInvariant();
        var t = Regex.Replace(raw, @"\s*[\(\[\{][^\)\]\}]*[\)\]\}]", "");
        t = Regex.Replace(t, @"\b(feat|ft|prod)\.?\s.*$", "");
        t = Squash(t.Replace("&", " and "));
        return t.Length == 0 ? Squash(raw) : t;
    }
    static string NoMarks(string s) => new(s.Where(c => c < 0x300 || c > 0x36F).ToArray());
    /// Keeps a-z, 0-9 and spaces, with runs of spaces made one and the ends trimmed.
    static string Squash(string s) =>
        string.Join(" ", new string(s.Where(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or ' ').ToArray()).Split(' ', StringSplitOptions.RemoveEmptyEntries));

    public static bool HasValue(string v)
    {
        var t = v.Trim();
        return t.Length > 0 && !Regex.IsMatch(t, @"^(n/?a|none|unknown|tba|tbd|null|-+|\?+)$", RegexOptions.IgnoreCase);
    }
    public static string YearOf(string v) { var m = Regex.Match(v, @"\b(19|20)\d{2}\b"); return m.Success ? m.Value : ""; }
    public static bool HasArtist(string text) =>
        new string(text.ToLowerInvariant().Where(c => c is >= 'a' and <= 'z').ToArray()).Contains("juicewrld");
    /// Whether the library counts a file as Juice WRLD: its path or its artist tags say so.
    public static bool CountsAsJuice(string path, Dictionary<string, string> tags) =>
        HasArtist(path) || HasArtist($"{tags.GetValueOrDefault("artist", "")} {tags.GetValueOrDefault("albumartist", "")}");
    public static string ExtOf(string path) { var m = Regex.Match(path, @"\.([a-zA-Z0-9]+)$"); return m.Success ? m.Groups[1].Value.ToLowerInvariant() : ""; }
    public static string BaseName(string path) => path.Split('/', '\\').Last();
    public static string StemOf(string path) => Regex.Replace(BaseName(path), @"\.[^.]+$", "").ToLowerInvariant().Trim();
    public static string TitleFromFilename(string path)
    {
        var stem = Regex.Replace(BaseName(path), @"\.[^.]+$", "");
        if (stem.Contains(" - ")) stem = stem.Split(" - ").Last();
        return Regex.Replace(stem, @"^\d{1,3}[\s._-]+", "");
    }

    // MARK: Catalog

    static readonly string[] DetailKeys = ["engineers", "recording_locations", "original_key", "additional_information", "notes", "preview_date", "date_leaked", "session_titles"];

    // JSON values the way JavaScript sees them: null is missing, and "", 0 and false are falsy.
    static JsonNode? Present(JsonNode? v) => v is JsonValue jv && jv.GetValueKind() == JsonValueKind.Null ? null : v;
    static bool Truthy(JsonNode? v)
    {
        v = Present(v);
        if (v is null) return false;
        if (v is JsonValue jv)
        {
            switch (jv.GetValueKind())
            {
                case JsonValueKind.String: return jv.GetValue<string>().Length > 0;
                case JsonValueKind.Number: var d = jv.GetValue<double>(); return d != 0 && !double.IsNaN(d);
                case JsonValueKind.False: return false;
            }
        }
        return true;
    }
    /// JavaScript's String(v).
    public static string JsString(JsonNode? v)
    {
        v = Present(v);
        switch (v)
        {
            case null: return "";
            case JsonArray a: return string.Join(",", a.Select(x => Present(x) is null ? "" : JsString(x)));
            case JsonObject: return "[object Object]";
            case JsonValue jv:
                switch (jv.GetValueKind())
                {
                    case JsonValueKind.String: return jv.GetValue<string>();
                    case JsonValueKind.True: return "true";
                    case JsonValueKind.False: return "false";
                    case JsonValueKind.Number:
                        var d = jv.GetValue<double>();
                        return d == Math.Round(d) && Math.Abs(d) < 1e15 ? ((long)d).ToString(CultureInfo.InvariantCulture) : d.ToString("R", CultureInfo.InvariantCulture);
                }
                break;
        }
        return v.ToJsonString();
    }
    static JsonNode? Either(JsonObject s, params string[] keys)
    {
        foreach (var k in keys) if (Present(s[k]) is { } v) return v;
        return null;
    }
    public static List<string> ToList(JsonNode? v)
    {
        if (!Truthy(v)) return [];
        if (Present(v) is JsonArray a) return a.Where(Truthy).Select(JsString).ToList();
        return JsString(v).Split(['\n', ';', '|']).Select(x => x.Trim()).Where(x => x.Length > 0).ToList();
    }
    public static string TextOf(JsonNode? v)
    {
        if (Present(v) is JsonArray a) return string.Join(", ", a.Where(Truthy).Select(JsString));
        return Truthy(v) ? JsString(v).Trim() : "";
    }

    public static EngineSong CleanSong(JsonObject s)
    {
        var name = Truthy(s["name"]) ? JsString(s["name"]) : "Unknown";
        var seen = new List<string>();
        var alt = ToList(Either(s, "alt", "alt_titles", "track_titles")).Where(t =>
        {
            var low = t.ToLowerInvariant();
            if (low == name.ToLowerInvariant() || seen.Contains(low)) return false;
            seen.Add(low);
            return true;
        }).ToList();
        string era = Present(s["era"]) is JsonObject e ? (Truthy(e["name"]) ? JsString(e["name"]) : "Unknown") : (Truthy(s["era"]) ? JsString(s["era"]) : "Unknown");
        var path = Present(s["path"]) is JsonValue pv && pv.GetValueKind() == JsonValueKind.String ? pv.GetValue<string>() : null;
        var filePath = Present(s["filePath"]) is JsonValue fv && fv.GetValueKind() == JsonValueKind.String ? fv.GetValue<string>() : (path is not null && path.Contains('/') ? path : "");
        bool hasDetails = Present(s["hasDetails"]) is JsonValue hv && hv.GetValueKind() is JsonValueKind.True or JsonValueKind.False
            ? hv.GetValue<bool>() : DetailKeys.Any(s.ContainsKey);
        return new EngineSong
        {
            Id = JsString(Either(s, "id", "public_id") ?? JsonValue.Create(name)),
            PublicId = Present(s["publicId"]) is { } p1 ? JsString(p1) : Present(s["public_id"]) is { } p2 ? JsString(p2) : "",
            Name = name, Alt = alt, Era = era,
            Category = Truthy(s["category"]) ? JsString(s["category"]) : "unknown",
            Length = Truthy(s["length"]) ? JsString(s["length"]) : "",
            Release = TextOf(Either(s, "release", "release_date")),
            Artists = TextOf(Either(s, "artists", "credited_artists")),
            Producers = TextOf(s["producers"]),
            RecordDates = TextOf(Either(s, "recordDates", "record_dates")),
            Engineers = TextOf(s["engineers"]),
            Locations = TextOf(Either(s, "locations", "recording_locations")),
            Key = TextOf(Either(s, "key", "original_key")),
            Info = TextOf(Either(s, "info", "additional_information")),
            Notes = TextOf(s["notes"]),
            PreviewDate = TextOf(Either(s, "previewDate", "preview_date")),
            LeakDate = TextOf(Either(s, "leakDate", "date_leaked")),
            LeakType = TextOf(Either(s, "leakType", "leak_type")),
            Sessions = TextOf(Either(s, "sessions", "session_titles")),
            Dates = TextOf(s["dates"]),
            Bitrate = TextOf(s["bitrate"]),
            FilePath = filePath,
            HasDetails = hasDetails,
        };
    }

    /// Era descriptions and time frames from raw songs; the first song of an era wins.
    public static Dictionary<string, EraInfo> CollectEras(IEnumerable<JsonObject> raw, Dictionary<string, EraInfo>? into = null)
    {
        var output = into is null ? new Dictionary<string, EraInfo>() : new Dictionary<string, EraInfo>(into);
        foreach (var s in raw)
        {
            if (Present(s["era"]) is not JsonObject e || !Truthy(e["name"])) continue;
            var name = JsString(e["name"]);
            output.TryAdd(name, new EraInfo(null, TextOf(e["description"]), TextOf(Either(e, "time_frame", "timeFrame"))));
        }
        return output;
    }

    public static List<JsonObject> SongsFromJson(JsonNode? data) => data switch
    {
        JsonArray a => a.OfType<JsonObject>().ToList(),
        JsonObject d when d["results"] is JsonArray r => r.OfType<JsonObject>().ToList(),
        JsonObject d when d["songs"] is JsonArray r => r.OfType<JsonObject>().ToList(),
        _ => [],
    };

    /// Cleans and de-duplicates by id: a later copy replaces an earlier one but keeps its place.
    public static List<EngineSong> MergeSongs(IEnumerable<IEnumerable<JsonObject>> lists)
    {
        var order = new List<string>(); var byId = new Dictionary<string, EngineSong>();
        foreach (var list in lists)
            foreach (var raw in list)
            {
                var s = CleanSong(raw);
                if (!byId.ContainsKey(s.Id)) order.Add(s.Id);
                byId[s.Id] = s;
            }
        return order.Select(id => byId[id]).ToList();
    }

    public sealed record FetchedCatalog(List<JsonObject> Raw, List<EngineSong> Songs, Dictionary<string, EraInfo> Eras);
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(60) };

    /// Downloads the whole catalog, 100 songs a page, waiting out rate limits like the page does.
    public static async Task<FetchedCatalog> FetchCatalogAsync(Action<int, int?>? progress = null, CancellationToken ct = default)
    {
        var raw = new List<JsonObject>(); int? total = null;
        for (int page = 1; page <= 500; page++)
        {
            string body = ""; int status = 0;
            for (int attempt = 0; attempt < 5; attempt++)
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, $"{Api}?page={page}&page_size=100");
                req.Headers.Accept.ParseAdd("application/json");
                using var r = await Http.SendAsync(req, ct);
                status = (int)r.StatusCode; body = await r.Content.ReadAsStringAsync(ct);
                if (r.StatusCode != HttpStatusCode.TooManyRequests) break;
                await Task.Delay(TimeSpan.FromSeconds(Math.Pow(2, attempt) * 3), ct);
            }
            if (status == 404 && page > 1) break;
            if (status is < 200 or >= 300) throw new EngineError($"The catalog request failed (status {status}).");
            var json = JsonNode.Parse(body);
            var results = SongsFromJson(json);
            raw.AddRange(results);
            var d = json as JsonObject;
            if (d?["count"] is JsonValue c && c.GetValueKind() == JsonValueKind.Number) total = c.GetValue<int>();
            progress?.Invoke(raw.Count, total);
            if (!Truthy(d?["next"]) || results.Count == 0 || (total is { } t && raw.Count >= t)) break;
            await Task.Delay(300, ct);
        }
        var songs = MergeSongs([raw]);
        if (songs.Count == 0) throw new EngineError("The catalog came back empty.");
        var eras = CollectEras(raw);
        try
        {
            foreach (var (name, info) in await FetchEraListAsync(ct)) // the era list is optional
            {
                var have = eras.GetValueOrDefault(name) ?? new EraInfo(null, "", "");
                eras[name] = new EraInfo(info.Id, HasValue(have.Description) ? have.Description : info.Description,
                                         HasValue(have.TimeFrame) ? have.TimeFrame : info.TimeFrame);
            }
        }
        catch (Exception) when (!ct.IsCancellationRequested) { }
        return new FetchedCatalog(raw, songs, eras);
    }

    public static async Task<Dictionary<string, EraInfo>> FetchEraListAsync(CancellationToken ct = default)
    {
        var eras = new Dictionary<string, EraInfo>();
        string? url = "https://juicewrldapi.com/juicewrld/eras/?page_size=100";
        for (int n = 0; n < 20 && url is not null; n++)
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.Accept.ParseAdd("application/json");
            using var r = await Http.SendAsync(req, ct);
            if (!r.IsSuccessStatusCode) break;
            var json = JsonNode.Parse(await r.Content.ReadAsStringAsync(ct));
            var list = json as JsonArray ?? (json as JsonObject)?["results"] as JsonArray ?? [];
            foreach (var e in list.OfType<JsonObject>().Where(e => Truthy(e["name"])))
                eras[JsString(e["name"])] = new EraInfo(Present(e["id"]) is JsonValue iv && iv.GetValueKind() == JsonValueKind.Number ? iv.GetValue<int>() : null,
                                                        TextOf(e["description"]), TextOf(Either(e, "time_frame", "timeFrame")));
            url = json is JsonObject o && Truthy(o["next"]) ? Regex.Replace(JsString(o["next"]), "^http:", "https:") : null;
        }
        return eras;
    }
}
