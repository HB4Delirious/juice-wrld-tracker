import AppKit
import SwiftUI

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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Hosts the shared web view inside the SwiftUI window.
struct TrackerView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebViewContainer {
        WKWebViewContainer(webView: WebViewStore.shared.webView)
    }
    func updateNSView(_ nsView: WKWebViewContainer, context: Context) {}
}
