import AppKit

/// Remove's marks over the Develop preview (RAW-260): a pin on each spot (as Tool Overlay says), the selected
/// spot's area (and its source, when it copies from one), an area waiting to be removed in red, and the brush.
///
/// Drag on the photo to paint; in Heal and Clone a click places a round spot. Drag a pin to move its spot, or a
/// copied spot's source to move that. ⌘-drag with a Remove spot selected gives it a source of its own. Scroll
/// to resize the brush.
final class RemoveOverlayView: NSView {
    var previewFrame = PreviewFrame.zero { didSet { invalidateAreas(); needsDisplay = true } }
    var frameRect: CGRect { previewFrame.rect }
    var spots: [PhotoAdjustments.Spot] = [] { didSet { needsDisplay = true } }
    var selectedID: UUID? { didSet { needsDisplay = true } }
    /// An area painted with Detect Objects on, waiting for Remove or Cancel.
    var pendingArea: PhotoAdjustments.RemoveArea? { didSet { needsDisplay = true } }
    var isDetecting = false { didSet { needsDisplay = true } }
    var mode = RemovePanelViewController.Mode.remove
    var toolOverlay = RemovePanelViewController.ToolOverlay.always { didSet { needsDisplay = true } }
    /// The brush's radius as a fraction of the photo's long edge.
    var brushSize = 0.02 { didSet { needsDisplay = true } }
    /// Painting takes away from the pending area (the Selected card's Subtract).
    var subtracts = false { didSet { needsDisplay = true } }
    /// Spots whose fills are still being made: their pins show it.
    var unfilledIDs: Set<UUID> = [] { didSet { needsDisplay = true } }

    /// A finished stroke (unit coordinates, origin bottom-left; size a fraction of the long edge).
    var onStroke: ((PhotoAdjustments.BrushStroke) -> Void)?
    /// A click on empty photo in Heal or Clone.
    var onPlace: ((PhotoAdjustments.UnitPoint) -> Void)?
    var onSelect: ((UUID?) -> Void)?
    var onChange: ((_ spot: PhotoAdjustments.Spot, _ isFinal: Bool, _ actionName: String) -> Void)?
    var onBrushResize: ((Double) -> Void)?
    /// A drag with Space held, in points, to move the zoomed photo.
    var onPan: ((CGVector) -> Void)?
    /// Space is held while the photo is zoomed: the pointer is a hand, and dragging moves the photo instead of
    /// painting (as in Lightroom).
    var isHandHeld = false {
        didSet {
            guard isHandHeld != oldValue else { return }
            if let window { pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil) }
            if let pointer, bounds.contains(pointer), !isHidden { cursor(at: pointer).set() }
            needsDisplay = true
        }
    }
    /// Whether the hand moved the photo since Space went down (a tap with no drag toggles the zoom instead).
    private(set) var didPanWithHand = false
    /// Whether Space is still down (it can be let go in another window, out of sight of the key handler).
    var isSpaceDown: () -> Bool = { CGEventSource.keyState(.combinedSessionState, key: 49) }

    private enum Drag {
        case paint([PhotoAdjustments.UnitPoint])
        case spot(UUID, start: CGPoint, original: PhotoAdjustments.Spot)
        case source(UUID, start: CGPoint, original: PhotoAdjustments.Spot)
        /// ⌘-drag: the selected Remove spot's own source follows the pointer.
        case customSource(UUID, original: PhotoAdjustments.Spot)
        /// Space held: the photo follows the pointer.
        case hand(last: CGPoint)
    }
    private var drag: Drag?
    private var moved = false
    private var pointer: CGPoint?
    private static let clickSlop: CGFloat = 3, pinRadius: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Remove")
        setAccessibilityIdentifier("removeOverlay")
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var longEdge: CGFloat { max(frameRect.width, frameRect.height) }
    private var aspect: Double { Double(frameRect.width / max(frameRect.height, 1)) }

    private func viewPoint(_ p: PhotoAdjustments.UnitPoint) -> CGPoint {
        previewFrame.viewPoint(CGPoint(x: p.x * frameRect.width, y: p.y * frameRect.height))
    }

    private func unit(_ point: CGPoint) -> PhotoAdjustments.UnitPoint {
        let point = previewFrame.framePoint(point)
        return .init(x: Double(point.x / max(frameRect.width, 1)), y: Double(point.y / max(frameRect.height, 1)))
    }

    // MARK: Hit testing

    private enum Target {
        case pin(PhotoAdjustments.Spot)
        case source(PhotoAdjustments.Spot)
    }

    /// Pins show always, only the selected one's, or none (but the selected spot can still be dragged).
    private func showsPin(_ spot: PhotoAdjustments.Spot) -> Bool {
        switch toolOverlay {
        case .always: true
        case .selected: spot.id == selectedID
        case .never: false
        }
    }

    private func target(at point: CGPoint) -> Target? {
        guard pendingArea == nil, !isDetecting else { return nil }
        for spot in spots.reversed() where showsPin(spot) || spot.id == selectedID {
            if hypot(point.x - viewPoint(spot.center).x, point.y - viewPoint(spot.center).y) <= Self.pinRadius + 4 { return .pin(spot) }
        }
        // A copying spot's source, when it's selected.
        if let spot = spots.first(where: { $0.id == selectedID }), !spot.isFilled {
            let reach = spot.area == nil ? max(spot.radius * longEdge, 6) : Self.pinRadius + 4
            if hypot(point.x - viewPoint(spot.source).x, point.y - viewPoint(spot.source).y) <= reach { return .source(spot) }
        }
        return nil
    }

    // MARK: Drawing

    /// Areas drawn at the view's size, kept until the area or the frame changes.
    private var areaImages: [PhotoAdjustments.RemoveArea: (frame: CGRect, image: CGImage, box: CGRect)] = [:]

    private func invalidateAreas() { areaImages.removeAll() }

    /// The area as a tinted image over its box (view points of the unrotated frame).
    private func image(for area: PhotoAdjustments.RemoveArea) -> (image: CGImage, box: CGRect)? {
        if let cached = areaImages[area], cached.frame == frameRect { return (cached.image, cached.box) }
        guard let painted = area.bounds(aspect: aspect), frameRect.width > 0 else { return nil }
        let box = painted.intersection(CGRect(x: -0.5, y: -0.5, width: 2, height: 2))
        let viewBox = CGRect(x: box.minX * frameRect.width, y: box.minY * frameRect.height, width: box.width * frameRect.width, height: box.height * frameRect.height)
        let shrink = min(1, 512 / max(viewBox.width, viewBox.height, 1))
        let width = max(1, Int(viewBox.width * shrink)), height = max(1, Int(viewBox.height * shrink))
        let coverage = RemoveAreaRaster.coverage(of: area, box: box, frameSize: frameRect.size, width: width, height: height)
        // Rows from the bottom into a bitmap whose rows are from the top.
        var bytes = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width { bytes[(height - 1 - row) * width + column] = UInt8(min(255, max(0, coverage[row * width + column] * 255))) }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let mask = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        areaImages[area] = (frameRect, mask, viewBox)
        return (mask, viewBox)
    }

    /// Fills the area with `color` (offset by `shift` view points), in the frame's (possibly straightened) place.
    private func drawArea(_ area: PhotoAdjustments.RemoveArea, color: NSColor, shift: CGVector = .zero) {
        guard let (mask, box) = image(for: area), let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // Into the frame's coordinates (rotated when straightened), where the box is.
        context.concatenate(previewFrame.rotation)
        context.translateBy(x: frameRect.minX, y: frameRect.minY)
        context.translateBy(x: shift.dx, y: shift.dy)
        context.clip(to: box, mask: mask)
        context.setFillColor(color.cgColor)
        context.fill(box)
        context.restoreGState()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard frameRect.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        previewFrame.outline.addClip()
        // The selected spot: its area, and where it copies from.
        if let spot = spots.first(where: { $0.id == selectedID }), pendingArea == nil {
            let center = viewPoint(spot.center), source = viewPoint(spot.source)
            if let area = spot.area {
                drawArea(area, color: NSColor.white.withAlphaComponent(0.28))
                if !spot.isFilled {
                    let shift = previewFrame.frameVector(CGVector(dx: source.x - center.x, dy: source.y - center.y))
                    drawArea(area, color: Accent.color.withAlphaComponent(0.25), shift: shift)
                }
            } else {
                let radius = max(spot.radius * longEdge, 4)
                outline(NSBezierPath(ovalIn: circle(center, radius)), selected: true, dashed: false)
                if !spot.isFilled { outline(NSBezierPath(ovalIn: circle(source, radius)), selected: true, dashed: true) }
            }
            if !spot.isFilled {
                let line = NSBezierPath()
                line.move(to: source)
                line.line(to: center)
                outline(line, selected: true, dashed: true)
                if spot.area != nil { pin(at: source, selected: true, hollow: true, busy: false) }
            }
        }
        // An area waiting for Remove, in red (as Lightroom shows it).
        if let pendingArea {
            drawArea(pendingArea, color: NSColor.systemRed.withAlphaComponent(isDetecting ? 0.25 : 0.5))
        }
        // The stroke being painted.
        if case .paint(let points)? = drag, points.count > 1 {
            let path = NSBezierPath()
            path.move(to: viewPoint(points[0]))
            for point in points.dropFirst() { path.line(to: viewPoint(point)) }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.lineWidth = max(2, brushSize * longEdge * 2)
            (subtracts && pendingArea != nil ? NSColor.black : NSColor.systemRed).withAlphaComponent(0.35).setStroke()
            path.stroke()
        }
        // Pins.
        if pendingArea == nil, !isDetecting {
            for spot in spots where showsPin(spot) {
                pin(at: viewPoint(spot.center), selected: spot.id == selectedID, hollow: false, busy: unfilledIDs.contains(spot.id))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        // The brush, where the pointer is over the photo and not on a pin.
        if let pointer, !isHandHeld, drag == nil || { if case .paint = drag { true } else { false } }(), target(at: pointer) == nil,
           previewFrame.visible.contains(pointer) {
            let radius = max(brushSize * longEdge, 2)
            let path = NSBezierPath(ovalIn: circle(pointer, radius))
            path.lineWidth = 2.5
            NSColor.black.withAlphaComponent(0.45).setStroke()
            path.stroke()
            path.lineWidth = 1
            NSColor.white.setStroke()
            path.stroke()
        }
    }

    private func pin(at point: CGPoint, selected: Bool, hollow: Bool, busy: Bool) {
        let path = NSBezierPath(ovalIn: circle(point, Self.pinRadius))
        (hollow ? NSColor.clear : (selected ? Accent.color : NSColor.white)).setFill()
        path.fill()
        path.lineWidth = 2
        NSColor.black.withAlphaComponent(0.6).setStroke()
        path.stroke()
        if busy {
            // A dashed ring while the fill is being made.
            let ring = NSBezierPath(ovalIn: circle(point, Self.pinRadius + 4))
            ring.lineWidth = 1.5
            ring.setLineDash([3, 3], count: 2, phase: 0)
            NSColor.white.setStroke()
            ring.stroke()
        }
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

    func cursor(at point: CGPoint) -> NSCursor {
        if isHandHeld { return .openHand }
        switch target(at: point) {
        case .pin?, .source?: return .openHand
        case nil: return .crosshair
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        cursor(at: pointer!).set()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        needsDisplay = true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        moved = false
        if isHandHeld, !isSpaceDown() { isHandHeld = false }
        if isHandHeld {
            drag = .hand(last: point)
            NSCursor.closedHand.set()
            return
        }
        // ⌘-drag: the selected Remove spot copies from where the pointer goes.
        if event.modifierFlags.contains(.command), let spot = spots.first(where: { $0.id == selectedID }), spot.kind == .remove, pendingArea == nil {
            drag = .customSource(spot.id, original: spot)
            return
        }
        switch target(at: point) {
        case .pin(let spot)?:
            drag = .spot(spot.id, start: point, original: spot)
            if spot.id != selectedID { onSelect?(spot.id) }
            return
        case .source(let spot)?:
            drag = .source(spot.id, start: point, original: spot)
            return
        case nil:
            break
        }
        guard previewFrame.visible.contains(point) else {
            if pendingArea == nil { onSelect?(nil) }
            return
        }
        drag = .paint([unit(point)])
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pointer = point
        moved = true
        guard let drag else { return }
        switch drag {
        case .paint(var points):
            points.append(unit(point))
            self.drag = .paint(points)
            needsDisplay = true
        case .spot, .source, .customSource:
            update(to: point, isFinal: false)
        case .hand(let last):
            onPan?(CGVector(dx: point.x - last.x, dy: point.y - last.y))
            didPanWithHand = true
            self.drag = .hand(last: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer {
            drag = nil
            needsDisplay = true
        }
        guard let drag else { return }
        switch drag {
        case .paint(let points):
            let start = points.first.map(viewPoint) ?? point
            let isClick = !moved || hypot(point.x - start.x, point.y - start.y) < Self.clickSlop && points.count < 4
            if isClick, mode != .remove, pendingArea == nil {
                onPlace?(points[0])
            } else {
                onStroke?(PhotoAdjustments.BrushStroke(points: points, size: brushSize, feather: mode == .remove ? 0.1 : 0.3, flow: 1, density: 1,
                                                       isErasing: subtracts && pendingArea != nil))
            }
        case .spot, .source, .customSource:
            if moved { update(to: point, isFinal: true) }
        case .hand:
            cursor(at: point).set()
        }
    }

    /// Space went down: the hand hasn't moved the photo yet.
    func beginHand() {
        didPanWithHand = false
        isHandHeld = true
    }

    private func update(to point: CGPoint, isFinal: Bool) {
        guard let drag else { return }
        func vector(from start: CGPoint) -> (Double, Double) {
            let moved = previewFrame.frameVector(CGVector(dx: point.x - start.x, dy: point.y - start.y))
            return (Double(moved.dx / max(frameRect.width, 1)), Double(moved.dy / max(frameRect.height, 1)))
        }
        switch drag {
        case .spot(_, let start, let original):
            var spot = original
            let (dx, dy) = vector(from: start)
            spot.move(by: dx, dy)
            onChange?(spot, isFinal, "Move Spot")
        case .source(_, let start, let original):
            var spot = original
            let (dx, dy) = vector(from: start)
            spot.source = .init(x: original.source.x + dx, y: original.source.y + dy)
            onChange?(spot, isFinal, "Move Spot Source")
        case .customSource(_, let original):
            var spot = original
            spot.source = unit(point)
            spot.hasCustomSource = true
            onChange?(spot, isFinal, "Spot Source")
        case .paint, .hand:
            break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let factor = 1 + Double(event.scrollingDeltaY) * 0.01
        onBrushResize?((brushSize * factor).clamped(to: RemovePanelViewController.sizeRange))
    }
}
