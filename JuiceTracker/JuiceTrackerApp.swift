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
                    Button("Classic Window") { AppDelegate.shared?.showClassicWindow() }
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
        JTFonts.register()
        // macOS would otherwise quietly quit the app once its window is closed, defeating "Keep running".
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = false
        _ = WebViewStore.shared // start the engine (the page) right away
        showMainWindow()
        UNUserNotificationCenter.current().delegate = self
        SongAlerts.registerActions()
        SongAlerts.start()
        Updater.startDailyChecks()
        menuBar.start()
    }

    /// The app's window: the SwiftUI interface.
    func showMainWindow() { showNativeWindow() }

    var classicVisible: Bool { window?.isVisible == true }

    /// The classic (HTML) interface, kept for anything the native one doesn't do yet and for comparison. The page moves
    /// in here from the native window's engine host while this window is open.
    func showClassicWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Juice Tracker (Classic)"
            w.minSize = NSSize(width: 820, height: 600)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = WKWebViewContainer(webView: WebViewStore.shared.webView)
            if !w.setFrameUsingName("MainWindow") { w.center() }
            w.setFrameAutosaveName("MainWindow") // remembers size and position
            window = w
        }
        (window?.contentView as? WKWebViewContainer)?.adopt(WebViewStore.shared.webView)
        WebViewStore.shared.webView.evaluateJavaScript("window.jwEngineMode && window.jwEngineMode(false)")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The page goes back to running unseen inside the native window.
    private func parkEngine() {
        engineHost.adopt(WebViewStore.shared.webView)
        WebViewStore.shared.webView.evaluateJavaScript("window.jwEngineMode && window.jwEngineMode(true)")
    }

    private let engineHost = EngineHostView()

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
            engineHost.frame = NSRect(x: 0, y: 0, width: 4, height: 4)
            root.addSubview(engineHost) // first, so the interface covers it
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
        if !classicVisible { parkEngine() }
        nativeWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// With "Keep running" on, closing the window only hides it, so the app (and its daily checks) keeps running;
    /// the Dock icon or an alert brings it back. Off: the window closes and the app quits.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The classic window only shows the engine: closing it hides it and the page goes back behind the native window.
        if sender === window {
            sender.orderOut(nil)
            parkEngine()
            if nativeWindow?.isVisible != true, !Pref.bool(Pref.keepRunning, default: false) { NSApp.terminate(nil) }
            return false
        }
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
