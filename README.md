# juice-wrld-tracker

Juice WRLD collection tracker: compares the juicewrldapi.com catalog against your own music folder.

- `JuiceTracker/` — the macOS app (macOS 12+), all Swift: a SwiftUI interface (`Native*.swift`) on top of the engine
  (`Engine*.swift`; the pure logic is `Engine.swift`). It started as an HTML page; that page was retired in v1.24.
- `windows/` — the Windows app (Windows 10/11), native .NET/WPF, with the Mac app's look: the same night sky, stickers,
  fonts and hand-drawn outlines. `JuiceTracker.Core` is the engine in C#, checked against the same frozen answers as
  the Swift engine; `JuiceTracker.App` is the app. Each release has `JuiceTracker.exe`, one self-contained file
  (no install, no .NET needed).

## Build

Open `JuiceTracker.xcodeproj` in Xcode and Run, or build a DMG:

```bash
scripts/make-dmg.sh   # -> dist/JuiceTracker.dmg
```

Tests: `scripts/test-engine.sh` compiles `Engine.swift` with `tests/EngineTests.swift` and checks it against
`tests/fixtures`, the old HTML page's own answers for tricky titles, catalog records, tag files (written by its writers
and by hand), matching, save folders, the tag fixer, duplicates and file health. Tag writes must match byte for byte.
CI runs them before every build.

The DMG window is themed (background in `design/dmg-background.svg`, layout in `scripts/dmg-settings.py`, built with `dmgbuild` in a local venv). Artwork in `design/` is rendered with `swift scripts/render-art.swift`.

The app's version comes from the latest `v*` tag (override with `VERSION=1.5 scripts/make-dmg.sh`); the build number is the commit count.

The app is ad-hoc signed ("Sign to Run Locally"), so the first launch from a downloaded DMG needs
right-click > Open (or System Settings > Privacy & Security > Open Anyway).

The "Support this project" button opens https://ko-fi.com/hb4delirious (the sidebar, `NativeUI.swift`).

CI (`.github/workflows/build.yml`) builds the DMG on every push and PR; pushing a `v*` tag attaches it to a GitHub Release.

A song's **Download** button saves the file from juicewrldapi.com straight into the folder your era's songs live in, adds it to your library and tags it.

The sidebar's **Ambient music** toggle plays your matched songs, shuffled, at very low volume. It's on by default and remembers when you turn it off.

## Windows app

It has every screen the Mac app has: Collection, Player, Hunt, Playlists, Tag fixer, Duplicates, File health, Organize,
Credits, Stats, Timeline, Badges, Trivia and Export & backup, plus the song card (details, credit links, lyrics shown
live from the site, versions with A/B compare), downloads (taskbar progress, confetti and an optional chime when
songs land), the inbox folder, the music player (crossfade, Up next, era radio, sleep timer, volume matching, a mini
player and a lyrics window), era themes or your own colors, compact mode, a notification-area icon with new-song and
wishlist alerts, daily update checks, Discord status and Plex. Ctrl+K searches, Ctrl+, opens Settings, and typing 999
does what it does on the Mac.

Mac-only, with no Windows equivalent built: Spotlight, Siri/Shortcuts, the widget and the Dock icon glow. Discord
status needs your own Discord application ID (Settings explains how).

```bash
dotnet run --project windows/JuiceTracker.Tests      # engine checks (any OS)
dotnet build windows/JuiceTracker.App                # builds on any OS; runs on Windows
```

Your data is in `%LOCALAPPDATA%\JuiceTracker`. The exe isn't code-signed, so Windows SmartScreen may warn on first
open ("More info", then "Run anyway").

## Mac app extras

The interface is native SwiftUI with a Core Animation sky: about 2–5% CPU, against about 30% for the old HTML page.
Your data lives in `~/Library/Application Support/JuiceTracker/<app id>/engine/` (catalog, wishlist and notes, tag
cache, download queue).


- **Search:** ⌘K jumps to any song, era, producer/artist/engineer/studio, or page.
- **Download all:** the File links list downloads every missing song in view, one at a time (stoppable). New downloads are auto-tagged with the tag fixer's settings (option in the tag fixer).
- **Duplicates:** keep the best copy (lossless, then largest) and move the rest to the Trash. Only for files with exactly the same title, so remixes and versions are never touched.
- **Player:** pause, next and volume for the ambient music, and Play buttons on your files in each song's card. It shows in Now Playing (Control Center) with the cover art, and the keyboard's media keys and AirPods controls work.
- **Menu bar:** a butterfly mini player with play/pause, next, volume and the latest new songs (can be turned off in Settings).
- **Eras:** each era lists what you're missing (songs, other versions, sessions, remixes); "Complete this era" downloads all of them.
- **File health:** finds files that don't open, look cut off (much shorter than the catalog length) or very small, and files with missing or mismatched tags, with fixes: replace with the site's copy, Show in Finder, move to Trash, or open the tag fixer.
- **Drive status:** the sidebar shows whether the music folder's drive is connected, slow or disconnected; click it to reconnect.
- **Plex listening (Stats):** most-played songs, songs you've never played, and top eras by plays, from your Plex play counts.
- **Download queue:** downloads (Download all, Complete this era, missing versions, wishlist alerts) are queued in the app. The queue carries on after you quit, waits and reconnects when the music drive drops, and retries failed songs up to 3 times. Progress and a Stop button are in the sidebar.
- **Wishlist alerts:** when a wishlist song gets a file on the site or is released, it gets its own notification with a Download button.
- **Library snapshot:** every week a CSV of your files, tags and matched songs is saved to iCloud Drive (or Documents), off the music drive. Export & backup can open a snapshot to download what's missing.
- **Versions:** each song card lists all versions side by side, with a button to download the missing ones. **On this day** on the home page shows songs recorded, previewed, surfaced or released on today's date.
- **Music:** pick an era to shuffle (or Play this era from its card); songs you've heard today are skipped until everything has played. **Smart playlists:** Plex "most played" and "never played" lists in Export & backup. **Trivia:** Name that song plays a clip from your own files.
- **Upgrades:** File health also lists songs where the site has a lossless or higher-bitrate copy, with an Upgrade button.
- **Lyrics and artwork:** song cards show the lyrics from juicewrldapi.com (timed lyrics follow the music while the song plays), the era's artwork, and instrumental notes. The sidebar player shows the line being sung, and songs without their own cover use the era art in Now Playing.
- **Mini player** (Window > Mini Player, ⌘3): a small window that stays on top, with a visualizer that moves with the music (the sky glows along with it).
- **Listening (Stats):** a listening timeline (plays per day for 30 days, or per week for 26), your top songs this week and all time from the app's own plays (with a button to play your most played), your most played eras, what you played recently, owned songs you've never played, and Plex play counts.
- **Spotlight and Shortcuts:** songs you have show up in ⌘Space search; Shortcuts and Siri can play an era, pause, skip, say what's playing, and download your wishlist.
- **Desktop widget:** your collection count, what's playing and "On this day" (right-click the desktop > Edit Widgets > Juice Tracker; macOS 14 or later).
- **Juice touches** (original art): era cards wear stickers that fit the era (a race car for DRFL, a halo for LND, a demon for FD, balloons for the party eras, 999 flash, a globe for WOD), a second tattoo-flash layer drifts through the sky, loading shows a spinning 999, and **Badges** collects milestones (999 club and more) and completed eras.
- **Motion**: confetti and a note when songs land, the big count rolls up, pages fade in, the sidebar highlight glides, bars grow in, era cards rise in and their stickers slap on, finished eras get a COMPLETE stamp, the song playing shows bouncing bars, earned badges glint, and notes drift up from the player. All of it is Core Animation or one-shot SwiftUI, so it costs next to nothing.
- **Era themes** (Settings > Look): recolor the accents and the sky after an era: Goodbye & Good Riddance blue, Death Race for Love red, Legends Never Die gold, Fighting Demons green or WRLD on Drugs cyan.
- **Timeline:** every song as a dot in the month it was recorded, with yours lit up. **Collection card** (Export & backup): an image of your progress to post or keep.
- **Playback:** songs crossfade into each other (Settings > Playback, off to 12 seconds). **Play next** (song card or a row's right-click menu) queues a song after the one playing; the player shows what's up next. **Era radio:** the player's era menu can play an era in recording order instead of shuffled. Pausing and resuming fade over a moment, and the app can ask before quitting while a song plays (both in Settings).
- **Ratings and rarity:** rate songs 1–5 hearts on their card; Collection has a **Top rated** tab. Unreleased songs with no file on the site are marked **Rare**, and **Grail** when you have them.
- **Full-screen lyrics:** the quote button on the player opens a big lyrics window (full screen works) with the line being sung large. Shown live from juicewrldapi.com, never saved.
- **Year in review (Stats):** your plays this year, about how long you listened, top songs, top eras and your busiest month, and a Wrapped picture of it to save or copy.
- **Watching the folder:** files added, changed or removed in the music folder show up a moment later, without a rescan. The catalog is also refreshed in the background when it's over 12 hours old, and new songs with a file get a notification with a Download button.
- **Compare with another drive** (Export & backup): scans a second folder, like a backup drive, and lists the songs only on one of them, with a button to download the ones missing here. Nothing on either drive changes.
- **Loudness and cover art (File health):** files much quieter or louder than the rest of your library, and files with no cover art. **Add artwork** writes the song's picture from the site into the file (one at a time or all at once), with the same safety check and backup as the tag fixer.
- **Faster first scan:** a network drive is read 16 files at a time.
- **Hunt:** one song you don't have, picked each day, with its story and where it might turn up, plus "you rated these highly, so try…" suggestions (same song's other versions, the same producer, the same era).
- **Player tab:** made to leave on screen: deep space with a ringed black hole whose glowing disc takes its colors from the song's cover (the era's art when the file has none), the time above it, the line being sung lighting up word by word, the cover on a tilted card (click for the song card), the queue floating at the left (click plays, right-click moves or removes), and a control bar with shuffle by era, restart, play/pause, next, era radio, progress you can click, a heart (5 hearts or clear), sleep timer, lyrics window, mini player and volume. The search button opens all your playable songs by era: play one now or next (double-click plays), play an era in recording order, or shuffle it. Flair: sparks orbit inside the disc, its near side glows brighter, the ring around the hole swells with the music (Mac; it breathes slowly on Windows), a ring in the new song's colors rolls out when a song starts, stars twinkle and shooting stars cross now and then, the word being sung takes the song's color, the play button and progress glow in its colors, and the cover card straightens up under the pointer. Hearts, 999s, butterflies and stickers swirl around the hole and speed up with the beat (on Windows the app measures the playing file's loudness for this), and faint doodles drift across the sky behind. On the Mac the motion runs in Core Animation and stops while the app is in the background (about 9% CPU on the Player tab with music playing).
- **Go live from the app:** Settings > Live takes the Server URL and Stream Key TikTok gives when you set up a LIVE on a computer (TikTok LIVE Studio / LIVE Center; new ones each LIVE; any RTMP service works too). Then the Player tab's broadcast button > Go live (portrait or landscape) opens the stream window and streams it: a LIVE badge shows the time on air (Mac: and the bitrate). Mac: the window's picture and the app's own sound are captured with ScreenCaptureKit (macOS asks once for Screen Recording permission; macOS 13+), encoded on the Mac's media engine (1080x1920 or 1920x1080, H.264 4.5 Mbps, AAC 128 kbps) and sent over RTMP by the app itself. Windows: the picture is drawn 30 times a second (720x1280 or 1280x720) and this PC's sound is taken from the speakers (so other sounds go out too); FFmpeg 9.0.2 encodes and sends them, fetched the first time (about 115 MB, checked against its fingerprint) into the data folder. The key is kept in the Keychain (Mac) or encrypted for your Windows account. CI streams a test picture from each app into an RTMP receiver and checks it decodes.
- **Streaming (TikTok LIVE, OBS):** the Player tab's broadcast button (Mac: also Window > Stream Window) opens a clean window of the player, no buttons, in **portrait 9:16** for phones or **landscape 16:9**, or both at once. Each lays itself out for its shape and keeps its shape when resized; with a stream window open the motion and lyrics keep going while the app is in the background.
  - Windows: in TikTok LIVE Studio add a Window Capture of "Juice Tracker Stream (portrait)" (or landscape, matching the orientation you pick in LIVE Studio).
  - Mac: in OBS add a macOS Screen Capture of the stream window (canvas 1080x1920 for portrait, 1920x1080 for landscape) and stream to TikTok with your LIVE stream key.
  - A TikTok LIVE is one shape at a time: portrait fills phones held upright; landscape lives fill the screen when viewers rotate their phone. To offer both, capture both windows (for example OBS with a vertical canvas plugin) or switch scenes. TikTok may mute or end lives that play copyrighted music.
- **Identify a song:** drop any audio file on Juice Tracker to see which catalog song it is (by its tags, name and length), whether you have it, and open its card.
- **Notifications:** the bell at the top of the sidebar keeps the app's recent alerts: new songs, downloads that landed, updates, a full drive.
- **Auto-download:** with it on (Settings), new songs that have a file download on their own when the daily check finds them, keeping 2 GB free on the music drive; any download stops with 1 GB left.
- **Equalizer:** bass, mids and treble (Settings), with presets (Bass boost, Vocals, Bright, Late night). Your files don't change; with it off, songs play exactly as before.
- **Music videos:** a video of the song in its folder (an .mp4, .mov or .m4v with the file's name or the song's title) plays on the Player tab, muted and in time with the song.
- **Player looks:** the Player tab's sparkle button shows every look playing: the ringed black hole, Rings, Bars and a spinning Record with the cover. Click one to use it. Settings can switch the look with every song, and lifts quiet songs so the visuals still move.
- **Keyboard shortcuts:** set your own keys in Settings for play/pause, next song, start the song again and volume up/down; turn on Global and they work while another app is in front.
- **Time the lyrics:** the Player tab's timer button makes synced lyrics for the song playing: press Space as each line (or each word) starts. The Player then sings your timing; it stays on your computer, and you can export it as an .lrc file.
- **Lyric styles:** in Settings, the Player sings the line being sung word by word, or the scrolling list with the lines around it (optionally blurred), in one of five fonts, each previewed singing the line playing.
- **Heardle:** name the song from a clip of your own files: one second at first, more after each wrong guess or skip (up to 16), six tries. Daily (same song all day, with streaks) or unlimited, from the intro or a spot inside the song, from all eras or one.
- **Desktop widgets:** a clock tinted by the cover, what's playing (play/pause, next), up next, a playlist (or your 4-5 heart songs), and an edge light that makes the screen's edges glow with the music in the cover's colors or your own, fading out when the music stops, round every screen. Turn each on in Settings; drag to move, right-click to lock in place or close.
- **Share picture:** the song card's Share picture button saves or copies a 1080x1350 picture of the song: its art, era, dates, producers, and whether you have it.
- **Wordle:** guess a Juice WRLD song title letter by letter (green right place, yellow elsewhere in the title), six tries; one title a day (with played, won and streak counts) or unlimited, from all eras or one.
- **Tier list:** drag your songs into S to D rows (right-click works too), keep several lists, limit one to an era, and save it as a picture.
- **Lyrics card:** the Player tab's quote button turns up to four lines of the song playing into a 1080x1350 picture with its cover (or your own picture), your color, and the title (or none), to save or copy. The lyrics come live from the site and aren't kept.
- **Playlists:** make your own, drag to reorder, play them in order, and download a playlist's missing songs in one go, and export M3U files (also one-click M3Us for an era, top rated, your wishlist and never played).
- **Player:** a seek bar in the sidebar, mini player and menu bar; a sleep timer (15, 30 or 60 minutes, or the end of the song, fading out); volume matching evens out quiet and loud files without changing them. The menu bar also shows your count.
- **Versions and A/B:** each song card lists the song's other versions with what you have, and **Compare A/B** plays two versions in step and switches between them instantly (Tab), pausing the background music meanwhile.
- **Ratings keys and credit links:** on a song card, 1–5 rates and 0 clears; producer, artist, engineer and studio names open Credits on that person, with a button to download what you're missing of theirs.
- **Stats:** a listening calendar (plays per day, with streaks) and a gaps heatmap of every month from 2014 to 2024 by how much of it you have (click a month for its songs). The home page counts your grails.
- **Wishlist ranking:** drag your wishlist into order (Collection > Wishlist > Rank wishlist); wishlist downloads go most wanted first.
- **Organize:** the **file organizer** moves matched files into a pattern like `{era}/{song}` after a preview, never over another file, with Undo; the **inbox folder** files songs you drop in into their era folder (tagging them when it's sure which version); **Fill a drive** copies your best-rated, then rarest, then most played songs to a phone or USB stick up to a size.
- **Look:** your own accent and sky colors, compact mode for small windows, the sky's flash layer shows your era theme's sticker, and the stars and nebula move with the music; the Dock icon glows while music plays and shows download progress; an optional chime when songs land; earned badges save as image cards; and typing 999 in ⌘K (or a count with 999 in it) fills the window with 999s.
- **Discord status:** shows what's playing in your Discord profile through the Discord app (Settings > Discord; needs a free Discord application ID).
- **Settings (⌘,):**
  - Daily new-song and release alerts (macOS notifications), "Keep running when the window is closed", and "Open at login".
  - Automatic app updates from GitHub releases (also Juice Tracker > Check for Updates…).
  - Plex: server address plus token (kept in the Keychain). Plex rescans after downloads and tag edits, and Export & backup can make Plex playlists.

Because the app is ad-hoc signed, macOS may ask once after each update to let it read the Plex token from the Keychain; choose Always Allow. Utilities that quit apps with no windows (for example Vorssaint) override "Keep running"; add Juice Tracker as an exception there.
