import AppKit

/// The selected mask's shapes drawn over the Develop preview, with handles to drag: a linear
/// gradient's zero and full lines (and the band between), a radial gradient's edge, feather and
/// rotation handle.
final class MaskOverlayView: NSView {
    /// The photo's frame in view points.
    var frameRect = CGRect.zero { didSet { needsDisplay = true } }
    var adjustment: PhotoAdjustments.LocalAdjustment? { didSet { needsDisplay = true } }
    /// Called with the adjustment while a handle is dragged (`isFinal` on mouse up).
    var onChange: ((PhotoAdjustments.LocalAdjustment, Bool) -> Void)?
    /// A click on empty space (to pick another mask or clear the selection).
    var onClickEmpty: (() -> Void)?

    private enum Drag {
        case linear(component: Int, handle: MaskGeometry.LinearHandle, start: CGPoint, original: PhotoAdjustments.LinearGradient)
        case radial(component: Int, handle: MaskGeometry.RadialHandle, start: CGPoint, original: PhotoAdjustments.RadialGradient)
    }

    private var drag: Drag?
    private static let hitTolerance: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Mask handles")
        setAccessibilityIdentifier("maskOverlay")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Points in the frame (pixels of `frameRect`) from view points.
    private func framePoint(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - frameRect.minX, y: point.y - frameRect.minY) }
    private func viewPoint(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + frameRect.minX, y: point.y + frameRect.minY) }

    override func draw(_ dirtyRect: NSRect) {
        guard let adjustment, adjustment.isEnabled, frameRect.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: frameRect).addClip()
        for component in adjustment.components {
            switch component.shape {
            case .linear(let gradient): drawLinear(gradient)
            case .radial(let ellipse): drawRadial(ellipse)
            }
        }
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

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = framePoint(convert(event.locationInWindow, from: nil))
        guard let adjustment else { onClickEmpty?(); return }
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
            }
        }
        onClickEmpty?()
    }

    override func mouseDragged(with event: NSEvent) { update(with: event, isFinal: false) }
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
        }
        self.adjustment = adjustment
        onChange?(adjustment, isFinal)
    }
}
