import AppKit

/// The butterfly in the menu bar: what's playing, play/pause, next, volume and the latest new songs,
/// without opening the window. Shown unless turned off in Settings.
final class MenuBar: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let volume = NSSlider(value: 6, minValue: 0, maxValue: 100, target: nil, action: nil)

    func start() {
        volume.target = self
        volume.action = #selector(setVolume)
        volume.isContinuous = true
        update()
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(playerChanged), name: AmbientPlayer.changed, object: nil)
    }

    /// Adds or removes the icon to follow the Settings switch.
    @objc private func update() {
        let wanted = Pref.bool(Pref.menuBar, default: true)
        if wanted, item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            it.button?.image = Self.butterfly
            it.button?.toolTip = "Juice Tracker"
            let menu = NSMenu()
            menu.delegate = self
            it.menu = menu
            item = it
        } else if !wanted, let it = item {
            NSStatusBar.system.removeStatusItem(it)
            item = nil
        }
    }

    @objc private func playerChanged() {
        item?.button?.toolTip = AmbientPlayer.shared.title.map { "Juice Tracker: \($0)" } ?? "Juice Tracker"
    }

    // Built fresh each time it opens, so it always shows the current song and the latest check.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let p = AmbientPlayer.shared
        let now = NSMenuItem(title: p.title.map { "♪ \($0)" } ?? (p.hasSongs ? "Not playing" : "Open your music folder in Juice Tracker to play songs"),
                             action: nil, keyEquivalent: "")
        now.isEnabled = false
        menu.addItem(now)
        if p.hasSongs {
            menu.addItem(action(p.isPlaying ? "Pause" : "Play", #selector(togglePause)))
            menu.addItem(action("Next Song", #selector(skip)))
            volume.floatValue = p.volume * 100
            volume.frame = NSRect(x: 18, y: 4, width: 190, height: 22)
            let row = NSView(frame: NSRect(x: 0, y: 0, width: 224, height: 30))
            row.addSubview(volume)
            let slider = NSMenuItem()
            slider.view = row
            menu.addItem(slider)
        }
        menu.addItem(.separator())
        let defaults = UserDefaults.standard
        if let names = defaults.stringArray(forKey: "alertsLastNew"), !names.isEmpty,
           let when = defaults.object(forKey: "alertsLastNewDate") as? Date {
            let day = Calendar.current.isDateInToday(when) ? "today" : RelativeDateTimeFormatter().localizedString(for: when, relativeTo: Date())
            let head = NSMenuItem(title: "New songs \(day):", action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            for name in names.prefix(5) { menu.addItem(action("   \(name)", #selector(open))) }
            if names.count > 5 { menu.addItem(action("   and \(names.count - 5) more", #selector(open))) }
        } else {
            let none = NSMenuItem(title: defaults.object(forKey: "alertsLastCheck") == nil ? "No new-song check yet" : "No new songs since the last check",
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        menu.addItem(action("Open Juice Tracker", #selector(open)))
        menu.addItem(action("Settings…", #selector(settings)))
        menu.addItem(action("Quit Juice Tracker", #selector(NSApplication.terminate(_:)), target: NSApp))
    }

    private func action(_ title: String, _ selector: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        it.target = target ?? self
        return it
    }

    @objc private func togglePause() { AmbientPlayer.shared.togglePause() }
    @objc private func skip() { AmbientPlayer.shared.skip() }
    @objc private func setVolume() { AmbientPlayer.shared.volume = volume.floatValue / 100 }
    @objc private func open() { AppDelegate.shared?.showMainWindow() }
    @objc private func settings() {
        NSApp.activate(ignoringOtherApps: true)
        // Press the app menu's own "Settings…" (⌘,): SwiftUI's Settings window has no public way to open it.
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) else { return }
        appMenu.performActionForItem(at: index)
    }

    /// A small butterfly drawn as a template image, so it follows the menu bar's light and dark look.
    private static let butterfly: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            for side: CGFloat in [-1, 1] {
                let t = NSAffineTransform()
                t.translateX(by: 9, yBy: 0)
                t.scaleX(by: side, yBy: 1)
                let upper = NSBezierPath()
                upper.move(to: NSPoint(x: 0.6, y: 8))
                upper.curve(to: NSPoint(x: 7.5, y: 2.5), controlPoint1: NSPoint(x: 1.5, y: 3.5), controlPoint2: NSPoint(x: 5, y: 1))
                upper.curve(to: NSPoint(x: 0.6, y: 9.5), controlPoint1: NSPoint(x: 9.5, y: 5), controlPoint2: NSPoint(x: 6, y: 9))
                let lower = NSBezierPath()
                lower.move(to: NSPoint(x: 0.6, y: 10))
                lower.curve(to: NSPoint(x: 5.5, y: 15.5), controlPoint1: NSPoint(x: 5, y: 9.5), controlPoint2: NSPoint(x: 8, y: 13))
                lower.curve(to: NSPoint(x: 0.6, y: 11.5), controlPoint1: NSPoint(x: 3, y: 17), controlPoint2: NSPoint(x: 1, y: 14))
                for wing in [upper, lower] { wing.transform(using: t as AffineTransform); wing.fill() }
            }
            let body = NSBezierPath(roundedRect: NSRect(x: 8.2, y: 5.5, width: 1.6, height: 9), xRadius: 0.8, yRadius: 0.8)
            body.fill()
            return true
        }
        img.isTemplate = true
        return img
    }()
}
