import AppKit

/// Spots drawn over the Develop preview while Spot Removal is open: each spot's circle and, joined by
/// an arrow, its source. Click to place one, drag a circle to move it, drag one of the handles on the
/// hovered or selected circle (or scroll) to resize it. While the photo is zoomed in the cursor is a
/// hand, and dragging off the spots pans the photo.
final class RetouchOverlayView: NSView {
    /// The photo's frame in view points.
    var frameRect = CGRect.zero { didSet { needsDisplay = true } }
    var spots: [PhotoAdjustments.Spot] = [] { didSet { needsDisplay = true } }
    var redEyes: [PhotoAdjustments.RedEyeSpot] = [] { didSet { needsDisplay = true } }
    var selectedID: UUID? { didSet { needsDisplay = true } }
    /// The spot or red eye under the pointer: it shows its resize handles, as the selected one does.
    private(set) var hoveredID: UUID? { didSet { if hoveredID != oldValue { needsDisplay = true } } }

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
        /// A resize handle: the circle's edge follows the pointer.
        case resize(UUID)
        /// Empty space while zoomed: a click places, a drag pans.
        case pan(down: CGPoint, last: CGPoint, isPanning: Bool)
    }
    private var drag: Drag?
    private var moved = false
    /// Movement under this many points is still a click.
    private static let clickSlop: CGFloat = 3
    /// A handle's drawn radius, and how close the pointer must come to grab it.
    private static let handleRadius: CGFloat = 3.5, handleReach: CGFloat = 7
    /// Red eyes are drawn this much larger than the pupil they darken.
    private static let eyeOutline = 1.4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Spots")
        setAccessibilityIdentifier("retouchOverlay")
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// How far the photo is zoomed past fitting the view (1 while it fits).
    var zoomFactor: Double {
        guard isZoomed(), bounds.width > 0, bounds.height > 0 else { return 1 }
        return max(1, frameRect.width / bounds.width, frameRect.height / bounds.height)
    }

    /// Call when the zoom changes, so the cursor follows.
    func zoomDidChange() {
        updateCursor()
    }

    private var longEdge: CGFloat { max(frameRect.width, frameRect.height) }

    private func viewPoint(_ p: PhotoAdjustments.UnitPoint) -> CGPoint {
        CGPoint(x: frameRect.minX + p.x * frameRect.width, y: frameRect.minY + p.y * frameRect.height)
    }

    private func unit(_ point: CGPoint) -> PhotoAdjustments.UnitPoint {
        .init(x: Double((point.x - frameRect.minX) / max(frameRect.width, 1)), y: Double((point.y - frameRect.minY) / max(frameRect.height, 1)))
    }

    /// The circle drawn for a spot or red eye (the one its handles sit on), in view points.
    private func outlineCircle(_ id: UUID) -> (center: CGPoint, radius: CGFloat)? {
        if let spot = spots.first(where: { $0.id == id }) {
            return (viewPoint(spot.center), max(spot.radius * longEdge, 4))
        }
        if let eye = redEyes.first(where: { $0.id == id }) {
            return (viewPoint(eye.center), max(eye.radius * longEdge, 4) * Self.eyeOutline)
        }
        return nil
    }

    /// The four resize handles (top, right, bottom, left) of the hovered and selected circles.
    private func handles() -> [(id: UUID, point: CGPoint, vertical: Bool)] {
        [selectedID, hoveredID].compactMap { $0 }.reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
            .flatMap { id -> [(id: UUID, point: CGPoint, vertical: Bool)] in
                guard let (center, radius) = outlineCircle(id) else { return [] }
                return [
                    (id, CGPoint(x: center.x, y: center.y + radius), true), (id, CGPoint(x: center.x + radius, y: center.y), false),
                    (id, CGPoint(x: center.x, y: center.y - radius), true), (id, CGPoint(x: center.x - radius, y: center.y), false),
                ]
            }
    }

    private enum Target {
        case handle(UUID, vertical: Bool)
        case spot(PhotoAdjustments.Spot)
        case source(PhotoAdjustments.Spot)
        case eye(PhotoAdjustments.RedEyeSpot)
    }

    /// What's under `point`: handles first, then spots on top, their circles before their sources.
    private func target(at point: CGPoint) -> Target? {
        if let handle = handles().first(where: { hypot(point.x - $0.point.x, point.y - $0.point.y) <= Self.handleReach }) {
            return .handle(handle.id, vertical: handle.vertical)
        }
        for spot in spots.reversed() {
            let radius = max(spot.radius * longEdge, 4) + 3
            if hypot(point.x - viewPoint(spot.center).x, point.y - viewPoint(spot.center).y) <= radius { return .spot(spot) }
            if hypot(point.x - viewPoint(spot.source).x, point.y - viewPoint(spot.source).y) <= radius { return .source(spot) }
        }
        for eye in redEyes.reversed() {
            if hypot(point.x - viewPoint(eye.center).x, point.y - viewPoint(eye.center).y) <= max(eye.radius * longEdge, 4) * Self.eyeOutline + 3 {
                return .eye(eye)
            }
        }
        return nil
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
            outline(NSBezierPath(ovalIn: circle(viewPoint(eye.center), radius * Self.eyeOutline)), selected: eye.id == selectedID, dashed: false)
        }
        for handle in handles() {
            let path = NSBezierPath(ovalIn: circle(handle.point, Self.handleRadius))
            NSColor.white.setFill()
            path.fill()
            path.lineWidth = 1
            NSColor.black.withAlphaComponent(0.6).setStroke()
            path.stroke()
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

    // MARK: Pointer

    /// A resize cursor over a handle, a pointing hand over a spot, and otherwise a hand while zoomed
    /// (dragging pans) or a crosshair (clicking places).
    func cursor(at point: CGPoint) -> NSCursor {
        switch target(at: point) {
        case .handle(_, let vertical)?: vertical ? .rowResize : .columnResize
        case .spot?, .source?, .eye?: .pointingHand
        case nil: isZoomed() ? .openHand : .crosshair
        }
    }

    /// The spot whose handles show for a pointer at `point`: the one under it, or the one whose handle it's on.
    private func hoverTarget(at point: CGPoint) -> UUID? {
        switch target(at: point) {
        case .handle(let id, _)?: id
        case .spot(let spot)?: spot.id
        case .source(let spot)?: spot.id
        case .eye(let eye)?: eye.id
        case nil: nil
        }
    }

    private func updateCursor() {
        guard let window, drag == nil else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point), !isHidden else { return }
        cursor(at: point).set()
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredID = hoverTarget(at: point)
        cursor(at: point).set()
    }

    override func mouseExited(with event: NSEvent) {
        hoveredID = nil
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        moved = false
        switch target(at: point) {
        case .handle(let id, _)?:
            drag = .resize(id)
            if id != selectedID { onSelect?(id) }
            return
        case .spot(let spot)?:
            drag = .spot(spot.id, start: point, original: spot)
            onSelect?(spot.id)
            return
        case .source(let spot)?:
            drag = .source(spot.id, start: point, original: spot)
            onSelect?(spot.id)
            return
        case .eye(let eye)?:
            drag = .eye(eye.id, start: point, original: eye)
            onSelect?(eye.id)
            return
        case nil:
            break
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
        defer { updateCursor() }
        if case .pan(let down, _, let isPanning) = drag {
            drag = nil
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
        var action = "Move Spot"
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
        case .resize(let id):
            guard let (center, _) = outlineCircle(id) else { return }
            let distance = Double(hypot(point.x - center.x, point.y - center.y) / max(longEdge, 1))
            if let index = newSpots.firstIndex(where: { $0.id == id }) {
                newSpots[index].radius = distance.clamped(to: Self.radiusRange)
            } else if let index = newEyes.firstIndex(where: { $0.id == id }) {
                newEyes[index].radius = (distance / Self.eyeOutline).clamped(to: Self.radiusRange)
            } else { return }
            action = "Resize Spot"
        case .pan:
            return
        }
        onChange?(newSpots, newEyes, isFinal, action)
    }

    /// Spot and red eye radii, as a fraction of the photo's long edge (the Size slider's range).
    static let radiusRange = 0.002...0.1

    override func scrollWheel(with event: NSEvent) {
        guard let id = selectedID else { return }
        let factor = 1 + Double(event.scrollingDeltaY) * 0.01
        var newSpots = spots, newEyes = redEyes
        if let index = newSpots.firstIndex(where: { $0.id == id }) {
            newSpots[index].radius = (newSpots[index].radius * factor).clamped(to: Self.radiusRange)
        } else if let index = newEyes.firstIndex(where: { $0.id == id }) {
            newEyes[index].radius = (newEyes[index].radius * factor).clamped(to: Self.radiusRange)
        } else { return }
        onChange?(newSpots, newEyes, event.phase == .ended || event.momentumPhase == .ended || event.phase.isEmpty, "Resize Spot")
    }
}

private extension PhotoAdjustments.UnitPoint {
    var clamped01: PhotoAdjustments.UnitPoint { .init(x: x.clamped(to: 0...1), y: y.clamped(to: 0...1)) }
}
