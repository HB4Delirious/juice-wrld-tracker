import AppKit
import SwiftUI
import UserNotifications

@main
struct JuiceTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The main window is a plain AppKit window owned by AppDelegate (SwiftUI's window restoration could
    // relaunch the app with no window). SwiftUI provides the Settings window and the menus.
    var body: some Scene {
        Settings { SettingsView() }
            .commands {
                // One window is enough: the page keeps its own state.
                CommandGroup(replacing: .newItem) {}
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { Task { await Updater.check(userInitiated: true) } }
                }
                CommandGroup(after: .toolbar) {
                    Button("Reload Page") { WebViewStore.shared.reload() }
                        .keyboardShortcut("r", modifiers: .command)
                    Divider()
                    Button("Actual Size") { WebViewStore.shared.setZoom(1) }
                        .keyboardShortcut("0", modifiers: .command)
                    Button("Zoom In") { WebViewStore.shared.zoom(by: 0.1) }
                        .keyboardShortcut("+", modifiers: .command)
                    Button("Zoom Out") { WebViewStore.shared.zoom(by: -0.1) }
                        .keyboardShortcut("-", modifiers: .command)
                }
                CommandGroup(before: .windowList) {
                    Button("Juice Tracker") { AppDelegate.shared?.showMainWindow() }
                        .keyboardShortcut("1", modifiers: .command)
                    Button("Native Preview (Beta)") { AppDelegate.shared?.showNativeWindow() }
                        .keyboardShortcut("2", modifiers: .command)
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
    private var window: NSWindow?
    private var nativeWindow: NSWindow?
    private let menuBar = MenuBar()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        // macOS would otherwise quietly quit the app once its window is closed, defeating "Keep running".
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = false
        showMainWindow()
        UNUserNotificationCenter.current().delegate = self
        SongAlerts.registerActions()
        SongAlerts.start()
        Updater.startDailyChecks()
        menuBar.start()
    }

    /// Shows the one main window, creating it the first time. Closing only hides it, so reopening keeps the page as it was.
    func showMainWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Juice WRLD Collection Tracker"
            w.minSize = NSSize(width: 820, height: 600)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = WKWebViewContainer(webView: WebViewStore.shared.webView)
            if !w.setFrameUsingName("MainWindow") { w.center() }
            w.setFrameAutosaveName("MainWindow") // remembers size and position
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The SwiftUI interface (stage 1 of moving off HTML). The classic page keeps running as its engine.
    func showNativeWindow() {
        if nativeWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Juice Tracker (Native Preview)"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.minSize = NSSize(width: 900, height: 600)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: NativeRoot())
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
        // The classic window is the native one's engine: while the native window is open, closing it only hides it.
        if sender === window, nativeWindow?.isVisible == true { sender.orderOut(nil); return false }
        guard Pref.bool(Pref.keepRunning, default: false) else { return true }
        WebViewStore.shared.stopAmbient() // music shouldn't keep playing from a hidden window
        sender.orderOut(nil)
        return false
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
            WebViewStore.shared.webView.evaluateJavaScript("window.jwTakePendingDownloads && window.jwTakePendingDownloads()")
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

