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

## Not done yet
1. `JuiceTracker.xcodeproj` (none written yet). Easiest: in Xcode, File > New > Project > macOS App (SwiftUI), name JuiceTracker,
   bundle id com.hb4delirious.JuiceTracker, macOS 12.0+, then replace the generated sources with the files above and add as resources:
   `JuiceTracker/bridge.js` and `web/juice-tracker.html` (reference, don't copy, so there's one source of truth).
   Settings: App Sandbox OFF (or add user-selected read/write + outgoing network), Signing "Sign to Run Locally".
   Share the scheme (Product > Scheme > Manage Schemes > Shared) so CI can build it.
2. `scripts/make-dmg.sh`: xcodebuild Release into build/, stage the .app + /Applications symlink, `hdiutil create -format UDZO`.
3. `.github/workflows/build.yml`: macos-14 runner, build + DMG, upload artifact; on `v*` tags, attach the DMG to a GitHub Release.
4. README.md and .gitignore (build/, DerivedData/, xcuserdata/, *.dmg, .DS_Store).
5. Test in the app: catalog loads from juicewrldapi.com (file:// origin + CORS), localStorage persists between launches,
   folder scan + tag writing through the bridge, exports save, target=_blank links open in the browser.
