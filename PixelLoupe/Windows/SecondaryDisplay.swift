import AppKit
import Observation

/// A connected display, as the secondary window and Settings ▸ Displays see it.
struct DisplayInfo: Equatable, Identifiable {
    /// The display's UUID: stable across restarts and reconnects, unlike its display ID.
    var id: String
    var name: String
    /// Where the display sits in the arrangement (screen coordinates, origin bottom-left).
    var frame: CGRect

    init(id: String, name: String, frame: CGRect) {
        self.id = id
        self.name = name
        self.frame = frame
    }

    init?(screen: NSScreen) {
        guard let id = screen.displayUUID else { return nil }
        self.init(id: id, name: screen.localizedName, frame: screen.frame)
    }

    /// Every connected display, in `NSScreen.screens` order (the menu-bar display first).
    static func connected() -> [DisplayInfo] {
        NSScreen.screens.compactMap(DisplayInfo.init(screen:))
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    var displayUUID: String? {
        guard let displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func with(displayUUID: String) -> NSScreen? {
        screens.first { $0.displayUUID == displayUUID }
    }
}

/// What the secondary window shows (Lightroom's Secondary Window menu).
enum SecondaryView: String, CaseIterable {
    case grid
    /// The active photo, following the selection.
    case loupe
    /// The photo under the pointer in the main window's grid or filmstrip.
    case liveLoupe
    /// One photo, kept until another view is chosen.
    case lockedLoupe
    /// The Select and Candidate photos side by side.
    case compare
    /// Every selected photo side by side.
    case survey

    var title: String {
        switch self {
        case .grid: "Grid"
        case .loupe: "Loupe – Normal"
        case .liveLoupe: "Loupe – Live"
        case .lockedLoupe: "Loupe – Locked"
        case .compare: "Compare"
        case .survey: "Survey"
        }
    }
}

enum SecondaryDisplay {
    /// The display the secondary window goes on: the one chosen in Settings ▸ Displays while it's
    /// connected, otherwise the first that isn't showing the main window. Nil with only one display.
    static func target(among displays: [DisplayInfo], preferred: String?, mainWindowDisplay: String?) -> DisplayInfo? {
        guard displays.count > 1 else { return nil }
        if let preferred, let match = displays.first(where: { $0.id == preferred }) { return match }
        return displays.first { $0.id != mainWindowDisplay } ?? displays.first
    }

    /// Displays scaled into `bounds` for drawing the arrangement, keeping their proportions and
    /// relative positions (flipped so the top of the arrangement is at the top).
    static func layout(_ displays: [DisplayInfo], in bounds: CGSize, padding: CGFloat = 12) -> [String: CGRect] {
        guard !displays.isEmpty else { return [:] }
        let union = displays.dropFirst().reduce(displays[0].frame) { $0.union($1.frame) }
        let available = CGSize(width: max(bounds.width - padding * 2, 1), height: max(bounds.height - padding * 2, 1))
        let scale = min(available.width / union.width, available.height / union.height)
        let offset = CGPoint(x: (bounds.width - union.width * scale) / 2, y: (bounds.height - union.height * scale) / 2)
        var frames: [String: CGRect] = [:]
        for display in displays {
            let frame = display.frame
            frames[display.id] = CGRect(
                x: offset.x + (frame.minX - union.minX) * scale,
                y: offset.y + (union.maxY - frame.maxY) * scale,
                width: frame.width * scale,
                height: frame.height * scale
            )
        }
        return frames
    }
}

/// The secondary window's saved state: the display chosen in Settings ▸ Displays, and whether the
/// window was showing, full screen, and in which view, so it comes back when a catalog opens.
@Observable
final class SecondaryDisplaySettings {
    static let shared = SecondaryDisplaySettings(defaults: Defaults.store)
    static let didChangeNotification = Notification.Name("SecondaryDisplaySettingsDidChange")

    private static let displayKey = "SecondaryDisplay"
    private static let shownKey = "SecondaryWindowShown"
    private static let fullScreenKey = "SecondaryWindowFullScreen"
    private static let viewKey = "SecondaryWindowView"
    static let thumbnailSizeKey = "SecondaryThumbnailSize"

    @ObservationIgnored private let defaults: UserDefaults

    /// The display picked in Settings ▸ Displays (its UUID); nil until one is picked.
    var preferredDisplayID: String? {
        didSet {
            guard preferredDisplayID != oldValue else { return }
            defaults.set(preferredDisplayID, forKey: Self.displayKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    var isShown: Bool {
        didSet { defaults.set(isShown, forKey: Self.shownKey) }
    }

    var isFullScreen: Bool {
        didSet { defaults.set(isFullScreen, forKey: Self.fullScreenKey) }
    }

    var view: SecondaryView {
        didSet { defaults.set(view.rawValue, forKey: Self.viewKey) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        preferredDisplayID = defaults.string(forKey: Self.displayKey)
        isShown = defaults.bool(forKey: Self.shownKey)
        isFullScreen = defaults.bool(forKey: Self.fullScreenKey)
        view = defaults.string(forKey: Self.viewKey).flatMap(SecondaryView.init(rawValue:)) ?? .grid
    }
}
