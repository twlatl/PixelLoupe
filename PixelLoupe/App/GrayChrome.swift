import AppKit

/// Settings ▸ Appearance ▸ Gray: Aperture's look, between Light and Dark. The app stays in Light
/// Mode, so controls and text are the system's own, and each window's chrome is painted Aperture's
/// mid-gray instead of Light Mode's near-white. The matte behind photos turns black (see
/// ``AppSettings/grayMatte``).
@MainActor
enum GrayChrome {
    /// Aperture 3's panel gray.
    static let color = NSColor(srgbRed: 200 / 255, green: 200 / 255, blue: 200 / 255, alpha: 1)

    static var isOn: Bool { AppSettings.shared.appearance == .gray }

    /// Windows painted gray, to put back when Gray is turned off. Windows with chrome of their own (the
    /// black full-screen viewer and slideshow, the welcome window's transparent titlebar) are left alone.
    private static let painted = NSHashTable<NSWindow>.weakObjects()
    private static let leftAlone = NSHashTable<NSWindow>.weakObjects()

    /// Paints `window`'s chrome for the current setting.
    static func apply(to window: NSWindow) {
        if isOn {
            if !painted.contains(window) {
                guard !leftAlone.contains(window) else { return }
                guard window.backgroundColor == .windowBackgroundColor, !window.titlebarAppearsTransparent else {
                    leftAlone.add(window)
                    return
                }
                painted.add(window)
                window.backgroundColor = color
                // The toolbar shows the window's gray rather than Light Mode's white titlebar.
                window.titlebarAppearsTransparent = true
            }
            if let frame = window.contentView?.superview { fillSidebars(in: frame, on: true) }
        } else if painted.contains(window) {
            painted.remove(window)
            window.backgroundColor = .windowBackgroundColor
            window.titlebarAppearsTransparent = false
            if let frame = window.contentView?.superview { fillSidebars(in: frame, on: false) }
        }
    }

    /// Split views' sidebars sit in Liquid Glass, which can't be tinted darker than Light Mode's; Gray
    /// fills the glass's content instead.
    private static func fillSidebars(in view: NSView, on: Bool) {
        if let split = view as? NSSplitView {
            fillPanes(of: split, on: on)
        }
        for subview in view.subviews { fillSidebars(in: subview, on: on) }
    }

    private static func fillPanes(of split: NSSplitView, on: Bool) {
        for pane in split.subviews {
            guard let glass = pane.subviews.first as? NSGlassEffectView, let content = glass.contentView else { continue }
            let fill = on ? color.cgColor : nil
            if content.layer?.backgroundColor != fill {
                content.wantsLayer = true
                content.layer?.backgroundColor = fill
            }
        }
    }

    /// Applies the current setting to every window (after it changes).
    static func applyToAllWindows() {
        for window in NSApp.windows { apply(to: window) }
    }

    /// Paints windows as they first update (whether or not they become key, as Settings doesn't when
    /// it opens behind another app), sidebars again as windows become key, and sidebars as they're
    /// shown again. Call once at launch.
    static func startFollowingWindows() {
        // Windows update on every pass of the event loop: only one not painted yet is looked at.
        NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                if let window, isOn, !painted.contains(window), !leftAlone.contains(window) { apply(to: window) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                if let window, isOn { apply(to: window) }
            }
        }
        // Expanding a collapsed sidebar can bring in its glass.
        NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main
        ) { notification in
            let split = notification.object as? NSSplitView
            MainActor.assumeIsolated {
                if let split, isOn, let window = split.window, painted.contains(window) { fillPanes(of: split, on: true) }
            }
        }
    }
}
