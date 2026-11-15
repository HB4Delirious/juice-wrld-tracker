using System.IO;
using System.Windows.Media;
using System.Windows.Threading;

namespace JuiceTracker.App;

/// Plays your own matched songs, shuffled (quietly by default, as ambient music), with pause, skip, volume, an era
/// filter, a seek bar and "play this song now". Songs heard today are skipped until everything has played. The Mac
/// app's AmbientPlayer, on Windows' built-in media player (MP3, M4A, FLAC, WAV, WMA).
public sealed class Player
{
    public static Player Shared { get; } = new();
    public event Action? Changed;

    readonly MediaPlayer media = new();
    readonly DispatcherTimer tick = new() { Interval = TimeSpan.FromMilliseconds(500) };
    List<(string File, string Title)> items = [];
    List<int> order = [];
    public string? Title { get; private set; }
    public string? CurrentFile { get; private set; }
    public bool IsPaused { get; private set; }
    public bool IsPlaying => CurrentFile is not null && !IsPaused;
    public static readonly HashSet<string> Playable = ["mp3", "m4a", "m4b", "aac", "flac", "wav", "wma"];

    Player()
    {
        media.MediaEnded += (_, _) => Next();
        media.MediaFailed += (_, _) => Next(failures: 1);
        media.MediaOpened += (_, _) => Changed?.Invoke();
        tick.Tick += (_, _) => { if (IsPlaying) Changed?.Invoke(); };
        tick.Start();
    }

    public double Volume
    {
        get => Store.Shared.Me.Volume;
        set { Store.Shared.Me.Volume = value; media.Volume = value / 100; Changed?.Invoke(); }
    }
    public TimeSpan Position => media.Position;
    public TimeSpan Duration => media.NaturalDuration.HasTimeSpan ? media.NaturalDuration.TimeSpan : TimeSpan.Zero;
    public void Seek(TimeSpan t) { media.Position = t; Changed?.Invoke(); }

    /// The eras you have songs from (for the era menu).
    public List<string> Eras => Playables().Select(p => p.Era).Distinct().Order().ToList();

    List<(string File, string Title, string Era)> Playables()
    {
        var store = Store.Shared; var output = new List<(string, string, string)>(); var seen = new HashSet<string>();
        foreach (var (i, paths) in store.Match.Owned)
            foreach (var p in paths)
                if (Playable.Contains(Engine.ExtOf(p)) && store.FullPath(p) is { } full && seen.Add(full))
                    output.Add((full, store.Catalog[i].Name, Engine.EraName(store.Catalog[i])));
        return output;
    }

    /// Hands the player the songs (one era's, or all when that era has none) and starts or stops it.
    public void Sync()
    {
        var store = Store.Shared; var all = Playables();
        var era = store.Me.AmbientEra;
        var picked = era.Length > 0 ? all.Where(p => p.Era == era).ToList() : [];
        var list = (picked.Count > 0 ? picked : all).Select(p => (p.File, p.Title)).ToList();
        if (!list.Select(x => x.File).SequenceEqual(items.Select(x => x.File))) order = [];
        items = list;
        if (store.Me.AmbientOn && items.Count > 0) { if (CurrentFile is null && !IsPaused) Next(); }
        else if (!store.Me.AmbientOn) Stop();
        Changed?.Invoke();
    }

    public void SetOn(bool on) { Store.Shared.Me.AmbientOn = on; Store.Shared.SavePersonal(); Sync(); }
    public void SetEra(string era) { Store.Shared.Me.AmbientEra = era; Store.Shared.Me.AmbientOn = true; Store.Shared.SavePersonal(); order = []; Sync(); Skip(); }

    public void Stop() { media.Stop(); media.Close(); CurrentFile = null; Title = null; IsPaused = false; Changed?.Invoke(); }
    public void Pause() { if (CurrentFile is null) return; IsPaused = true; media.Pause(); Changed?.Invoke(); }
    public void Resume() { IsPaused = false; if (CurrentFile is not null) { media.Play(); Changed?.Invoke(); } else Next(); }
    public void TogglePause() { if (IsPlaying) Pause(); else Resume(); }
    public void Skip() { IsPaused = false; Next(); }
    public void PlayNow(string file, string title) { IsPaused = false; Start(file, title); }

    void Next(int failures = 0)
    {
        if (items.Count == 0 || failures >= Math.Min(items.Count, 5)) { Stop(); return; }
        if (order.Count == 0)
        {
            var heard = HeardToday();
            var fresh = Enumerable.Range(0, items.Count).Where(i => !heard.Contains(items[i].File)).ToList();
            order = (fresh.Count == 0 ? Enumerable.Range(0, items.Count).ToList() : fresh).OrderBy(_ => Random.Shared.Next()).ToList();
        }
        var n = order[^1]; order.RemoveAt(order.Count - 1);
        if (!File.Exists(items[n].File)) { Next(failures + 1); return; }
        Start(items[n].File, items[n].Title);
    }

    void Start(string file, string title)
    {
        media.Open(new Uri(file));
        media.Volume = Volume / 100;
        media.Play();
        CurrentFile = file; Title = title;
        MarkHeard(file); LogPlay(file);
        Changed?.Invoke();
    }

    // Songs heard today (kept across launches) and every play (for "your listening" later).
    static string Today => DateTime.Now.ToString("yyyy-MM-dd");
    static string HeardFile => Path.Combine(Store.DataDir, "heard.txt");
    static HashSet<string> HeardToday()
    {
        try { var lines = File.ReadAllLines(HeardFile); return lines.Length > 0 && lines[0] == Today ? lines.Skip(1).ToHashSet() : []; } catch { return []; }
    }
    static void MarkHeard(string file)
    {
        var heard = HeardToday(); heard.Add(file);
        try { File.WriteAllLines(HeardFile, [Today, .. heard]); } catch (IOException) { }
    }
    static void LogPlay(string file)
    {
        try { File.AppendAllText(Path.Combine(Store.DataDir, "plays.tsv"), $"{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}\t{file}\n"); } catch (IOException) { }
    }
}
