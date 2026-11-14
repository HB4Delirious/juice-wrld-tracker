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

## Moving to SwiftUI (in progress)

Goal: a native SwiftUI interface, which costs far less CPU than the web page (measured: about 4.6% with the native
window in front, against about 30.5% for the classic window). The classic page stays the engine while screens move over:
it loads the catalog, scans and matches the library, writes tags (with its tested safety checks) and downloads.

- `JuiceTracker/NativeUI.swift`: the native window (the app's main window; ⌘1). The sky is drawn by Core
  Animation. `NativeStore` receives the page's snapshot (`jwState` message, sent by `pushNativeState()` after each change)
  and calls `window.jwNativeAction({ op, i })` for actions (wish, download, play, details, refresh).
- Screens not moved yet open in the classic window (`showView(...)`).

Stages:
1. Done: window, native sky, sidebar, Collection (scoreboard, eras, song list with search, filters and wishlist, song card).
2. Done: Timeline, Stats (without Plex listening yet) and Credits, in `JuiceTracker/NativeScreens.swift`. The snapshot now
   sends the catalog's fixed details (dates, years, credits) only when they change; owned, wishlist and the queue go each time.
3. Done: File health and Duplicates, in `JuiceTracker/NativeTools.swift`. Fixes that touch files stay in the page's tested
   code (`trashExtraCopies(groups, confirmed)`, `runHealthCheck()`, `healthFix(op, path)`); the native screens ask for
   confirmation in their own dialogs and show the page's result (or its error message).
4. Done: Tag fixer, in `JuiceTracker/NativeFixer.swift`. Its settings stay in the page's own controls (`fixSet`,
   `fixGenre`), so both windows agree; writing runs the page's `writeSelectedTags(confirmed)` with its safety checks.
5. Done: Trivia, Export & backup, the setup screen, the sidebar player, Download all / Complete this era, and notes on
   song cards (`JuiceTracker/NativeExtras.swift`).
6. Done: the native window is the app's window. The page runs unseen inside it (`EngineHostView`, in "engine mode" so
   nothing animates) and moves into Window > Classic Window (⌘2) only while that's open.

Not done on purpose: the classic interface's code is still there. The page is the engine (its render functions also
compute state: the fixer plan, health results, duplicates), and it's the only version that runs in a browser.
Taking the classic screens out means first moving that state into plain functions; worth doing once the native app
has settled.
