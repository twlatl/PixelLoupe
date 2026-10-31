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
/// tint, an eyedropper for picking from the photo, and the photo's main colors in the wheel's tonal range. Like
/// Lightroom's, it stays open while you work (picking from the photo included) until its close button.
final class ColorGradingWellPopover: NSViewController {
    /// A swatch was clicked, with its color.
    var onPick: ((ColorGradingSwatches.RGB) -> Void)?
    /// The eyedropper was switched on (clicks on the photo pick) or off.
    var onEyedropper: ((Bool) -> Void)?
    /// The eyedropper was dragged out and let go here (screen coordinates).
    var onEyedropperDrop: ((NSPoint) -> Void)?
    /// The close button was clicked.
    var onClose: (() -> Void)?

    var current: NSColor = .gray {
        didSet { currentWell.color = current }
    }

    /// The photo's colors, or `nil` while they're still being found.
    var swatches: [ColorGradingSwatches.RGB]? {
        didSet { showSwatches() }
    }

    /// Whether the eyedropper is on.
    var isPicking: Bool {
        get { eyedropper.state == .on }
        set {
            eyedropper.state = newValue ? .on : .off
            eyedropper.contentTintColor = newValue ? Accent.color : nil
        }
    }

    let tab: ColorGradingTab
    private let currentWell = ColorGradingWellButton()
    private let eyedropper = ColorGradingEyedropperButton()
    private let closeButton = NSButton()
    private let swatchRow = NSStackView()
    private let spinner = NSProgressIndicator()
    private let emptyLabel = NSTextField(labelWithString: "No colors")
    private var targets: [ActionTarget] = []
    private var swatchTargets: [ActionTarget] = []

    init(tab: ColorGradingTab) {
        self.tab = tab
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The swatch buttons shown (for tests).
    var swatchButtons: [NSButton] { swatchRow.arrangedSubviews.compactMap { $0 as? NSButton } }
    var eyedropperButton: ColorGradingEyedropperButton { eyedropper }
    var closeButtonForTesting: NSButton { closeButton }

    override func loadView() {
        let title = NSTextField(labelWithString: tab.title)
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.isBordered = false
        closeButton.bezelStyle = .toolbar
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close"
        closeButton.setAccessibilityIdentifier("colorGradingWellClose")
        closeButton.keyEquivalent = "\u{1b}"
        let closeTarget = ActionTarget { [weak self] _ in self?.onClose?() }
        closeButton.target = closeTarget
        closeButton.action = #selector(ActionTarget.fire(_:))
        targets.append(closeTarget)

        currentWell.refusesFirstResponder = true
        currentWell.setAccessibilityLabel("Current \(tab.title.lowercased()) color")

        eyedropper.image = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil)
        eyedropper.setButtonType(.pushOnPushOff)
        eyedropper.isBordered = false
        eyedropper.bezelStyle = .toolbar
        eyedropper.imagePosition = .imageOnly
        eyedropper.toolTip = "Click, then click the photo to pick a color (or drag onto the photo)"
        eyedropper.onDrop = { [weak self] point in self?.onEyedropperDrop?(point) }
        eyedropper.setAccessibilityLabel("Pick a \(tab.title.lowercased()) color from the photo")
        eyedropper.setAccessibilityIdentifier("colorGradingEyedropper")
        let eyedropperTarget = ActionTarget { [weak self] _ in
            guard let self else { return }
            isPicking = eyedropper.state == .on
            onEyedropper?(isPicking)
        }
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

        let header = NSStackView(views: [title, NSView(), closeButton])
        let current = NSStackView(views: [currentWell, eyedropper])
        current.spacing = 6
        let stack = NSStackView(views: [header, current, label, swatchRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 8)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -18).isActive = true
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        currentWell.color = self.current
        view = stack
        showSwatches()
    }

    private func showSwatches() {
        guard isViewLoaded else { return }
        swatchRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        swatchTargets = []
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
            swatchTargets.append(target)
            swatchRow.addArrangedSubview(button)
        }
    }
}

extension NSCursor {
    /// The Color Grading eyedropper's pointer: the eyedropper symbol, picking at its tip, with a light halo so it shows
    /// on dark and light photos alike.
    static let eyedropper: NSCursor = {
        let side = 22.0
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return .crosshair }
        func tinted(_ color: NSColor) -> NSImage {
            NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
        }
        let halo = tinted(.white), body = tinted(.black)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            // The symbol's tip is its lower left; put it at the image's lower left, inside the halo.
            let origin = CGPoint(x: 1.5, y: 1.5)
            for dx in [-1.0, 0, 1] {
                for dy in [-1.0, 0, 1] where dx != 0 || dy != 0 {
                    halo.draw(at: CGPoint(x: origin.x + dx, y: origin.y + dy), from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
            body.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        // Hot spots count from the top left.
        return NSCursor(image: image, hotSpot: NSPoint(x: 3, y: side - 2.5))
    }()
}

/// The popover's eyedropper, a toggle: click it on, then click the photo (as often as you like) to pick. It can also be
/// dragged out and let go over the photo to pick there.
final class ColorGradingEyedropperButton: NSButton {
    /// Where a drag out of the button was let go, in screen coordinates.
    var onDrop: ((NSPoint) -> Void)?
    /// How far the pointer moves before a press becomes a drag.
    static let dragThreshold = 4.0

    override func mouseDown(with event: NSEvent) {
        guard let window, isEnabled else { return }
        let start = event.locationInWindow
        var isDragging = false
        highlight(true)
        defer {
            highlight(false)
            if isDragging { NSCursor.pop() }
        }
        // The window that got the press keeps getting the drag, even outside the popover.
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let location = next.locationInWindow
            if next.type == .leftMouseDragged {
                if !isDragging, hypot(location.x - start.x, location.y - start.y) > Self.dragThreshold {
                    isDragging = true
                    highlight(false)
                    NSCursor.eyedropper.push()
                }
                continue
            }
            if isDragging {
                onDrop?(window.convertPoint(toScreen: location))
            } else if bounds.contains(convert(location, from: nil)) {
                // Tracking is done here rather than by the cell, so flip the toggle as a click would.
                state = state == .on ? .off : .on
                sendAction(action, to: target)
            }
            return
        }
    }
}
