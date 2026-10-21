import AppKit

/// Spots drawn over the Develop preview while Spot Removal is open: each spot's circle and, joined by
/// an arrow, its source. Click to place one, drag a circle to move it, scroll to resize the selected one.
/// While the photo is zoomed in the cursor is a hand, and dragging off the spots pans the photo.
final class RetouchOverlayView: NSView {
    /// The photo's frame in view points.
    var frameRect = CGRect.zero { didSet { needsDisplay = true } }
    var spots: [PhotoAdjustments.Spot] = [] { didSet { needsDisplay = true } }
    var redEyes: [PhotoAdjustments.RedEyeSpot] = [] { didSet { needsDisplay = true } }
    var selectedID: UUID? { didSet { needsDisplay = true } }

    /// A click on empty space: place something there (unit coordinates, origin bottom-left).
    var onPlace: ((PhotoAdjustments.UnitPoint) -> Void)?
    var onSelect: ((UUID?) -> Void)?
    var onChange: ((_ spots: [PhotoAdjustments.Spot], _ redEyes: [PhotoAdjustments.RedEyeSpot], _ isFinal: Bool, _ actionName: String) -> Void)?
    var isZoomed: () -> Bool = { false }
    /// A drag off the spots while zoomed, by this many points (drag direction).
    var onPan: ((CGVector) -> Void)?

    private enum Drag {
        case spot(UUID, start: CGPoint, original: PhotoAdjustments.Spot)
        case source(UUID, start: CGPoint, original: PhotoAdjustments.Spot)
        case eye(UUID, start: CGPoint, original: PhotoAdjustments.RedEyeSpot)
        /// Empty space while zoomed: a click places, a drag pans.
        case pan(down: CGPoint, last: CGPoint, isPanning: Bool)
    }
    private var drag: Drag?
    private var moved = false
    /// Movement under this many points is still a click.
    private static let clickSlop: CGFloat = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Spots")
        setAccessibilityIdentifier("retouchOverlay")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: isZoomed() ? .openHand : .crosshair) }

    /// Call when the zoom changes, so the cursor follows.
    func zoomDidChange() {
        window?.invalidateCursorRects(for: self)
    }

    private var longEdge: CGFloat { max(frameRect.width, frameRect.height) }

    private func viewPoint(_ p: PhotoAdjustments.UnitPoint) -> CGPoint {
        CGPoint(x: frameRect.minX + p.x * frameRect.width, y: frameRect.minY + p.y * frameRect.height)
    }

    private func unit(_ point: CGPoint) -> PhotoAdjustments.UnitPoint {
        .init(x: Double((point.x - frameRect.minX) / max(frameRect.width, 1)), y: Double((point.y - frameRect.minY) / max(frameRect.height, 1)))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard frameRect.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: frameRect).addClip()
        for spot in spots {
            let selected = spot.id == selectedID
            let center = viewPoint(spot.center), source = viewPoint(spot.source)
            let radius = max(spot.radius * longEdge, 4)
            // The arrow from the source to the spot.
            if selected {
                let line = NSBezierPath()
                line.move(to: source)
                line.line(to: center)
                outline(line, selected: true, dashed: true)
            }
            outline(NSBezierPath(ovalIn: circle(source, radius)), selected: selected, dashed: true)
            outline(NSBezierPath(ovalIn: circle(center, radius)), selected: selected, dashed: false)
        }
        for eye in redEyes {
            let radius = max(eye.radius * longEdge, 4)
            outline(NSBezierPath(ovalIn: circle(viewPoint(eye.center), radius * 1.4)), selected: eye.id == selectedID, dashed: false)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    private func outline(_ path: NSBezierPath, selected: Bool, dashed: Bool) {
        path.lineWidth = 3
        NSColor.black.withAlphaComponent(0.5).setStroke()
        path.stroke()
        path.lineWidth = selected ? 1.8 : 1.1
        if dashed { path.setLineDash([4, 3], count: 2, phase: 0) }
        (selected ? Accent.color : NSColor.white).setStroke()
        path.stroke()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        moved = false
        // Spots on top first: their circles, then their sources.
        for spot in spots.reversed() {
            let radius = max(spot.radius * longEdge, 4) + 3
            if hypot(point.x - viewPoint(spot.center).x, point.y - viewPoint(spot.center).y) <= radius {
                drag = .spot(spot.id, start: point, original: spot)
                onSelect?(spot.id)
                return
            }
            if hypot(point.x - viewPoint(spot.source).x, point.y - viewPoint(spot.source).y) <= radius {
                drag = .source(spot.id, start: point, original: spot)
                onSelect?(spot.id)
                return
            }
        }
        for eye in redEyes.reversed() {
            if hypot(point.x - viewPoint(eye.center).x, point.y - viewPoint(eye.center).y) <= max(eye.radius * longEdge, 4) * 1.4 + 3 {
                drag = .eye(eye.id, start: point, original: eye)
                onSelect?(eye.id)
                return
            }
        }
        if isZoomed() {
            // Wait for the mouse up: a drag pans instead of placing.
            drag = .pan(down: point, last: point, isPanning: false)
            return
        }
        guard frameRect.contains(point) else { onSelect?(nil); return }
        drag = nil
        onPlace?(unit(point))
    }

    override func mouseDragged(with event: NSEvent) {
        if case .pan(let down, let last, var isPanning) = drag {
            let point = convert(event.locationInWindow, from: nil)
            if !isPanning, hypot(point.x - down.x, point.y - down.y) >= Self.clickSlop {
                isPanning = true
                NSCursor.closedHand.set()
            }
            if isPanning { onPan?(CGVector(dx: point.x - last.x, dy: point.y - last.y)) }
            drag = .pan(down: down, last: point, isPanning: isPanning)
            return
        }
        moved = true
        update(with: event, isFinal: false)
    }

    override func mouseUp(with event: NSEvent) {
        if case .pan(let down, _, let isPanning) = drag {
            drag = nil
            window?.invalidateCursorRects(for: self)
            guard !isPanning else { return }
            if frameRect.contains(down) { onPlace?(unit(down)) } else { onSelect?(nil) }
            return
        }
        if moved { update(with: event, isFinal: true) }
        drag = nil
    }

    private func update(with event: NSEvent, isFinal: Bool) {
        guard let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        func shifted(_ p: PhotoAdjustments.UnitPoint, from start: CGPoint) -> PhotoAdjustments.UnitPoint {
            .init(x: (p.x + Double((point.x - start.x) / max(frameRect.width, 1))).clamped(to: -0.5...1.5),
                  y: (p.y + Double((point.y - start.y) / max(frameRect.height, 1))).clamped(to: -0.5...1.5))
        }
        var newSpots = spots, newEyes = redEyes
        switch drag {
        case .spot(let id, let start, let original):
            guard let index = newSpots.firstIndex(where: { $0.id == id }) else { return }
            newSpots[index].center = shifted(original.center, from: start).clamped01
        case .source(let id, let start, let original):
            guard let index = newSpots.firstIndex(where: { $0.id == id }) else { return }
            newSpots[index].source = shifted(original.source, from: start)
        case .eye(let id, let start, let original):
            guard let index = newEyes.firstIndex(where: { $0.id == id }) else { return }
            newEyes[index].center = shifted(original.center, from: start).clamped01
        case .pan:
            return
        }
        onChange?(newSpots, newEyes, isFinal, "Move Spot")
    }

    override func scrollWheel(with event: NSEvent) {
        guard let id = selectedID else { return }
        let factor = 1 + Double(event.scrollingDeltaY) * 0.01
        var newSpots = spots, newEyes = redEyes
        if let index = newSpots.firstIndex(where: { $0.id == id }) {
            newSpots[index].radius = (newSpots[index].radius * factor).clamped(to: 0.002...0.1)
        } else if let index = newEyes.firstIndex(where: { $0.id == id }) {
            newEyes[index].radius = (newEyes[index].radius * factor).clamped(to: 0.002...0.1)
        } else { return }
        onChange?(newSpots, newEyes, event.phase == .ended || event.momentumPhase == .ended || event.phase.isEmpty, "Resize Spot")
    }
}

private extension PhotoAdjustments.UnitPoint {
    var clamped01: PhotoAdjustments.UnitPoint { .init(x: x.clamped(to: 0...1), y: y.clamped(to: 0...1)) }
}
