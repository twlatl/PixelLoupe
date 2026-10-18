import AppKit
import ImageIO

/// The catalogs opened most recently, newest first, shown in File ▸ Open Recent and the welcome
/// window's Open Recent menu. Kept in the app's preferences rather than `NSDocumentController`'s
/// recent documents so the list is ours to cap and test (unit tests get a throwaway domain).
final class RecentCatalogs {
    struct Entry: Codable, Equatable {
        var path: String
        /// The catalog's name (`CatalogInfo.name`), saved so building the menu doesn't read the package.
        var name: String
        var openedAt: Date

        var url: URL { URL(filePath: path, directoryHint: .isDirectory) }
    }

    static let shared = RecentCatalogs(defaults: Defaults.store)
    /// Posted (by the list) when entries are added, removed or cleared.
    static let didChange = Notification.Name("RecentCatalogsDidChange")
    static let maximumCount = 5
    static let defaultsKey = "RecentCatalogs"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private(set) var entries: [Entry] {
        get {
            guard let data = defaults.data(forKey: Self.defaultsKey),
                  let entries = try? PropertyListDecoder().decode([Entry].self, from: data) else { return [] }
            return entries
        }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.defaultsKey)
            } else if let data = try? PropertyListEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.defaultsKey)
            }
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// Moves the catalog to the top of the list (adding it if needed), dropping the oldest past five.
    func noteOpened(_ url: URL, name: String, at date: Date = .now) {
        let path = Self.path(of: url)
        var entries = entries.filter { $0.path != path }
        entries.insert(Entry(path: path, name: name, openedAt: date), at: 0)
        self.entries = Array(entries.prefix(Self.maximumCount))
    }

    func remove(_ url: URL) {
        let path = Self.path(of: url)
        entries = entries.filter { $0.path != path }
    }

    func clear() {
        entries = []
    }

    private static func path(of url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
    }
}

// MARK: - Presentation

extension RecentCatalogs.Entry {
    /// The folder holding the catalog, with the home folder shortened to `~` ("~/Pictures/PixelLoupe").
    var displayFolder: String {
        let folder = url.deletingLastPathComponent().path(percentEncoded: false).trimmingSuffix("/")
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false).trimmingSuffix("/")
        if folder == home { return "~" }
        if folder.hasPrefix(home + "/") { return "~" + folder.dropFirst(home.count) }
        return folder
    }

    /// Whether the catalog can be opened now; false when its drive isn't mounted or it was deleted.
    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

extension RecentCatalogs {
    /// When a catalog was last opened, as the mockup words it: Today, Yesterday, 3 days ago, Last
    /// week, then a short date (Sep 28; with the year when it isn't this year).
    static func relativeDate(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case 2...6: return "\(days) days ago"
        case 7...13: return "Last week"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: .current, calendar: calendar, timeZone: calendar.timeZone)
                .month(.abbreviated).day()
            if !sameYear { style = style.year() }
            return date.formatted(style)
        }
    }

    /// A small preview of a catalog: the cached thumbnail of the photo selected when it was last
    /// closed, or else any of its thumbnails. Nil when it has none (or can't be read).
    @concurrent nonisolated static func previewImage(forCatalogAt package: URL, maxPixelSize: Int = 96) async -> CGImage? {
        let thumbnails = CatalogPackage.thumbnailsURL(in: package)
        var candidates = CatalogViewState.load(from: package).selectedPhotos.prefix(1)
            .map { ThumbnailStore.url(for: $0, in: thumbnails) }
        if let any = try? FileManager.default.contentsOfDirectory(at: thumbnails, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension.lowercased() == "jpg" }) {
            candidates.append(any)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        for url in candidates {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return image
            }
        }
        return nil
    }
}
