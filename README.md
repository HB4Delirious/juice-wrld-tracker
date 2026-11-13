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
- **Player:** pause, next and volume for the ambient music, and Play buttons on your files in each song's card.
- **Settings (⌘,):**
  - Daily new-song and release alerts (macOS notifications), "Keep running when the window is closed", and "Open at login".
  - Automatic app updates from GitHub releases (also Juice Tracker > Check for Updates…).
  - Plex: server address plus token (kept in the Keychain). Plex rescans after downloads and tag edits, and Export & backup can make Plex playlists.

Because the app is ad-hoc signed, macOS may ask once after each update to let it read the Plex token from the Keychain; choose Always Allow. Utilities that quit apps with no windows (for example Vorssaint) override "Keep running"; add Juice Tracker as an exception there.
