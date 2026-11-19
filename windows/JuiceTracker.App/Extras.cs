using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Shell;
using Path = System.IO.Path;

namespace JuiceTracker.App;

// MARK: - Era themes and your own colors

public static class Themes
{
    public sealed record Theme(string Id, string Name, Color Accent, Color AccentHi, Color[] Glows);
    static Color C(byte r, byte g, byte b, double a = 1) => Color.FromArgb((byte)Math.Round(a * 255), r, g, b);
    public static readonly Theme[] All =
    [
        new("cosmic", "Cosmic (original)", C(255, 106, 213), C(255, 148, 226), [C(232, 110, 70, 0.30), C(214, 48, 140, 0.42), C(80, 130, 255, 0.32), C(140, 40, 190, 0.36)]),
        new("gbgr", "Goodbye & Good Riddance (heartbreak blue)", C(106, 168, 255), C(153, 199, 255), [C(70, 140, 232, 0.32), C(120, 90, 214, 0.38), C(60, 200, 255, 0.28), C(90, 60, 190, 0.36)]),
        new("drfl", "Death Race for Love (racing red)", C(255, 77, 90), C(255, 128, 128), [C(255, 80, 60, 0.34), C(200, 30, 60, 0.42), C(255, 170, 60, 0.26), C(120, 20, 60, 0.4)]),
        new("lnd", "Legends Never Die (sunset gold)", C(255, 184, 77), C(255, 209, 128), [C(255, 160, 60, 0.36), C(255, 90, 120, 0.34), C(255, 210, 90, 0.26), C(170, 70, 160, 0.34)]),
        new("fd", "Fighting Demons (demon green)", C(155, 255, 106), C(191, 255, 153), [C(120, 220, 80, 0.26), C(140, 40, 200, 0.42), C(60, 200, 140, 0.26), C(90, 30, 160, 0.4)]),
        new("wod", "WRLD on Drugs (electric cyan)", C(79, 216, 255), C(140, 235, 255), [C(60, 200, 255, 0.32), C(40, 90, 220, 0.4), C(120, 255, 220, 0.22), C(30, 60, 160, 0.4)]),
    ];
    public static Color? Hex(string hex) => hex.Length == 6 && uint.TryParse(hex, System.Globalization.NumberStyles.HexNumber, null, out var v) ? Color.FromRgb((byte)(v >> 16), (byte)(v >> 8), (byte)v) : null;
    public static string Hex(Color c) => $"{c.R:x2}{c.G:x2}{c.B:x2}";
    /// Sets the accent and sky colors from Settings (the window is rebuilt afterwards to use them).
    public static void Apply()
    {
        var me = Store.Shared.Me;
        if (me.Theme == "custom")
        {
            var accent = Hex(me.CustomAccent) ?? All[0].Accent; Color a = Hex(me.CustomSky1) ?? C(214, 48, 140), b = Hex(me.CustomSky2) ?? C(80, 130, 255);
            JT.Lavender = accent; JT.LavenderHi = Color.FromRgb((byte)(accent.R + (255 - accent.R) * 0.35), (byte)(accent.G + (255 - accent.G) * 0.35), (byte)(accent.B + (255 - accent.B) * 0.35));
            JT.Glows = [Color.FromArgb(82, a.R, a.G, a.B), Color.FromArgb(102, b.R, b.G, b.B), Color.FromArgb(66, a.R, a.G, a.B), Color.FromArgb(92, b.R, b.G, b.B)];
        }
        else { var t = All.FirstOrDefault(x => x.Id == me.Theme) ?? All[0]; JT.Lavender = t.Accent; JT.LavenderHi = t.AccentHi; JT.Glows = t.Glows; }
        if (Application.Current is { } app) app.Resources["Lavender"] = new SolidColorBrush(JT.Lavender);
    }
}

// MARK: - Celebrations: confetti, the chime and the 999 shower

public static class Fx
{
    static Canvas? layer;
    public static void Attach(Canvas c) => layer = c;

    /// Confetti (rainbow bits, hearts, 999s and butterflies) rains down when songs land in your library.
    public static void Confetti()
    {
        if (layer is null || layer.ActualWidth == 0) return;
        double w = layer.ActualWidth, h = layer.ActualHeight;
        for (int n = 0; n < 90; n++)
        {
            FrameworkElement bit = n % 9 == 0 ? new Image { Source = JT.Image(new[] { "jt-heart", "jt-era-999", "jt-fly" }[n % 3]), Width = 26, Height = 26 }
                : new Rectangle { Width = 8, Height = 14, RadiusX = 2, RadiusY = 2, Fill = JT.Brush(JT.Rainbow[n % JT.Rainbow.Length]) };
            Drop(bit, w * 0.1 + Random.Shared.NextDouble() * w * 0.8, -30, h + 40, 3 + Random.Shared.NextDouble() * 3, Random.Shared.NextDouble() * 0.3);
        }
        Chime.Play();
    }
    /// The 999 easter egg: "999"s and sparkles drifting up from the bottom, glowing.
    public static void Shower999()
    {
        if (layer is null || layer.ActualWidth == 0) return;
        double w = layer.ActualWidth, h = layer.ActualHeight;
        for (int n = 0; n < 40; n++)
        {
            var t = new TextBlock { Text = "999", FontFamily = JT.Marker, FontSize = 26 + Random.Shared.Next(16), Foreground = Brushes.White, Effect = UI.Glow(JT.Lavender, 8, 0.9) };
            Drop(t, Random.Shared.NextDouble() * w, h + 20, -60, 4 + Random.Shared.NextDouble() * 3, Random.Shared.NextDouble() * 1.6);
        }
    }
    static void Drop(FrameworkElement e, double x, double from, double to, double secs, double delay)
    {
        e.IsHitTestVisible = false; Canvas.SetLeft(e, x); Canvas.SetTop(e, from); e.Opacity = 0;
        var spin = new RotateTransform(Random.Shared.Next(360)); e.RenderTransform = spin; e.RenderTransformOrigin = new Point(0.5, 0.5);
        layer!.Children.Add(e);
        var begin = TimeSpan.FromSeconds(delay); var dur = TimeSpan.FromSeconds(secs);
        var fall = new DoubleAnimation(from, to, dur) { BeginTime = begin, EasingFunction = new QuadraticEase { EasingMode = to > from ? EasingMode.EaseIn : EasingMode.EaseOut } };
        fall.Completed += (_, _) => layer.Children.Remove(e);
        e.BeginAnimation(Canvas.TopProperty, fall);
        e.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimationUsingKeyFrames { BeginTime = begin, KeyFrames = { new LinearDoubleKeyFrame(1, KeyTime.FromPercent(0.05)), new LinearDoubleKeyFrame(1, KeyTime.FromPercent(0.7)), new LinearDoubleKeyFrame(0, KeyTime.FromPercent(1)) }, Duration = dur });
        spin.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(spin.Angle, spin.Angle + (Random.Shared.Next(2) == 0 ? -360 : 360), dur) { BeginTime = begin });
    }
}

/// A short bell (three rising notes), made in code, so it's ours. Off unless turned on in Settings.
public static class Chime
{
    static readonly byte[] Wav = Make();
    public static void Play() { if (!Store.Shared.Me.Chime) return; try { new System.Media.SoundPlayer(new MemoryStream(Wav)).Play(); } catch (Exception) { } }
    static byte[] Make()
    {
        int rate = 44100, n = (int)(rate * 1.2);
        (double F, double Start)[] notes = [(1318.51, 0), (1975.53, 0.09), (2637.02, 0.18)]; // E6, B6, E7
        using var ms = new MemoryStream(); using var w = new BinaryWriter(ms);
        w.Write("RIFF"u8); w.Write(36 + n * 2); w.Write("WAVEfmt "u8); w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16);
        w.Write("data"u8); w.Write(n * 2);
        for (int k = 0; k < n; k++)
        {
            double t = (double)k / rate, v = 0;
            foreach (var (f, s) in notes) if (t >= s) { double u = t - s; v += (Math.Sin(2 * Math.PI * f * u) + 0.3 * Math.Sin(4 * Math.PI * f * u)) * Math.Exp(-5 * u) * Math.Min(1, u * 400); }
            w.Write((short)(Math.Clamp(v * 0.22, -1, 1) * short.MaxValue));
        }
        return ms.ToArray();
    }
}

// MARK: - The notification-area icon (the Mac app's menu bar player) and new-song alerts

public static class Tray
{
    static System.Windows.Forms.NotifyIcon? icon;
    public static bool Quitting;
    public static void Start()
    {
        if (icon is not null) return;
        var exe = Environment.ProcessPath;
        icon = new System.Windows.Forms.NotifyIcon
        {
            Icon = exe is not null ? System.Drawing.Icon.ExtractAssociatedIcon(exe) : System.Drawing.SystemIcons.Application,
            Text = "Juice Tracker", Visible = true, ContextMenuStrip = new System.Windows.Forms.ContextMenuStrip(),
        };
        icon.ContextMenuStrip.Opening += (_, _) => BuildMenu();
        icon.DoubleClick += (_, _) => Open();
        icon.BalloonTipClicked += (_, _) => { Open(); MainWindow.Current?.Show(Page.Collection); };
        Player.Shared.Changed += () => { if (icon is not null) icon.Text = Trim(Player.Shared.Title is { } t ? $"Juice Tracker: {t}" : "Juice Tracker"); };
    }
    static string Trim(string s) => s.Length > 63 ? s[..63] : s;
    static void BuildMenu()
    {
        var m = icon!.ContextMenuStrip!; m.Items.Clear(); var p = Player.Shared; var store = Store.Shared;
        m.Items.Add(new System.Windows.Forms.ToolStripMenuItem($"You have {store.Owned.Count:N0} of {store.Catalog.Count:N0} songs") { Enabled = false });
        m.Items.Add(new System.Windows.Forms.ToolStripMenuItem(p.Title is { } t ? $"♪ {t}" : "Not playing") { Enabled = false });
        m.Items.Add(p.IsPlaying ? "Pause" : "Play", null, (_, _) => App.Current.Dispatcher.Invoke(p.TogglePause));
        m.Items.Add("Next song", null, (_, _) => App.Current.Dispatcher.Invoke(p.Skip));
        m.Items.Add(new System.Windows.Forms.ToolStripSeparator());
        if (store.NewSongNames.Count > 0)
        {
            m.Items.Add(new System.Windows.Forms.ToolStripMenuItem("New songs:") { Enabled = false });
            foreach (var n in store.NewSongNames.Take(5)) m.Items.Add($"   {n}", null, (_, _) => Open());
        }
        m.Items.Add("Open Juice Tracker", null, (_, _) => Open());
        m.Items.Add("Settings…", null, (_, _) => App.Current.Dispatcher.Invoke(() => { Open(); SettingsWindow.Open(); }));
        m.Items.Add("Quit Juice Tracker", null, (_, _) => App.Current.Dispatcher.Invoke(() => { if (!App.ConfirmQuit()) return; Quitting = true; App.Current.Shutdown(); }));
    }
    public static void Open() => App.Current.Dispatcher.Invoke(() => { var w = MainWindow.Current; if (w is null) return; w.Show(); if (w.WindowState == WindowState.Minimized) w.WindowState = WindowState.Normal; w.Activate(); });
    public static void Notify(string title, string text) { if (icon is null) return; icon.BalloonTipTitle = title; icon.BalloonTipText = text; icon.ShowBalloonTip(8000); }
    public static void Stop() { if (icon is not null) { icon.Visible = false; icon.Dispose(); icon = null; } }
}

// MARK: - Updates from GitHub releases

public static class Updater
{
    const string Feed = "https://api.github.com/repos/HB4Delirious/juice-wrld-tracker/releases/latest";
    public static string Current => typeof(Updater).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}" : "0";
    static bool IsNewer(string a, string b)
    {
        var x = a.Split('.').Select(s => int.TryParse(s, out var n) ? n : 0).ToArray(); var y = b.Split('.').Select(s => int.TryParse(s, out var n) ? n : 0).ToArray();
        for (int i = 0; i < Math.Max(x.Length, y.Length); i++) { int p = i < x.Length ? x[i] : 0, q = i < y.Length ? y[i] : 0; if (p != q) return p > q; }
        return false;
    }
    public static void StartDailyChecks()
    {
        // leftovers from the last update
        try { if (Environment.ProcessPath is { } exe && File.Exists(exe + ".old")) File.Delete(exe + ".old"); } catch (Exception) { }
        var t = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromHours(24) };
        t.Tick += (_, _) => { if (Store.Shared.Me.AutoUpdate) _ = Check(false); };
        t.Start();
        Task.Delay(TimeSpan.FromSeconds(15)).ContinueWith(_ => App.Current.Dispatcher.Invoke(() => { if (Store.Shared.Me.AutoUpdate) _ = Check(false); }));
    }
    public static async Task Check(bool userAsked)
    {
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("JuiceTracker-Windows");
            var json = JsonNode.Parse(await http.GetStringAsync(Feed));
            var tag = json?["tag_name"]?.GetValue<string>() ?? throw new EngineError("Couldn't read the latest release.");
            var latest = tag.TrimStart('v');
            if (!IsNewer(latest, Current)) { if (userAsked) MessageBox.Show($"Juice Tracker {Current} is the latest version.", "You're up to date."); return; }
            if (!userAsked && Store.Shared.Me.SkippedVersion == latest) return;
            var url = (json?["assets"] as JsonArray)?.FirstOrDefault(a => a?["name"]?.GetValue<string>() == "JuiceTracker.exe")?["browser_download_url"]?.GetValue<string>()
                      ?? throw new EngineError($"The {tag} release has no Windows app.");
            Inbox.Add($"Juice Tracker {latest} is available", $"You have {Current}.");
            var answer = MessageBox.Show($"You have {Current}. Update now? Juice Tracker will close, update and reopen.\n\n(No skips this version.)", $"Juice Tracker {latest} is available", MessageBoxButton.YesNoCancel, MessageBoxImage.Information);
            if (answer == MessageBoxResult.No) { Store.Shared.Me.SkippedVersion = latest; Store.Shared.SavePersonal(); return; }
            if (answer != MessageBoxResult.Yes) return;
            await Install(http, url);
        }
        catch (Exception e) { if (userAsked) MessageBox.Show(e.Message, "Couldn't check for updates"); }
    }
    /// Downloads the new exe next to this one, checks it's a Windows program of a sensible size, then swaps it in (a
    /// running exe can be renamed, not overwritten) and restarts.
    static async Task Install(HttpClient http, string url)
    {
        var exe = Environment.ProcessPath ?? throw new EngineError("Can't find where Juice Tracker is installed.");
        var tmp = exe + ".new";
        await using (var fs = File.Create(tmp)) await (await http.GetStreamAsync(url)).CopyToAsync(fs);
        var head = new byte[2]; await using (var f = File.OpenRead(tmp)) _ = await f.ReadAsync(head);
        if (head[0] != 'M' || head[1] != 'Z' || new FileInfo(tmp).Length < 10_000_000) { File.Delete(tmp); throw new EngineError("The download isn't the Juice Tracker app, so it wasn't installed."); }
        File.Move(exe, exe + ".old", true);
        // antivirus scanning the new file can block this for a moment: then the old app goes back, so there's always one
        try { File.Move(tmp, exe); }
        catch (Exception) { File.Move(exe + ".old", exe, true); throw new EngineError("The new version couldn't be put in place (another program had it open), so you still have this one. Try again in a minute."); }
        Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true });
        Tray.Quitting = true;
        App.Current.Shutdown();
    }
}

// MARK: - Discord status

/// Shows "Listening to …" in your Discord profile while music plays, through the Discord app on this PC (its local
/// pipe; nothing goes over the network from here). Needs a Discord application ID (Settings).
public static class Discord
{
    static NamedPipeClientStream? pipe; static string connectedId = "", lastKey = "";
    static readonly SemaphoreSlim gate = new(1, 1);
    public static void Start()
    {
        Player.Shared.Changed += () => _ = Update();
        var retry = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(30) };
        retry.Tick += (_, _) => { if (pipe is null) lastKey = ""; _ = Update(); }; // Discord opened mid-song: try again
        retry.Start();
    }
    static async Task Update()
    {
        var me = Store.Shared.Me; var p = Player.Shared;
        var id = me.DiscordAppId.Trim(); var title = me.DiscordOn && p.IsPlaying ? p.Title : null;
        var era = title is not null && p.CurrentFile is { } f && Store.Shared.SongForFile(f) is var i and >= 0 ? Engine.EraName(Store.Shared.Catalog[i]) : "";
        var key = $"{id}|{title}|{era}";
        if (key == lastKey) return;
        lastKey = key;
        var started = DateTimeOffset.UtcNow.ToUnixTimeSeconds() - (long)p.Position.TotalSeconds;
        await gate.WaitAsync();
        try { await Task.Run(() => Send(id, title, era, started)); } finally { gate.Release(); }
    }
    static void Send(string id, string? title, string era, long started)
    {
        if (id.Length == 0 || !id.All(char.IsDigit)) { Close(); return; }
        if (pipe is null || connectedId != id) { Close(); Connect(id); }
        if (pipe is null) return;
        JsonNode? activity = title is null ? null : new JsonObject
        {
            ["details"] = title, ["state"] = era.Length == 0 ? "Juice WRLD" : $"Juice WRLD · {era}", ["assets"] = new JsonObject { ["large_text"] = "Juice Tracker" },
            ["timestamps"] = new JsonObject { ["start"] = started },
        };
        if (!Frame(1, new JsonObject { ["cmd"] = "SET_ACTIVITY", ["args"] = new JsonObject { ["pid"] = Environment.ProcessId, ["activity"] = activity }, ["nonce"] = Guid.NewGuid().ToString() })) Close();
    }
    static void Connect(string id)
    {
        for (int n = 0; n < 10; n++)
        {
            var p = new NamedPipeClientStream(".", $"discord-ipc-{n}", PipeDirection.InOut, PipeOptions.None);
            try { p.Connect(200); } catch (Exception) { p.Dispose(); continue; }
            pipe = p; connectedId = id;
            if (Frame(0, new JsonObject { ["v"] = 1, ["client_id"] = id })) return;
            Close(); return;
        }
    }
    static bool Frame(int op, JsonObject body)
    {
        try
        {
            var json = Encoding.UTF8.GetBytes(body.ToJsonString());
            var msg = new byte[8 + json.Length];
            BitConverter.GetBytes(op).CopyTo(msg, 0); BitConverter.GetBytes(json.Length).CopyTo(msg, 4); json.CopyTo(msg, 8);
            pipe!.Write(msg); pipe.Flush();
            var head = new byte[8]; if (pipe.Read(head, 0, 8) == 8) { var left = BitConverter.ToInt32(head, 4); var buf = new byte[4096]; while (left > 0) { int r = pipe.Read(buf, 0, Math.Min(left, buf.Length)); if (r <= 0) break; left -= r; } }
            return true;
        }
        catch (Exception) { return false; }
    }
    static void Close() { pipe?.Dispose(); pipe = null; connectedId = ""; }
}

// MARK: - Plex

/// Your Plex server: rescans after downloads and tag edits, play counts for Stats, and playlists from your lists.
public static class Plex
{
    static string Server => (Store.Shared.Me.PlexServer ?? "").Trim().TrimEnd('/');
    public static bool Configured => Server.Length > 0 && Token is not null;
    static string? Token
    {
        get
        {
            try
            {
                var file = Path.Combine(Store.DataDir, "plex.token");
                return File.Exists(file) ? Encoding.UTF8.GetString(System.Security.Cryptography.ProtectedData.Unprotect(File.ReadAllBytes(file), null, System.Security.Cryptography.DataProtectionScope.CurrentUser)) : null;
            }
            catch (Exception) { return null; }
        }
    }
    /// Kept encrypted for your Windows account (DPAPI), never in plain text.
    public static void SaveToken(string token)
    {
        var file = Path.Combine(Store.DataDir, "plex.token");
        if (token.Trim().Length == 0) { File.Delete(file); return; }
        File.WriteAllBytes(file, System.Security.Cryptography.ProtectedData.Protect(Encoding.UTF8.GetBytes(token.Trim()), null, System.Security.Cryptography.DataProtectionScope.CurrentUser));
    }
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };
    static async Task<JsonObject> Call(string path, HttpMethod? method = null)
    {
        if (!Configured || !Uri.TryCreate(Server + path, UriKind.Absolute, out var url) || url.Scheme is not ("http" or "https")) throw new EngineError("Set up Plex in Settings first.");
        using var req = new HttpRequestMessage(method ?? HttpMethod.Get, url);
        req.Headers.Add("X-Plex-Token", Token); req.Headers.Add("Accept", "application/json"); req.Headers.Add("X-Plex-Product", "Juice Tracker"); req.Headers.Add("X-Plex-Client-Identifier", "juice-tracker-windows");
        using var r = await Http.SendAsync(req);
        if ((int)r.StatusCode == 401) throw new EngineError("Plex didn't accept the token.");
        if (!r.IsSuccessStatusCode) throw new EngineError($"Plex answered {(int)r.StatusCode}.");
        var body = await r.Content.ReadAsStringAsync();
        return body.Length > 0 && JsonNode.Parse(body)?["MediaContainer"] is JsonObject c ? c : [];
    }
    public static async Task<List<(string Key, string Title)>> MusicSections() =>
        ((await Call("/library/sections"))["Directory"] as JsonArray ?? []).Where(d => d?["type"]?.GetValue<string>() == "artist")
            .Select(d => (d!["key"]!.GetValue<string>(), d["title"]?.GetValue<string>() ?? "")).ToList();
    static CancellationTokenSource? pending;
    /// Downloads and tag edits come in bursts; one rescan a few seconds after the last change is enough.
    public static void ScheduleRefresh()
    {
        if (!Configured) return;
        pending?.Cancel(); pending = new CancellationTokenSource(); var ct = pending.Token;
        Task.Delay(5000, ct).ContinueWith(async t => { if (t.IsCanceled) return; try { foreach (var s in await MusicSections()) await Call($"/library/sections/{s.Key}/refresh"); } catch (Exception) { } }, TaskScheduler.Default);
    }
    /// Every Plex track by "folder/file name" (Plex may see the files under other paths), with play counts.
    static async Task<Dictionary<string, (string Key, int Plays)>> Tracks()
    {
        var byTail = new Dictionary<string, (string, int)>(StringComparer.OrdinalIgnoreCase);
        foreach (var (key, _) in await MusicSections())
            foreach (var t in (await Call($"/library/sections/{key}/all?type=10"))["Metadata"] as JsonArray ?? [])
            {
                var file = (t?["Media"] as JsonArray)?.FirstOrDefault()?["Part"] is JsonArray parts ? parts.FirstOrDefault()?["file"]?.GetValue<string>() : null;
                if (file is null || t!["ratingKey"]?.GetValue<string>() is not { } rk) continue;
                byTail[Tail(file)] = (rk, t["viewCount"]?.GetValue<int>() ?? 0);
            }
        return byTail;
    }
    static string Tail(string path) { var parts = path.Replace('\\', '/').Split('/'); return string.Join("/", parts.TakeLast(2)); }
    /// Plex's play counts by song, loaded at launch; Stats adds them to the plays heard in this app.
    public static Dictionary<int, int> Counts { get; private set; } = [];
    public static async Task LoadCounts() { if (!Configured) return; try { Counts = await PlayCounts(); Store.Shared.Notify(); } catch (Exception) { } }
    static async Task<Dictionary<int, int>> PlayCounts()
    {
        var tracks = await Tracks(); var store = Store.Shared; var output = new Dictionary<int, int>();
        foreach (var (i, paths) in store.Match.Owned) foreach (var p in paths) if (tracks.TryGetValue(Tail(p), out var t) && t.Plays > 0) output[i] = output.GetValueOrDefault(i) + t.Plays;
        return output;
    }
    /// Makes a Plex playlist from songs you have; returns how many Plex found.
    public static async Task<int> MakePlaylist(string title, IEnumerable<int> songs)
    {
        var tracks = await Tracks(); var store = Store.Shared;
        var keys = songs.SelectMany(i => store.Match.Owned.GetValueOrDefault(i) ?? []).Select(p => tracks.TryGetValue(Tail(p), out var t) ? t.Key : null).OfType<string>().Distinct().ToList();
        if (keys.Count == 0) throw new EngineError("Plex hasn't found these files yet; let it finish scanning and try again.");
        var id = (await Call("/identity"))["machineIdentifier"]?.GetValue<string>() ?? throw new EngineError("Plex didn't say who it is.");
        var uri = Uri.EscapeDataString($"server://{id}/com.plexapp.plugins.library/library/metadata/{string.Join(",", keys)}");
        await Call($"/playlists?type=audio&title={Uri.EscapeDataString(title)}&smart=0&uri={uri}", HttpMethod.Post);
        return keys.Count;
    }
}
