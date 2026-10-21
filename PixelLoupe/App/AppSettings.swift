import AppKit
import Observation

/// User preferences shown in Settings. Changes are saved immediately and broadcast with
/// `didChangeNotification` so AppKit views can refresh.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    static let didChangeNotification = Notification.Name("AppSettingsDidChange")

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: Self { self }

        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    private static let appearanceKey = "Appearance"
    nonisolated private static let matteKey = "MatteColor"
    nonisolated private static let separateJPEGsKey = "TreatJPEGsAsSeparate"
    private static let monochromeKey = "MonochromeMode"
    private static let confirmQuitKey = "ConfirmQuit"
    private static let importOnCardKey = "OpenImportOnCardInsert"
    /// The system's per-app accent override; -1 is Graphite. macOS reads it when the app launches.
    private static let systemAccentKey = "AppleAccentColor"

    var appearance: Appearance {
        didSet {
            Defaults.store.set(appearance.rawValue, forKey: Self.appearanceKey)
            applyAppearance()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// The theme's matte when `matte` is `nil`: 10% in Light Mode, 85% in Dark Mode.
    nonisolated static let lightMatte = 0.10
    nonisolated static let darkMatte = 0.85

    nonisolated static func themeMatte(for appearance: NSAppearance) -> Double {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkMatte : lightMatte
    }

    /// Matte behind photos: 0 is white, 1 is black. `nil` follows the light/dark theme.
    var matte: Double? {
        didSet {
            if let matte {
                Defaults.store.set(matte.clamped(to: 0...1), forKey: Self.matteKey)
            } else {
                Defaults.store.removeObject(forKey: Self.matteKey)
            }
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// Settings ▸ Appearance ▸ Monochrome Mode: sliders, buttons and icons use dark gray (Dark Mode)
    /// or black (Light Mode) instead of the accent color. Off by default. See ``Accent``.
    var isMonochrome: Bool {
        didSet {
            guard isMonochrome != oldValue else { return }
            Defaults.store.set(isMonochrome, forKey: Self.monochromeKey)
            Self.setGraphiteAccent(isMonochrome)
            Accent.applyToAllWindows()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// Checkboxes, switches and focus rings follow the app's system accent, which can only be set
    /// before launch: Graphite while Monochrome Mode is on. Only in the app's real preferences, never
    /// while tests run (they use a throwaway domain).
    private static func setGraphiteAccent(_ on: Bool) {
        guard Defaults.store === UserDefaults.standard else { return }
        if on {
            UserDefaults.standard.set(-1, forKey: systemAccentKey)
        } else {
            UserDefaults.standard.removeObject(forKey: systemAccentKey)
        }
    }

    /// Settings ▸ Import ▸ Treat JPEG files next to raw files as separate photos. Off by default, as in
    /// Lightroom: the JPEG is the raw photo's sidecar. Readable from any thread.
    nonisolated static var treatsJPEGsAsSeparate: Bool {
        get { Defaults.store.bool(forKey: separateJPEGsKey) }
        set { Defaults.store.set(newValue, forKey: separateJPEGsKey) }
    }

    /// The setting for Settings ▸ Import's toggle. Stored (not read through to the defaults) so SwiftUI
    /// sees it change; the toggle couldn't be turned off when it wasn't.
    var treatJPEGsAsSeparate: Bool {
        didSet {
            guard treatJPEGsAsSeparate != oldValue else { return }
            Self.treatsJPEGsAsSeparate = treatJPEGsAsSeparate
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// Settings ▸ General ▸ Confirm when quitting PixelLoupe. On by default.
    var confirmsQuit: Bool {
        didSet { Defaults.store.set(confirmsQuit, forKey: Self.confirmQuitKey) }
    }

    /// Settings ▸ Import ▸ Open the import window when a memory card is inserted. Off by default.
    var opensImportOnCardInsert: Bool {
        didSet { Defaults.store.set(opensImportOnCardInsert, forKey: Self.importOnCardKey) }
    }

    private init() {
        confirmsQuit = Defaults.store.object(forKey: Self.confirmQuitKey) as? Bool ?? true
        treatJPEGsAsSeparate = Self.treatsJPEGsAsSeparate
        opensImportOnCardInsert = Defaults.store.bool(forKey: Self.importOnCardKey)
        appearance = Defaults.store.string(forKey: Self.appearanceKey).flatMap(Appearance.init) ?? .system
        matte = Self.storedMatte()
        isMonochrome = Defaults.store.bool(forKey: Self.monochromeKey)
    }

    /// Readable from any thread, for dynamic colors resolved during drawing.
    nonisolated static func storedMatte() -> Double? {
        Defaults.store.object(forKey: matteKey) as? Double
    }

    /// Whether the app last looked dark, to tell a light/dark switch from other appearance changes.
    private var isDark: Bool?
    private var appearanceObservation: NSKeyValueObservation?

    /// Puts Matte Color back to the theme's each time the app switches between Light and Dark,
    /// whether from the Appearance setting or from macOS.
    func startFollowingAppearance() {
        isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] app, _ in
            MainActor.assumeIsolated { self?.effectiveAppearanceDidChange(app.effectiveAppearance) }
        }
    }

    func effectiveAppearanceDidChange(_ appearance: NSAppearance) {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        defer { isDark = dark }
        guard let isDark, isDark != dark, matte != nil else { return }
        matte = nil
    }

    func applyAppearance() {
        NSApp.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Colors for the matte behind photos (grid, enlarged view and Develop preview).
nonisolated enum GridColors {
    /// Matte brightness (0 black … 1 white) for `appearance`, honoring the user's Matte Color setting.
    static func matteWhite(for appearance: NSAppearance) -> CGFloat {
        1 - (AppSettings.storedMatte() ?? AppSettings.themeMatte(for: appearance))
    }

    /// Cells sit slightly lighter on dark mattes and slightly darker on light ones.
    private static func offset(_ white: CGFloat, dark: CGFloat, light: CGFloat) -> CGFloat {
        white < 0.5 ? white + dark : white - light
    }

    // Concrete colors, resolved when drawn. Dynamic NSColors cache their value per appearance, so
    // they wouldn't pick up Matte Color changes.
    static func background(for appearance: NSAppearance) -> NSColor {
        NSColor(white: matteWhite(for: appearance), alpha: 1)
    }

    static func cell(for appearance: NSAppearance) -> NSColor {
        NSColor(white: offset(matteWhite(for: appearance), dark: 0.09, light: 0.08), alpha: 1)
    }

    static func selectedCell(for appearance: NSAppearance) -> NSColor {
        NSColor(white: offset(matteWhite(for: appearance), dark: 0.19, light: 0.18), alpha: 1)
    }

    /// Appearance for content drawn on the matte, so labels stay readable on a custom matte. `nil`
    /// when the matte follows the theme.
    static func contentAppearance() -> NSAppearance? {
        guard let matte = AppSettings.storedMatte() else { return nil }
        return NSAppearance(named: matte > 0.5 ? .darkAqua : .aqua)
    }
}

/// A view filled with the matte color. It follows appearance and Matte Color changes and adopts a
/// light or dark appearance for its contents to match the matte.
final class MatteView: NSView {
    var onMatteChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        appearance = GridColors.contentAppearance()
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange(_:)),
            name: AppSettings.didChangeNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = resolvedMatte
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        onMatteChange?()
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        appearance = GridColors.contentAppearance()
        needsDisplay = true
        onMatteChange?()
    }

    /// The matte color resolved for this view's current appearance.
    var resolvedMatte: CGColor {
        GridColors.background(for: effectiveAppearance).cgColor
    }
}
