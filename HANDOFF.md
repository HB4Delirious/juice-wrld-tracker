# Handoff

Juice WRLD Collection Tracker: a native macOS app (macOS 12+) that compares the juicewrldapi.com catalog with your own
music folder, downloads and tags what's missing, and plays your collection. All Swift since v1.24.

## Layout

- **Interface (SwiftUI):** `NativeUI.swift` (window, sky, sidebar, Collection, song card, `NativeStore`),
  `NativeScreens.swift` (Timeline, Stats, Credits), `NativeTools.swift` (Duplicates, File health), `NativeFixer.swift`
  (Tag fixer), `NativeExtras.swift` (setup, player, Trivia, Export & backup), `NativeMore.swift` (lyrics, mini player,
  Spotlight, Shortcuts, widget feed), `NativeJuice.swift` (era stickers and themes, badges, motion), `NativeFeatures.swift` (ratings, rarity, year in review,
  the lyrics window, drive comparison, seek bar and sleep timer, versions and A/B, listening calendar, gaps heatmap),
  `NativeCollection.swift` (Hunt and suggestions, Playlists and M3U, Organize: file organizer, inbox, Fill a drive;
  wishlist ranking).
- **Engine:**
  - `Engine.swift`: the pure logic, Foundation only: catalog cleaning, tag reading (ID3v1/v2.2–2.4, FLAC, MP4,
    Ogg/Opus) and writing (MP3, FLAC, M4A, with safety checks), scanning, matching, save folders, the tag fixer
    plan, duplicates, file health, export helpers.
  - `EngineState.swift`: the catalog (12-hour cache, new and newly released songs), your saved data (`personal.json`:
    wishlist, notes, hand matches, trivia, fixer settings) and the state every screen shows.
  - `EngineLibrary.swift`: the music folder (bookmark under `lastFolder.plex-music`), tag cache, scan and matching,
    watching the folder (FSEvents) and comparing with another drive, moving files (the organizer, with Undo from
    `lastOrganize.json`) and the inbox folder (`inboxFolder` setting, its own FSEvents stream).
  - `EngineDownloads.swift`: the download queue, drive status, background music, weekly snapshot.
  - `EngineTools.swift`: tag fixer writing, auto-tag after downloads, duplicate cleanup, file health.
  - `EngineActions.swift`: backup and restore, the catalog spreadsheet, the collection card.
  - `EngineRest.swift`: `EngineRouter`, which answers the screens' `NativeStore.act(...)` requests (details, play,
    play history, trivia, Plex, snapshots, and the tools above).
- `Player.swift`: the background music player (`AmbientPlayer`) and `Downloader` (site files into the folder).
- `Services.swift`: settings, Plex, daily song alerts, the updater, snapshots folder. `MenuBar.swift`: menu bar player.
- `JuiceTrackerWidget/`: the widget (reads `widget.json`, written by `WidgetFeed`).
- Saved data: `~/Library/Application Support/JuiceTracker/<app id>/engine/` (`catalog.json`, `saved.json`,
  `personal.json` (also ratings, `wishOrder` and `playlists`, all in backups), `tags.json`, `items.json`, `queue.json`,
  `settings.json`, `lastOrganize.json`).

## Safety rules for your files

Tags and cover art are only written after `TagWriter`'s check passes (audio bytes unchanged, every tag reads back); the original
is backed up first when a backup folder is set; writes are atomic. Files are only removed by moving them to the Trash.
Downloads never overwrite, and never leave the music folder. The organizer and inbox move files only inside the music
folder (or from the inbox into it), never onto an existing file; a folder a move empties is removed only if it's empty.
When a title matches several versions, `Engine.primarySong` settles it (one name among the plain-named versions, and
the era most of them share) or the file stays put. A move never takes a file somewhere the library would stop counting it
(`Engine.countsAsJuice`). The inbox only takes files that have finished arriving (`Engine.settled`: same size a few
seconds apart, untouched for 10 seconds), runs one pass at a time, and tags each file it moves (artist included).

## Tests

`scripts/test-engine.sh` (run in CI before every build) compiles `Engine.swift` with `tests/EngineTests.swift` and
checks it against `tests/fixtures`: the old HTML page's own answers for tricky inputs, frozen when the page was
retired. Tag writes must match the page byte for byte, with the same safety-check results and error text. Two cases
go beyond the page on purpose: tags after large cover art are read (the page missed them), and adding cover art
(`TagWriter.addArt`) to each format leaves the tags readable and refuses a second picture. The organizer's plan
and `primarySong` have their own checks.

## History

The app began as a single HTML page in a WKWebView (v1.0–v1.17), got a native SwiftUI interface with the page running
unseen as its engine (v1.17–v1.21), and the engine was then ported to Swift in stages with parity tests against the
page (v1.22–v1.24): data and matching, the catalog and the screens' state, backup/export/card, the library, downloads
and file writes, then the rest; then the page, the web view, the bridge and `web/` were deleted.

Updating from v1.21 or earlier straight to v1.24+ loses what only the page held (its tag cache and queue, and the
wishlist and notes if v1.22 never ran): v1.22 and v1.23 carried those over. A missing tag cache just means one full
rescan.

## Not done yet
- Unsigned/un-notarized: Gatekeeper warns on first open of a downloaded DMG.
