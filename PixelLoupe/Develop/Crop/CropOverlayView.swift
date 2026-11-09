import AppKit

/// The crop rectangle drawn over the Develop preview while Crop & Straighten is active.
///
/// Drag a corner or edge to resize (keeping the aspect when locked), drag inside to move the crop,
/// and drag outside to rotate, as in Lightroom. With the straighten tool on, drag along a line that
/// should be level.
final class CropOverlayView: NSView {
    /// The photo's frame (its full size before cropping) in view points.
    var frameRect = CGRect.zero { didSet { needsDisplay = true } }
    var imageSize = CGSize(width: 1, height: 1)
    var crop = PhotoAdjustments.Crop() { didSet { needsDisplay = true } }
    var toolOverlay = CropPanelViewController.ToolOverlay.auto { didSet { needsDisplay = true } }
    var guideOverlay = CropGuideOverlay.default { didSet { needsDisplay = true } }
    /// The guide's ⇧O orientation (see ``CropGuideOverlay/orientationCount``).
    var guideOrientation = 0 { didSet { needsDisplay = true } }
    /// The Grid guide's cells across the long side (⌥-scroll).
    var gridCells = CropGuideOverlay.defaultGridCells { didSet { needsDisplay = true } }
    /// Called when ⌥-scroll changes the grid's density.
    var onGridCellsChange: (Int) -> Void = { _ in }
    private var gridScroll: Double = 0
    /// The ratios the Aspect Ratios guide outlines.
    var aspectRatios = Set(CropGuideOverlay.AspectRatio.allCases) { didSet { needsDisplay = true } }
    /// The guide's name, shown briefly after O changes it.
    private(set) var flashedName: String?
    private var flashGeneration = 0
    var isStraightening = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    var onChange: (_ crop: PhotoAdjustments.Crop, _ isFinal: Bool) -> Void = { _, _ in }
    /// Called with the angle change that levels a line drawn with the straighten tool.
    var onStraighten: (Double) -> Void = { _ in }

    private enum Drag {
        case resize(Handle, start: CGRect, startPoint: CGPoint)
        case move(start: CGRect, startPoint: CGPoint)
        case rotate(startAngle: Double, startPoint: CGPoint)
        case straighten(start: CGPoint, end: CGPoint)
    }

    enum Handle: CaseIterable {
        case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left

        var movesMinX: Bool { [.bottomLeft, .topLeft, .left].contains(self) }
        var movesMaxX: Bool { [.bottomRight, .topRight, .right].contains(self) }
        var movesMinY: Bool { [.bottomLeft, .bottomRight, .bottom].contains(self) }
        var movesMaxY: Bool { [.topLeft, .topRight, .top].contains(self) }
        var isCorner: Bool { [.bottomLeft, .bottomRight, .topLeft, .topRight].contains(self) }
    }

    private var drag: Drag?
    private static let handleHitRadius: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Crop")
        setAccessibilityIdentifier("cropOverlay")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Geometry

    /// The crop rectangle in view points.
    var cropRectInView: CGRect {
        CGRect(
            x: frameRect.minX + crop.rect.minX * frameRect.width,
            y: frameRect.minY + crop.rect.minY * frameRect.height,
            width: crop.rect.width * frameRect.width,
            height: crop.rect.height * frameRect.height
        )
    }

    private func point(for handle: Handle, in rect: CGRect) -> CGPoint {
        let x = handle.movesMinX ? rect.minX : handle.movesMaxX ? rect.maxX : rect.midX
        let y = handle.movesMinY ? rect.minY : handle.movesMaxY ? rect.maxY : rect.midY
        return CGPoint(x: x, y: y)
    }

    func handle(at point: CGPoint) -> Handle? {
        let rect = cropRectInView
        return Handle.allCases
            .map { ($0, hypot(self.point(for: $0, in: rect).x - point.x, self.point(for: $0, in: rect).y - point.y)) }
            .filter { $0.1 <= Self.handleHitRadius }
            .min { $0.1 < $1.1 }?.0
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !frameRect.isEmpty else { return }
        let rect = cropRectInView

        // Dim everything outside the crop.
        let shade = NSBezierPath(rect: bounds)
        shade.append(NSBezierPath(rect: rect).reversed)
        NSColor.black.withAlphaComponent(0.55).setFill()
        shade.fill()

        if showsGuide {
            let guide = NSBezierPath()
            for segment in guideOverlay.segments(in: rect, orientation: guideOrientation, gridCells: gridCells) {
                guide.move(to: segment.start)
                guide.line(to: segment.end)
            }
            for curve in guideOverlay.curves(in: rect, orientation: guideOrientation) {
                guard let first = curve.first else { continue }
                guide.move(to: first)
                for point in curve.dropFirst() { guide.line(to: point) }
            }
            let boxes = guideOverlay == .aspectRatios ? CropGuideOverlay.aspectBoxes(in: rect, showing: aspectRatios) : []
            for box in boxes { guide.append(NSBezierPath(rect: box.rect)) }
            strokeGuide(guide)
            drawAspectLabels(boxes, in: rect)
        }

        let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        NSColor.white.setStroke()
        border.stroke()

        // Handles: short ticks at the corners and edge midpoints, like Lightroom's.
        let tick: CGFloat = 12
        let handles = NSBezierPath()
        for handle in Handle.allCases {
            let p = point(for: handle, in: rect)
            if handle.isCorner {
                let dx: CGFloat = handle.movesMinX ? tick : -tick
                let dy: CGFloat = handle.movesMinY ? tick : -tick
                handles.move(to: CGPoint(x: p.x + dx, y: p.y))
                handles.line(to: p)
                handles.line(to: CGPoint(x: p.x, y: p.y + dy))
            } else if handle == .top || handle == .bottom {
                handles.move(to: CGPoint(x: p.x - tick / 2, y: p.y))
                handles.line(to: CGPoint(x: p.x + tick / 2, y: p.y))
            } else {
                handles.move(to: CGPoint(x: p.x, y: p.y - tick / 2))
                handles.line(to: CGPoint(x: p.x, y: p.y + tick / 2))
            }
        }
        handles.lineWidth = 3
        handles.stroke()

        if case .straighten(let start, let end) = drag {
            let line = NSBezierPath()
            line.move(to: start)
            line.line(to: end)
            line.lineWidth = 1.5
            line.setLineDash([6, 3], count: 2, phase: 0)
            NSColor.white.setStroke()
            line.stroke()
            for p in [start, end] {
                NSBezierPath(ovalIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
            }
        }

        if let flashedName { drawName(flashedName, in: rect) }
    }

    /// Strokes guide lines like Lightroom's: 2 pixels of white with 2 pixels of half-black on each side,
    /// so they stand out on light and dark photos alike.
    private func strokeGuide(_ path: NSBezierPath) {
        let pixel = 1 / max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1, 1)
        path.lineJoinStyle = .round
        path.lineWidth = 6 * pixel
        NSColor.black.withAlphaComponent(0.5).setStroke()
        path.stroke()
        path.lineWidth = 2 * pixel
        NSColor.white.setStroke()
        path.stroke()
    }

    /// Whether the guide shows: always, never, or (Auto) while dragging and just after O changes it.
    var showsGuide: Bool {
        switch toolOverlay {
        case .always: true
        case .never: false
        case .auto: drag != nil || flashedName != nil
        }
    }

    /// Shows the guide's name (or other text) for a second, centred near the top of the crop.
    func flashGuideName(_ text: String? = nil) {
        flashGeneration += 1
        let generation = flashGeneration
        let text = text ?? guideOverlay.title
        flashedName = text
        setAccessibilityValue(text)
        needsDisplay = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, flashGeneration == generation else { return }
            flashedName = nil
            needsDisplay = true
        }
    }

    /// Labels each box on one of its inner edges, stepped so neighbouring labels don't overlap, like
    /// Lightroom's.
    private func drawAspectLabels(_ boxes: [CropGuideOverlay.AspectBox], in rect: CGRect) {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        for (index, box) in boxes.enumerated() {
            let text = NSAttributedString(string: box.aspect.title, attributes: [.font: font, .foregroundColor: NSColor.white])
            let size = text.size()
            let step = CGFloat(index) * (size.height + 10)
            // Narrower than the crop: on the box's left side; shorter: on its top.
            let origin = box.rect.width < rect.width - 1
                ? CGPoint(x: box.rect.minX - size.width / 2, y: rect.maxY - 28 - size.height - step)
                : CGPoint(x: rect.minX + 28 + step * 3, y: box.rect.maxY - size.height / 2)
            let badge = CGRect(origin: origin, size: size).insetBy(dx: -4, dy: -2)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
            text.draw(at: origin)
        }
    }

    private func drawName(_ name: String, in rect: CGRect) {
        let text = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        let badge = CGRect(x: rect.midX - size.width / 2 - 10, y: rect.maxY - size.height - 20,
                           width: size.width + 20, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
        text.draw(at: CGPoint(x: badge.minX + 10, y: badge.minY + 4))
    }

    // MARK: - Scrolling

    /// ⌥ and two fingers up or down: a finer or coarser Grid guide, as in Lightroom. Anything else
    /// scrolls as usual.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.option), guideOverlay == .grid, showsGuideForScrolling else {
            super.scrollWheel(with: event)
            return
        }
        if event.phase == .began { gridScroll = 0 }
        var vertical = Double(event.scrollingDeltaY)
        // ⌥ doesn't turn a wheel sideways, but ⇧ might be held too.
        if vertical == 0 { vertical = Double(event.scrollingDeltaX) }
        // Lines from a wheel, points from a trackpad.
        if !event.hasPreciseScrollingDeltas { vertical *= Self.scrollPointsPerCell }
        // Fingers moving up, whichever way the system scrolls.
        gridScroll += event.isDirectionInvertedFromDevice ? -vertical : vertical
        let steps = Int((gridScroll / Self.scrollPointsPerCell).rounded(.towardZero))
        guard steps != 0 else { return }
        gridScroll -= Double(steps) * Self.scrollPointsPerCell
        let cells = (gridCells + steps).clamped(to: CropGuideOverlay.gridCellRange)
        guard cells != gridCells else { return }
        gridCells = cells
        onGridCellsChange(cells)
        flashGuideName("Grid: \(cells) across")
    }

    private static let scrollPointsPerCell = 8.0

    /// The Grid guide changes size only when it can be seen (or would be, with Auto).
    private var showsGuideForScrolling: Bool { toolOverlay != .never }

    // MARK: - Cursors

    override func resetCursorRects() {
        guard !frameRect.isEmpty else { return }
        if isStraightening {
            addCursorRect(bounds, cursor: .crosshair)
            return
        }
        let rect = cropRectInView
        addCursorRect(bounds, cursor: .arrow)
        addCursorRect(rect.insetBy(dx: Self.handleHitRadius, dy: Self.handleHitRadius), cursor: .openHand)
        for handle in Handle.allCases {
            let p = point(for: handle, in: rect)
            let r = Self.handleHitRadius
            let position: NSCursor.FrameResizePosition = switch handle {
            case .bottomLeft: .bottomLeft
            case .bottom: .bottom
            case .bottomRight: .bottomRight
            case .right: .right
            case .topRight: .topRight
            case .top: .top
            case .topLeft: .topLeft
            case .left: .left
            }
            addCursorRect(CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2),
                          cursor: .frameResize(position: position, directions: .all))
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if isStraightening {
            drag = .straighten(start: p, end: p)
        } else if let handle = handle(at: p) {
            drag = .resize(handle, start: crop.rect, startPoint: p)
        } else if cropRectInView.contains(p) {
            drag = .move(start: crop.rect, startPoint: p)
            NSCursor.closedHand.set()
        } else {
            drag = .rotate(startAngle: crop.angle, startPoint: p)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let drag, frameRect.width > 0, frameRect.height > 0 else { return }
        var crop = crop
        switch drag {
        case .resize(let handle, let start, let startPoint):
            let delta = CGVector(dx: (p.x - startPoint.x) / frameRect.width, dy: (p.y - startPoint.y) / frameRect.height)
            if crop.isAspectLocked {
                crop.rect = constrained(resized(start, handle: handle, by: delta), from: start)
            } else {
                // Free-form: as with moving, settle each axis on its own so a side already at an edge
                // doesn't stop the other side from following the pointer.
                let horizontal = constrained(resized(start, handle: handle, by: CGVector(dx: delta.dx, dy: 0)), from: start)
                crop.rect = constrained(resized(horizontal, handle: handle, by: CGVector(dx: 0, dy: delta.dy)), from: horizontal)
            }
        case .move(let start, let startPoint):
            crop.rect = moved(start, by: CGVector(dx: (p.x - startPoint.x) / frameRect.width, dy: (p.y - startPoint.y) / frameRect.height))
        case .rotate(let startAngle, let startPoint):
            let center = CGPoint(x: frameRect.midX, y: frameRect.midY)
            let turn = (atan2(p.y - center.y, p.x - center.x) - atan2(startPoint.y - center.y, startPoint.x - center.x)) * 180 / .pi
            crop.angle = ((startAngle + turn) * 100).rounded() / 100
            crop.angle = crop.angle.clamped(to: CropGeometry.angleRange)
            if crop.constrainToImage { crop.rect = CropGeometry.fit(crop.rect, angle: crop.angle, imageSize: imageSize) }
        case .straighten(let start, _):
            self.drag = .straighten(start: start, end: p)
            needsDisplay = true
            return
        }
        self.crop = crop
        onChange(crop, false)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
        if case .straighten(let start, let end) = drag {
            // Measure the line in photo pixels (the frame may be scaled non-uniformly on screen).
            let sx = imageSize.width / max(frameRect.width, 1), sy = imageSize.height / max(frameRect.height, 1)
            if let turn = CropGeometry.straighteningAngle(
                from: CGPoint(x: start.x * sx, y: start.y * sy), to: CGPoint(x: end.x * sx, y: end.y * sy)
            ) {
                onStraighten(turn)
            }
            return
        }
        if drag != nil { onChange(crop, true) }
    }

    // MARK: - Resizing

    private func resized(_ start: CGRect, handle: Handle, by delta: CGVector) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if handle.movesMinX { minX = min(minX + delta.dx, maxX - CropGeometry.minimumSize) }
        if handle.movesMaxX { maxX = max(maxX + delta.dx, minX + CropGeometry.minimumSize) }
        if handle.movesMinY { minY = min(minY + delta.dy, maxY - CropGeometry.minimumSize) }
        if handle.movesMaxY { maxY = max(maxY + delta.dy, minY + CropGeometry.minimumSize) }
        var rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        guard crop.isAspectLocked, let ratio = crop.aspect.landscapeRatio(imageSize: imageSize) ?? lockedRatio(of: start) else {
            return rect
        }
        let portrait = CropGeometry.isPortrait(start, imageSize: imageSize)
        let pixelRatio = portrait ? 1 / ratio : ratio
        let frameRatio = imageSize.width / imageSize.height
        let unitRatio = CGFloat(pixelRatio) / frameRatio
        if handle.isCorner {
            let anchor = CGPoint(x: handle.movesMinX ? start.maxX : start.minX, y: handle.movesMinY ? start.maxY : start.minY)
            rect = CropGeometry.constrain(rect, toPixelRatio: pixelRatio, imageSize: imageSize, anchor: anchor)
            // Keep the anchored corner fixed.
            rect.origin.x = handle.movesMinX ? anchor.x - rect.width : anchor.x
            rect.origin.y = handle.movesMinY ? anchor.y - rect.height : anchor.y
        } else if handle == .left || handle == .right {
            let height = rect.width / unitRatio
            rect = CGRect(x: rect.minX, y: start.midY - height / 2, width: rect.width, height: height)
        } else {
            let width = rect.height * unitRatio
            rect = CGRect(x: start.midX - width / 2, y: rect.minY, width: width, height: rect.height)
        }
        return rect
    }

    /// `start` moved by `delta`, sliding along an edge it can't cross. Each axis is settled on its own: a
    /// crop that already touches an edge (any preset that fills the photo's height or width) would
    /// otherwise not move at all, since any drag with even a little motion toward that edge is invalid as
    /// a whole and ``constrained(_:from:)`` would scale the whole move back to nothing.
    func moved(_ start: CGRect, by delta: CGVector) -> CGRect {
        let horizontal = constrained(start.offsetBy(dx: delta.dx, dy: 0), from: start)
        let rect = constrained(horizontal.offsetBy(dx: 0, dy: delta.dy), from: horizontal)
        // Validity allows a hair past the frame; land exactly on it.
        return CGRect(
            x: rect.minX.clamped(to: 0...max(0, 1 - rect.width)), y: rect.minY.clamped(to: 0...max(0, 1 - rect.height)),
            width: rect.width, height: rect.height
        )
    }

    /// A locked Custom aspect keeps whatever ratio the crop had.
    private func lockedRatio(of rect: CGRect) -> Double? {
        let ratio = Double(rect.width * imageSize.width / max(rect.height * imageSize.height, 1))
        return max(ratio, 1 / ratio)
    }

    /// Accepts `candidate` if it's valid (inside the frame, and inside the photo when constrained);
    /// otherwise moves as far toward it from `start` as stays valid.
    private func constrained(_ candidate: CGRect, from start: CGRect) -> CGRect {
        func isValid(_ rect: CGRect) -> Bool {
            rect.minX >= -0.0001 && rect.minY >= -0.0001 && rect.maxX <= 1.0001 && rect.maxY <= 1.0001
                && rect.width >= CropGeometry.minimumSize && rect.height >= CropGeometry.minimumSize
                && (!crop.constrainToImage || CropGeometry.isInsidePhoto(rect, angle: crop.angle, imageSize: imageSize))
        }
        if isValid(candidate) { return candidate }
        var low: CGFloat = 0, high: CGFloat = 1
        for _ in 0..<20 {
            let t = (low + high) / 2
            let rect = CGRect(
                x: start.minX + (candidate.minX - start.minX) * t, y: start.minY + (candidate.minY - start.minY) * t,
                width: start.width + (candidate.width - start.width) * t, height: start.height + (candidate.height - start.height) * t
            )
            if isValid(rect) { low = t } else { high = t }
        }
        let t = low
        return CGRect(
            x: start.minX + (candidate.minX - start.minX) * t, y: start.minY + (candidate.minY - start.minY) * t,
            width: start.width + (candidate.width - start.width) * t, height: start.height + (candidate.height - start.height) * t
        )
    }
}
