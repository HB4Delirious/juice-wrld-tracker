# juice-wrld-tracker

Juice WRLD collection tracker: compares the juicewrldapi.com catalog against your own music folder.

- `web/juice-tracker.html` — the whole tracker, one self-contained file. Works on its own in Chrome/Edge.
- `JuiceTracker/` — macOS app (macOS 12+) that hosts the same HTML in a WKWebView, with a native file bridge
  (`bridge.js` + `NativeBridge.swift`) so folder scanning and tag writing work without Chrome.

## Build

Open `JuiceTracker.xcodeproj` in Xcode and Run, or build a DMG:

```bash
scripts/make-dmg.sh   # -> dist/JuiceTracker.dmg
```

Tests for the matcher, tag writers, link setting and backups: `node --test tests/core.test.mjs` (they load the page's `<script id="core">` block, which must stay free of page, storage and network access). CI runs them before every build.

The DMG window is themed (background in `design/dmg-background.svg`, layout in `scripts/dmg-settings.py`, built with `dmgbuild` in a local venv). Artwork in `design/` is rendered with `swift scripts/render-art.swift`.

The app's version comes from the latest `v*` tag (override with `VERSION=1.5 scripts/make-dmg.sh`); the build number is the commit count.

The app is ad-hoc signed ("Sign to Run Locally"), so the first launch from a downloaded DMG needs
right-click > Open (or System Settings > Privacy & Security > Open Anyway).

The "Support this project" button opens `TIP_URL` (near the end of `web/juice-tracker.html`), currently https://ko-fi.com/hb4delirious.

CI (`.github/workflows/build.yml`) builds the DMG on every push and PR; pushing a `v*` tag attaches it to a GitHub Release.

In the Mac app, a song's **Download** link saves the file from juicewrldapi.com straight into the folder the tracker suggests inside your music folder, and adds it to your library right away (⌘-click opens the site instead).

In the Mac app, the sidebar's **Ambient music** toggle plays your matched songs, shuffled, at very low volume. It's on by default and remembers when you turn it off.

## Mac app extras

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
- **Timeline:** every song as a dot in the month it was recorded, with yours lit up. **Collection card** (Export & backup): an image of your progress to post or keep.
- **Settings (⌘,):**
  - Daily new-song and release alerts (macOS notifications), "Keep running when the window is closed", and "Open at login".
  - Automatic app updates from GitHub releases (also Juice Tracker > Check for Updates…).
  - Plex: server address plus token (kept in the Keychain). Plex rescans after downloads and tag edits, and Export & backup can make Plex playlists.

Because the app is ad-hoc signed, macOS may ask once after each update to let it read the Plex token from the Keychain; choose Always Allow. Utilities that quit apps with no windows (for example Vorssaint) override "Keep running"; add Juice Tracker as an exception there.
