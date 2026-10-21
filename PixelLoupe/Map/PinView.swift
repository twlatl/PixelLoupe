import AppKit
import MapKit

/// PixelLoupe's map pin (`Design/MapPin.svg`), for the Map module and the Location panel: a teardrop
/// in `tint` with a white border and a drop shadow, setting it apart from the map, and a dark circle
/// holding a photo glyph or a cluster's count. Its point is on the location.
class PinView: MKAnnotationView {
    enum Content: Equatable {
        case glyph
        case count(Int)
    }

    /// The pin itself; the view is larger by `margin`, room for its shadow.
    static let pinSize = NSSize(width: 30, height: 30 * 611 / 492)
    private static let margin = NSEdgeInsets(top: 2, left: 4, bottom: 5, right: 4)
    static let size = NSSize(width: pinSize.width + margin.left + margin.right, height: pinSize.height + margin.top + margin.bottom)
    /// Where the pin is drawn in the view.
    private static let pinRect = NSRect(x: margin.left, y: margin.bottom, width: pinSize.width, height: pinSize.height)
    /// The inner circle, as fractions of the pin's width and height (from the artwork).
    private static let circleCenter = NSPoint(x: 245.0 / 492, y: 1 - 247.0 / 611)
    private static let circleRadius = 170.0 / 492
    private static let circleColor = NSColor(srgbRed: 0x25 / 255.0, green: 0x26 / 255.0, blue: 0x26 / 255.0, alpha: 1)
    private static let glyph = NSImage(systemSymbolName: "photo.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))

    var tint: NSColor = .systemRed {
        didSet { if tint != oldValue { needsDisplay = true } }
    }
    var content: Content = .glyph {
        didSet { if content != oldValue { needsDisplay = true } }
    }

    private static let borderWidth: CGFloat = 1.5
    private static let shadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        return shadow
    }()

    /// The pin's outline in the view's coordinates (y up), inset so the border fits inside `pinRect`.
    private static let outline: NSBezierPath = {
        let path = svgPath(shapeData)
        let rect = pinRect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        var transform = AffineTransform(translationByX: rect.minX, byY: rect.maxY)
        transform.scale(x: rect.width / 492, y: -rect.height / 611)
        transform.translate(x: -26, y: -23)
        path.transform(using: transform)
        path.lineWidth = borderWidth
        return path
    }()

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame.size = Self.size
        // The point at the bottom of the pin sits on the location.
        centerOffset = NSPoint(x: (Self.margin.left - Self.margin.right) / 2, y: -Self.size.height / 2 + Self.margin.bottom)
        canShowCallout = false
        collisionMode = .circle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        Self.shadow.set()
        tint.setFill()
        Self.outline.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setStroke()
        Self.outline.stroke()
        let inner = Self.pinRect.insetBy(dx: Self.borderWidth / 2, dy: Self.borderWidth / 2)
        let center = NSPoint(x: inner.minX + inner.width * Self.circleCenter.x, y: inner.minY + inner.height * Self.circleCenter.y)
        let radius = inner.width * Self.circleRadius
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

    /// The pin's outline from `Design/MapPin.svg` ("Shape", absolute M, C and Z commands), in its
    /// 543 × 650 artboard.
    private static let shapeData = """
        M 273.79 630.85 C 271.15 633.21 271.15 633.21 249.83 612.41 C 238.1 600.97 205.96 569.09 178.42 541.55 C
        150.87 514.02 124.52 487 119.86 481.5 C 115.21 476 107.33 466.28 102.37 459.9 C 97.4 453.53 89.94 443.4
        85.79 437.4 C 81.64 431.41 75.3 421.72 71.69 415.87 C 68.08 410.02 62.36 400 58.97 393.61 C 55.59 387.22
        50.68 376.93 48.07 370.74 C 45.47 364.56 41.7 354.77 39.69 349 C 37.69 343.23 34.7 333.11 33.04 326.52 C
        31.38 319.94 29.23 309.14 28.26 302.52 C 27.01 293.96 26.5 284.31 26.5 269 C 26.5 257.17 27.08 243 27.78
        237.5 C 28.48 232 30.21 222.33 31.62 216 C 33.03 209.67 36.38 197.82 39.07 189.65 C 41.75 181.48 47.05
        168.39 50.83 160.56 C 54.62 152.74 61.21 140.97 65.48 134.42 C 69.75 127.86 76.21 118.67 79.84 114 C
        83.47 109.33 91.4 100.54 97.47 94.48 C 103.53 88.42 112.32 80.39 117 76.65 C 121.68 72.9 131.19 66.03
        138.15 61.37 C 145.11 56.71 155.01 50.73 160.15 48.08 C 165.29 45.44 174.68 41.21 181 38.69 C 187.32
        36.17 197.23 32.74 203 31.07 C 208.77 29.4 219.51 27.01 226.85 25.77 C 238.65 23.76 243.63 23.5 269.85
        23.5 C 288.17 23.5 303.39 23.99 309.69 24.79 C 315.29 25.5 325.91 27.61 333.3 29.47 C 340.69 31.33
        351.63 34.69 357.62 36.95 C 363.6 39.2 373.61 43.59 379.85 46.7 C 386.09 49.82 396.44 55.8 402.85 60 C
        409.26 64.2 419.19 71.39 424.93 75.97 C 430.67 80.55 439.69 88.62 444.99 93.9 C 450.28 99.18 457.68
        107.32 461.42 111.99 C 465.16 116.65 471.51 125.43 475.54 131.49 C 479.56 137.54 485.54 147.67 488.83
        154 C 492.12 160.33 496.85 170.67 499.34 177 C 501.83 183.33 505.5 194.12 507.5 201 C 509.49 207.88
        512.24 220.02 513.61 228 C 515.22 237.44 516.3 248.52 516.7 259.73 C 517.07 270.15 516.85 281.99 516.14
        289.68 C 515.5 296.68 513.86 307.88 512.5 314.58 C 511.15 321.28 508.43 332.11 506.46 338.63 C 504.5
        345.16 500.38 356.8 497.32 364.5 C 494.26 372.2 488.61 384.58 484.77 392 C 480.92 399.42 473.91 411.58
        469.19 419 C 464.46 426.42 457.54 436.77 453.82 442 C 450.09 447.23 443.25 456.37 438.63 462.32 C 434
        468.27 426.28 477.72 421.46 483.32 C 416.65 488.92 391.96 514.22 366.6 539.53 C 341.25 564.85 310.58
        595.23 298.46 607.03 C 286.34 618.84 275.24 629.56 273.79 630.85 Z M 275 409.53 C 285.11 409.29 292.53
        408.52 299.5 406.99 C 305 405.78 312.88 403.55 317 402.04 C 321.12 400.53 328.1 397.48 332.5 395.26 C
        336.9 393.03 344.17 388.58 348.65 385.36 C 353.13 382.14 358.98 377.44 361.65 374.93 C 364.32 372.42
        368.94 367.69 371.92 364.43 C 374.9 361.17 379.56 355.12 382.27 351 C 384.98 346.88 388.97 339.99 391.13
        335.7 C 393.3 331.41 396.4 323.92 398.03 319.06 C 399.66 314.19 401.9 304.94 403 298.51 C 404.1 292.07
        405 282.39 405 277 C 405 271.61 404.1 261.93 403 255.49 C 401.9 249.06 399.66 239.81 398.03 234.94 C
        396.4 230.08 393.3 222.59 391.13 218.3 C 388.97 214.01 384.85 206.92 381.98 202.54 C 379.08 198.11
        371.85 189.66 365.64 183.44 C 359.51 177.3 350.94 169.91 346.59 167.01 C 342.24 164.1 334.14 159.56
        328.59 156.92 C 323.04 154.28 314.55 150.97 309.72 149.58 C 304.9 148.19 297.02 146.48 292.22 145.77 C
        287.43 145.07 277.42 144.5 270 144.5 C 261.12 144.5 253.25 145.12 247 146.31 C 241.77 147.31 233.49
        149.47 228.58 151.1 C 223.68 152.74 216.12 155.86 211.78 158.05 C 207.44 160.24 200.88 164.03 197.2
        166.48 C 193.51 168.92 187.35 173.66 183.5 177 C 179.65 180.34 174.1 185.87 171.16 189.29 C 168.23 192.7
        163.88 198.2 161.5 201.5 C 159.13 204.8 155.16 211.55 152.68 216.5 C 150.2 221.45 146.79 229.46 145.1
        234.3 C 143.41 239.14 141.12 248.31 140.01 254.68 C 138.84 261.42 138 270.75 138 277 C 138 283.25 138.84
        292.58 140.01 299.32 C 141.12 305.69 143.42 314.86 145.12 319.69 C 146.83 324.52 149.96 331.99 152.08
        336.29 C 154.2 340.58 158.01 347.18 160.53 350.94 C 163.06 354.71 167.77 360.85 171.02 364.6 C 174.26
        368.35 179.97 374.04 183.71 377.24 C 187.44 380.44 193.48 385.07 197.12 387.52 C 200.76 389.97 207.06
        393.62 211.12 395.64 C 215.18 397.65 222.06 400.6 226.41 402.2 C 230.76 403.79 237.51 405.78 241.41
        406.61 C 245.31 407.44 251.2 408.52 254.5 409.01 C 257.8 409.49 267.02 409.73 275 409.53 Z
        """

    /// Reads the absolute M, L, C and Z commands of SVG path data.
    private static func svgPath(_ data: String) -> NSBezierPath {
        let path = NSBezierPath()
        let scanner = Scanner(string: data)
        var command: Character = "M"
        func point() -> NSPoint? {
            guard let x = scanner.scanDouble(), let y = scanner.scanDouble() else { return nil }
            return NSPoint(x: x, y: y)
        }
        while !scanner.isAtEnd {
            if let letter = scanner.scanCharacters(from: CharacterSet(charactersIn: "MLCZ")), let last = letter.last {
                command = last
                if command == "Z" { path.close(); continue }
            }
            switch command {
            case "M": if let p = point() { path.move(to: p) } else { return path }
            case "L": if let p = point() { path.line(to: p) } else { return path }
            case "C":
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.curve(to: p, controlPoint1: c1, controlPoint2: c2)
            default: return path
            }
        }
        return path
    }
}
