using System.Windows.Media;
using System.Windows.Threading;
using NAudio.CoreAudioApi;
using NAudio.Dsp;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace JuiceTracker.App;

/// Bass, mids and treble (Settings > Equalizer). Songs go through NAudio with the EQ only while it's on and not
/// flat; otherwise they play on Windows' media player as before.
static class Equalizer
{
    public static event Action? Changed;
    public static double[] Bands => [.. Store.Shared.Me.EqBands.Concat([0.0, 0, 0]).Take(3)];
    public static bool Active => Store.Shared.Me.EqOn && Bands.Any(b => b != 0);
    static DispatcherTimer? save;
    /// Takes effect right away; saved a moment after the sliders stop moving (they change many times a second).
    public static void Set(bool on, double[] bands)
    {
        Store.Shared.Me.EqOn = on; Store.Shared.Me.EqBands = [.. bands];
        Changed?.Invoke(); Player.Shared.EqualizerChanged();
        save?.Stop();
        save = new DispatcherTimer(TimeSpan.FromMilliseconds(400), DispatcherPriority.Background, (s, _) => { ((DispatcherTimer)s!).Stop(); Store.Shared.SavePersonal(); }, Dispatcher.CurrentDispatcher);
    }
}

/// What plays a song: Windows' media player, or (equalizer on) NAudio with the EQ.
interface ISong
{
    double Volume { get; set; }
    TimeSpan Position { get; set; }
    TimeSpan? Length { get; }
    void Open(string file);
    void Play();
    void Pause();
    void Stop();
    void Close();
    event Action? Ended, Failed, Opened;
}

sealed class MediaSong : ISong
{
    readonly MediaPlayer m = new();
    public event Action? Ended, Failed, Opened;
    public MediaSong() { m.MediaEnded += (_, _) => Ended?.Invoke(); m.MediaFailed += (_, _) => Failed?.Invoke(); m.MediaOpened += (_, _) => Opened?.Invoke(); }
    public double Volume { get => m.Volume; set => m.Volume = value; }
    public TimeSpan Position { get => m.Position; set => m.Position = value; }
    public TimeSpan? Length => m.NaturalDuration.HasTimeSpan ? m.NaturalDuration.TimeSpan : null;
    public void Open(string file) => m.Open(new Uri(file));
    public void Play() => m.Play();
    public void Pause() => m.Pause();
    public void Stop() => m.Stop();
    public void Close() => m.Close();
}

sealed class EqSong : ISong
{
    readonly Dispatcher ui = Dispatcher.CurrentDispatcher;
    MediaFoundationReader? reader; WasapiOut? output; VolumeSampleProvider? level; EqStage? eq;
    double volume; bool wantPlay, closed, stopping; TimeSpan? pendingPosition;
    public event Action? Ended, Failed, Opened;

    public double Volume { get => volume; set { volume = value; if (level is not null) level.Volume = (float)value; } }
    public TimeSpan Position
    {
        get => reader?.CurrentTime ?? pendingPosition ?? TimeSpan.Zero;
        set { if (reader is null) pendingPosition = value; else reader.CurrentTime = value; }
    }
    public TimeSpan? Length => reader?.TotalTime;

    /// Opens off the UI thread (a network drive can take seconds), then plays if Play was asked for meanwhile.
    public void Open(string file)
    {
        closed = false;
        Task.Run(() =>
        {
            try
            {
                var r = new MediaFoundationReader(file);
                var e = new EqStage(r.ToSampleProvider());
                var v = new VolumeSampleProvider(e) { Volume = (float)volume };
                var o = new WasapiOut(AudioClientShareMode.Shared, 120);
                o.Init(v);
                ui.BeginInvoke(() =>
                {
                    if (closed) { o.Dispose(); r.Dispose(); return; }
                    reader = r; eq = e; level = v; output = o;
                    level.Volume = (float)volume;
                    if (pendingPosition is { } p) r.CurrentTime = p;
                    o.PlaybackStopped += (_, args) => ui.BeginInvoke(() =>
                    {
                        if (stopping || closed || output != o) { stopping = false; return; }
                        if (args.Exception is not null) Failed?.Invoke(); else Ended?.Invoke();
                    });
                    Equalizer.Changed += Retune;
                    Opened?.Invoke();
                    if (wantPlay) o.Play();
                });
            }
            catch (Exception) { ui.BeginInvoke(() => Failed?.Invoke()); }
        });
    }
    void Retune() => eq?.Tune();
    public void Play() { wantPlay = true; output?.Play(); }
    public void Pause() { wantPlay = false; output?.Pause(); }
    public void Stop() { wantPlay = false; if (output is null) return; stopping = true; output.Stop(); if (reader is not null) reader.CurrentTime = TimeSpan.Zero; }
    public void Close()
    {
        closed = true; wantPlay = false; Equalizer.Changed -= Retune;
        stopping = true; output?.Dispose(); reader?.Dispose(); output = null; reader = null;
    }
}

/// Three filters per channel (low shelf, a bell for the mids, high shelf), and the headroom so boosts don't clip.
sealed class EqStage : ISampleProvider
{
    readonly ISampleProvider source;
    BiQuadFilter[][] filters = [];
    float gain = 1;
    public WaveFormat WaveFormat => source.WaveFormat;
    public EqStage(ISampleProvider source) { this.source = source; Tune(); }

    public void Tune()
    {
        var b = Equalizer.Bands; bool on = Store.Shared.Me.EqOn; float rate = WaveFormat.SampleRate;
        filters = on ? [.. Enumerable.Range(0, WaveFormat.Channels).Select(_ => new[]
        {
            BiQuadFilter.LowShelf(rate, 120, 1, (float)b[0]), BiQuadFilter.PeakingEQ(rate, 1000, 1, (float)b[1]), BiQuadFilter.HighShelf(rate, 6000, 1, (float)b[2]),
        })] : [];
        gain = on ? (float)Math.Pow(10, Engine.EqHeadroom(b) / 20) : 1;
    }

    public int Read(float[] buffer, int offset, int count)
    {
        int n = source.Read(buffer, offset, count);
        var f = filters; // swapped whole by Tune, never changed in place
        if (f.Length == 0) return n;
        int channels = f.Length;
        for (int k = 0; k < n; k++)
        {
            var x = buffer[offset + k];
            foreach (var q in f[k % channels]) x = q.Transform(x);
            buffer[offset + k] = x * gain;
        }
        return n;
    }
}
