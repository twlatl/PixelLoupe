import AppKit

/// The color PixelLoupe uses for selected and active controls, tool icons and selection
/// highlights: the system accent color, or with Settings ▸ Appearance ▸ Monochrome Mode, dark gray
/// in Dark Mode and black in Light Mode.
///
/// Code that tints or draws with the accent uses ``color``. Native controls that would otherwise
/// draw in the system accent (segmented controls, default buttons) are recolored by
/// ``apply(in:)``, which runs for every window when it becomes key, when the setting changes, and
/// when a view builds its controls after its window is already showing. Checkboxes, switches and
/// focus rings have no tint of their own; for those, Monochrome Mode sets the app's accent to
/// Graphite, which macOS reads when the app launches. Sliders are gray whatever the setting
/// (`MonochromeSlider`).
@MainActor
enum Accent {
    /// The accent to tint or draw with now. Not a dynamic color for the setting itself: read it again
    /// after ``AppSettings/didChangeNotification``.
    static var color: NSColor { color(monochrome: AppSettings.shared.isMonochrome) }

    static func color(monochrome isOn: Bool) -> NSColor {
        isOn ? monochrome : .controlAccentColor
    }

    /// Dark gray in Dark Mode, black in Light Mode.
    static let monochrome = NSColor(name: "PixelLoupeMonochromeAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.33, alpha: 1) : .black
    }

    /// Whether `color` is one of the accents (so it should follow the setting).
    static func isAccent(_ color: NSColor?) -> Bool {
        guard let color else { return false }
        return color == .controlAccentColor || color == monochrome
    }

    /// Recolors the native controls in `view` and below for the current setting. With `redraw`, also
    /// redraws every view, for custom views that draw with ``color`` (only when the setting changes:
    /// windows become key often, and the grid has many cells).
    static func apply(in view: NSView, monochrome mono: Bool = AppSettings.shared.isMonochrome, redraw: Bool = false) {
        let fill: NSColor? = mono ? monochrome : nil
        switch view {
        case let segmented as AccentSegmentedControl:
            let accent = color(monochrome: mono)
            if segmented.selectedSegmentBezelColor != accent { segmented.selectedSegmentBezelColor = accent }
        case let segmented as NSSegmentedControl:
            if segmented.selectedSegmentBezelColor != fill { segmented.selectedSegmentBezelColor = fill }
        case let button as ProminentButton:
            button.applyAccent(monochrome: mono)
        case let button as NSButton:
            if isAccent(button.contentTintColor) { button.contentTintColor = color(monochrome: mono) }
            if button.keyEquivalent == "\r", button.isBordered, button.bezelColor != fill { button.bezelColor = fill }
        default:
            break
        }
        if redraw { view.needsDisplay = true }
        for subview in view.subviews { apply(in: subview, monochrome: mono, redraw: redraw) }
    }

    /// Applies the current setting to every window (after it changes).
    static func applyToAllWindows() {
        for window in NSApp.windows {
            if let content = window.contentView { apply(in: content, redraw: true) }
            // The toolbar's own views (the right-sidebar and loupe toggles, the mode picker) live outside
            // the content view.
            for item in window.toolbar?.items ?? [] { if let view = item.view { apply(in: view, redraw: true) } }
        }
    }

    /// Recolors each window's controls as it becomes key, so sheets and dialogs built after the
    /// setting changed match. Call once at launch.
    static func startFollowingWindows() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                if let content = window?.contentView { apply(in: content) }
            }
        }
    }
}

/// A segmented control whose selected segment is filled with the accent color (or Monochrome Mode's), where
/// a plain one draws the system's neutral selection: for a picker whose choice should stand out, like the
/// Masking panel's kinds of mask. ``Accent/apply(in:monochrome:redraw:)`` keeps it in step with the setting.
final class AccentSegmentedControl: NSSegmentedControl {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        selectedSegmentBezelColor = Accent.color
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A filled default button (the import window's Import): the accent color with white text, or in
/// Monochrome Mode the opposite of the window, white with black text in Dark Mode and black with white
/// text in Light Mode, so it stands out as the mockups show. ``Accent/apply(in:monochrome:redraw:)``
/// keeps it in step with the setting.
final class ProminentButton: NSButton {
    /// The button's text (use this rather than `title`, so the text keeps its color).
    var label = "" {
        didSet { updateTitle() }
    }

    private var isMonochrome = AppSettings.shared.isMonochrome

    private static let monochromeFill = NSColor(name: "PixelLoupeProminentFill") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.93, alpha: 1) : .black
    }

    private static let monochromeText = NSColor(name: "PixelLoupeProminentText") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white
    }

    convenience init(label: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        bezelStyle = .push
        controlSize = .large
        keyEquivalent = "\r"
        self.target = target
        self.action = action
        self.label = label
        applyAccent(monochrome: isMonochrome)
    }

    func applyAccent(monochrome: Bool) {
        isMonochrome = monochrome
        let fill = monochrome ? Self.monochromeFill : NSColor.controlAccentColor
        if bezelColor != fill { bezelColor = fill }
        updateTitle()
    }

    private func updateTitle() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: controlSize), weight: .medium),
            .foregroundColor: isMonochrome ? Self.monochromeText : NSColor.white,
            .paragraphStyle: paragraph,
        ])
    }
}
