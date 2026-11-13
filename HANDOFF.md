# Handoff: work in progress

Started in a Claude chat session; continue in Claude Code on the Mac.

## Goal
Turn `web/juice-tracker.html` (single-file Juice WRLD collection tracker) into a native macOS app:
an editable Xcode project, a DMG, and this GitHub repo for history.

## Done
- `web/juice-tracker.html`: the tracker (bulk file links, save-to folder suggestions, M4A tag editing, manual matches). Still works on its own in Chrome/Edge.
- `JuiceTracker/JuiceTrackerApp.swift`: SwiftUI app, one window, Reload/Zoom menu commands.
- `JuiceTracker/WebViewStore.swift`: WKWebView host. Loads the bundled HTML via loadFileURL, opens http(s) links in the default browser,
  handles downloads with a save panel (WKDownload), alert/confirm panels, and <input type=file> open panels.
- `JuiceTracker/NativeBridge.swift`: WKScriptMessageHandlerWithReply named `jwNative`. Ops: pickFolder, list, stat, exists, read (base64 range),
  write (base64, atomic), mkdir, copy. Only paths inside folders picked via NSOpenPanel are allowed.
- `JuiceTracker/bridge.js`: injected at document start. Polyfills showDirectoryPicker and the directory/file handles + createWritable
  the tracker uses, so tag writing works in the app.
- `JuiceTracker/Assets.xcassets`: AppIcon (all mac sizes) + AccentColor.

## Also done
- `JuiceTracker.xcodeproj` (macOS 12+, sandbox off, ad-hoc signed, shared scheme; bridge.js and web/juice-tracker.html bundled by reference).
- `scripts/make-dmg.sh`, `.github/workflows/build.yml`, README.
- Tested in the app: catalog loads from juicewrldapi.com, localStorage survives relaunch, folder scan + M4A tag writing via the bridge,
  CSV export via save panel, target=_blank links open in the default browser.

## Not done yet
- Unsigned/un-notarized: Gatekeeper warns on first open of a downloaded DMG.
