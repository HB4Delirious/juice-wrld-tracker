using System.IO;
using System.Windows.Media;
using System.Windows.Threading;

namespace JuiceTracker.App;

/// Plays your own matched songs, shuffled (quietly by default, as ambient music): pause, skip, volume, a seek bar, an
/// era filter or era radio (in recording order), Up next, crossfade, a sleep timer and volume matching. Songs heard
/// today are skipped until everything has played. The Mac app's AmbientPlayer, on Windows' built-in media player.
public sealed class Player
{
    public static Player Shared { get; } = new();
    public event Action? Changed;

    MediaPlayer media = new();
    MediaPlayer? fading;                       // the song fading out under a crossfade
    readonly DispatcherTimer tick = new() { Interval = TimeSpan.FromMilliseconds(250) };
    List<(string File, string Title)> items = [];
    List<int> order = [];
    public List<(string File, string Title)> UpNext { get; } = [];
    public string? Title { get; private set; }
    public string? CurrentFile { get; private set; }
    public bool IsPaused { get; private set; }
    public bool IsPlaying => CurrentFile is not null && !IsPaused;
    public DateTime? SleepAt { get; private set; }
    public bool SleepAtEnd { get; private set; }
    public static readonly HashSet<string> Playable = ["mp3", "m4a", "m4b", "aac", "flac", "wav", "wma"];

    double gain = 1;                           // volume matching: this file's level brought to a typical one
    static readonly Dictionary<string, double> Levels = [];
    (double From, double To, DateTime Start, double Seconds, MediaPlayer Who)? ramp, rampOut;
    bool crossfading, sleepFading;

    Player()
    {
        Hook(media);
        tick.Tick += (_, _) => Tick();
        tick.Start();
    }
    void Hook(MediaPlayer m)
    {
        m.MediaEnded += (s, _) => { if (s == media) Ended(); };
        m.MediaFailed += (s, _) => { if (s == media) Next(failures: 1); };
        m.MediaOpened += (s, _) => { if (s == media) Changed?.Invoke(); };
    }

    public double Volume
    {
        get => Store.Shared.Me.Volume;
        set { Store.Shared.Me.Volume = value; if (ramp is null) media.Volume = Loud; Changed?.Invoke(); }
    }
    double Loud => Math.Min(1, Volume / 100 * gain);
    public TimeSpan Position => media.Position;
    public TimeSpan Duration => media.NaturalDuration.HasTimeSpan ? media.NaturalDuration.TimeSpan : TimeSpan.Zero;
    public void Seek(TimeSpan t) { media.Position = t; Changed?.Invoke(); }

    /// The eras you have songs from (for the era menu).
    public List<string> Eras => Playables().Select(p => p.Era).Distinct().Order().ToList();

    List<(string File, string Title, string Era, int When)> Playables()
    {
        var store = Store.Shared; var output = new List<(string, string, string, int)>(); var seen = new HashSet<string>();
        foreach (var (i, paths) in store.Match.Owned)
            foreach (var p in paths)
                if (Playable.Contains(Engine.ExtOf(p)) && store.FullPath(p) is { } full && seen.Add(full))
                    output.Add((full, store.Catalog[i].Name, Engine.EraName(store.Catalog[i]), Engine.RecordMonth(store.Catalog[i].RecordDates) ?? int.MaxValue));
        return output;
    }

    /// Hands the player the songs (one era's, or all when that era has none) and starts or stops it. Era radio plays an
    /// era in recording order instead of shuffled.
    public void Sync()
    {
        var store = Store.Shared; var all = Playables();
        var era = store.Me.AmbientEra;
        var picked = era.Length > 0 ? all.Where(p => p.Era == era).ToList() : [];
        bool radio = store.Me.InOrder && picked.Count > 0;
        var list = (radio ? picked.OrderBy(p => p.When).ThenBy(p => p.Title).ToList() : picked.Count > 0 ? picked : all).Select(p => (p.File, p.Title)).ToList();
        if (!list.Select(x => x.File).SequenceEqual(items.Select(x => x.File))) order = [];
        items = list;
        if (store.Me.AmbientOn && (items.Count > 0 || UpNext.Count > 0)) { if (CurrentFile is null && !IsPaused) Next(); }
        else if (!store.Me.AmbientOn) Stop();
        Changed?.Invoke();
    }

    public void SetOn(bool on) { Store.Shared.Me.AmbientOn = on; Store.Shared.SavePersonal(); Sync(); }
    public void SetEra(string era) { Store.Shared.Me.AmbientEra = era; Store.Shared.Me.AmbientOn = true; Store.Shared.SavePersonal(); order = []; Sync(); Skip(); }
    public void SetInOrder(bool on) { Store.Shared.Me.InOrder = on; Store.Shared.SavePersonal(); order = []; Sync(); if (Store.Shared.Me.AmbientEra.Length > 0) Skip(); }
    public void QueueNext(string file, string title)
    {
        UpNext.Add((file, title));
        if (!Store.Shared.Me.AmbientOn) { Store.Shared.Me.AmbientOn = true; Store.Shared.SavePersonal(); }
        if (CurrentFile is null && !IsPaused) Next();
        Changed?.Invoke();
    }
    public void ClearUpNext() { UpNext.Clear(); Changed?.Invoke(); }
    /// The Player tab's Up next list: move one up or down, or take it out.
    public void MoveUpNext(int k, int by) { int to = k + by; if (k < 0 || k >= UpNext.Count || to < 0 || to >= UpNext.Count) return; (UpNext[k], UpNext[to]) = (UpNext[to], UpNext[k]); Changed?.Invoke(); }
    public void RemoveUpNext(int k) { if (k >= 0 && k < UpNext.Count) { UpNext.RemoveAt(k); Changed?.Invoke(); } }
    /// Plays a song now; the mix (shuffle or era radio) carries on after it, turning the music on if it was off.
    public void PlaySong(string file, string title)
    {
        if (!Store.Shared.Me.AmbientOn) { Store.Shared.Me.AmbientOn = true; Store.Shared.SavePersonal(); }
        PlayNow(file, title);
        Sync(); // a song is playing, so this only hands over the mix
    }

    public void Stop()
    {
        media.Stop(); media.Close(); fading?.Close(); fading = null; ramp = rampOut = null;
        CurrentFile = null; Title = null; IsPaused = false; Changed?.Invoke();
    }
    public void Pause() { if (CurrentFile is null) return; IsPaused = true; media.Pause(); Changed?.Invoke(); }
    public void Resume() { IsPaused = false; if (CurrentFile is not null) { media.Play(); Changed?.Invoke(); } else Next(); }
    public void TogglePause() { if (IsPlaying) Pause(); else Resume(); }
    public void Skip() { IsPaused = false; Next(); }
    public void PlayNow(string file, string title) { IsPaused = false; Start(file, title, 0); }

    /// Sleep timer: fades out and pauses at a time, or when the current song ends.
    public void Sleep(int? minutes, bool atEnd = false) { SleepAt = minutes is { } m ? DateTime.Now.AddMinutes(m) : null; SleepAtEnd = atEnd; Changed?.Invoke(); }

    void Ended()
    {
        if (SleepAtEnd) { SleepAtEnd = false; IsPaused = true; media.Stop(); Changed?.Invoke(); return; } // paused; Play starts the song again
        Next();
    }

    void Next(int failures = 0, double fade = 0)
    {
        if (UpNext.Count > 0) { var n = UpNext[0]; UpNext.RemoveAt(0); Start(n.File, n.Title, fade); return; }
        if (items.Count == 0 || failures >= Math.Min(items.Count, 5)) { Stop(); return; }
        if (order.Count == 0)
        {
            if (Store.Shared.Me.InOrder && Store.Shared.Me.AmbientEra.Length > 0) order = Enumerable.Range(0, items.Count).Reverse().ToList(); // taken from the end: first song first
            else
            {
                var heard = HeardToday();
                var fresh = Enumerable.Range(0, items.Count).Where(i => !heard.Contains(items[i].File)).ToList();
                order = (fresh.Count == 0 ? Enumerable.Range(0, items.Count).ToList() : fresh).OrderBy(_ => Random.Shared.Next()).ToList();
            }
        }
        var k = order[^1]; order.RemoveAt(order.Count - 1);
        if (!File.Exists(items[k].File)) { Next(failures + 1, fade); return; }
        Start(items[k].File, items[k].Title, fade);
    }

    void Start(string file, string title, double fade)
    {
        if (fade > 0 && CurrentFile is not null)
        {
            // crossfade: the old song keeps playing, fading out, while the new one fades in
            fading?.Close();
            fading = media; rampOut = (fading.Volume, 0, DateTime.Now, fade, fading);
            media = new MediaPlayer(); Hook(media);
        }
        else { media.Stop(); fading?.Close(); fading = null; rampOut = null; }
        gain = Levels.TryGetValue(file, out var l) ? GainFor(l) : 1;
        media.Open(new Uri(file));
        media.Volume = 0;
        media.Play();
        ramp = (0, Loud, DateTime.Now, fade > 0 ? fade : 3, media);
        CurrentFile = file; Title = title; crossfading = false;
        MarkHeard(file); LogPlay(file);
        if (Store.Shared.Me.MatchVolume && !Levels.ContainsKey(file)) // measure now, then glide to the matched level
            Task.Run(() => Store.Loudness(file)).ContinueWith(t =>
            {
                if (t.Result is not { } lv) return;
                Levels[file] = lv;
                if (CurrentFile != file) return;
                gain = GainFor(lv);
                ramp = (media.Volume, Loud, DateTime.Now, Math.Max(1, fade), media);
            }, TaskScheduler.FromCurrentSynchronizationContext());
        Changed?.Invoke();
    }
    static double GainFor(double level) => Store.Shared.Me.MatchVolume ? Math.Pow(10, Math.Clamp(-20 - level, -9, 9) / 20) : 1;

    void Tick()
    {
        // volume ramps (fade-in, crossfade-out, the volume-matching glide, the sleep fade)
        if (ramp is { } r)
        {
            var p = Math.Min(1, (DateTime.Now - r.Start).TotalSeconds / r.Seconds);
            r.Who.Volume = r.From + (r.To - r.From) * p;
            if (p >= 1) ramp = null;
        }
        if (rampOut is { } o)
        {
            var p = Math.Min(1, (DateTime.Now - o.Start).TotalSeconds / o.Seconds);
            o.Who.Volume = o.From * (1 - p);
            if (p >= 1) { o.Who.Stop(); o.Who.Close(); if (fading == o.Who) fading = null; rampOut = null; }
        }
        // crossfade: a few seconds before a song ends, start the next one fading in over it
        var fadeSecs = Store.Shared.Me.Crossfade;
        if (fadeSecs > 0 && !crossfading && !SleepAtEnd && IsPlaying && Duration.TotalSeconds > fadeSecs * 3 && Duration - Position <= TimeSpan.FromSeconds(fadeSecs)
            && (items.Count > 0 || UpNext.Count > 0))
        {
            crossfading = true;
            Next(fade: fadeSecs);
        }
        if (SleepAt is { } at && DateTime.Now >= at && IsPlaying && !sleepFading)
        {
            sleepFading = true; SleepAt = null;
            var who = media; ramp = (who.Volume, 0, DateTime.Now, 8, who);
            new DispatcherTimer(TimeSpan.FromSeconds(8), DispatcherPriority.Normal, (s, _) =>
            {
                ((DispatcherTimer)s!).Stop(); sleepFading = false;
                if (media == who) { Pause(); who.Volume = Loud; }
            }, Dispatcher.CurrentDispatcher).Start();
        }
        if (IsPlaying) Changed?.Invoke();
    }

    // Songs heard today (kept across launches) and every play (for Stats).
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
        try { Directory.CreateDirectory(Store.DataDir); File.AppendAllText(Path.Combine(Store.DataDir, "plays.tsv"), $"{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}\t{file}\n"); } catch (IOException) { }
    }
}
