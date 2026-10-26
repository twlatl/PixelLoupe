import AppKit

/// The selected mask's shapes drawn over the Develop preview, with handles to drag: a linear
/// gradient's zero and full lines (and the band between), a radial gradient's edge, feather and
/// rotation handle. On a brush mask, dragging paints (⌥-dragging erases) and the pointer shows the brush; on a
/// Subject or Background mask, the brush refines it (adds, or with ⌥ takes away).
final class MaskOverlayView: NSView {
    /// The photo's frame in view points.
    var frameRect = CGRect.zero { didSet { needsDisplay = true } }
    var adjustment: PhotoAdjustments.LocalAdjustment? { didSet { needsDisplay = true } }
    /// Called with the adjustment while a handle is dragged or a stroke painted (`isFinal` on mouse up).
    var onChange: ((_ adjustment: PhotoAdjustments.LocalAdjustment, _ isFinal: Bool, _ actionName: String) -> Void)?
    /// What the next brush stroke is painted with.
    var brush = MaskGeometry.BrushSettings() { didSet { needsDisplay = true } }
    /// A click on empty space (to pick another mask or clear the selection).
    var onClickEmpty: (() -> Void)?

    private enum Drag {
        case linear(component: Int, handle: MaskGeometry.LinearHandle, start: CGPoint, original: PhotoAdjustments.LinearGradient)
        case radial(component: Int, handle: MaskGeometry.RadialHandle, start: CGPoint, original: PhotoAdjustments.RadialGradient)
        case brush(component: Int)
        /// Refining a Subject or Background mask; `last` is the stroke's last point.
        case refine(last: PhotoAdjustments.UnitPoint, isErasing: Bool)
    }

    private var drag: Drag?
    /// The pointer over the view (view points), for drawing the brush.
    private var pointer: CGPoint?
    private var flagsMonitor: Any?
    private static let hitTolerance: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Mask handles")
        setAccessibilityIdentifier("maskOverlay")
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Points in the frame (pixels of `frameRect`) from view points.
    private func framePoint(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - frameRect.minX, y: point.y - frameRect.minY) }
    private func viewPoint(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + frameRect.minX, y: point.y + frameRect.minY) }

    /// The brush the selected mask paints into: its last brush shape (not on a Subject or Background mask,
    /// which the brush refines instead).
    private var brushComponent: Int? {
        guard let adjustment, !adjustment.usesSubject else { return nil }
        return adjustment.components.lastIndex(where: \.shape.isBrush)
    }

    /// Whether dragging paints: on a brush mask, or a Subject or Background mask the brush refines.
    private var paints: Bool { brushComponent != nil || adjustment?.usesSubject == true }

    override func draw(_ dirtyRect: NSRect) {
        guard let adjustment, frameRect.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: frameRect).addClip()
        if adjustment.isEnabled {
            for component in adjustment.components {
                switch component.shape {
                case .linear(let gradient): drawLinear(gradient)
                case .radial(let ellipse): drawRadial(ellipse)
                case .brush, .subject, .background: break   // Shown by the red overlay (O).
                }
            }
        }
        if paints, let pointer, frameRect.contains(pointer) { drawBrush(at: pointer) }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func stroke(_ path: NSBezierPath, dashed: Bool = false) {
        path.lineWidth = 3
        NSColor.black.withAlphaComponent(0.5).setStroke()
        path.stroke()
        path.lineWidth = 1.2
        if dashed { path.setLineDash([5, 4], count: 2, phase: 0) }
        NSColor.white.setStroke()
        path.stroke()
    }

    private func handleDot(at point: CGPoint) {
        let rect = CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.black.withAlphaComponent(0.6).setStroke()
        NSBezierPath(ovalIn: rect).stroke()
    }

    private func drawLinear(_ gradient: PhotoAdjustments.LinearGradient) {
        let lines = MaskGeometry.lines(of: gradient, frame: frameRect.size)
        for (index, line) in [lines.zero, lines.full].enumerated() {
            let path = NSBezierPath()
            path.move(to: viewPoint(line.0))
            path.line(to: viewPoint(line.1))
            stroke(path, dashed: index == 0)
        }
        // The middle of the band, with a handle where the gradient's axis crosses it.
        let mid = CGPoint(x: (gradient.zero.x + gradient.full.x) / 2 * frameRect.width, y: (gradient.zero.y + gradient.full.y) / 2 * frameRect.height)
        handleDot(at: viewPoint(mid))
    }

    private func drawRadial(_ ellipse: PhotoAdjustments.RadialGradient) {
        let center = MaskGeometry.position(of: .center, in: ellipse, frame: frameRect.size)
        let rx = ellipse.radiusX * frameRect.width, ry = ellipse.radiusY * frameRect.height
        func ellipsePath(_ scale: Double) -> NSBezierPath {
            let path = NSBezierPath(ovalIn: CGRect(x: -rx * scale, y: -ry * scale, width: 2 * rx * scale, height: 2 * ry * scale))
            var transform = AffineTransform(translationByX: frameRect.minX + center.x, byY: frameRect.minY + center.y)
            transform.rotate(byDegrees: ellipse.angle)
            path.transform(using: transform)
            return path
        }
        stroke(ellipsePath(1))
        stroke(ellipsePath(max(0.02, 1 - ellipse.feather)), dashed: true)
        for handle: MaskGeometry.RadialHandle in [.center, .right, .left, .top, .bottom, .rotate] {
            handleDot(at: viewPoint(MaskGeometry.position(of: handle, in: ellipse, frame: frameRect.size)))
        }
    }

    /// The brush's edge, a dashed circle where its feather starts, and a minus while ⌥ erases.
    private func drawBrush(at point: CGPoint) {
        let radius = max(MaskGeometry.brushRadius(brush.size, frame: frameRect.size), 2)
        func circle(_ r: CGFloat) -> NSBezierPath { NSBezierPath(ovalIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)) }
        stroke(circle(radius))
        let core = radius * (1 - brush.feather)
        if brush.feather > 0, core > 1 { stroke(circle(core), dashed: true) }
        let mark = NSBezierPath()
        mark.move(to: CGPoint(x: point.x - 4, y: point.y))
        mark.line(to: CGPoint(x: point.x + 4, y: point.y))
        if !isErasing {
            mark.move(to: CGPoint(x: point.x, y: point.y - 4))
            mark.line(to: CGPoint(x: point.x, y: point.y + 4))
        }
        stroke(mark)
    }

    private var isErasing: Bool { NSEvent.modifierFlags.contains(.option) }

    // MARK: - Pointer

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        guard window != nil else { return }
        // ⌥ switches the brush between painting and erasing; redraw its mark.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, self.paints, self.pointer != nil { self.needsDisplay = true }
            }
            return event
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if paints { NSCursor.crosshair.set() } else { super.cursorUpdate(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        if paints { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        needsDisplay = true
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = framePoint(convert(event.locationInWindow, from: nil))
        guard var adjustment else { onClickEmpty?(); return }
        if adjustment.usesSubject {
            let erasing = event.modifierFlags.contains(.option)
            let start = MaskGeometry.unitPoint(point, frame: frameRect.size)
            adjustment.beginRefinement(brush.stroke(at: start, erasing: erasing))
            drag = .refine(last: start, isErasing: erasing)
            self.adjustment = adjustment
            onChange?(adjustment, false, erasing ? "Erase" : "Brush Stroke")
            return
        }
        if let index = brushComponent, case .brush(var brush) = adjustment.components[index].shape {
            brush.strokes.append(self.brush.stroke(at: MaskGeometry.unitPoint(point, frame: frameRect.size), erasing: event.modifierFlags.contains(.option)))
            adjustment.components[index].shape = .brush(brush)
            drag = .brush(component: index)
            self.adjustment = adjustment
            onChange?(adjustment, false, strokeActionName(brush))
            return
        }
        // The last component is on top.
        for index in adjustment.components.indices.reversed() {
            switch adjustment.components[index].shape {
            case .linear(let gradient):
                if let handle = MaskGeometry.linearHandle(at: point, gradient: gradient, frame: frameRect.size, tolerance: Self.hitTolerance) {
                    drag = .linear(component: index, handle: handle, start: point, original: gradient)
                    return
                }
            case .radial(let ellipse):
                if let handle = MaskGeometry.radialHandle(at: point, ellipse: ellipse, frame: frameRect.size, tolerance: Self.hitTolerance) {
                    drag = .radial(component: index, handle: handle, start: point, original: ellipse)
                    return
                }
            case .brush, .subject, .background:
                break
            }
        }
        onClickEmpty?()
    }

    override func mouseDragged(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        update(with: event, isFinal: false)
    }
    override func mouseUp(with event: NSEvent) {
        update(with: event, isFinal: true)
        drag = nil
    }

    private func update(with event: NSEvent, isFinal: Bool) {
        guard var adjustment, let drag else { return }
        let point = framePoint(convert(event.locationInWindow, from: nil))
        switch drag {
        case .linear(let component, let handle, let start, let original):
            let moved = MaskGeometry.dragLinear(handle, gradient: original, by: CGPoint(x: point.x - start.x, y: point.y - start.y), frame: frameRect.size)
            adjustment.components[component].shape = .linear(moved)
        case .radial(let component, let handle, let start, let original):
            let moved = MaskGeometry.dragRadial(handle, ellipse: original, to: point, from: start, frame: frameRect.size)
            adjustment.components[component].shape = .radial(moved)
        case .brush(let component):
            guard case .brush(var brush) = adjustment.components[component].shape, var stroke = brush.strokes.popLast() else { return }
            let next = MaskGeometry.unitPoint(point, frame: frameRect.size)
            // A point every couple of pixels is plenty: the dabs are spaced along the line between them.
            if let last = stroke.points.last,
               hypot((next.x - last.x) * frameRect.width, (next.y - last.y) * frameRect.height) >= 2 {
                stroke.points.append(next)
            }
            brush.strokes.append(stroke)
            adjustment.components[component].shape = .brush(brush)
            self.adjustment = adjustment
            onChange?(adjustment, isFinal, strokeActionName(brush))
            return
        case .refine(let last, let isErasing):
            let next = MaskGeometry.unitPoint(point, frame: frameRect.size)
            if hypot((next.x - last.x) * frameRect.width, (next.y - last.y) * frameRect.height) >= 2 {
                adjustment.extendRefinement(to: next)
                self.drag = .refine(last: next, isErasing: isErasing)
            }
            self.adjustment = adjustment
            onChange?(adjustment, isFinal, isErasing ? "Erase" : "Brush Stroke")
            return
        }
        self.adjustment = adjustment
        onChange?(adjustment, isFinal, "Move Mask")
    }

    private func strokeActionName(_ brush: PhotoAdjustments.BrushMask) -> String {
        brush.strokes.last?.isErasing == true ? "Erase" : "Brush Stroke"
    }
}
