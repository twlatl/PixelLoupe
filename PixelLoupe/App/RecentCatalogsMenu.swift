import AppKit

/// Fills an Open Recent menu (File ▸ Open Recent, the welcome window's Open Recent button) from
/// ``RecentCatalogs`` each time it opens: one item per catalog with its thumbnail, name, and folder
/// and when it was last opened, then Clear Menu. Catalogs that can't be reached are listed disabled.
final class RecentCatalogsMenu: NSObject, NSMenuDelegate {
    /// File ▸ Open Recent.
    static let fileMenu = RecentCatalogsMenu(header: nil, keepingFirst: 0)

    private let recents: RecentCatalogs
    /// A "Recent Catalogs" section header above the catalogs (the welcome window's menu has one).
    private let header: String?
    /// Items at the top left alone, such as a pull-down button's title item.
    private let keptItemCount: Int

    static let imageSize = RecentCatalogPreviews.size

    init(recents: RecentCatalogs = .shared, header: String?, keepingFirst keptItemCount: Int) {
        self.recents = recents
        self.header = header
        self.keptItemCount = keptItemCount
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        fill(menu)
    }

    func fill(_ menu: NSMenu) {
        menu.autoenablesItems = false
        while menu.numberOfItems > keptItemCount {
            menu.removeItem(at: menu.numberOfItems - 1)
        }
        let entries = recents.entries
        if let header, !entries.isEmpty {
            menu.addItem(.sectionHeader(title: header))
        }
        for entry in entries {
            menu.addItem(item(for: entry))
        }
        if !entries.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(PixelLoupeActions.clearRecentCatalogs(_:)), keyEquivalent: "")
        clear.isEnabled = !entries.isEmpty
        menu.addItem(clear)
    }

    func item(for entry: RecentCatalogs.Entry) -> NSMenuItem {
        let item = NSMenuItem(title: entry.name, action: #selector(PixelLoupeActions.openRecentCatalog(_:)), keyEquivalent: "")
        item.representedObject = entry.url
        item.subtitle = "\(entry.displayFolder) · \(RecentCatalogs.relativeDate(entry.openedAt))"
        item.isEnabled = entry.isAvailable
        item.toolTip = entry.path
        item.image = RecentCatalogPreviews.image(for: entry) { [weak item] preview in item?.image = preview }
        return item
    }
}

/// Small rounded previews of recent catalogs (their last selected photo), loaded off the main thread
/// and kept for the session, for the Open Recent menus and the welcome window's list.
enum RecentCatalogPreviews {
    static let size = NSSize(width: 32, height: 32)
    /// Previews already loaded, by catalog path, so reopening a menu doesn't flicker.
    private static var previews: [String: NSImage] = [:]

    /// The preview if it's loaded, otherwise a placeholder; `loaded` is called with the preview once
    /// it's read (not for unreachable catalogs, or ones without thumbnails).
    static func image(for entry: RecentCatalogs.Entry, loaded: @escaping (NSImage) -> Void) -> NSImage {
        if let preview = previews[entry.path] { return preview }
        if entry.isAvailable {
            Task {
                guard let image = await RecentCatalogs.previewImage(forCatalogAt: entry.url) else { return }
                let preview = roundedPreview(image)
                previews[entry.path] = preview
                loaded(preview)
            }
        }
        return placeholder
    }

    static let placeholder: NSImage = {
        let symbol = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: "Catalog") ?? NSImage()
        let configured = symbol.withSymbolConfiguration(.init(pointSize: 18, weight: .regular)) ?? symbol
        return NSImage(size: size, flipped: false) { rect in
            let size = configured.size
            configured.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                       width: size.width, height: size.height))
            return true
        }
    }()

    /// The thumbnail cropped to a square with rounded corners, as the mockup shows.
    private static func roundedPreview(_ image: CGImage) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).addClip()
            let side = CGFloat(min(image.width, image.height))
            let crop = CGRect(x: (CGFloat(image.width) - side) / 2, y: (CGFloat(image.height) - side) / 2, width: side, height: side)
            if let square = image.cropping(to: crop) {
                NSGraphicsContext.current?.cgContext.draw(square, in: rect)
            }
            return true
        }
    }
}

/// Something that asks to open a recent catalog (an Open Recent menu item, the welcome window's list).
@objc protocol RecentCatalogSender {
    var recentCatalogURL: URL? { get }
}

extension NSMenuItem: RecentCatalogSender {
    var recentCatalogURL: URL? { representedObject as? URL }
}
