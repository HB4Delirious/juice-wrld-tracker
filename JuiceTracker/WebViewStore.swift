import AppKit
import WebKit

/// Height of the invisible title-bar strip; the page leaves the same space via --top-inset in juice-tracker.html.
let titleBarInset: CGFloat = 28

/// Fills the window with the web view, running it under the (hidden) title bar.
final class WKWebViewContainer: NSView {
    init(webView: WKWebView) {
        super.init(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        let strip = TitleBarDragView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip) // above the web view, which would otherwise swallow the clicks
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.heightAnchor.constraint(equalToConstant: titleBarInset),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// No title bar: the page's night sky runs to the top edge and the window buttons float over the sidebar.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 7 / 255, green: 4 / 255, blue: 15 / 255, alpha: 1) // #07040f, top of the page's sky
    }
}

/// Invisible strip where the title bar was: drag to move the window, double-click to zoom.
final class TitleBarDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            // Follow System Settings > Desktop & Dock > "Double-click a window's title bar to".
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window?.performMiniaturize(nil) } else if action != "None" { window?.performZoom(nil) }
        } else {
            window?.performDrag(with: event)
        }
    }
}

/// Owns the WKWebView that runs web/juice-tracker.html, plus everything a browser would normally do for it:
/// opening links in the default browser, save dialogs for exports, alert/confirm panels, and file pickers.
final class WebViewStore: NSObject {
    static let shared = WebViewStore()

    let webView: WKWebView
    private let bridge = NativeBridge()

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // keeps localStorage (wishlist, notes, cached catalog) between launches

        let content = WKUserContentController()
        if let url = Bundle.main.url(forResource: "bridge", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            content.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        config.userContentController = content

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        content.addScriptMessageHandler(bridge, contentWorld: .page, name: "jwNative")
        content.add(NativeStore.shared, contentWorld: .page, name: "jwState") // snapshots for the native window
        bridge.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        if #available(macOS 13.3, *) { webView.isInspectable = true } // Safari > Develop menu can inspect the page
        load()
    }

    func load() {
        guard let url = Bundle.main.url(forResource: "juice-tracker", withExtension: "html") else {
            webView.loadHTMLString("<p style='font:15px system-ui;padding:40px'>juice-tracker.html is missing from the app bundle.</p>", baseURL: nil)
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func reload() { webView.reload() }
    func stopAmbient() { bridge.stopAmbient() }
    func setZoom(_ value: CGFloat) { webView.pageZoom = value }
    func zoom(by delta: CGFloat) { webView.pageZoom = min(max(webView.pageZoom + delta, 0.5), 2.5) }

    private static func isWeb(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "mailto"
    }
}

// MARK: - Navigation and downloads

extension WebViewStore: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        // Links to websites open in the user's browser; the app window only ever shows the tracker.
        if Self.isWeb(navigationAction.request.url), navigationAction.targetFrame?.isMainFrame ?? true {
            if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
}

extension WebViewStore: WKDownloadDelegate {
    /// CSV exports, backups and link pages: ask where to save, defaulting to Downloads.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.begin { result in
            guard result == .OK, let url = panel.url else { completionHandler(nil); return }
            // The save panel already asked about replacing; WKDownload refuses to overwrite on its own.
            try? FileManager.default.removeItem(at: url)
            completionHandler(url)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}

// MARK: - Windows, panels and pickers

extension WebViewStore: WKUIDelegate {
    /// target="_blank" links (song pages, site files, Apple Music, Spotify) open in the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, Self.isWeb(url) { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    /// <input type="file"> (saved catalog files, backup restore, and the read-only folder picker).
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !parameters.allowsDirectories
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.begin { result in completionHandler(result == .OK ? panel.urls : nil) }
    }
}
