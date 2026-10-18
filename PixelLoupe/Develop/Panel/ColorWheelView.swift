import AppKit

/// A hue/strength wheel for color grading. Drag the puck away from the center to tint; double-click
/// to reset.
final class ColorWheelView: NSView {
    var hue = 0.0 { didSet { needsDisplay = true } }
    var amount = 0.0 { didSet { needsDisplay = true } }
    var onChange: ((_ hue: Double, _ amount: Double, _ isFinal: Bool) -> Void)?

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

    private var wheelRect: CGRect {
        let side = min(bounds.width, bounds.height) - 4
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = wheelRect
        let scale = window?.backingScaleFactor ?? 2
        if wheelImage?.size != rect.width * scale {
            wheelImage = Self.makeWheel(diameter: Int(rect.width * scale)).map { (rect.width * scale, $0) }
        }
        if let image = wheelImage?.image {
            context.saveGState()
            context.addEllipse(in: rect)
            context.clip()
            context.draw(image, in: rect)
            context.restoreGState()
        }
        NSColor.separatorColor.setStroke()
        NSBezierPath(ovalIn: rect).stroke()

        let puck = puckCenter
        let puckRect = CGRect(x: puck.x - 5, y: puck.y - 5, width: 10, height: 10)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: puckRect).fill()
        NSColor.black.withAlphaComponent(0.6).setStroke()
        NSBezierPath(ovalIn: puckRect).stroke()
    }

    private var puckCenter: CGPoint {
        let rect = wheelRect
        let angle = hue * 2 * .pi
        let radius = amount * rect.width / 2
        return CGPoint(x: rect.midX + cos(angle) * radius, y: rect.midY + sin(angle) * radius)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            hue = 0
            amount = 0
            onChange?(hue, amount, true)
            return
        }
        track(event, isFinal: false)
    }

    override func mouseDragged(with event: NSEvent) {
        track(event, isFinal: false)
    }

    override func mouseUp(with event: NSEvent) {
        track(event, isFinal: true)
    }

    private func track(_ event: NSEvent, isFinal: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        let rect = wheelRect
        let dx = point.x - rect.midX, dy = point.y - rect.midY
        var angle = atan2(dy, dx) / (2 * .pi)
        if angle < 0 { angle += 1 }
        hue = angle
        amount = min(1, hypot(dx, dy) / (rect.width / 2))
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
