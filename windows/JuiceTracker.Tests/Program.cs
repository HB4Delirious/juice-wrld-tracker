// Checks the C# engine (windows/JuiceTracker.Core) against the old HTML page's own answers in tests/fixtures, the
// same frozen answers the Mac app's Swift engine is checked against. Run: dotnet run --project windows/JuiceTracker.Tests
using System.Text.Json;
using System.Text.Json.Nodes;
using JuiceTracker;

var dir = args.Length > 0 ? args[0] : FindFixtures();
var fx = JsonNode.Parse(File.ReadAllText(Path.Combine(dir, "fixtures.json")))!.AsObject();
int checks = 0, failures = 0;
void Expect(bool ok, Func<string> what) { checks++; if (!ok) { failures++; Console.WriteLine("FAIL: " + what()); } }
static string S(JsonNode? n) => n?.GetValue<string>() ?? "";
static Dictionary<string, string> Tags(JsonNode? n) => n is JsonObject o ? o.ToDictionary(kv => kv.Key, kv => kv.Value?.GetValue<string>() ?? "") : [];
static bool SameTags(Dictionary<string, string> a, Dictionary<string, string> b) => a.Count == b.Count && a.All(kv => b.TryGetValue(kv.Key, out var v) && v == kv.Value);
static string Show(Dictionary<string, string> t) => "{" + string.Join(", ", t.OrderBy(kv => kv.Key).Select(kv => $"{kv.Key}: {kv.Value}")) + "}";
static List<EngineSong> Songs(JsonNode? n) => n!.AsArray().Select(x => x!.Deserialize<EngineSong>(Engine.Json)!).ToList();

// text helpers
var text = fx["text"]!.AsObject();
foreach (var c in text["normalize"]!.AsArray()) { var a = c![0]?.GetValue<string>(); var got = Engine.Normalize(a); Expect(got == S(c[1]), () => $"normalize({a}) = {got}, page says {c[1]}"); }
foreach (var c in text["hasValue"]!.AsArray()) Expect(Engine.HasValue(S(c![0])) == c[1]!.GetValue<bool>(), () => $"hasValue({c![0]})");
foreach (var c in text["yearOf"]!.AsArray()) Expect(Engine.YearOf(S(c![0])) == S(c[1]), () => $"yearOf({c![0]})");
foreach (var c in text["hasArtist"]!.AsArray()) Expect(Engine.HasArtist(S(c![0])) == c[1]!.GetValue<bool>(), () => $"hasArtist({c![0]})");
foreach (var c in text["extOf"]!.AsArray()) Expect(Engine.ExtOf(S(c![0])) == S(c[1]), () => $"extOf({c![0]}) = {Engine.ExtOf(S(c![0]))}");
foreach (var c in text["stemOf"]!.AsArray()) Expect(Engine.StemOf(S(c![0])) == S(c[1]), () => $"stemOf({c![0]}) = {Engine.StemOf(S(c![0]))}");
foreach (var c in text["titleFromFilename"]!.AsArray()) Expect(Engine.TitleFromFilename(S(c![0])) == S(c[1]), () => $"titleFromFilename({c![0]}) = {Engine.TitleFromFilename(S(c![0]))}");
foreach (var c in text["similarity"]!.AsArray())
{
    var got = Engine.Similarity(System.Text.Encoding.UTF8.GetBytes(S(c![0])), System.Text.Encoding.UTF8.GetBytes(S(c[1])));
    Expect(Math.Abs(got - c[2]!.GetValue<double>()) < 1e-12, () => $"similarity({c[0]}, {c[1]}) = {got}, page says {c[2]}");
}

// catalog cleaning: compared as JSON, field by field
var catalog = fx["catalog"]!.AsObject();
var raw = catalog["raw"]!.AsArray().Select(x => x!.AsObject()).ToList();
var cleaned = catalog["cleaned"]!.AsArray();
for (int n = 0; n < cleaned.Count; n++)
{
    var page = cleaned[n]!.AsObject(); var mine = JsonSerializer.SerializeToNode(Engine.CleanSong(raw[n]), Engine.Json)!.AsObject();
    foreach (var k in page.Select(kv => kv.Key).Union(mine.Select(kv => kv.Key)))
    {
        var a = mine[k]?.ToJsonString() ?? "null"; var b = page[k]?.ToJsonString() ?? "null";
        Expect(a == b, () => $"cleanSong #{n} {k}: {a} vs page {b}");
    }
}
var merged = Engine.MergeSongs([raw]).Select(s => s.Id).ToList(); var pageMerged = catalog["merged"]!.AsArray().Select(x => S(x!["id"])).ToList();
Expect(merged.SequenceEqual(pageMerged), () => $"mergeSongs ids {string.Join(",", merged)} vs page {string.Join(",", pageMerged)}");
var eras = Engine.CollectEras(raw); var pageEras = catalog["eras"]!.AsObject();
Expect(eras.Keys.Order().SequenceEqual(pageEras.Select(kv => kv.Key).Order()), () => "collectEras names");
foreach (var (name, pe) in pageEras) Expect(eras.TryGetValue(name, out var mine) && mine.Description == S(pe!["description"]) && mine.TimeFrame == S(pe["timeFrame"]), () => $"collectEras {name}");

// tag reading, on files the page's own writers made and hand-built ones
foreach (var f in fx["files"]!.AsArray())
{
    var name = S(f!["name"]); var page = Tags(f["tags"]);
    var mine = TagReader.Read(Path.Combine(dir, "files", name), S(f["ext"]));
    Expect(SameTags(mine, page), () => $"tags of {name}: {Show(mine)} vs page {Show(page)}");
}

// matching
var m = fx["matching"]!.AsObject();
var mSongs = Songs(m["catalog"]);
var mFiles = m["files"]!.AsArray().Select(x => new LibraryFile(S(x!["path"]), Engine.ExtOf(S(x["path"])), [], S(x["title"]), S(x["key"]), S(x["stem"]), false, 0)).ToList();
var matched = Engine.MatchFiles(mSongs, mFiles, Tags(m["overrides"]));
var pageOwned = m["owned"]!.AsObject().ToDictionary(kv => int.Parse(kv.Key), kv => kv.Value!.AsArray().Select(S).ToList());
Expect(matched.Owned.Count == pageOwned.Count && matched.Owned.All(kv => pageOwned.TryGetValue(kv.Key, out var v) && v.SequenceEqual(kv.Value)), () => "owned differs");
Expect(matched.Unmatched.SequenceEqual(m["unmatched"]!.AsArray().Select(S)), () => $"unmatched {string.Join(",", matched.Unmatched)}");
Expect(SameTags(matched.How, Tags(m["how"])), () => $"matched by {Show(matched.How)} vs page {Show(Tags(m["how"]))}");

// what the screens show
var d = fx["derived"]!.AsObject();
static List<int> Ints(JsonNode? n) => n is JsonArray a ? a.Select(x => x!.GetValue<int>()).ToList() : [];
foreach (var c in d["splitNames"]!.AsArray()) { var t = S(c![0]); Expect(Engine.SplitNames(t).SequenceEqual(c[1]!.AsArray().Select(S)), () => $"splitNames({t}) = {string.Join("|", Engine.SplitNames(t))}, page {c[1]}"); }
foreach (var c in d["splitStudios"]!.AsArray()) { var t = S(c![0]); Expect(Engine.SplitStudios(t).SequenceEqual(c[1]!.AsArray().Select(S)), () => $"splitStudios({t}) = {string.Join("|", Engine.SplitStudios(t))}, page {c[1]}"); }
foreach (var c in d["yearsIn"]!.AsArray()) { var t = S(c![0]); Expect(Engine.YearsIn(t).SequenceEqual(Ints(c[1])), () => $"yearsIn({t}) = {string.Join(",", Engine.YearsIn(t))}, page {c[1]}"); }
foreach (var c in d["recordMonth"]!.AsArray()) { var t = S(c![0]); Expect(Engine.RecordMonth(t) == c[1]?.GetValue<int?>(), () => $"recordMonth({t}) = {Engine.RecordMonth(t)}, page {c[1]}"); }
foreach (var c in d["timeKey"]!.AsArray()) { var t = S(c![0]); Expect(Engine.TimeKey(t) == c[1]?.GetValue<int?>(), () => $"timeKey({t}) = {Engine.TimeKey(t)}, page {c[1]}"); }
foreach (var c in d["datesIn"]!.AsArray())
{
    var t = S(c![0]); var page = c[1]!.AsArray().Select(x => (x!["y"]!.GetValue<int>(), x["m"]!.GetValue<int>(), x["d"]!.GetValue<int>())).ToList();
    Expect(Engine.DatesIn(t).SequenceEqual(page), () => $"datesIn({t})");
}
foreach (var c in d["capital"]!.AsArray()) Expect(Engine.Capital(S(c![0])) == S(c[1]), () => $"capital({c![0]})");
var eraFx = fx["eras"]!.AsObject();
var eraSongs = Songs(eraFx["catalog"]);
var info = eraFx["info"]!.AsObject().ToDictionary(kv => kv.Key, kv => new EraInfo(kv.Value!["id"]?.GetValue<int?>(), S(kv.Value["description"]), S(kv.Value["timeFrame"])));
var stats = Engine.EraStats(eraSongs, Ints(eraFx["owned"]).ToHashSet(), info);
var pageStats = eraFx["stats"]!.AsArray().Select(x => new Engine.EraStat(S(x!["name"]), x["have"]!.GetValue<int>(), x["total"]!.GetValue<int>(), S(x["timeFrame"]), S(x["description"]))).ToList();
Expect(stats.SequenceEqual(pageStats), () => $"eraStats {string.Join(",", stats.Select(s => s.Name))} vs page {string.Join(",", pageStats.Select(s => s.Name))}");

// export helpers
var ex = fx["exportCases"]!.AsObject();
foreach (var c in ex["uri"]!.AsArray()) Expect(Engine.EncodeUriComponent(S(c![0])) == S(c[1]), () => $"encodeURIComponent({c![0]}) = {Engine.EncodeUriComponent(S(c![0]))}, page {c[1]}");
foreach (var c in ex["fileUrl"]!.AsArray()) { var s = new EngineSong { Id = "1", Name = "x", FilePath = S(c![0]) }; Expect(Engine.FileUrl(s) == S(c[1]), () => $"fileUrl({c[0]}) = {Engine.FileUrl(s)}"); }
var csv = Engine.CsvText([["id", "name", "note"], ["1", "He said \"hi\"", "line\nbreak, comma"], ["2", "", "Ünïcode"]]);
Expect(csv.StartsWith('﻿') == ex["csvBom"]!.GetValue<bool>(), () => "csvText byte order mark");
Expect(csv[1..] == S(ex["csv"]), () => $"csvText: {csv} vs page {ex["csv"]}");

// writing tags: the same bytes, or the same error, as the page's writers
foreach (var c in fx["writes"]!.AsArray())
{
    var name = S(c!["name"]); var ext = S(c["ext"]);
    var input = Convert.FromBase64String(S(c["input"])); var desired = Tags(c["desired"]);
    var pageError = c["error"]?.GetValue<string>();
    try
    {
        var r = ext == "mp3" ? TagWriter.WriteMp3(input, desired) : ext == "flac" ? TagWriter.WriteFlac(input, desired) : TagWriter.WriteM4a(input, desired);
        if (pageError is not null) { Expect(false, () => $"{name}: C# wrote it, the page refused ({pageError})"); continue; }
        var pageOut = Convert.FromBase64String(S(c["out"]));
        Expect(r.Out.AsSpan().SequenceEqual(pageOut), () => $"{name}: different bytes ({r.Out.Length} vs page {pageOut.Length})");
        string? verifyError = null;
        try { if (ext == "mp3") TagWriter.VerifyMp3(input, r, desired); else if (ext == "flac") TagWriter.VerifyFlac(input, r, desired); else TagWriter.VerifyM4a(input, r, desired); }
        catch (EngineError err) { verifyError = err.Message; }
        Expect(verifyError == c["verify"]?.GetValue<string>(), () => $"{name}: safety check {verifyError ?? "passed"}, page {c["verify"]?.GetValue<string>() ?? "passed"}");
    }
    catch (EngineError err) { Expect(err.Message == pageError, () => $"{name}: {err.Message}, page {pageError ?? "wrote it"}"); }
}

// where missing songs are saved
var layoutSongs = Songs(fx["layoutSongs"]);
foreach (var l in fx["layouts"]!.AsArray())
{
    var name = S(l!["name"]);
    var files = l["files"]!.AsArray().Select(x => new LibraryFile(S(x!["path"]), Engine.ExtOf(S(x["path"])), Tags(x["tags"]), S(x["title"]), S(x["key"]), S(x["stem"]), false, x["size"]!.GetValue<long>())).ToList();
    var lm = Engine.MatchFiles(layoutSongs, files, new Dictionary<string, string>());
    var layout = Engine.LearnLayout(layoutSongs, files, lm);
    var snap = Engine.SnapshotCsv(files, lm, layoutSongs)[1..];
    Expect(snap == S(l["snapshot"]), () => $"{name}: snapshot CSV differs:\n{snap}\nvs page\n{l["snapshot"]}");
    for (int n = 0; n < layoutSongs.Count; n++)
    {
        var s = layoutSongs[n]; var want = S(l["folders"]![n]); var folder = Engine.SaveFolder(s, layout);
        Expect(folder == want, () => $"{name}: save folder for {s.Name} ({s.Era}) = {folder}, page {want}");
        Expect(Engine.SaveFileName(s) == S(l["fileNames"]![n]), () => $"{name}: file name for {s.Name} = {Engine.SaveFileName(s)}");
    }
}

// the tag fixer, duplicates and file health
var tools = fx["tools"]!.AsObject();
var toolSongs = Songs(tools["songs"]);
var toolLib = tools["lib"]!.AsArray().Select(x => new LibraryFile(S(x!["path"]), S(x["ext"]), Tags(x["tags"]), S(x["title"]), S(x["key"]), S(x["stem"]), x["fromTags"]!.GetValue<bool>(), x["size"]!.GetValue<long>())).ToList();
var tm = Engine.MatchFiles(toolSongs, toolLib, Tags(tools["overrides"]));
var planned = tools["planned"]!.AsArray();
for (int n = 0; n < planned.Count; n++)
{
    var mine = Engine.PlannedTags(toolSongs[n]).Where(kv => kv.Value.Length > 0).ToDictionary(); var page = Tags(planned[n]).Where(kv => kv.Value.Length > 0).ToDictionary();
    Expect(SameTags(mine, page), () => $"plannedTags({toolSongs[n].Name}) = {Show(mine)}, page {Show(page)}");
}
foreach (var p in tools["plans"]!.AsArray())
{
    var fields = p!["fields"]!.AsArray().Select(S).ToList(); var blanks = p["blanks"]!.GetValue<bool>();
    var plan = Engine.BuildPlan(toolLib, tm, toolSongs, fields, blanks, S(p["genre"]));
    var label = $"plan [{string.Join(",", fields)}] blanks={blanks}";
    Expect(plan.Same == p["same"]!.GetValue<int>(), () => $"{label}: {plan.Same} the same, page {p["same"]}");
    var pageSkipped = p["skipped"]!.AsArray().Select(x => S(x![0]) + "|" + S(x[1])).ToList();
    Expect(plan.Skipped.Select(x => x.Path + "|" + x.Reason).SequenceEqual(pageSkipped), () => $"{label}: skipped");
    var pageChanges = p["changes"]!.AsArray().Select(c => $"{S(c!["path"])} #{c["song"]} " + string.Join("; ", c["changes"]!.AsArray().Select(x => string.Join("→", x!.AsArray().Select(S))))).ToList();
    var mineChanges = plan.Changes.Select(c => $"{c.Path} #{c.Song} " + string.Join("; ", c.Changes.Select(x => $"{x.Key}→{x.From}→{x.To}"))).ToList();
    Expect(mineChanges.SequenceEqual(pageChanges), () => $"{label}: changes\n{string.Join("\n", mineChanges)}\nvs page\n{string.Join("\n", pageChanges)}");
}
var groups = Engine.DuplicateGroups(toolLib, tm, toolSongs); var pageGroups = tools["dupGroups"]!.AsArray();
Expect(groups.Count == pageGroups.Count, () => $"duplicate groups: {groups.Count}, page {pageGroups.Count}");
foreach (var (gr, pg) in groups.Zip(pageGroups))
{
    Expect(gr.Song == pg!["song"]?.GetValue<int?>() && gr.Title == S(pg["title"]) && gr.Files.Select(f => f.Path).SequenceEqual(pg["files"]!.AsArray().Select(S)) && gr.Extra == pg["extra"]!.GetValue<long>(),
           () => $"duplicate group {gr.Title} [{string.Join(",", gr.Files.Select(f => f.Path))}] extra {gr.Extra} vs page {pg.ToJsonString()}");
    Expect(Engine.IsExactDuplicate(gr) == pg["exact"]!.GetValue<bool>() && Engine.BestCopy(gr.Files).Path == S(pg["keep"]), () => $"duplicate group {gr.Title}: exact/keep");
}
var probes = tools["probes"]!.AsObject().ToDictionary(kv => kv.Key, kv => new Engine.Probe(kv.Value!["ok"]!.GetValue<bool>(), kv.Value["seconds"]!.GetValue<double>(), kv.Value["size"]!.GetValue<long>()));
var issues = Engine.HealthIssues(toolLib, tm, toolSongs, probes).Select(i => $"{i.Path}|{i.Group}|{i.Text}").ToList();
var pageIssues = tools["health"]!.AsArray().Select(x => string.Join("|", x!.AsArray().Select(S))).ToList();
Expect(issues.SequenceEqual(pageIssues), () => $"health issues\n{string.Join("\n", issues)}\nvs page\n{string.Join("\n", pageIssues)}");
foreach (var c in tools["sizes"]!.AsArray()) { var n = c![0]!.GetValue<long>(); Expect(Engine.FormatSize(n) == S(c[1]), () => $"formatSize({n}) = {Engine.FormatSize(n)}, page {c[1]}"); }
foreach (var c in tools["times"]!.AsArray()) { var n = c![0]!.GetValue<double>(); Expect(Engine.FmtTime(n) == S(c[1]), () => $"fmtTime({n}) = {Engine.FmtTime(n)}, page {c[1]}"); }
foreach (var c in tools["kbps"]!.AsArray()) Expect(Engine.SiteKbps(S(c![0]), S(c[1])) == c[2]!.GetValue<int>(), () => $"siteKbps({c![0]})");
foreach (var c in tools["lengths"]!.AsArray()) Expect(Engine.LengthSeconds(S(c![0])) == c[1]?.GetValue<double?>(), () => $"lengthSeconds({c![0]})");
foreach (var c in tools["keys"]!.AsArray()) Expect(Engine.CmdkKey(S(c![0])) == S(c[1]), () => $"cmdkKey({c![0]}) = {Engine.CmdkKey(S(c![0]))}, page {c[1]}");

// Beyond the page: text frames after big cover art are read (the page missed them once the title was found).
{
    static byte[] Frame(string id, byte[] body) => [.. System.Text.Encoding.ASCII.GetBytes(id), .. TagWriter.U32be(body.Length), 0, 0, .. body];
    var art = Enumerable.Repeat((byte)0x55, 300 * 1024).ToArray();
    byte[] frames = [.. Frame("TIT2", [0, .. "Big Art"u8.ToArray()]), .. Frame("APIC", [0, .. "image/jpeg"u8.ToArray(), 0, 3, 0, .. art]),
                     .. Frame("TALB", [0, .. "Mainstream"u8.ToArray()]), .. Frame("TYER", [0, .. "2019"u8.ToArray()])];
    int n = frames.Length;
    byte[] tag = [.. "ID3"u8.ToArray(), 3, 0, 0, (byte)(n >> 21 & 0x7f), (byte)(n >> 14 & 0x7f), (byte)(n >> 7 & 0x7f), (byte)(n & 0x7f), .. frames];
    var tmp = Path.Combine(Path.GetTempPath(), $"jt-big-art-{Guid.NewGuid():N}.mp3");
    File.WriteAllBytes(tmp, [.. tag, 0xff, 0xfb, .. Enumerable.Repeat((byte)1, 1000)]);
    var bigArt = TagReader.Read(tmp, "mp3");
    File.Delete(tmp);
    Expect(SameTags(bigArt, new() { ["title"] = "Big Art", ["album"] = "Mainstream", ["year"] = "2019" }), () => $"tags after big cover art: {Show(bigArt)}");
}

// reading snapshots back
foreach (var c in fx["csvCases"]!.AsArray())
{
    var t = S(c![0]); var page = c[1]!.AsArray().Select(r => r!.AsArray().Select(S).ToList()).ToList(); var mine = Engine.ParseCsv(t);
    Expect(mine.Count == page.Count && mine.Zip(page).All(x => x.First.SequenceEqual(x.Second)), () => $"parseCsv({t})");
}

// Beyond the page: the organizer, versions, finished copies and era names (the same cases as the Swift tests)
{
    static EngineSong Song(string id, string name, string era) => new() { Id = id, PublicId = id, Name = name, Era = era, Category = "Unreleased", RecordDates = "2018" };
    static LibraryFile File1(string path) => new(path, Engine.ExtOf(path), new() { ["artist"] = "Juice WRLD" }, "", "", "", false, 1);
    var cat = new List<EngineSong> { Song("1", "Lucid Dreams", "GB&GR"), Song("2", "What?/Why", "DRFL") };
    var files = new List<LibraryFile> { File1("M/a.mp3"), File1("M/b.flac"), File1("M/c.mp3"), File1("M/GB&GR/Lucid Dreams.mp3") };
    var om = new Engine.Match();
    om.SongsFor["M/a.mp3"] = [0]; om.SongsFor["M/b.flac"] = [1]; om.SongsFor["M/c.mp3"] = [0, 1]; om.SongsFor["M/GB&GR/Lucid Dreams.mp3"] = [0];
    om.How["M/a.mp3"] = "title"; om.How["M/b.flac"] = "close"; om.How["M/c.mp3"] = "title"; om.How["M/GB&GR/Lucid Dreams.mp3"] = "title";
    Expect(Engine.OrganizePlan(files, om, cat, "{era}/{song}").Count == 0, () => "organizer: a file already in place is never overwritten, close and unsettled matches stay");
    Expect(Engine.PrimarySong([0, 1], cat) is null, () => "primary song: different names stay unsettled");
    var versions = new List<EngineSong> { Song("3", "Lean Wit' Me", "GB&GR"), Song("4", "Lean Wit' Me", "GB&GR"), Song("5", "Lean Wit' Me (Live)", "WOD"), Song("6", "Lean Wit' Me", "Mainstream") };
    Expect(Engine.PrimarySong([0, 1, 2, 3], versions) == 0, () => "primary song: the era most plain-named versions share");
    Expect(Engine.PrimarySong([0, 3], versions) is null, () => "primary song: a tie stays unsettled");
    om.How["M/b.flac"] = "title";
    var p2 = Engine.OrganizePlan(files, om, cat, "{year}/{song} ({era})").Select(x => x.To).ToList();
    Expect(p2.SequenceEqual(["M/2018/Lucid Dreams (GB&GR).mp3", "M/2018/WhatWhy (DRFL).flac"]), () => $"organizer: pattern fields and safe names ({string.Join(", ", p2)})");
    var untagged = files[0] with { Path = "M/Juice WRLD/a.mp3", Tags = [] };
    om.SongsFor[untagged.Path] = [0]; om.How[untagged.Path] = "title";
    Expect(Engine.OrganizePlan([untagged], om, cat, "{era}/{song}").Count == 0, () => "organizer: a file counted only by its Juice WRLD folder stays put");
    Expect(Engine.OrganizePlan([untagged], om, cat, "Juice WRLD/{era}/{song}").Select(x => x.To).SequenceEqual(["M/Juice WRLD/GB&GR/Lucid Dreams.mp3"]), () => "organizer: it can move inside a Juice WRLD folder");
    var t0 = DateTime.UnixEpoch.AddSeconds(1_000_000);
    Expect(!Engine.Settled(100, 200, t0, t0.AddSeconds(60)), () => "inbox: a growing file isn't settled");
    Expect(!Engine.Settled(200, 200, t0, t0.AddSeconds(3)), () => "inbox: a file written seconds ago isn't settled");
    Expect(Engine.Settled(200, 200, t0, t0.AddSeconds(30)), () => "inbox: a finished file is settled");
    Expect(!Engine.Settled(0, 0, t0, t0.AddSeconds(30)), () => "inbox: an empty file isn't settled");
    Expect(Engine.Settled(200, 200, t0.AddSeconds(3600), t0), () => "inbox: a file dated in the future is settled by its size");
    var eraNames = new[] { ("DRFL", "Death Race For Love"), ("DRFL (TV)", "Death Race For Love TV mixes"), ("TPNE", "The Party Never Ends"), ("TPNE 2.0", "The Party Never Ends 2.0"), ("GB&GR", "Goodbye & Good Riddance") };
    Expect(Engine.ErasNamed("drfl", eraNames).SequenceEqual(["DRFL"]), () => "era names: the short name, any case");
    Expect(Engine.ErasNamed("death race for love", eraNames).SequenceEqual(["DRFL"]), () => "era names: the full name beats the TV mixes");
    Expect(Engine.ErasNamed("goodbye and good riddance", eraNames).SequenceEqual(["GB&GR"]), () => "era names: & and and are the same");
    Expect(Engine.ErasNamed("party never ends", eraNames).SequenceEqual(["TPNE", "TPNE 2.0"]), () => "era names: several fits are all returned");
    Expect(Engine.ErasNamed("fighting demons", eraNames).Count == 0, () => "era names: no fit, nothing");
    Expect(Engine.WordleWord("Lucid Dreams (Forget Me)") == "LUCID DREAMS", () => "wordle: brackets dropped, words kept");
    Expect(Engine.WordleWord("Bandit [v1]") == "BANDIT", () => "wordle: version marks dropped");
    Expect(Engine.WordleWord("Can't Die") == "CANT DIE", () => "wordle: apostrophes dropped");
    Expect(Engine.WordleWord("All Girls Are The Same") is null && Engine.WordleWord("Hey") is null, () => "wordle: too long or too short is skipped");
    Expect(Engine.WordleScore("CRANE", "CREAK").SequenceEqual([2, 2, 1, 0, 1]), () => "wordle: green, yellow and grey");
    DateTime Day(int d, int h) => new(2026, 3, d, h, 0, 0);
    DateTime[] plays = [Day(10, 9), Day(9, 23), Day(2, 12), Day(1, 0), Day(11, 8)];
    Expect(Engine.PlayTimeline(plays, 7, 1, Day(10, 12)).SequenceEqual([0, 0, 0, 0, 0, 1, 1]), () => "timeline: plays by day, today last, older and future plays left out");
    Expect(Engine.PlayTimeline(plays, 2, 7, Day(10, 12)).SequenceEqual([2, 2]), () => "timeline: plays by week, the week ending today last");
    Expect(Engine.M3u([("/m/a.mp3", "Lucid Dreams", 239.6), ("/m/b.flac", "Two\nLines", null)]) == "#EXTM3U\n#EXTINF:239,Juice WRLD - Lucid Dreams\n/m/a.mp3\n#EXTINF:-1,Juice WRLD - Two Lines\n/m/b.flac\n", () => "m3u: length, title on one line, path");
    Expect(Engine.Boosted(0.2, 0.25) == (0.8, 0.25) && Engine.Boosted(0.05, 0) == (0.2, 0.25), () => "boost: a quiet song is lifted, near-silence only so far");
    Expect(Engine.Boosted(0.9, 0.4) == (1, 0.9) && Engine.Boosted(0.45, 0.9).Level == 0.45 / (0.9 * 0.995), () => "boost: a loud song sets the peak, which falls back slowly");
    Expect(Engine.EqPreset([-2, 4, 2]) == "Vocals" && Engine.EqPreset([0, 4, 2]) == "Custom", () => "equalizer: bands name their preset, or Custom");
    Expect(Engine.EqHeadroom([6, 0, 1]) == -3 && Engine.EqHeadroom([-4, 1, -3]) == -0.5 && Engine.EqHeadroom([-4, -1, -3]) == 0, () => "equalizer: turned down by half the biggest boost");
    var lrc = Engine.ParseLrc("[ar:Juice WRLD]\n[00:12.50]second line\n[00:03.00]<00:03.00>first <00:03.60>line <00:04.20>here\n[00:20.00]<00:20.00>wrong count");
    Expect(lrc.Select(l => l.At).SequenceEqual([3, 12.5, 20]) && lrc[0].Line == "first line here", () => "lrc: tags skipped, sorted by time, word times taken out of the text");
    Expect(lrc[0].Words.SequenceEqual([3, 3.6, 4.2]) && lrc[1].Words.Length == 0 && lrc[2].Words.Length == 0, () => "lrc: word times only when every word has one");
    var back = Engine.ParseLrc(Engine.FormatLrc(lrc));
    Expect(back.Count == lrc.Count && back.Zip(lrc).All(p => p.First.At == p.Second.At && p.First.Line == p.Second.Line && p.First.Words.SequenceEqual(p.Second.Words)), () => "lrc: what's written reads back the same");
    Expect(Engine.LrcStamp(83.456) == "01:23.46" && Engine.LrcStamp(600) == "10:00.00", () => "lrc: times as mm:ss.xx");
    Expect(Engine.LitWords(lrc, 0, 3.7) == (2, true) && Engine.LitWords(lrc, 0, 13) == (3, false), () => "lrc: word times light the words they time");
    Expect(Engine.LitWords(lrc, 1, 12.5 + 7.5 * 0.85 / 2) == (1, true) && Engine.LitWords(lrc, 1, 19.9) == (2, false), () => "lrc: an untimed line spreads over its words");
    Expect(Engine.WordleScore("LLAMA", "HELLO").SequenceEqual([1, 1, 0, 0, 0]), () => "wordle: a repeated letter is yellow as often as the answer has it");
    Expect(Engine.WordleScore("EERIE", "THREE").SequenceEqual([1, 0, 2, 0, 2]), () => "wordle: greens first, then yellows from what's left");
    Expect(Engine.WordleScore("LUCIDDREAMS", "LUCID DREAMS").SequenceEqual(Enumerable.Repeat(2, 11)), () => "wordle: spaces don't count");
}

// Cover art (beyond the page): added to each format, tags and audio untouched, and refused the second time.
{
    byte[] jpeg = [0xFF, 0xD8, 0xFF, 0xE0, .. Enumerable.Repeat((byte)0x42, 5000), 0xFF, 0xD9];
    foreach (var name in new[] { "written.mp3", "written.flac", "written.m4a" })
    {
        var file = Path.Combine(dir, "files", name); var ext = Engine.ExtOf(name);
        var orig = File.ReadAllBytes(file); var before = TagReader.Read(file, ext);
        try
        {
            var output = CoverArt.AddArt(orig, ext, jpeg, 600, 600);
            var copy = Path.Combine(Path.GetTempPath(), $"jt-art-{Guid.NewGuid():N}.{ext}");
            File.WriteAllBytes(copy, output);
            Expect(CoverArt.HasArt(copy, ext), () => $"{name}: cover art reads back from disk");
            var after = TagReader.Read(copy, ext);
            Expect(SameTags(after, before), () => $"{name}: tags unchanged by adding cover art ({Show(after)} vs {Show(before)})");
            File.Delete(copy);
            Expect(!CoverArt.HasArt(orig, ext), () => $"{name}: the original had no art");
            bool refused = false; try { CoverArt.AddArt(output, ext, jpeg, 600, 600); } catch (EngineError) { refused = true; }
            Expect(refused, () => $"{name}: a second picture is refused");
        }
        catch (EngineError e) { Expect(false, () => $"{name}: adding cover art failed: {e.Message}"); }
    }
}

Console.WriteLine($"{checks - failures} of {checks} engine checks match the page");
return failures > 0 ? 1 : 0;

static string FindFixtures()
{
    for (var d = new DirectoryInfo(AppContext.BaseDirectory); d is not null; d = d.Parent)
        if (File.Exists(Path.Combine(d.FullName, "tests", "fixtures", "fixtures.json"))) return Path.Combine(d.FullName, "tests", "fixtures");
    throw new FileNotFoundException("tests/fixtures/fixtures.json not found; pass the folder as the first argument");
}
