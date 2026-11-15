# Handoff: work in progress

Started in a Claude chat session; continue in Claude Code on the Mac.

## Goal
Turn `web/juice-tracker.html` (single-file Juice WRLD collection tracker) into a native macOS app:
an editable Xcode project, a DMG, and this GitHub repo for history.

## Done
- `web/juice-tracker.html`: the tracker (bulk file links, save-to folder suggestions, M4A tag editing, manual matches). Still works on its own in Chrome/Edge.
- `JuiceTracker/JuiceTrackerApp.swift`: SwiftUI app, one window.
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
   nothing animates). The Classic window was removed in engine stage 2 (below).

Not done on purpose: the classic interface's code is still there. The page is the engine (its render functions also
compute state: the fixer plan, health results, duplicates), and it's the only version that runs in a browser.
Taking the classic screens out means first moving that state into plain functions; worth doing once the native app
has settled.

## Replacing the HTML engine with Swift (in progress)

The page (`web/juice-tracker.html`) still does the work behind the native window. It's being ported to Swift in
five stages, each shippable; the page stays in charge until the Swift side matches it.

1. **Data and matching (done).** `JuiceTracker/Engine.swift` ports the catalog fetch and cleaning, tag reading
   (ID3v1/v2.2–2.4, FLAC, MP4, Ogg/Opus), the folder scan with its tag cache, and matching, line for line.
   `scripts/test-engine.sh` (in CI) has the page's own code answer tricky inputs and tag files its writers make,
   then checks Swift gives the same answers. Window > Check Swift Engine… copies your saved data out of the web
   view into `~/Library/Application Support/JuiceTracker/<app id>/engine/` and compares Swift with the page on
   your real catalog and folder (read only; report in `check-report.json`).
2. **Native as the source of truth (done).** `JuiceTracker/EngineState.swift` owns the catalog (12-hour cache,
   refreshed automatically when stale; new and newly released songs tracked in `saved.json`), your wishlist and notes
   (`personal.json`), and builds everything the screens show (eras, categories, notices, "on this day", each song's
   credits and dates). The first launch copies these out of the web view. Swift hands the page its catalog (the
   `useCatalog` action, with a token the page echoes back as `cv`), so song numbers mean the same songs on both sides,
   and the wishlist and notes (`setPersonal`). The page's snapshot is now only what you own, the file count, the
   drive and the queue. The Classic window, the page zoom and Reload Page are gone, and the hidden page can no longer
   take the keyboard (`EngineWebView`).
3. **Actions that stand on their own (done).** `JuiceTracker/EngineActions.swift`: backup and restore (the wishlist
   and notes merge into Swift's, then the page merges the fields it still owns: trivia, hand matches, link and genre
   settings), the full catalog spreadsheet (your files come from the page's `ownedPaths`), and the collection card
   (SwiftUI, rendered to a 1200 × 630 PNG). Downloads, the queue, ambient music, snapshots and the drive status
   turned out to depend on the library (the save folder for a song comes from how your era folders are laid out,
   and a download is added to the library and auto-tagged), so they move with it in stage 4.
4. **The library and writing to files**, in steps:
   - 4a (done): `TagWriter` in `Engine.swift` ports the MP3 (ID3v2.3/2.4), FLAC and M4A writers and their safety
     checks. `scripts/test-engine.sh` runs the page's writers and Swift's on 24 inputs (new tags, retags, Unicode,
     64-bit offsets, moov before and after the audio, and every refusal) and requires the same bytes, the same
     safety-check result and the same error text. Not wired into the app yet.
   - 4b: the folder scan and matching (stage 1 code) become the source of truth; the page is handed the library
     (paths and tags, with `jwFileHandle` handles) instead of scanning, and tells Swift about files it adds or retags.
   - 4c: downloads and the queue, rescan, drive status, ambient music and snapshots.
   - 4d: the tag fixer, auto-tagging after downloads, duplicates and file health fixes, writing with `TagWriter`.
5. **Removal:** Plex, trivia, listening stats; then delete the page, the web view, the Classic window and `web/`.
