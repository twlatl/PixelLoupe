import AppKit

/// Loupe preferences, remembered between sessions.
final class LoupeSettings {
    static let zoomLevels: [Double] = [0.5, 1, 2, 4, 8, 16]
    static let sizeRange: ClosedRange<CGFloat> = 160...640

    private enum Key {
        static let zoom = "LoupeZoom"
        static let size = "LoupeSize"
        static let focusOnCursor = "LoupeFocusOnCursor"
        static let centered = "LoupeCentered"
        static let pixelGrid = "LoupePixelGrid"
        static let colorValue = "LoupeColorValue"
    }

    private let defaults: UserDefaults

    /// Magnification relative to the original's actual pixels (1 = 100%).
    var zoom: Double { didSet { defaults.set(zoom, forKey: Key.zoom) } }
    /// Width of the whole loupe graphic, in points.
    var size: CGFloat { didSet { defaults.set(Double(size), forKey: Key.size) } }
    /// Magnify whatever the pointer is over instead of what's under the loupe.
    var focusOnCursor: Bool { didSet { defaults.set(focusOnCursor, forKey: Key.focusOnCursor) } }
    /// Magnify what's under the lens center; otherwise magnify the target just past the corner tab.
    var centered: Bool { didSet { defaults.set(centered, forKey: Key.centered) } }
    var showsPixelGrid: Bool { didSet { defaults.set(showsPixelGrid, forKey: Key.pixelGrid) } }
    var showsColorValue: Bool { didSet { defaults.set(showsColorValue, forKey: Key.colorValue) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedZoom = defaults.double(forKey: Key.zoom)
        zoom = Self.zoomLevels.contains(storedZoom) ? storedZoom : 1
        let storedSize = CGFloat(defaults.double(forKey: Key.size))
        size = storedSize > 0 ? storedSize.clamped(to: Self.sizeRange) : 320
        focusOnCursor = defaults.bool(forKey: Key.focusOnCursor)
        centered = defaults.object(forKey: Key.centered) as? Bool ?? true
        showsPixelGrid = defaults.bool(forKey: Key.pixelGrid)
        showsColorValue = defaults.bool(forKey: Key.colorValue)
    }

    static func title(forZoom zoom: Double) -> String {
        "\(Int((zoom * 100).rounded()))"
    }
}

/// Maps between points in the Develop preview and pixels of the full-resolution photo.
nonisolated struct PreviewGeometry: Equatable {
    /// Where the photo is drawn, in view points.
    var imageRect: CGRect
    /// Full-resolution photo size, in pixels.
    var imageSize: CGSize
    /// Display pixels per point.
    var backingScale: CGFloat

    func imagePoint(forViewPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - imageRect.minX) / imageRect.width * imageSize.width,
            y: (point.y - imageRect.minY) / imageRect.height * imageSize.height
        )
    }

    func viewPoint(forImagePoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: imageRect.minX + point.x / imageSize.width * imageRect.width,
            y: imageRect.minY + point.y / imageSize.height * imageRect.height
        )
    }

    /// Points on screen per photo pixel at `zoom` (100% = one photo pixel per display pixel).
    func pointsPerImagePixel(zoom: Double) -> CGFloat {
        CGFloat(zoom) / backingScale
    }

    /// Diameter, in preview points, of the photo area a lens of `lensDiameter` points shows at `zoom`.
    func previewDiameter(ofLens lensDiameter: CGFloat, zoom: Double) -> CGFloat {
        let imagePixels = lensDiameter / pointsPerImagePixel(zoom: zoom)
        return imagePixels / imageSize.width * imageRect.width
    }
}

/// The loupe graphic, reproduced from the RAW-3 design (Loupe.svg, a 600 × 600 artboard): a
/// circular lens with a thick black ring over a rounded tab at the lower right, which holds the
/// zoom menu and a resize grip.
nonisolated enum LoupeShape {
    static let artboard: CGFloat = 600
    static let center = CGPoint(x: 299.5, y: 299.5)
    /// Ring stroke is centered on this radius.
    static let ringRadius: CGFloat = 290.5
    static let ringWidth: CGFloat = 20
    /// Radius of the clear lens inside the ring.
    static let lensRadius: CGFloat = ringRadius - ringWidth / 2
    static let tabRect = CGRect(x: 316, y: 298, width: 283, height: 300)
    static let tabCornerRadius: CGFloat = 18
    static let gripLines: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 574.61731, y: 592.061035), CGPoint(x: 593.968994, y: 573.232483)),
        (CGPoint(x: 564.71875, y: 591.925415), CGPoint(x: 593.387878, y: 564.031311)),
        (CGPoint(x: 554.839539, y: 590.375671), CGPoint(x: 592.826172, y: 553.416016)),
        (CGPoint(x: 545.677063, y: 588.128601), CGPoint(x: 592.264404, y: 542.80072)),
    ]
    /// The tab's outer corner, which the grip is anchored to.
    static let gripAnchor = CGPoint(x: 599, y: 598)
    /// The grip keeps the design's proportions at this artboard scale whatever the loupe's size,
    /// so its lines don't thicken as the loupe grows.
    static let gripScale: CGFloat = 320 / 600
    static let gripLineWidth: CGFloat = 2
    /// Grip hit area, in points around the middle of the lines.
    static let gripCenterOffset = CGPoint(x: -24, y: -24)
    static let gripHitRadius: CGFloat = 18
    /// What an offset (non-centered) loupe magnifies: just past the tab's outer corner.
    static let target = CGPoint(x: 630, y: 630)

    enum Region: Equatable {
        case lens, edge, grip, none
    }

    /// Hit-tests a point in artboard coordinates (y down, as in the SVG). The grip is fixed-size,
    /// so it's tested in view coordinates by `LoupePlacement`.
    static func region(at point: CGPoint) -> Region {
        let distance = hypot(point.x - center.x, point.y - center.y)
        if distance < lensRadius { return .lens }
        if distance <= ringRadius + ringWidth / 2 { return .edge }
        if tabRect.contains(point) { return .edge }
        return .none
    }
}

/// Places the 600-unit loupe artboard in a view: the lens center at `lensCenter`, the whole
/// graphic `size` points wide. View coordinates have y up; the artboard has y down.
nonisolated struct LoupePlacement: Equatable {
    var lensCenter: CGPoint
    var size: CGFloat

    var scale: CGFloat { size / LoupeShape.artboard }

    var lensRadius: CGFloat { LoupeShape.lensRadius * scale }

    /// Radius the magnified photo is drawn to: out to the middle of the ring, so the opaque ring
    /// always covers its edge.
    var coverRadius: CGFloat { LoupeShape.ringRadius * scale }

    /// Grip lines in view points, at a constant size anchored to the tab corner.
    var gripLines: [(CGPoint, CGPoint)] {
        LoupeShape.gripLines.map { (gripPoint($0.0), gripPoint($0.1)) }
    }

    var gripCenter: CGPoint {
        gripPoint(CGPoint(
            x: LoupeShape.gripAnchor.x + LoupeShape.gripCenterOffset.x,
            y: LoupeShape.gripAnchor.y + LoupeShape.gripCenterOffset.y
        ))
    }

    private func gripPoint(_ artboardPoint: CGPoint) -> CGPoint {
        let anchor = viewPoint(LoupeShape.gripAnchor)
        return CGPoint(
            x: anchor.x + (artboardPoint.x - LoupeShape.gripAnchor.x) * LoupeShape.gripScale,
            y: anchor.y - (artboardPoint.y - LoupeShape.gripAnchor.y) * LoupeShape.gripScale
        )
    }

    /// Artboard → view transform.
    var transform: CGAffineTransform {
        CGAffineTransform(translationX: lensCenter.x, y: lensCenter.y)
            .scaledBy(x: scale, y: -scale)
            .translatedBy(x: -LoupeShape.center.x, y: -LoupeShape.center.y)
    }

    func viewPoint(_ artboardPoint: CGPoint) -> CGPoint {
        artboardPoint.applying(transform)
    }

    func artboardPoint(_ viewPoint: CGPoint) -> CGPoint {
        viewPoint.applying(transform.inverted())
    }

    func region(at viewPoint: CGPoint) -> LoupeShape.Region {
        if hypot(viewPoint.x - gripCenter.x, viewPoint.y - gripCenter.y) <= LoupeShape.gripHitRadius { return .grip }
        return LoupeShape.region(at: artboardPoint(viewPoint))
    }

    /// The point the loupe magnifies when focused on itself.
    func focusPoint(centered: Bool) -> CGPoint {
        centered ? lensCenter : viewPoint(LoupeShape.target)
    }

    /// Moves the loupe so it magnifies `point`.
    mutating func focus(on point: CGPoint, centered: Bool) {
        let offset = CGPoint(x: lensCenter.x - focusPoint(centered: centered).x,
                             y: lensCenter.y - focusPoint(centered: centered).y)
        lensCenter = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
    }

    /// Bounds of the drawn graphic (plus the offset target), in view points.
    var bounds: CGRect {
        let corners = [CGPoint(x: -1, y: -1), CGPoint(x: 601, y: 601), LoupeShape.target]
        let points = corners.map(viewPoint)
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -4, dy: -4)
    }
}
