import AppKit

/// Remove's marks over the Develop preview (RAW-260): a pin on each spot (as Tool Overlay says), the selected
/// spot's area (and its source, when it copies from one), an area waiting to be removed in red, the brush, and the
/// outlines of the blemishes Blemish Removal removed (RAW-306).
///
/// Drag on the photo to paint; in Heal and Clone a click places a round spot. Drag a pin to move its spot, or a
/// copied spot's source to move that. ⌘-drag with a Remove spot selected gives it a source of its own. Scroll
/// to resize the brush. Click a blemish's outline to put it back, or to remove it again.
final class RemoveOverlayView: NSView {
    var previewFrame = PreviewFrame.zero { didSet { invalidateAreas(); needsDisplay = true } }
    var frameRect: CGRect { previewFrame.rect }
    var spots: [PhotoAdjustments.Spot] = [] { didSet { needsDisplay = true } }
    /// One of Blemish Removal's marks: removed, or put back by the user.
    struct BlemishMark: Equatable {
        var id: UInt64
        var area: PhotoAdjustments.RemoveArea
        var isExcluded: Bool
    }
    /// Blemish Removal's marks: each drawn as a white outline, dashed when put back (unless Tool Overlay is Never).
    /// A click on one puts it back, or removes it again.
    var blemishMarks: [BlemishMark] = [] {
        didSet {
            guard blemishMarks != oldValue else { return }
            if !blemishMarks.contains(where: { $0.id == hoveredBlemish }) { hoveredBlemish = nil }
            needsDisplay = true
        }
    }
    var onToggleBlemish: ((UInt64) -> Void)?
    /// The mark the pointer is on: filled lightly, to show a click acts on it.
    private(set) var hoveredBlemish: UInt64? { didSet { if hoveredBlemish != oldValue { needsDisplay = true } } }
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
    /// Option is held: the brush does the opposite of the Selected card's Add or Subtract, as in Lightroom.
    var isOptionDown = false {
        didSet {
            guard isOptionDown != oldValue else { return }
            needsDisplay = true
            onOptionChange?(isOptionDown)
        }
    }
    /// Option went down or up: the Selected card shows which way the brush paints.
    var onOptionChange: ((Bool) -> Void)?
    private var flagsMonitor: Any?
    /// What painting does to the pending area now: Subtract (or Add with Option) takes away from it.
    var paintSubtracts: Bool { pendingArea != nil && subtracts != isOptionDown }
    /// Spots whose fills are still being made: their pins show it.
    var unfilledIDs: Set<UUID> = [] {
        didSet {
            needsDisplay = true
            updateFillAnimation()
        }
    }

    // MARK: Fill animation

    /// While a fill is being made its pin pulses (its color toward red, its size up to half as big again) and the
    /// dashed ring around it turns clockwise, so it's clear Remove is working; when the fill is done it stops.
    private var fillAnimation: Timer?
    var isAnimatingFill: Bool { fillAnimation != nil }
    /// Seconds for one pulse, out and back.
    nonisolated static let pulsePeriod: TimeInterval = 1.2

    /// How far into the pulse `time` is: 0 (the pin as it is) to 1 (red, 150 %), easing in and out.
    nonisolated static func pulse(at time: TimeInterval) -> CGFloat {
        CGFloat(1 - cos(2 * .pi * time / pulsePeriod)) / 2
    }

    private func updateFillAnimation() {
        let wanted = !unfilledIDs.isEmpty && window != nil
        if wanted, fillAnimation == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            }
            // Common modes, so it keeps going while the mouse is down.
            RunLoop.main.add(timer, forMode: .common)
            fillAnimation = timer
        } else if !wanted, let fillAnimation {
            fillAnimation.invalidate()
            self.fillAnimation = nil
        }
    }

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

    /// The blemish mark at `point`: the smallest, when they overlap. Pins and the selected spot's source win over it.
    func blemish(at point: CGPoint) -> BlemishMark? {
        guard mode == .remove, toolOverlay != .never, pendingArea == nil, !isDetecting, target(at: point) == nil,
              previewFrame.visible.contains(point) else { return nil }
        // A little around it, so a tiny mark can be clicked.
        let center = unit(point), slop: CGFloat = 3
        let w = slop / max(frameRect.width, 1), h = slop / max(frameRect.height, 1)
        let box = CGRect(x: center.x - w, y: center.y - h, width: w * 2, height: h * 2)
        func size(_ mark: BlemishMark) -> CGFloat {
            let bounds = mark.area.bounds(aspect: aspect) ?? .zero
            return bounds.width * bounds.height
        }
        return blemishMarks.filter { mark in
            guard let bounds = mark.area.bounds(aspect: aspect), bounds.intersects(box) else { return false }
            return RemoveAreaRaster.coverage(of: mark.area, box: box, frameSize: frameRect.size, width: 5, height: 5).contains { $0 > 0.5 }
        }.min { size($0) < size($1) }
    }

    // MARK: Drawing

    /// How an area is drawn: filled, or as its outline (a thin line, and a wider one under it to set it off).
    enum AreaStyle { case fill, outline, outlineShadow, dashed, dashedShadow }

    private struct AreaMasks {
        var frame: CGRect
        var box: CGRect
        var fill: CGImage
        var outline: CGImage
        var outlineShadow: CGImage
        var dashed: CGImage
        var dashedShadow: CGImage
    }

    /// Areas drawn at the view's size, kept until the area or the frame changes.
    private var areaImages: [PhotoAdjustments.RemoveArea: AreaMasks] = [:]

    private func invalidateAreas() { areaImages.removeAll() }

    /// The area as a mask over its box (view points of the unrotated frame), filled or outlined.
    private func image(for area: PhotoAdjustments.RemoveArea, style: AreaStyle = .fill) -> (image: CGImage, box: CGRect)? {
        guard let masks = masks(for: area) else { return nil }
        switch style {
        case .fill: return (masks.fill, masks.box)
        case .outline: return (masks.outline, masks.box)
        case .outlineShadow: return (masks.outlineShadow, masks.box)
        case .dashed: return (masks.dashed, masks.box)
        case .dashedShadow: return (masks.dashedShadow, masks.box)
        }
    }

    private func masks(for area: PhotoAdjustments.RemoveArea) -> AreaMasks? {
        if let cached = areaImages[area], cached.frame == frameRect { return cached }
        guard let painted = area.bounds(aspect: aspect), frameRect.width > 0 else { return nil }
        let box = painted.intersection(CGRect(x: -0.5, y: -0.5, width: 2, height: 2))
        let viewBox = CGRect(x: box.minX * frameRect.width, y: box.minY * frameRect.height, width: box.width * frameRect.width, height: box.height * frameRect.height)
        let shrink = min(1, 512 / max(viewBox.width, viewBox.height, 1))
        let width = max(1, Int(viewBox.width * shrink)), height = max(1, Int(viewBox.height * shrink))
        let coverage = RemoveAreaRaster.coverage(of: area, box: box, frameSize: frameRect.size, width: width, height: height)
        // The outline: inside pixels next to outside ones, about 1 point wide (and 3 for the shadow under it).
        let inside = coverage.map { $0 > 0.5 }
        let pixelsPerPoint = Double(width) / max(Double(viewBox.width), 1)
        func edge(points: Double) -> [Float] {
            let reach = max(1, Int((points * pixelsPerPoint).rounded()))
            let outside = RemoveFillStore.dilate(inside.map { !$0 }, width: width, height: height, by: reach)
            let grown = RemoveFillStore.dilate(inside, width: width, height: height, by: max(0, reach - 1))
            return inside.indices.map { grown[$0] && outside[$0] ? 1 : 0 }
        }
        // Rows from the bottom into a bitmap whose rows are from the top.
        func mask(_ values: [Float]) -> CGImage? {
            var bytes = [UInt8](repeating: 0, count: width * height)
            for row in 0..<height {
                for column in 0..<width { bytes[(height - 1 - row) * width + column] = UInt8(min(255, max(0, values[row * width + column] * 255))) }
            }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        // Dashes about 4 points long, around the middle of the area.
        let dashes = max(5, (Double.pi * Double(viewBox.width + viewBox.height) / 2 / 8).rounded())
        func dash(_ values: [Float]) -> [Float] {
            values.indices.map { i in
                let angle = atan2((Double(i / width) + 0.5) / Double(height) - 0.5, (Double(i % width) + 0.5) / Double(width) - 0.5)
                let turn = (angle / (2 * .pi) + 0.5) * dashes
                return turn - turn.rounded(.down) < 0.5 ? values[i] : 0
            }
        }
        let line = edge(points: 1), under = edge(points: 2.5)
        guard let fill = mask(coverage), let outline = mask(line), let shadow = mask(under),
              let dashed = mask(dash(line)), let dashedShadow = mask(dash(under)) else { return nil }
        let masks = AreaMasks(frame: frameRect, box: viewBox, fill: fill, outline: outline, outlineShadow: shadow,
                              dashed: dashed, dashedShadow: dashedShadow)
        areaImages[area] = masks
        return masks
    }

    /// Fills the area (or its outline) with `color` (offset by `shift` view points), in the frame's (possibly
    /// straightened) place.
    private func drawArea(_ area: PhotoAdjustments.RemoveArea, color: NSColor, style: AreaStyle = .fill, shift: CGVector = .zero) {
        guard let (mask, box) = image(for: area, style: style), let context = NSGraphicsContext.current?.cgContext else { return }
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
        // Blemish Removal's marks, outlined (under the selected spot).
        if toolOverlay != .never, pendingArea == nil {
            for mark in blemishMarks {
                if mark.id == hoveredBlemish { drawArea(mark.area, color: NSColor.white.withAlphaComponent(0.28)) }
                drawArea(mark.area, color: NSColor.black.withAlphaComponent(0.45), style: mark.isExcluded ? .dashedShadow : .outlineShadow)
            }
            for mark in blemishMarks {
                drawArea(mark.area, color: .white, style: mark.isExcluded ? .dashed : .outline)
            }
        }
        // The selected spot: its area, and where it copies from.
        if let spot = spots.first(where: { $0.id == selectedID }), pendingArea == nil {
            let center = viewPoint(spot.center), source = viewPoint(spot.source)
            if let area = spot.area {
                // Its outline, so the result shows through; filled lightly only while the pointer is on its pin.
                if hoveredID == spot.id { drawArea(area, color: NSColor.white.withAlphaComponent(0.28)) }
                drawArea(area, color: NSColor.black.withAlphaComponent(0.45), style: .outlineShadow)
                drawArea(area, color: .white, style: .outline)
                if !spot.isFilled {
                    let shift = previewFrame.frameVector(CGVector(dx: source.x - center.x, dy: source.y - center.y))
                    drawArea(area, color: NSColor.black.withAlphaComponent(0.45), style: .outlineShadow, shift: shift)
                    drawArea(area, color: Accent.color, style: .outline, shift: shift)
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
            (paintSubtracts ? NSColor.black : NSColor.systemRed).withAlphaComponent(0.35).setStroke()
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
           drag != nil || blemish(at: pointer) == nil, previewFrame.visible.contains(pointer) {
            let radius = max(brushSize * longEdge, 2)
            let path = NSBezierPath(ovalIn: circle(pointer, radius))
            path.lineWidth = 2.5
            NSColor.black.withAlphaComponent(0.45).setStroke()
            path.stroke()
            path.lineWidth = 1
            NSColor.white.setStroke()
            path.stroke()
            // A minus in the middle while the brush takes away.
            if paintSubtracts {
                let bar = NSBezierPath()
                let half = min(radius * 0.5, 6)
                bar.move(to: CGPoint(x: pointer.x - half, y: pointer.y))
                bar.line(to: CGPoint(x: pointer.x + half, y: pointer.y))
                bar.lineCapStyle = .round
                bar.lineWidth = 3
                NSColor.black.withAlphaComponent(0.45).setStroke()
                bar.stroke()
                bar.lineWidth = 1.2
                NSColor.white.setStroke()
                bar.stroke()
            }
        }
    }

    private func pin(at point: CGPoint, selected: Bool, hollow: Bool, busy: Bool) {
        let now = CACurrentMediaTime()
        // Busy: pulsing toward red and up to 150 %.
        let pulse = busy ? Self.pulse(at: now) : 0
        let radius = Self.pinRadius * (1 + 0.5 * pulse)
        let base = hollow ? NSColor.clear : (selected ? Accent.color : NSColor.white)
        let path = NSBezierPath(ovalIn: circle(point, radius))
        (busy && !hollow ? (base.blended(withFraction: pulse, of: .systemRed) ?? base) : base).setFill()
        path.fill()
        path.lineWidth = 2
        NSColor.black.withAlphaComponent(0.6).setStroke()
        path.stroke()
        if busy {
            // A dashed ring that turns clockwise while the fill is being made. The ring is drawn counterclockwise (the
            // view isn't flipped, so angles go up counterclockwise), and a growing dash phase carries the dashes back
            // along it: clockwise.
            let ring = NSBezierPath()
            ring.appendArc(withCenter: point, radius: radius + 4, startAngle: 0, endAngle: 360, clockwise: false)
            ring.setLineDash([3, 3], count: 2, phase: CGFloat((now * 12).truncatingRemainder(dividingBy: 6)))
            ring.lineWidth = 3
            NSColor.black.withAlphaComponent(0.45).setStroke()
            ring.stroke()
            ring.lineWidth = 1.5
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
        case nil: return blemish(at: point) == nil ? .crosshair : .pointingHand
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    /// The spot whose pin the pointer is on: its area is shown filled.
    private(set) var hoveredID: UUID? { didSet { if hoveredID != oldValue { needsDisplay = true } } }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        isOptionDown = event.modifierFlags.contains(.option)
        if case .pin(let spot)? = target(at: pointer!) { hoveredID = spot.id } else { hoveredID = nil }
        hoveredBlemish = isHandHeld ? nil : blemish(at: pointer!)?.id
        cursor(at: pointer!).set()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        hoveredID = nil
        hoveredBlemish = nil
        needsDisplay = true
    }

    // MARK: Mouse

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        updateFillAnimation()
        guard window != nil else { return }
        // Watched in the window, not just when this view has the keyboard: Option shows on the Selected card at once.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.isOptionDown = event.modifierFlags.contains(.option) }
            return event
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        moved = false
        isOptionDown = event.modifierFlags.contains(.option)
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
        isOptionDown = event.modifierFlags.contains(.option)
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
        isOptionDown = event.modifierFlags.contains(.option)
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
            } else if isClick, let mark = blemish(at: start) {
                // Only a click: a drag over a mark paints.
                onToggleBlemish?(mark.id)
            } else {
                onStroke?(PhotoAdjustments.BrushStroke(points: points, size: brushSize, feather: mode == .remove ? 0.1 : 0.3, flow: 1, density: 1,
                                                       isErasing: paintSubtracts))
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
