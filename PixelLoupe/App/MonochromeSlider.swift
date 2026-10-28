import AppKit
import SwiftUI

/// PixelLoupe's slider: a thin gray track and a round knob, the same whatever the accent color or
/// Monochrome Mode (RAW-201). A value slider shows 11 tick marks under the track, one at every tenth
/// of its range (5 on each side of the middle); set `numberOfTickMarks` to 0 for one that navigates
/// (thumbnail size, zoom), or to its own count for one with discrete steps. Option-dragging snaps to
/// the ticks.
class MonochromeSlider: NSSlider {
    /// The ticks a value slider shows.
    static let tickCount = 11

    override class var cellClass: AnyClass? {
        get { MonochromeSliderCell.self }
        set {}
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        numberOfTickMarks = Self.tickCount
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `value` moved to the nearest tick, or unchanged on a slider without ticks.
    func snapped(_ value: Double) -> Double {
        numberOfTickMarks > 1 ? closestTickMarkValue(toValue: value) : value
    }

    @discardableResult
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if NSApp.currentEvent?.type == .leftMouseDragged, NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            doubleValue = snapped(doubleValue)
        }
        return super.sendAction(action, to: target)
    }
}

/// Draws `MonochromeSlider`: the track, the ticks under it and the knob, in system grays so it works
/// in light and dark appearances. A disabled slider is drawn faded.
class MonochromeSliderCell: NSSliderCell {
    static let knobDiameter: CGFloat = 14
    static let barHeight: CGFloat = 4
    /// Room above and below the knob for its shadow.
    static let margin: CGFloat = 1
    static let tickGap: CGFloat = 2
    static let tickLength: CGFloat = 3
    /// The middle tick of a range balanced around 0 (Exposure, Tint), longer so 0 stands out.
    static let centerTickLength: CGFloat = 5

    /// Light gray in Dark Mode; white (with a shadow) in Light Mode.
    static let knobColor = NSColor(name: "PixelLoupeSliderKnob") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.72, alpha: 1) : .white
    }

    var showsTicks: Bool { numberOfTickMarks > 1 }

    /// Whether the middle tick is 0, in a range balanced around it.
    var isBipolar: Bool { maxValue > 0 && minValue == -maxValue && numberOfTickMarks % 2 == 1 }

    override var knobThickness: CGFloat { Self.knobDiameter }

    override var cellSize: NSSize {
        let ticks = showsTicks ? Self.tickGap + Self.centerTickLength : Self.margin
        return NSSize(width: super.cellSize.width, height: Self.margin + Self.knobDiameter + ticks)
    }

    // MARK: Geometry

    /// How far below the top of `frame` the knob's center is, with the drawing centered vertically.
    private func knobCenterOffset(in frame: NSRect) -> CGFloat {
        (frame.height - cellSize.height) / 2 + Self.margin + Self.knobDiameter / 2
    }

    /// The y coordinate `offset` below the top of `frame`.
    private func y(_ offset: CGFloat, in frame: NSRect, flipped: Bool) -> CGFloat {
        flipped ? frame.minY + offset : frame.maxY - offset
    }

    /// The x coordinate of the knob's center at `fraction` (0…1) of the range: knob centers stay
    /// inside the frame, as AppKit's tracking expects from `knobThickness`.
    func x(at fraction: Double, in frame: NSRect) -> CGFloat {
        frame.minX + Self.knobDiameter / 2 + CGFloat(min(max(fraction, 0), 1)) * (frame.width - Self.knobDiameter)
    }

    private var fraction: Double {
        maxValue > minValue ? (doubleValue - minValue) / (maxValue - minValue) : 0
    }

    private var controlBounds: NSRect { controlView?.bounds ?? NSRect(origin: .zero, size: cellSize) }

    func knobRect(in frame: NSRect, flipped: Bool) -> NSRect {
        let d = Self.knobDiameter
        let center = NSPoint(x: x(at: fraction, in: frame), y: y(knobCenterOffset(in: frame), in: frame, flipped: flipped))
        return NSRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
    }

    func barRect(in frame: NSRect, flipped: Bool) -> NSRect {
        let h = Self.barHeight
        let centerY = y(knobCenterOffset(in: frame), in: frame, flipped: flipped)
        return NSRect(x: frame.minX + 1, y: centerY - h / 2, width: max(frame.width - 2, 0), height: h)
    }

    override func knobRect(flipped: Bool) -> NSRect { knobRect(in: controlBounds, flipped: flipped) }

    override func barRect(flipped: Bool) -> NSRect { barRect(in: controlBounds, flipped: flipped) }

    override func rectOfTickMark(at index: Int) -> NSRect {
        tickRect(at: index, in: controlBounds, flipped: controlView?.isFlipped ?? false)
    }

    private func tickRect(at index: Int, in frame: NSRect, flipped: Bool) -> NSRect {
        let length = isBipolar && index == numberOfTickMarks / 2 ? Self.centerTickLength : Self.tickLength
        let top = knobCenterOffset(in: frame) + Self.knobDiameter / 2 + Self.tickGap
        let centerX = x(at: Double(index) / Double(numberOfTickMarks - 1), in: frame)
        let minY = flipped ? y(top, in: frame, flipped: true) : y(top + length, in: frame, flipped: false)
        return NSRect(x: (centerX - 0.5).rounded(), y: minY, width: 1, height: length)
    }

    // MARK: Drawing

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let flipped = controlView.isFlipped
        let context = NSGraphicsContext.current?.cgContext
        if !isEnabled {
            context?.setAlpha(0.45)
            context?.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        drawBar(inside: barRect(in: cellFrame, flipped: flipped), flipped: flipped)
        if showsTicks {
            NSColor.tertiaryLabelColor.setFill()
            for index in 0..<numberOfTickMarks { tickRect(at: index, in: cellFrame, flipped: flipped).fill() }
        }
        drawKnob(knobRect(in: cellFrame, flipped: flipped))
        if !isEnabled { context?.endTransparencyLayer() }
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let knob = NSBezierPath(ovalIn: knobRect.insetBy(dx: 0.5, dy: 0.5))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        Self.knobColor.setFill()
        knob.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        knob.lineWidth = 0.5
        knob.stroke()
    }

    override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSBezierPath(ovalIn: knobRect(in: cellFrame, flipped: controlView.isFlipped)).fill()
    }

    override func focusRingMaskBounds(forFrame cellFrame: NSRect, in controlView: NSView) -> NSRect {
        knobRect(in: cellFrame, flipped: controlView.isFlipped)
    }
}

/// `MonochromeSlider` for SwiftUI, in place of `Slider` (whose Liquid Glass look follows the accent).
/// With a `step`, values are rounded to it; a stepped slider with at most 11 values shows a tick at
/// each one instead of at every tenth.
struct MonochromeSliderView: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    /// Off for a slider that navigates rather than sets a value.
    var showsTicks = true
    let label: String
    var identifier: String?

    var tickCount: Int {
        guard showsTicks else { return 0 }
        if let step, step > 0 {
            let values = Int(((range.upperBound - range.lowerBound) / step).rounded()) + 1
            if values <= MonochromeSlider.tickCount { return values }
        }
        return MonochromeSlider.tickCount
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MonochromeSlider {
        let slider = MonochromeSlider(frame: .zero)
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel(label)
        if let identifier { slider.setAccessibilityIdentifier(identifier) }
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: MonochromeSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        if slider.numberOfTickMarks != tickCount { slider.numberOfTickMarks = tickCount }
        if slider.doubleValue != value { slider.doubleValue = value }
        slider.isEnabled = context.environment.isEnabled
    }

    /// `value` rounded to the step, within the range.
    func stepped(_ value: Double) -> Double {
        guard let step, step > 0 else { return value }
        let rounded = range.lowerBound + ((value - range.lowerBound) / step).rounded() * step
        return min(max(rounded, range.lowerBound), range.upperBound)
    }

    final class Coordinator: NSObject {
        var parent: MonochromeSliderView

        init(_ parent: MonochromeSliderView) { self.parent = parent }

        @objc func changed(_ sender: NSSlider) {
            let value = parent.stepped(sender.doubleValue)
            if parent.value != value { parent.value = value }
        }
    }
}
