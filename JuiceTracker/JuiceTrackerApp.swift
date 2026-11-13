import AppKit
import SwiftUI
import UserNotifications

@main
struct JuiceTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Juice WRLD Collection Tracker") {
            TrackerView()
                .ignoresSafeArea() // the page runs under the hidden title bar
                .frame(minWidth: 820, minHeight: 600)
        }
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
            CommandGroup(replacing: .help) {
                Button("Open juicewrldapi.com") {
                    NSWorkspace.shared.open(URL(string: "https://juicewrldapi.com")!)
                }
            }
        }
        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        SongAlerts.start()
        Updater.startDailyChecks()
        // Music shouldn't keep playing from an app with no window.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            if (note.object as? NSWindow)?.title == "Juice WRLD Collection Tracker" {
                WebViewStore.shared.stopAmbient()
            }
        }
    }

    /// With "Keep running" on, closing the window leaves the app (and its daily checks) running; the Dock icon reopens it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Pref.bool(Pref.keepRunning, default: false)
    }

    // Clicking an alert brings the window back, reopening it if it was closed.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.windows.contains(where: { $0.isVisible && $0.title == "Juice WRLD Collection Tracker" }) {
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

/// Hosts the shared web view inside the SwiftUI window.
struct TrackerView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebViewContainer {
        WKWebViewContainer(webView: WebViewStore.shared.webView)
    }
    func updateNSView(_ nsView: WKWebViewContainer, context: Context) {}
}
