using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.IO.Pipes;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using NAudio.Wave;
using Path = System.IO.Path;

namespace JuiceTracker.App;

/// Go live on TikTok (or anywhere that takes RTMP) straight from the app. The stream window's picture is drawn here
/// 30 times a second and this PC's sound is taken from the speakers (Windows can't give one app's sound on its own
/// here); FFmpeg encodes them (H.264, AAC) and sends them with the Server URL and Stream Key TikTok gives you. FFmpeg is
/// fetched the first time (a fixed version, checked against its fingerprint) and kept in the data folder.
public sealed class LiveStream
{
    public static LiveStream Shared { get; } = new();
    public enum Phase { Off, Getting, Connecting, Live, Failed }
    public Phase State { get; private set; }
    public string Note { get; private set; } = "";
    public DateTime Since { get; private set; }
    public bool Portrait { get; private set; }
    public bool IsOn => State is Phase.Getting or Phase.Connecting or Phase.Live;
    public event Action? Changed;

    // FFmpeg 9.0.2, Gyan Doshi's "essentials" Windows build (includes libx264 and AAC), from its GitHub release
    const string FfmpegUrl = "https://github.com/GyanD/codexffmpeg/releases/download/9.0.2/ffmpeg-9.0.2-essentials_build.zip";
    const string FfmpegSha256 = "60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba";
    static string FfmpegDir => Path.Combine(Store.DataDir, "ffmpeg-9.0.2");
    public static string FfmpegExe => Path.Combine(FfmpegDir, "ffmpeg.exe");

    Process? ffmpeg;
    DispatcherTimer? frames, watch;
    WasapiLoopbackCapture? speakers;
    BufferedWaveProvider? sound;
    NamedPipeServerStream? audioPipe;
    Thread? audioThread;
    FrameworkElement? picture;
    volatile bool running, writing;
    int width, height;
    string lastError = "";

    /// Fetches FFmpeg the first time, checks its fingerprint, keeps ffmpeg.exe.
    public static async Task<string> EnsureFfmpeg(Action<string> progress)
    {
        if (File.Exists(FfmpegExe)) return FfmpegExe;
        Directory.CreateDirectory(FfmpegDir);
        var zip = Path.Combine(FfmpegDir, "download.zip");
        using (var http = new HttpClient { Timeout = TimeSpan.FromMinutes(20) })
        {
            http.DefaultRequestHeaders.UserAgent.ParseAdd("JuiceTracker");
            using var r = await http.GetAsync(FfmpegUrl, HttpCompletionOption.ResponseHeadersRead);
            r.EnsureSuccessStatusCode();
            long total = r.Content.Headers.ContentLength ?? 0, got = 0; int last = -1;
            await using var src = await r.Content.ReadAsStreamAsync();
            await using var dst = File.Create(zip);
            var buf = new byte[1 << 20]; int n;
            while ((n = await src.ReadAsync(buf)) > 0)
            {
                await dst.WriteAsync(buf.AsMemory(0, n)); got += n;
                int pct = total > 0 ? (int)(got * 100 / total) : 0;
                if (pct != last) { last = pct; progress($"Getting the streaming engine (one time, {total / 1_000_000} MB)… {pct}%"); }
            }
        }
        string hash;
        await using (var f = File.OpenRead(zip)) hash = Convert.ToHexString(await SHA256.HashDataAsync(f)).ToLowerInvariant();
        if (hash != FfmpegSha256) { File.Delete(zip); throw new EngineError("The streaming engine download didn't match its fingerprint, so it wasn't used."); }
        using (var archive = ZipFile.OpenRead(zip))
        {
            var entry = archive.Entries.FirstOrDefault(e => e.FullName.EndsWith("/bin/ffmpeg.exe", StringComparison.OrdinalIgnoreCase))
                        ?? throw new EngineError("The streaming engine download didn't contain ffmpeg.exe.");
            entry.ExtractToFile(FfmpegExe, true);
        }
        File.Delete(zip);
        return FfmpegExe;
    }

    // The Stream Key, encrypted for this Windows account (like the Plex token)
    static string KeyFile => Path.Combine(Store.DataDir, "live.key");
    public static bool HasKey => File.Exists(KeyFile);
    public static void SaveKey(string key)
    {
        if (key.Trim().Length == 0) { File.Delete(KeyFile); return; }
        File.WriteAllBytes(KeyFile, ProtectedData.Protect(Encoding.UTF8.GetBytes(key.Trim()), null, DataProtectionScope.CurrentUser));
    }
    static string? ReadKey()
    {
        try { return HasKey ? Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(KeyFile), null, DataProtectionScope.CurrentUser)) : null; }
        catch (Exception) { return null; }
    }

    /// Opens the stream window for this shape and goes live from it.
    public async void Start(bool portrait)
    {
        if (IsOn) return;
        var server = (Store.Shared.Me.LiveServer ?? "").Trim();
        if (server.Length == 0 || ReadKey() is not { } key) { Fail("Add the Server URL and Stream Key from TikTok LIVE in Settings > Live first."); return; }
        if (!server.StartsWith("rtmp://", StringComparison.OrdinalIgnoreCase) && !server.StartsWith("rtmps://", StringComparison.OrdinalIgnoreCase))
        { Fail("The Server URL should start with rtmp:// or rtmps:// (copy it from TikTok LIVE)."); return; }
        Portrait = portrait;
        StreamWindow.Show(portrait);
        try
        {
            Set(Phase.Getting, "Getting the streaming engine…");
            var exe = await EnsureFfmpeg(note => Application.Current.Dispatcher.Invoke(() => Set(Phase.Getting, note)));
            if (StreamWindow.PictureOf(portrait) is not { } page) throw new EngineError("The stream window didn't open.");
            Begin(exe, server.TrimEnd('/') + "/" + key, page, portrait);
        }
        catch (Exception e) { Fail(e.Message); }
    }

    /// Starts FFmpeg and feeds it pictures (from `page`) and sound. Also used by the CI self-test.
    public void Begin(string exe, string url, FrameworkElement page, bool portrait)
    {
        picture = page; Portrait = portrait;
        (width, height) = portrait ? (720, 1280) : (1280, 720);
        Set(Phase.Connecting, "Connecting…");
        // the speakers' sound (all of this PC's sound); silence if there's no output device
        var format = WaveFormat.CreateIeeeFloatWaveFormat(48000, 2);
        try
        {
            speakers = new WasapiLoopbackCapture();
            if (speakers.WaveFormat.Encoding == WaveFormatEncoding.IeeeFloat || speakers.WaveFormat.Encoding == WaveFormatEncoding.Extensible) format = WaveFormat.CreateIeeeFloatWaveFormat(speakers.WaveFormat.SampleRate, speakers.WaveFormat.Channels);
        }
        catch (Exception) { speakers = null; }
        sound = new BufferedWaveProvider(format) { BufferDuration = TimeSpan.FromSeconds(2), DiscardOnBufferOverflow = true, ReadFully = true };
        if (speakers is not null) { speakers.DataAvailable += (_, a) => sound.AddSamples(a.Buffer, 0, a.BytesRecorded); speakers.StartRecording(); }

        var pipeName = $"jt-audio-{Environment.ProcessId}-{Environment.TickCount64}";
        audioPipe = new NamedPipeServerStream(pipeName, PipeDirection.Out, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        var args = string.Join(' ',
            "-hide_banner -loglevel error",
            $"-thread_queue_size 64 -use_wallclock_as_timestamps 1 -f rawvideo -pix_fmt bgra -video_size {width}x{height} -i pipe:0",
            $"-thread_queue_size 1024 -f f32le -ar {format.SampleRate} -ac {format.Channels} -i \\\\.\\pipe\\{pipeName}",
            "-fps_mode cfr -r 30 -c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p -b:v 3500k -maxrate 3500k -bufsize 7000k -g 60",
            "-c:a aac -b:a 128k -ar 48000 -ac 2 -f flv", $"\"{url}\"");
        ffmpeg = new Process { StartInfo = new ProcessStartInfo(exe, args) { UseShellExecute = false, RedirectStandardInput = true, RedirectStandardError = true, CreateNoWindow = true }, EnableRaisingEvents = true };
        ffmpeg.ErrorDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) lastError = e.Data.Trim(); };
        ffmpeg.Exited += (_, _) => Application.Current?.Dispatcher.BeginInvoke(() => { if (running) Fail($"The stream stopped: {(lastError.Length > 0 ? lastError : "the connection ended.")}"); });
        ffmpeg.Start();
        ffmpeg.BeginErrorReadLine();
        running = true;

        // sound: steady real-time chunks (silence fills the gaps, so FFmpeg never waits)
        audioThread = new Thread(() =>
        {
            try
            {
                audioPipe.WaitForConnection();
                var clock = Stopwatch.StartNew(); long sent = 0; int bytesPerSecond = format.AverageBytesPerSecond, block = format.BlockAlign;
                var buf = new byte[bytesPerSecond / 10];
                while (running)
                {
                    long due = (long)(clock.Elapsed.TotalSeconds * bytesPerSecond) / block * block - sent;
                    if (due > 0)
                    {
                        int n = (int)Math.Min(due, buf.Length) / block * block;
                        sound.Read(buf, 0, n); audioPipe.Write(buf, 0, n); sent += n;
                    }
                    Thread.Sleep(10);
                }
            }
            catch (Exception) { /* FFmpeg went away; Exited reports it */ }
        }) { IsBackground = true, Name = "live audio" };
        audioThread.Start();

        // pictures: the stream window drawn at 720 by 1280 (or 1280 by 720), 30 a second
        frames = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(33) };
        frames.Tick += (_, _) => Frame();
        frames.Start();
        // it's live once FFmpeg has kept going a few seconds (it quits at once if the server says no)
        watch = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        watch.Tick += (_, _) => { watch?.Stop(); if (running && ffmpeg is { HasExited: false }) { Since = DateTime.Now; Set(Phase.Live, ""); } };
        watch.Start();
    }

    void Frame()
    {
        if (!running || writing || picture is null || ffmpeg is null || picture.ActualWidth == 0) return;
        double dpi = 96.0 * width / picture.ActualWidth;
        var bitmap = new RenderTargetBitmap(width, height, dpi, dpi, PixelFormats.Pbgra32);
        bitmap.Render(picture);
        var pixels = new byte[width * height * 4];
        bitmap.CopyPixels(pixels, width * 4, 0);
        writing = true;
        var input = ffmpeg.StandardInput.BaseStream;
        Task.Run(() =>
        {
            try { input.Write(pixels, 0, pixels.Length); input.Flush(); }
            catch (Exception) { /* FFmpeg went away; Exited reports it */ }
            finally { writing = false; }
        });
    }

    public void Stop() => End(Phase.Off, "");
    void Fail(string why) => End(Phase.Failed, why);

    void End(Phase phase, string note)
    {
        running = false;
        frames?.Stop(); frames = null; watch?.Stop(); watch = null;
        try { speakers?.StopRecording(); speakers?.Dispose(); } catch (Exception) { }
        speakers = null;
        try { ffmpeg?.StandardInput.Close(); } catch (Exception) { }
        try { audioPipe?.Dispose(); } catch (Exception) { }
        var old = ffmpeg; ffmpeg = null; audioPipe = null;
        if (old is not null) Task.Run(() => { try { if (!old.WaitForExit(3000)) old.Kill(); } catch (Exception) { } });
        Set(phase, note);
    }

    void Set(Phase phase, string note) { State = phase; Note = note; Changed?.Invoke(); }

    /// CI: `JuiceTracker.exe --rtmp-selftest <server> <key>`: six seconds of the portrait stream picture (with a made-up
    /// library) and silence to an RTMP server, then exit 0, or 1 with the reason in %TEMP%\juicetracker-live.txt.
    public static async Task<int> SelfTest(string server, string key)
    {
        var report = Path.Combine(Path.GetTempPath(), "juicetracker-live.txt");
        try
        {
            var exe = await EnsureFfmpeg(_ => { });
            Store.Shared.FillForSmokeTest();
            var page = new PlayerPage(stream: true) { Width = 540, Height = 960 };
            var host = new Window { Content = page, Width = 560, Height = 1000, ShowInTaskbar = false, Left = -4000, Top = 0, WindowStyle = WindowStyle.None };
            host.Show();
            var live = new LiveStream();
            live.Begin(exe, server.TrimEnd('/') + "/" + key, page, portrait: true);
            await Task.Delay(TimeSpan.FromSeconds(7));
            if (live.State == Phase.Failed) throw new EngineError(live.Note);
            live.Stop();
            await Task.Delay(TimeSpan.FromSeconds(2));
            File.WriteAllText(report, $"ok {exe}");
            return 0;
        }
        catch (Exception e) { File.WriteAllText(report, e.ToString()); return 1; }
    }
}
