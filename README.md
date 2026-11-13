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

The DMG window is themed (background in `design/dmg-background.svg`, layout in `scripts/dmg-settings.py`, built with `dmgbuild` in a local venv). Artwork in `design/` is rendered with `swift scripts/render-art.swift`.

The app's version comes from the latest `v*` tag (override with `VERSION=1.5 scripts/make-dmg.sh`); the build number is the commit count.

The app is ad-hoc signed ("Sign to Run Locally"), so the first launch from a downloaded DMG needs
right-click > Open (or System Settings > Privacy & Security > Open Anyway).

The "Support this project" button opens `TIP_URL` (near the end of `web/juice-tracker.html`), currently https://ko-fi.com/hb4delirious.

CI (`.github/workflows/build.yml`) builds the DMG on every push and PR; pushing a `v*` tag attaches it to a GitHub Release.

In the Mac app, the sidebar's **Ambient music** toggle plays your matched songs, shuffled, at very low volume. It's on by default and remembers when you turn it off.
