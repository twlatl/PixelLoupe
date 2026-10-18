import AppKit

/// A slider with two thumbs selecting a range (0…1) over a hue gradient, like Lightroom's Purple
/// Hue and Green Hue. AppKit has no range slider, so this is a custom control; each thumb is its
/// own accessibility slider.
final class HueRangeSlider: NSControl {
    /// The gradient's colors from left to right.
    let colors: [NSColor]
    let minimumWidth: Double

    var lower: Double = 0.3 {
        didSet { needsDisplay = true; updateAccessibility() }
    }
    var upper: Double = 0.7 {
        didSet { needsDisplay = true; updateAccessibility() }
    }

    /// The range changed (`isFinal` on mouse up or a keyboard step).
    var onChange: (_ lower: Double, _ upper: Double, _ isFinal: Bool) -> Void = { _, _, _ in }

    private enum Thumb { case lower, upper }
    private var dragging: Thumb?
    private let thumbSize: CGFloat = 13
    private lazy var thumbElements = [ThumbElement(slider: self, isLower: true), ThumbElement(slider: self, isLower: false)]

    init(colors: [NSColor], minimumWidth: Double = 0.1, title: String) {
        self.colors = colors
        self.minimumWidth = minimumWidth
        super.init(frame: .zero)
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        thumbElements[0].label = "\(title) lower bound"
        thumbElements[1].label = "\(title) upper bound"
        heightAnchor.constraint(equalToConstant: 18).isActive = true
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    private var track: NSRect {
        NSRect(x: thumbSize / 2, y: bounds.midY - 2, width: max(1, bounds.width - thumbSize), height: 4)
    }

    private func x(for value: Double) -> CGFloat { track.minX + track.width * CGFloat(value) }

    private func thumbRect(_ value: Double) -> NSRect {
        NSRect(x: x(for: value) - thumbSize / 2, y: bounds.midY - thumbSize / 2, width: thumbSize, height: thumbSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        let path = NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2)
        NSGradient(colors: colors.map { $0.withAlphaComponent(alpha) })?.draw(in: path, angle: 0)
        for value in [lower, upper] {
            let rect = thumbRect(value).insetBy(dx: 0.5, dy: 0.5)
            let thumb = NSBezierPath(ovalIn: rect)
            NSColor.white.withAlphaComponent(alpha).setFill()
            thumb.fill()
            NSColor.black.withAlphaComponent(0.35 * alpha).setStroke()
            thumb.lineWidth = 0.5
            thumb.stroke()
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        // The nearer thumb; between them, whichever the click is closer to.
        dragging = abs(point.x - x(for: lower)) <= abs(point.x - x(for: upper)) ? .lower : .upper
        move(to: point.x, isFinal: false)
    }

    override func mouseDragged(with event: NSEvent) {
        move(to: convert(event.locationInWindow, from: nil).x, isFinal: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging != nil else { return }
        move(to: convert(event.locationInWindow, from: nil).x, isFinal: true)
        dragging = nil
    }

    private func move(to position: CGFloat, isFinal: Bool) {
        guard let dragging else { return }
        let value = Double((position - track.minX) / track.width).clamped(to: 0...1)
        set(dragging == .lower ? value : nil, dragging == .upper ? value : nil, isFinal: isFinal)
    }

    /// Moves a bound, keeping the range at least `minimumWidth` wide.
    fileprivate func set(_ newLower: Double?, _ newUpper: Double?, isFinal: Bool) {
        if let newLower { lower = (newLower * 100).rounded() / 100 }
        if let newUpper { upper = (newUpper * 100).rounded() / 100 }
        lower = lower.clamped(to: 0...(1 - minimumWidth))
        upper = upper.clamped(to: (lower + minimumWidth)...1)
        onChange(lower, upper, isFinal)
    }

    // MARK: - Accessibility

    private func updateAccessibility() {
        thumbElements[0].setAccessibilityValue(Int((lower * 100).rounded()))
        thumbElements[1].setAccessibilityValue(Int((upper * 100).rounded()))
    }

    override func accessibilityChildren() -> [Any]? { thumbElements }

    fileprivate func frameForThumb(isLower: Bool) -> NSRect {
        let rect = thumbRect(isLower ? lower : upper)
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }

    /// One thumb, as an accessibility slider. Accessibility calls these on the main thread.
    nonisolated private final class ThumbElement: NSAccessibilityElement, @unchecked Sendable {
        private weak var slider: HueRangeSlider?
        private let isLower: Bool
        var label = ""

        init(slider: HueRangeSlider, isLower: Bool) {
            self.slider = slider
            self.isLower = isLower
            super.init()
            setAccessibilityRole(.slider)
            setAccessibilityParent(slider)
        }

        override func accessibilityLabel() -> String? { label }
        override func accessibilityMinValue() -> Any? { 0 }
        override func accessibilityMaxValue() -> Any? { 100 }

        override func accessibilityFrame() -> NSRect {
            let slider = slider, isLower = isLower
            return MainActor.assumeIsolated { slider?.frameForThumb(isLower: isLower) ?? .zero }
        }

        override func accessibilityPerformIncrement() -> Bool { step(0.05) }
        override func accessibilityPerformDecrement() -> Bool { step(-0.05) }

        private func step(_ delta: Double) -> Bool {
            let slider = slider, isLower = isLower
            return MainActor.assumeIsolated {
                guard let slider else { return false }
                if isLower { slider.set(slider.lower + delta, nil, isFinal: true) } else { slider.set(nil, slider.upper + delta, isFinal: true) }
                return true
            }
        }
    }
}
