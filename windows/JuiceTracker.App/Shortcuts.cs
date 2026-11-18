using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;

namespace JuiceTracker.App;

/// Your own keys for the player: in the app, or (with Global on) from any app, through Windows' hot keys.
static class Shortcuts
{
    public static readonly (string Id, string Name)[] Actions = [("playPause", "Play / pause"), ("next", "Next song"), ("restart", "Start the song again"), ("volUp", "Volume up"), ("volDown", "Volume down")];
    public static bool Recording; // while Settings records one, keys go to the recorder
    static HwndSource? source;
    static readonly List<int> registered = [];

    public static (ModifierKeys Mods, Key Key)? Get(string id)
    {
        var parts = (Store.Shared.Me.Shortcuts.GetValueOrDefault(id) ?? "").Split('|');
        return parts.Length == 2 && int.TryParse(parts[0], out var m) && int.TryParse(parts[1], out var k) ? ((ModifierKeys)m, (Key)k) : null;
    }
    public static void Set(string id, (ModifierKeys Mods, Key Key)? s)
    {
        if (s is { } v) Store.Shared.Me.Shortcuts[id] = $"{(int)v.Mods}|{(int)v.Key}"; else Store.Shared.Me.Shortcuts.Remove(id);
        Store.Shared.SavePersonal(); Apply();
    }
    public static string Label((ModifierKeys Mods, Key Key)? s) => s is not { } v ? "Not set" :
        string.Concat(new[] { (ModifierKeys.Control, "Ctrl+"), (ModifierKeys.Alt, "Alt+"), (ModifierKeys.Shift, "Shift+"), (ModifierKeys.Windows, "Win+") }.Where(m => v.Mods.HasFlag(m.Item1)).Select(m => m.Item2)) + v.Key;

    /// The key pressed, as a shortcut: it needs Ctrl, Alt or Win (or is a function key), so typing never sets one off.
    public static (ModifierKeys, Key)? From(KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin or Key.None) return null;
        var mods = Keyboard.Modifiers;
        bool fn = key is >= Key.F1 and <= Key.F24;
        return fn || (mods & (ModifierKeys.Control | ModifierKeys.Alt | ModifierKeys.Windows)) != 0 ? (mods, key) : null;
    }

    public static void Run(string id)
    {
        var p = Player.Shared;
        switch (id)
        {
            case "playPause": if (p.CurrentFile is null) { p.SetOn(true); p.Resume(); } else p.TogglePause(); break;
            case "next": p.Skip(); break;
            case "restart": p.Seek(TimeSpan.Zero); break;
            case "volUp": p.Volume = Math.Min(100, p.Volume + 5); break;
            case "volDown": p.Volume = Math.Max(0, p.Volume - 5); break;
        }
    }

    /// Hooks the main window: its keys always, and the system's hot keys while Global is on.
    public static void Start(Window main)
    {
        main.PreviewKeyDown += (_, e) =>
        {
            if (Recording || Store.Shared.Me.ShortcutsGlobal || From(e) is not { } k) return;
            foreach (var (id, _) in Actions) if (Get(id) is { } s && s == k) { Run(id); e.Handled = true; return; }
        };
        main.SourceInitialized += (_, _) =>
        {
            source = HwndSource.FromHwnd(new WindowInteropHelper(main).Handle);
            source.AddHook((IntPtr hwnd, int msg, IntPtr w, IntPtr l, ref bool handled) =>
            {
                if (msg == 0x0312 && (int)w is var n && n >= 1 && n <= Actions.Length && !Recording) { Run(Actions[n - 1].Id); handled = true; }
                return IntPtr.Zero;
            });
            Apply();
        };
    }
    public static void Apply()
    {
        if (source is null) return;
        foreach (var n in registered) UnregisterHotKey(source.Handle, n);
        registered.Clear();
        if (!Store.Shared.Me.ShortcutsGlobal) return;
        for (int n = 0; n < Actions.Length; n++)
        {
            if (Get(Actions[n].Id) is not { } s) continue;
            uint mods = 0x4000; // no repeat
            if (s.Mods.HasFlag(ModifierKeys.Alt)) mods |= 1; if (s.Mods.HasFlag(ModifierKeys.Control)) mods |= 2;
            if (s.Mods.HasFlag(ModifierKeys.Shift)) mods |= 4; if (s.Mods.HasFlag(ModifierKeys.Windows)) mods |= 8;
            if (RegisterHotKey(source.Handle, n + 1, mods, (uint)KeyInterop.VirtualKeyFromKey(s.Key))) registered.Add(n + 1);
        }
    }
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hwnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hwnd, int id);
}
