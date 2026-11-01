import AppKit

/// Edits a `ToneCurve`, or Lightroom's parametric curve.
///
/// Point mode: click the graph to add a point (up to 16), drag a point freely, drag it off the graph
/// or double-click it to delete it, and double-click empty space to reset the curve. Parametric mode
/// shows the four regions; drag the dividers between them to move the splits (the region amounts are
/// sliders under the graph).
final class CurveEditorView: NSView {
    var curve = ToneCurve.identity { didSet { needsDisplay = true; updateAccessibility() } }
    var parametric = ParametricCurve() { didSet { needsDisplay = true } }
    var channel = PhotoAdjustments.CurveChannel.rgb { didSet { needsDisplay = true } }
    /// Whether the graph shows the parametric curve (its dividers draggable) instead of the point curve.
    var isParametric = false { didSet { needsDisplay = true; updateAccessibility() } }
    var onChange: ((ToneCurve, Bool) -> Void)?
    var onParametricChange: ((ParametricCurve, Bool) -> Void)?

    private var draggedIndex: Int?
    private var draggedSplit: Int?
    /// While a point is dragged off the graph it is about to be deleted.
    private(set) var isDeleting = false
    private let inset: CGFloat = 6
    /// How far past the graph's edge a point is dragged to delete it.
    private let deleteDistance: CGFloat = 28
    private let handleRadius: CGFloat = 9

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateAccessibility() {
        setAccessibilityLabel(isParametric ? "Parametric curve" : "Tone curve")
        setAccessibilityValue(isParametric ? nil : "\(curve.points.count) points")
        setAccessibilityHelp(isParametric
            ? "Drag the dividers to move the region splits."
            : "Click to add a point, drag to move it, drag it off the graph or double-click it to delete it, double-click empty space to reset.")
    }

    private var plotRect: CGRect { bounds.insetBy(dx: inset, dy: inset) }

    private func location(of point: ToneCurve.Point) -> CGPoint {
        let rect = plotRect
        return CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }

    private func curvePoint(at location: CGPoint) -> ToneCurve.Point {
        let rect = plotRect
        return ToneCurve.Point(
            x: Double((location.x - rect.minX) / rect.width).clamped(to: 0...1),
            y: Double((location.y - rect.minY) / rect.height).clamped(to: 0...1))
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// The curve stands out from the plot (white in dark appearance, as in Lightroom), whatever the channel.
    private var curveColor: NSColor { isDark ? .white : NSColor(white: 0.08, alpha: 1) }

    /// The unchanged diagonal, solid and darker than the curve so it reads under it.
    private var baselineColor: NSColor { isDark ? .black : NSColor(white: 0.5, alpha: 1) }

    /// Lightroom's channel tint: the channel's color at the top left fading to its complement at the bottom right.
    private var channelTint: (NSColor, NSColor)? {
        guard !isParametric else { return nil }
        let alpha: CGFloat = isDark ? 0.3 : 0.22
        switch channel {
        case .rgb: return nil
        case .red: return (NSColor(red: 1, green: 0.15, blue: 0.15, alpha: alpha), NSColor(red: 0, green: 0.85, blue: 0.85, alpha: alpha))
        case .green: return (NSColor(red: 0.15, green: 0.9, blue: 0.15, alpha: alpha), NSColor(red: 0.9, green: 0, blue: 0.9, alpha: alpha))
        case .blue: return (NSColor(red: 0.2, green: 0.35, blue: 1, alpha: alpha), NSColor(red: 0.95, green: 0.9, blue: 0, alpha: alpha))
        }
    }

    private var splits: [Double] { [parametric.shadowSplit, parametric.midtoneSplit, parametric.highlightSplit] }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = plotRect
        let plot = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        (isDark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.86, alpha: 1)).setFill()
        plot.fill()
        if let (start, end) = channelTint {
            NSGradient(starting: start, ending: end)?.draw(in: plot, angle: -45)
        }

        if isParametric {
            // Alternating shading for the four regions.
            let knots = [0] + splits + [1]
            for region in 0..<4 where region % 2 == 0 {
                let shade = CGRect(x: rect.minX + knots[region] * rect.width, y: rect.minY,
                                   width: (knots[region + 1] - knots[region]) * rect.width, height: rect.height)
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                shade.fill()
            }
        }

        let grid = NSBezierPath()
        for i in 1..<4 {
            let fraction = CGFloat(i) / 4
            grid.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
            grid.line(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
            grid.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            grid.line(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
        }
        grid.lineWidth = 0.5
        NSColor.separatorColor.setStroke()
        grid.stroke()

        let diagonal = NSBezierPath()
        diagonal.move(to: CGPoint(x: rect.minX, y: rect.minY))
        diagonal.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
        diagonal.lineWidth = 1
        baselineColor.setStroke()
        diagonal.stroke()

        let path = NSBezierPath()
        let steps = 120
        for step in 0...steps {
            let x = Double(step) / Double(steps)
            let y = isParametric ? parametric.value(at: x) : curve.value(at: x)
            let point = CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
            step == 0 ? path.move(to: point) : path.line(to: point)
        }
        path.lineWidth = 1.5
        curveColor.setStroke()
        path.stroke()

        if isParametric {
            for (index, split) in splits.enumerated() {
                let x = rect.minX + split * rect.width
                let divider = NSBezierPath()
                divider.move(to: CGPoint(x: x, y: rect.minY))
                divider.line(to: CGPoint(x: x, y: rect.maxY))
                divider.lineWidth = draggedSplit == index ? 2 : 1
                Accent.color.withAlphaComponent(0.8).setStroke()
                divider.stroke()
                // A small grip at the bottom.
                let grip = NSBezierPath(roundedRect: CGRect(x: x - 4, y: rect.minY, width: 8, height: 10), xRadius: 2, yRadius: 2)
                Accent.color.setFill()
                grip.fill()
            }
            return
        }

        for (index, point) in curve.points.enumerated() {
            let center = location(of: point)
            let deleting = isDeleting && index == draggedIndex
            let handle = NSBezierPath(ovalIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
            (deleting ? NSColor.systemRed : curveColor).setFill()
            handle.fill()
            baselineColor.setStroke()
            handle.stroke()
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if isParametric {
            draggedSplit = splitIndex(near: location)
            if let draggedSplit { dragSplit(draggedSplit, to: location, isFinal: false) }
            else if event.clickCount == 2 {
                var reset = ParametricCurve()
                reset.shadowSplit = parametric.shadowSplit
                reset.midtoneSplit = parametric.midtoneSplit
                reset.highlightSplit = parametric.highlightSplit
                parametric = reset
                onParametricChange?(parametric, true)
            }
            return
        }
        let hit = pointIndex(near: location)
        if event.clickCount == 2 {
            if let hit {
                if curve.removePoint(hit) { onChange?(curve, true) }
            } else {
                curve = .identity
                onChange?(curve, true)
            }
            return
        }
        if let hit {
            draggedIndex = hit
        } else if plotRect.insetBy(dx: -inset, dy: -inset).contains(location) {
            let point = curvePoint(at: location)
            draggedIndex = curve.addPoint(x: point.x, y: point.y)
            if draggedIndex != nil { onChange?(curve, false) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if let draggedSplit {
            dragSplit(draggedSplit, to: location, isFinal: false)
        } else {
            dragPoint(to: location, isFinal: false)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if let draggedSplit {
            dragSplit(draggedSplit, to: location, isFinal: true)
            self.draggedSplit = nil
        } else {
            dragPoint(to: location, isFinal: true)
            draggedIndex = nil
            isDeleting = false
        }
        needsDisplay = true
    }

    private func pointIndex(near location: CGPoint) -> Int? {
        curve.points.indices
            .map { ($0, hypot(self.location(of: curve.points[$0]).x - location.x, self.location(of: curve.points[$0]).y - location.y)) }
            .filter { $0.1 <= handleRadius }
            .min { $0.1 < $1.1 }?.0
    }

    private func splitIndex(near location: CGPoint) -> Int? {
        let rect = plotRect
        return splits.indices
            .map { ($0, abs(rect.minX + splits[$0] * rect.width - location.x)) }
            .filter { $0.1 <= handleRadius }
            .min { $0.1 < $1.1 }?.0
    }

    private func dragPoint(to location: CGPoint, isFinal: Bool) {
        guard let index = draggedIndex, curve.points.indices.contains(index) else { return }
        let rect = plotRect
        let outside = location.x < rect.minX - deleteDistance || location.x > rect.maxX + deleteDistance
            || location.y < rect.minY - deleteDistance || location.y > rect.maxY + deleteDistance
        isDeleting = outside && curve.canRemovePoint
        if isDeleting {
            // The point stays where it was until the mouse is released.
            if isFinal, curve.removePoint(index) { onChange?(curve, true) }
            needsDisplay = true
            return
        }
        let point = curvePoint(at: location)
        curve.movePoint(index, toX: point.x, y: point.y)
        onChange?(curve, isFinal)
    }

    private func dragSplit(_ index: Int, to location: CGPoint, isFinal: Bool) {
        let rect = plotRect
        parametric.setSplit(index, to: Double((location.x - rect.minX) / rect.width))
        onParametricChange?(parametric, isFinal)
    }
}
