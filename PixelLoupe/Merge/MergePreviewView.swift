import AppKit

/// The merge sheet's preview: the whole merged photo fitted in the view, or, after a click, the part
/// around the click at 100% (one photo pixel per screen pixel), which can be dragged around. Another
/// click fits the photo again. The 100% view starts as the fitted preview enlarged and sharpens when
/// the full-resolution part (``showDetail(_:center:)``) arrives.
final class HDRPreviewView: NSView {
    /// The whole photo, as merged at preview size.
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    /// The photo's full-resolution size, in pixels.
    var photoSize: CGSize = .zero

    /// Asks for the part of the photo at 100% around a point (fractions of the photo, from the top
    /// left), so many pixels in size.
    var onDetailNeeded: ((CGPoint, CGSize) -> Void)?

    private(set) var isZoomed = false {
        didSet {
            window?.invalidateCursorRects(for: self)
            setAccessibilityValue(isZoomed ? "100%" : "Fit")
        }
    }

    /// The middle of the 100% view, as fractions of the photo from the top left.
    private(set) var center = CGPoint(x: 0.5, y: 0.5)
    private var detail: (image: NSImage, center: CGPoint)?
    private var drag: (start: NSPoint, center: CGPoint, moved: Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Views don't clip their drawing by default; a dragged 100% view must stay inside the well.
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Merged photo preview")
        setAccessibilityHelp("Click to zoom to 100%; drag to look around; click again to fit.")
        setAccessibilityValue("Fit")
        toolTip = "Click to zoom to 100%"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// How many pixels the 100% view needs.
    var detailPixels: CGSize {
        let scale = window?.backingScaleFactor ?? 2
        return CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }

    /// Shows the full-resolution part, if it's still the part being looked at.
    func showDetail(_ image: NSImage, center: CGPoint) {
        guard isZoomed, center == self.center else { return }
        detail = (image, center)
        needsDisplay = true
    }

    /// Back to the whole photo.
    func zoomToFit() {
        isZoomed = false
        detail = nil
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isZoomed ? .openHand : .zoomIn)
    }

    // MARK: - Drawing

    /// Where the fitted photo is drawn.
    private var fitRect: CGRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// The part of the photo the 100% view shows around `center`, as fractions of the photo.
    private func region(around center: CGPoint) -> CGRect {
        guard photoSize.width > 0, photoSize.height > 0 else { return .zero }
        let pixels = detailPixels
        let width = min(1, pixels.width / photoSize.width), height = min(1, pixels.height / photoSize.height)
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    /// Keeps the 100% view inside the photo.
    private func clamp(_ point: CGPoint) -> CGPoint {
        let size = region(around: point).size
        return CGPoint(
            x: point.x.clamped(to: (size.width / 2)...max(size.width / 2, 1 - size.width / 2)),
            y: point.y.clamped(to: (size.height / 2)...max(size.height / 2, 1 - size.height / 2))
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        guard isZoomed else {
            image.draw(in: fitRect)
            return
        }
        let shown = region(around: center)
        // The part of the photo the view covers (it may be smaller than the view for a small photo).
        let scale = window?.backingScaleFactor ?? 2
        let destination = CGRect(
            x: (bounds.width - shown.width * photoSize.width / scale) / 2,
            y: (bounds.height - shown.height * photoSize.height / scale) / 2,
            width: shown.width * photoSize.width / scale, height: shown.height * photoSize.height / scale
        )
        // The preview enlarged, until (and around) the full-resolution part. Image coordinates run bottom up.
        image.draw(
            in: destination,
            from: CGRect(
                x: shown.minX * image.size.width, y: (1 - shown.maxY) * image.size.height,
                width: shown.width * image.size.width, height: shown.height * image.size.height
            ),
            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high]
        )
        if let detail {
            // Where the detail sits relative to the current center (it moves while dragging).
            let offset = CGPoint(
                x: (detail.center.x - center.x) * photoSize.width / scale,
                y: (detail.center.y - center.y) * photoSize.height / scale
            )
            detail.image.draw(
                in: destination.offsetBy(dx: offset.x, dy: offset.y), from: .zero,
                operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
            )
        }
    }

    // MARK: - Clicking and dragging

    override func mouseDown(with event: NSEvent) {
        drag = (convert(event.locationInWindow, from: nil), center, false)
        if isZoomed { NSCursor.closedHand.push() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag, isZoomed, photoSize.width > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 2
        let dx = point.x - drag.start.x, dy = point.y - drag.start.y
        if abs(dx) + abs(dy) > 2 { drag.moved = true }
        self.drag = drag
        center = clamp(CGPoint(
            x: drag.center.x - dx * scale / photoSize.width,
            y: drag.center.y - dy * scale / photoSize.height
        ))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        if isZoomed { NSCursor.pop() }
        guard let drag, image != nil else { return }
        if drag.moved {
            onDetailNeeded?(center, detailPixels)
            return
        }
        if isZoomed {
            zoomToFit()
            return
        }
        let fit = fitRect
        guard fit.contains(drag.start) else { return }
        center = clamp(CGPoint(x: (drag.start.x - fit.minX) / fit.width, y: (drag.start.y - fit.minY) / fit.height))
        detail = nil
        isZoomed = true
        needsDisplay = true
        onDetailNeeded?(center, detailPixels)
    }
}
