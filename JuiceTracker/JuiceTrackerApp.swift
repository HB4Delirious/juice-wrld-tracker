import AppKit
import SwiftUI
import CoreSpotlight
import UserNotifications

@main
struct JuiceTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The main window is a plain AppKit window owned by AppDelegate (SwiftUI's window restoration could
    // relaunch the app with no window). SwiftUI provides the Settings window and the menus.
    var body: some Scene {
        Settings { SettingsView() }
            .commands {
                // One window is enough.
                CommandGroup(replacing: .newItem) {}
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { Task { await Updater.check(userInitiated: true) } }
                }
                CommandGroup(before: .windowList) {
                    Button("Juice Tracker") { AppDelegate.shared?.showMainWindow() }
                        .keyboardShortcut("1", modifiers: .command)
                    Button("Mini Player") { MiniPlayer.show() }
                        .keyboardShortcut("3", modifiers: .command)
                }
                CommandGroup(replacing: .help) {
                    Button("Open juicewrldapi.com") {
                        NSWorkspace.shared.open(URL(string: "https://juicewrldapi.com")!)
                    }
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    /// SwiftUI wraps the app delegate, so NSApp.delegate isn't this object; menus and windows use this instead.
    private(set) static weak var shared: AppDelegate?
    private var nativeWindow: NSWindow?
    private let menuBar = MenuBar()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        JTFonts.register()
        _ = NowPlaying.shared // follows the player for lyrics, artwork and the visualizer
        // macOS would otherwise quietly quit the app once its window is closed, defeating "Keep running".
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = false
        Task { await EngineState.shared.start() } // the catalog, your data and your library
        showMainWindow()
        UNUserNotificationCenter.current().delegate = self
        SongAlerts.registerActions()
        SongAlerts.start()
        Updater.startDailyChecks()
        menuBar.start()
    }

    /// The app's window: the SwiftUI interface.
    func showMainWindow() { showNativeWindow() }


    /// The SwiftUI interface. The page (catalog, scanning, matching, tag writing, downloads) runs unseen behind it.
    func showNativeWindow() {
        if nativeWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Juice Tracker"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.minSize = NSSize(width: 900, height: 600)
            w.isReleasedWhenClosed = false
            w.delegate = self
            let root = NSView()
            let hosting = NSHostingView(rootView: NativeRoot())
            hosting.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: root.leadingAnchor), hosting.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: root.topAnchor), hosting.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
            w.contentView = root
            if !w.setFrameUsingName("NativeWindow") { w.center() }
            w.setFrameAutosaveName("NativeWindow")
            nativeWindow = w
        }
        nativeWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// With "Keep running" on, closing the window only hides it, so the app (and its daily checks) keeps running;
    /// the Dock icon or an alert brings it back. Off: the window closes and the app quits.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard Pref.bool(Pref.keepRunning, default: false) else { return true }
        AmbientPlayer.shared.stop(); AmbientPlayer.shared.stopClip() // music shouldn't keep playing from a hidden window
        sender.orderOut(nil)
        return false
    }

    /// A song picked in Spotlight (⌘Space) opens its card.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
        SpotlightIndex.open(id)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Pref.bool(Pref.keepRunning, default: false)
    }

    // Clicking the Dock icon (or opening the app again) brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    // Clicking an alert brings the window back; a wishlist alert's Download button queues those songs.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        showMainWindow()
        if response.actionIdentifier == SongAlerts.downloadAction,
           let ids = response.notification.request.content.userInfo["songIds"] as? [String] {
            // Kept until the page takes them: if the alert started the app, the page isn't loaded yet.
            let pending = UserDefaults.standard.stringArray(forKey: "pendingDownloads") ?? []
            UserDefaults.standard.set(pending + ids, forKey: "pendingDownloads")
            Task { @MainActor in EngineDownloads.shared.takePending() } // if the library isn't up yet, it takes them when it is
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}


/// The classic page's fonts (Permanent Marker and Figtree), bundled in the asset catalog for the SwiftUI interface.
enum JTFonts {
    static func register() {
        for name in ["jt-font-marker", "jt-font-figtree"] {
            guard let data = NSDataAsset(name: name)?.data, let provider = CGDataProvider(data: data as CFData),
                  let font = CGFont(provider) else { continue }
            CTFontManagerRegisterGraphicsFont(font, nil)
        }
    }
}
