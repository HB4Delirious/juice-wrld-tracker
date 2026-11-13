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

The app is ad-hoc signed ("Sign to Run Locally"), so the first launch from a downloaded DMG needs
right-click > Open (or System Settings > Privacy & Security > Open Anyway).

CI (`.github/workflows/build.yml`) builds the DMG on every push and PR; pushing a `v*` tag attaches it to a GitHub Release.
