import AppKit

/// The Secondary Window menu (Lightroom's): in the catalog window's display toolbar button and in
/// Window ▸ Secondary Display. The catalog window validates the items (checkmarks, and disabling the
/// single-key shortcuts while typing) and handles them.
enum SecondaryDisplayMenu {
    static func make(title: String = "Secondary Display", header: Bool) -> NSMenu {
        let menu = NSMenu(title: title)
        if header { menu.addItem(.sectionHeader(title: "Secondary Window:")) }
        let f11 = String(Character(UnicodeScalar(NSF11FunctionKey)!))
        menu.addItem(item("Show", #selector(PixelLoupeActions.toggleSecondaryWindow(_:)), f11, [.command]))
        menu.addItem(item("Full Screen", #selector(PixelLoupeActions.toggleSecondaryFullScreen(_:)), f11, [.command, .shift]))
        menu.addItem(item("Show Second Monitor Preview", #selector(PixelLoupeActions.toggleSecondaryPreview(_:)), "", []))
        menu.addItem(.separator())
        // ⇧G, ⇧E, ⇧C and ⇧N, as in Lightroom: handled as keys by the catalog window, like G, E, C and N.
        for view in SecondaryView.allCases {
            let item = item(view.title, #selector(PixelLoupeActions.showSecondaryView(_:)), view.key.character, view.key.modifiers)
            item.representedObject = view.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        // ⌥⇧⌘Return, as in Lightroom: plays on the secondary display while you keep working.
        menu.addItem(item("Slideshow", #selector(PixelLoupeActions.toggleSecondarySlideshow(_:)), "\r", [.option, .shift, .command]))
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

extension SecondaryView {
    /// The view's shortcut (Lightroom's), for the menus.
    var key: (character: String, modifiers: NSEvent.ModifierFlags) {
        switch self {
        case .grid: ("g", [.shift])
        case .loupe: ("e", [.shift])
        case .liveLoupe: ("", [])
        case .lockedLoupe: ("\r", [.shift, .command])
        case .compare: ("c", [.shift])
        case .survey: ("n", [.shift])
        }
    }
}
