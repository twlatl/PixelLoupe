import AppKit

/// A transparent view over a photo that does Lightroom's click-to-zoom: a click switches between the
/// fit choice and the zoom (centered where you clicked), and dragging a zoomed photo pans it. The cursor
/// is a magnifying glass while the photo fits, and a hand while it's zoomed.
final class ZoomClickView: NSView {
    /// Whether clicks zoom at all (no photo, a video, or a tool that uses clicks itself: then no).
    var isActive: () -> Bool = { true }
    var isZoomed: () -> Bool = { false }
    /// A click (not a drag) at this view point.
    var onClick: (CGPoint) -> Void = { _ in }
    /// A drag while zoomed, by this many points (drag direction).
    var onPan: (CGVector) -> Void = { _ in }

    private var downPoint: CGPoint?
    private var lastPoint: CGPoint?
    private var isPanning = false
    /// Movement under this many points is still a click.
    private static let clickSlop: CGFloat = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isActive() ? super.hitTest(point) : nil
    }

    override func resetCursorRects() {
        guard isActive() else { return }
        addCursorRect(bounds, cursor: isZoomed() ? .openHand : .zoomIn)
    }

    /// Call when the zoom changes, so the cursor follows.
    func zoomDidChange() {
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        downPoint = point
        lastPoint = point
        isPanning = false
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let down = downPoint, let last = lastPoint, isZoomed() else { return }
        if !isPanning, hypot(point.x - down.x, point.y - down.y) >= Self.clickSlop {
            isPanning = true
            NSCursor.closedHand.set()
        }
        if isPanning { onPan(CGVector(dx: point.x - last.x, dy: point.y - last.y)) }
        lastPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            downPoint = nil
            lastPoint = nil
            isPanning = false
            window?.invalidateCursorRects(for: self)
        }
        guard let down = downPoint, !isPanning else { return }
        onClick(down)
    }
}
