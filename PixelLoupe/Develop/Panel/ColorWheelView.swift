import AppKit

/// A hue/strength wheel for color grading, as in Lightroom: drag the puck away from the center to tint, or the dot
/// outside the rim to change only the hue. Shift-drag changes only the strength, Command-drag moves the puck finely,
/// and double-click resets. The wheel is dimmed unless the pointer is over it.
final class ColorWheelView: NSView {
    var hue = 0.0 { didSet { if hue != oldValue { needsDisplay = true } } }
    var amount = 0.0 { didSet { if amount != oldValue { needsDisplay = true } } }
    var onChange: ((_ hue: Double, _ amount: Double, _ isFinal: Bool) -> Void)?
    /// The pointer moved over or off the wheel, or a drag began or ended: `isHighlighted` changed.
    var onHighlight: ((Bool) -> Void)?

    /// Whether the wheel is drawn at full brightness: the pointer is over it, or it's being dragged.
    private(set) var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            needsDisplay = true
            onHighlight?(isHighlighted)
        }
    }
    private var isHovered = false { didSet { updateHighlight() } }
    private var drag: Drag? { didSet { updateHighlight() } }

    private struct Drag {
        var mode: ColorWheelGeometry.Mode
        /// The pointer's last position, for Command's fine moves.
        var pointer: CGPoint
    }

    private var wheelImage: (size: CGFloat, image: CGImage)?

    override var intrinsicContentSize: NSSize { NSSize(width: 76, height: 76) }
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.colorWell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var geometry: ColorWheelGeometry { ColorWheelGeometry(bounds: bounds) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private func updateHighlight() { isHighlighted = isHovered || drag != nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let geometry = geometry
        let rect = geometry.wheelRect
        let scale = window?.backingScaleFactor ?? 2
        if wheelImage?.size != rect.width * scale {
            wheelImage = Self.makeWheel(diameter: Int(rect.width * scale)).map { (rect.width * scale, $0) }
        }
        if let image = wheelImage?.image {
            context.saveGState()
            context.addEllipse(in: rect)
            context.clip()
            // Dimmed into whatever the panel's background is, so it follows the appearance and Matte Color.
            context.setAlpha(isHighlighted ? 1 : ColorWheelGeometry.dimmedAlpha)
            context.draw(image, in: rect)
            context.restoreGState()
        }
        NSColor.separatorColor.setStroke()
        NSBezierPath(ovalIn: rect).stroke()

        // The hue at full strength, just outside the rim.
        let dot = geometry.hueDotCenter(hue: hue)
        let dotRect = CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8)
        AdjustmentsPanelViewController.wheelColor(hue: hue).withAlphaComponent(amount > 0 || isHighlighted ? 1 : 0.5).setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        let puck = geometry.point(hue: hue, amount: amount)
        let puckRect = CGRect(x: puck.x - 5, y: puck.y - 5, width: 10, height: 10)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: puckRect).fill()
        NSColor.black.withAlphaComponent(0.6).setStroke()
        NSBezierPath(ovalIn: puckRect).stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            hue = 0
            amount = 0
            onChange?(hue, amount, true)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let onDot = geometry.isOnHueDot(point, hue: hue)
        drag = Drag(mode: onDot ? .hueOnly : .free, pointer: point)
        // Grabbing the dot doesn't move anything until it's dragged.
        if !onDot { track(event, isFinal: false) }
    }

    override func mouseDragged(with event: NSEvent) {
        track(event, isFinal: false)
    }

    override func mouseUp(with event: NSEvent) {
        if drag != nil { track(event, isFinal: true) }
        drag = nil
    }

    private func track(_ event: NSEvent, isFinal: Bool) {
        guard var drag else { return }
        let pointer = convert(event.locationInWindow, from: nil)
        let geometry = geometry
        // Shift can be pressed partway through a drag; the hue dot only ever turns the hue.
        let mode: ColorWheelGeometry.Mode = drag.mode == .hueOnly ? .hueOnly : event.modifierFlags.contains(.shift) ? .strengthOnly : .free
        // Command moves what's being dragged (the puck, or the dot) by a fraction of the pointer's move.
        let grabbed = mode == .hueOnly ? geometry.hueDotCenter(hue: hue) : geometry.point(hue: hue, amount: amount)
        let target = event.modifierFlags.contains(.command)
            ? geometry.fineTarget(moving: grabbed, from: drag.pointer, to: pointer)
            : pointer
        drag.pointer = pointer
        self.drag = drag
        (hue, amount) = geometry.value(at: target, mode: mode, current: (hue, amount))
        setAccessibilityValue("Hue \(Int(hue * 360))°, amount \(Int(amount * 100))%")
        onChange?(hue, amount, isFinal)
    }

    private static func makeWheel(diameter: Int) -> CGImage? {
        guard diameter > 0,
              let context = CGContext(
                data: nil, width: diameter, height: diameter, bitsPerComponent: 8, bytesPerRow: diameter * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let data = context.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        let radius = Double(diameter) / 2
        for y in 0..<diameter {
            for x in 0..<diameter {
                let dx = Double(x) + 0.5 - radius, dy = radius - Double(y) - 0.5
                let distance = min(1, hypot(dx, dy) / radius)
                var angle = atan2(dy, dx) * 180 / .pi
                if angle < 0 { angle += 360 }
                let (r, g, b) = ColorLUT.Transform.hsvToRGB(h: angle, s: distance * 0.85, v: 0.9)
                let offset = (y * diameter + x) * 4
                data[offset] = UInt8(r * 255)
                data[offset + 1] = UInt8(g * 255)
                data[offset + 2] = UInt8(b * 255)
                data[offset + 3] = 255
            }
        }
        return context.makeImage()
    }
}

/// Where things are on a color wheel and how the pointer maps to hue (0…1 around, 0 = red at the right, counter-
/// clockwise) and strength (0…1 out from the center).
nonisolated struct ColorWheelGeometry {
    enum Mode {
        /// The puck follows the pointer.
        case free
        /// The outer dot: only the hue follows the pointer's angle.
        case hueOnly
        /// Shift: only the strength follows the pointer's distance.
        case strengthOnly
    }

    /// How much of a drag Command passes on to the puck.
    static let fineScale = 0.25
    /// The wheel's brightness while the pointer isn't over it.
    static let dimmedAlpha = 0.45
    /// Room outside the rim for the hue dot.
    static let rimMargin = 7.0

    let bounds: CGRect

    var wheelRect: CGRect {
        let side = max(0, min(bounds.width, bounds.height) - 2 * Self.rimMargin)
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    private var radius: Double { wheelRect.width / 2 }
    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    func point(hue: Double, amount: Double) -> CGPoint {
        let angle = hue * 2 * .pi
        return CGPoint(x: center.x + cos(angle) * amount * radius, y: center.y + sin(angle) * amount * radius)
    }

    func hueDotCenter(hue: Double) -> CGPoint {
        let angle = hue * 2 * .pi, distance = radius + Self.rimMargin / 2 + 1
        return CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
    }

    /// Whether a click at `point` grabs the hue dot: near it (generously, as it's small) but outside the wheel, so a
    /// click on the wheel's edge still moves the puck there.
    func isOnHueDot(_ point: CGPoint, hue: Double) -> Bool {
        let dot = hueDotCenter(hue: hue)
        return hypot(point.x - dot.x, point.y - dot.y) <= 7 && hypot(point.x - center.x, point.y - center.y) > radius
    }

    /// The hue and strength for the pointer at `point`.
    func value(at point: CGPoint, mode: Mode, current: (hue: Double, amount: Double)) -> (hue: Double, amount: Double) {
        let dx = point.x - center.x, dy = point.y - center.y
        var angle = atan2(dy, dx) / (2 * .pi)
        if angle < 0 { angle += 1 }
        let distance = radius > 0 ? min(1, hypot(dx, dy) / radius) : 0
        switch mode {
        case .free: return (distance > 0 ? angle : current.hue, distance)
        case .hueOnly: return (dx == 0 && dy == 0 ? current.hue : angle, current.amount)
        case .strengthOnly: return (current.hue, distance)
        }
    }

    /// Where Command's fine drag aims: `grabbed` (the puck or the hue dot) moved by a quarter of the pointer's move.
    func fineTarget(moving grabbed: CGPoint, from previous: CGPoint, to pointer: CGPoint) -> CGPoint {
        CGPoint(x: grabbed.x + (pointer.x - previous.x) * Self.fineScale, y: grabbed.y + (pointer.y - previous.y) * Self.fineScale)
    }
}
