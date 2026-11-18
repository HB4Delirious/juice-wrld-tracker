using SMTC = global::Windows.Media.SystemMediaTransportControls;

namespace JuiceTracker.App;

/// The keyboard's media keys, and Windows' volume/media pop-up showing the song, through Windows' own media controls
/// (Settings). A silent Windows media player owns them; the music itself plays as before.
static class MediaKeys
{
    static global::Windows.Media.Playback.MediaPlayer? owner;
    static SMTC? smtc;
    static string? shownFile; static bool shownPlaying;

    public static void Apply()
    {
        if (!Store.Shared.Me.MediaKeys) { if (smtc is not null) smtc.IsEnabled = false; return; }
        if (smtc is null)
        {
            try
            {
                owner = new global::Windows.Media.Playback.MediaPlayer(); owner.CommandManager.IsEnabled = false;
                smtc = owner.SystemMediaTransportControls;
            }
            catch (Exception) { return; } // older Windows without them: the app works as before
            smtc.IsPlayEnabled = smtc.IsPauseEnabled = smtc.IsNextEnabled = smtc.IsPreviousEnabled = true;
            smtc.ButtonPressed += (_, e) => App.Current.Dispatcher.BeginInvoke(() =>
            {
                var p = Player.Shared;
                switch (e.Button)
                {
                    case global::Windows.Media.SystemMediaTransportControlsButton.Play: if (p.CurrentFile is null) p.SetOn(true); p.Resume(); break;
                    case global::Windows.Media.SystemMediaTransportControlsButton.Pause: p.Pause(); break;
                    case global::Windows.Media.SystemMediaTransportControlsButton.Next: p.Skip(); break;
                    case global::Windows.Media.SystemMediaTransportControlsButton.Previous: p.Seek(TimeSpan.Zero); break;
                }
            });
            Player.Shared.Changed += Update;
        }
        smtc.IsEnabled = true; shownFile = null; Update();
    }

    /// The pop-up's song and play state; the player ticks 4 times a second, so only on a change.
    // shortcut: no cover in the pop-up (it would need the art as a stream), add it if asked.
    static void Update()
    {
        if (smtc is not { IsEnabled: true }) return;
        var p = Player.Shared;
        if (p.CurrentFile == shownFile && p.IsPlaying == shownPlaying) return;
        shownPlaying = p.IsPlaying;
        smtc.PlaybackStatus = p.CurrentFile is null ? global::Windows.Media.MediaPlaybackStatus.Stopped : p.IsPlaying ? global::Windows.Media.MediaPlaybackStatus.Playing : global::Windows.Media.MediaPlaybackStatus.Paused;
        if (p.CurrentFile == shownFile) return;
        shownFile = p.CurrentFile;
        var d = smtc.DisplayUpdater;
        d.Type = global::Windows.Media.MediaPlaybackType.Music;
        d.MusicProperties.Title = p.Title ?? "Juice Tracker";
        d.MusicProperties.Artist = "Juice WRLD";
        d.MusicProperties.AlbumTitle = p.CurrentFile is { } f && Store.Shared.SongForFile(f) is var i and >= 0 ? Engine.EraName(Store.Shared.Catalog[i]) : "";
        d.Update();
    }
}
