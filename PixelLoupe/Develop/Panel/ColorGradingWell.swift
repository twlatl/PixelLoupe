import AppKit

/// A Color Grading wheel's color well (at the single wheel's lower left): a small square of the wheel's current tint.
/// Clicking it opens `ColorGradingWellPopover`.
final class ColorGradingWellButton: NSButton {
    static let side = 18.0

    var color: NSColor = .gray {
        didSet { if color != oldValue { needsDisplay = true } }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override func draw(_ dirtyRect: NSRect) {
        Self.drawSwatch(color, in: bounds, isEnabled: isEnabled)
    }

    /// A rounded square of `color` with a hairline edge, as the wells and swatches draw.
    static func drawSwatch(_ color: NSColor, in rect: NSRect, isEnabled: Bool = true) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: 3, yRadius: 3)
        color.withAlphaComponent(isEnabled ? 1 : 0.4).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// The tint a wheel gives: gray at no strength, its hue's full color at 100.
    static func tint(_ wheel: PhotoAdjustments.ColorWheel) -> NSColor {
        let full = ColorLUT.Transform.hsvToRGB(h: wheel.hue * 360, s: 0.85, v: 0.9)
        let gray = 0.5, amount = wheel.amount.clamped(to: 0...1)
        return NSColor(
            srgbRed: gray + (full.0 - gray) * amount, green: gray + (full.1 - gray) * amount,
            blue: gray + (full.2 - gray) * amount, alpha: 1
        )
    }
}

/// What a color well opens, like Lightroom's color popover but offering the photo's own colors: the wheel's current
/// tint, an eyedropper for picking from the photo, and the photo's main colors in the wheel's tonal range.
final class ColorGradingWellPopover: NSViewController {
    /// A swatch was clicked, with its color.
    var onPick: ((ColorGradingSwatches.RGB) -> Void)?
    /// The eyedropper was clicked.
    var onEyedropper: (() -> Void)?

    var current: NSColor = .gray {
        didSet { currentWell.color = current }
    }

    /// The photo's colors, or `nil` while they're still being found.
    var swatches: [ColorGradingSwatches.RGB]? {
        didSet { showSwatches() }
    }

    private let tab: ColorGradingTab
    private let currentWell = ColorGradingWellButton()
    private let eyedropper = NSButton()
    private let swatchRow = NSStackView()
    private let spinner = NSProgressIndicator()
    private let emptyLabel = NSTextField(labelWithString: "No colors")
    private var targets: [ActionTarget] = []

    init(tab: ColorGradingTab) {
        self.tab = tab
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The swatch buttons shown (for tests).
    var swatchButtons: [NSButton] { swatchRow.arrangedSubviews.compactMap { $0 as? NSButton } }
    var eyedropperButton: NSButton { eyedropper }

    override func loadView() {
        currentWell.refusesFirstResponder = true
        currentWell.setAccessibilityLabel("Current \(tab.title.lowercased()) color")

        eyedropper.image = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil)
        eyedropper.isBordered = false
        eyedropper.bezelStyle = .toolbar
        eyedropper.imagePosition = .imageOnly
        eyedropper.toolTip = "Pick a color from the photo"
        eyedropper.setAccessibilityLabel("Pick a \(tab.title.lowercased()) color from the photo")
        eyedropper.setAccessibilityIdentifier("colorGradingEyedropper")
        let eyedropperTarget = ActionTarget { [weak self] _ in self?.onEyedropper?() }
        eyedropper.target = eyedropperTarget
        eyedropper.action = #selector(ActionTarget.fire(_:))
        targets.append(eyedropperTarget)

        let label = NSTextField(labelWithString: tab == .global ? "Photo colors:" : "Photo colors in the \(tab.title.lowercased()):")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyLabel.textColor = .tertiaryLabelColor
        spinner.style = .spinning
        spinner.controlSize = .small
        swatchRow.spacing = 4

        let top = NSStackView(views: [currentWell, NSView(), eyedropper])
        let stack = NSStackView(views: [top, label, swatchRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        currentWell.color = current
        view = stack
        showSwatches()
    }

    private func showSwatches() {
        guard isViewLoaded else { return }
        swatchRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        targets.removeSubrange(1...)
        guard let swatches else {
            swatchRow.addArrangedSubview(spinner)
            spinner.startAnimation(nil)
            return
        }
        spinner.stopAnimation(nil)
        guard !swatches.isEmpty else {
            swatchRow.addArrangedSubview(emptyLabel)
            return
        }
        for (index, color) in swatches.enumerated() {
            let button = ColorGradingWellButton()
            button.color = NSColor(srgbRed: color.x, green: color.y, blue: color.z, alpha: 1)
            button.setAccessibilityLabel("Photo color \(index + 1)")
            button.setAccessibilityIdentifier("colorGradingSwatch.\(index)")
            if let wheel = ColorGradingSwatches.wheel(for: color) {
                button.toolTip = "Hue \(Int((wheel.hue * 360).rounded())), Saturation \(Int((wheel.amount * 100).rounded()))"
            }
            let target = ActionTarget { [weak self] _ in self?.onPick?(color) }
            button.target = target
            button.action = #selector(ActionTarget.fire(_:))
            targets.append(target)
            swatchRow.addArrangedSubview(button)
        }
    }
}
