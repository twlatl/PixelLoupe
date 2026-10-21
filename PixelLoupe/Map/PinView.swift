import AppKit
import MapKit

/// PixelLoupe's map pin (`Design/MapPin.svg`), for the Map module and the Location panel: a teardrop
/// in `tint` with a dark circle holding a photo glyph or a cluster's count. Its point is on the location.
class PinView: MKAnnotationView {
    enum Content: Equatable {
        case glyph
        case count(Int)
    }

    static let size = NSSize(width: 30, height: 30 * 611 / 492)
    /// The inner circle, as fractions of the pin's width and height (from the artwork).
    private static let circleCenter = NSPoint(x: 245.0 / 492, y: 1 - 247.0 / 611)
    private static let circleRadius = 170.0 / 492
    private static let shape = NSImage(named: "MapPin")
    private static let circleColor = NSColor(srgbRed: 0x25 / 255.0, green: 0x26 / 255.0, blue: 0x26 / 255.0, alpha: 1)
    private static let glyph = NSImage(systemSymbolName: "photo.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))

    var tint: NSColor = .systemRed {
        didSet { if tint != oldValue { needsDisplay = true } }
    }
    var content: Content = .glyph {
        didSet { if content != oldValue { needsDisplay = true } }
    }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame.size = Self.size
        // The point at the bottom of the pin sits on the location.
        centerOffset = NSPoint(x: 0, y: -Self.size.height / 2)
        canShowCallout = false
        collisionMode = .circle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        if let shape = Self.shape {
            // The template artwork, filled with the tint.
            let tinted = NSImage(size: bounds.size, flipped: false) { rect in
                shape.draw(in: rect)
                self.tint.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: bounds)
        }
        let center = NSPoint(x: bounds.width * Self.circleCenter.x, y: bounds.height * Self.circleCenter.y)
        let radius = bounds.width * Self.circleRadius
        Self.circleColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()

        switch content {
        case .glyph:
            guard let glyph = Self.glyph else { return }
            let image = NSImage(size: glyph.size, flipped: false) { rect in
                glyph.draw(in: rect)
                NSColor.white.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            image.draw(in: NSRect(x: center.x - glyph.size.width / 2, y: center.y - glyph.size.height / 2,
                                  width: glyph.size.width, height: glyph.size.height))
        case .count(let count):
            let text = count > 999 ? "999+" : "\(count)"
            let fontSize: CGFloat = text.count > 2 ? 7.5 : 10
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold), .foregroundColor: NSColor.white,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
        }
    }

    // MapKit reports markers' accessibility frames scaled away from the map's center, so VoiceOver
    // (and UI tests) would point at the wrong place; the view's own frame is the right one.
    override func accessibilityFrame() -> NSRect {
        NSAccessibility.screenRect(fromView: self, rect: bounds)
    }
}
