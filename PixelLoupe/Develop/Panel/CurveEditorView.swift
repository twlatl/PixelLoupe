import AppKit

/// Edits a `ToneCurve`, or Lightroom's parametric curve.
///
/// Point mode: click the graph to add a point (up to 16), drag a point freely, drag it off the graph
/// or double-click it to delete it, and double-click empty space to reset the curve. The last point clicked
/// or dragged is selected, for the Input and Output fields; hovering shows the input and output under the
/// pointer in the graph's corner. Parametric mode shows the four regions: drag up or down in one to change
/// its amount, as in Lightroom; hovering names the region and shades how far it can move the curve. (The
/// splits between regions are on a ``ParametricSplitBar`` under the graph.)
final class CurveEditorView: NSView {
    var curve = ToneCurve.identity {
        didSet {
            if let selectedIndex, !curve.points.indices.contains(selectedIndex) { self.selectedIndex = nil }
            needsDisplay = true
            updateAccessibility()
        }
    }
    var parametric = ParametricCurve() { didSet { needsDisplay = true } }
    var channel = PhotoAdjustments.CurveChannel.rgb {
        didSet {
            if channel != oldValue { selectedIndex = nil }
            needsDisplay = true
            histogramHeights = nil
        }
    }
    /// Whether the graph shows the parametric curve (its dividers draggable) instead of the point curve.
    var isParametric = false {
        didSet {
            if isParametric { selectedIndex = nil }
            updateHighlightedRegion()
            needsDisplay = true
            histogramHeights = nil
            updateAccessibility()
        }
    }
    /// The photo's histogram as drawn, shown behind the curve.
    var histogram: Histogram? {
        didSet {
            guard histogram != oldValue else { return }
            histogramHeights = nil
            needsDisplay = true
        }
    }
    /// The histogram's bins for the current mode as 0…1, worked out once per histogram and mode.
    private var histogramHeights: [Double]?
    var onChange: ((ToneCurve, Bool) -> Void)?
    var onParametricChange: ((ParametricCurve, Bool) -> Void)?
    /// The selection changed, or the selected point moved.
    var onSelectionChange: (() -> Void)?

    /// The point the Input and Output fields show: the one last clicked, added or dragged.
    private(set) var selectedIndex: Int? {
        didSet {
            guard selectedIndex != oldValue else { return }
            needsDisplay = true
            onSelectionChange?()
        }
    }
    var selectedPoint: ToneCurve.Point? { selectedIndex.map { curve.points[$0] } }
    /// Where the pointer is over the graph, for the readout in its corner.
    private var hoverLocation: CGPoint? { didSet { needsDisplay = true; updateHighlightedRegion() } }
    /// The parametric region being dragged: its index, its amount and the pointer's height when the drag began.
    private var draggedRegion: (index: Int, startAmount: Double, startY: CGFloat)?
    private var regionDidMove = false
    /// The parametric region being dragged, or under the pointer.
    private(set) var highlightedRegion: Int? {
        didSet {
            guard highlightedRegion != oldValue else { return }
            needsDisplay = true
            onHighlightRegion?(highlightedRegion)
        }
    }
    /// Which region's slider to emphasize, if any.
    var onHighlightRegion: ((Int?) -> Void)?

    private var draggedIndex: Int?
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
            ? "Drag up or down in a region to change its amount; double-click to reset the four regions."
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

    private var splits: [Double] { parametric.splits }

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
        drawHistogram(in: rect, clippedTo: plot)

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

        if isParametric, let region = highlightedRegion { drawRange(of: region, in: rect, clippedTo: plot) }

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
            if let region = highlightedRegion { drawRegionLabel(region, in: rect) }
            return
        }

        drawReadout(in: rect)
        for (index, point) in curve.points.enumerated() {
            let center = location(of: point)
            let deleting = isDeleting && index == draggedIndex
            let radius: CGFloat = index == selectedIndex ? 5 : 4
            let handle = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            (deleting ? NSColor.systemRed : curveColor).setFill()
            handle.fill()
            baselineColor.setStroke()
            handle.stroke()
        }
    }

    /// The channel's histogram in R, G or B; the three added together (a gray histogram) for the point
    /// and parametric curves.
    static func histogramHeights(_ histogram: Histogram, channel: PhotoAdjustments.CurveChannel?) -> [Double] {
        let counts: [UInt32] = switch channel {
        case .red: histogram.red
        case .green: histogram.green
        case .blue: histogram.blue
        case .rgb, nil: (0..<Histogram.binCount).map { histogram.red[$0] &+ histogram.green[$0] &+ histogram.blue[$0] }
        }
        return Histogram.normalizedHeights([counts])[0]
    }

    private func drawHistogram(in rect: CGRect, clippedTo plot: NSBezierPath) {
        guard let histogram else { return }
        let heights = histogramHeights ?? Self.histogramHeights(histogram, channel: isParametric ? nil : channel)
        histogramHeights = heights
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        for (bin, height) in heights.enumerated() {
            let x = rect.minX + CGFloat(bin) / CGFloat(heights.count - 1) * rect.width
            path.line(to: CGPoint(x: x, y: rect.minY + CGFloat(height) * rect.height * 0.94))
        }
        path.line(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.close()
        NSGraphicsContext.saveGraphicsState()
        plot.addClip()
        (isDark ? NSColor.white.withAlphaComponent(0.13) : NSColor.black.withAlphaComponent(0.1)).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Where the curve could go with `region` anywhere from -1 to 1 (the others as they are), shaded.
    private func drawRange(of region: Int, in rect: CGRect, clippedTo plot: NSBezierPath) {
        var low = parametric, high = parametric
        low[region: region] = -1
        high[region: region] = 1
        let steps = 120
        let xs = (0...steps).map { Double($0) / Double(steps) }
        let band = NSBezierPath()
        for (step, x) in xs.enumerated() {
            let point = CGPoint(x: rect.minX + x * rect.width, y: rect.minY + high.value(at: x) * rect.height)
            step == 0 ? band.move(to: point) : band.line(to: point)
        }
        for x in xs.reversed() {
            band.line(to: CGPoint(x: rect.minX + x * rect.width, y: rect.minY + low.value(at: x) * rect.height))
        }
        band.close()
        NSGraphicsContext.saveGraphicsState()
        plot.addClip()
        curveColor.withAlphaComponent(0.14).setFill()
        band.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The region's name at the bottom center and its amount at the bottom right, as in Lightroom.
    private func drawRegionLabel(_ region: Int, in rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: curveColor.withAlphaComponent(0.75),
        ]
        let name = NSAttributedString(string: ParametricCurve.regionNames[region], attributes: attributes)
        name.draw(at: CGPoint(x: rect.midX - name.size().width / 2, y: rect.minY + 5))
        let value = NSAttributedString(string: SliderRow.signed(parametric[region: region]), attributes: attributes)
        value.draw(at: CGPoint(x: rect.maxX - 6 - value.size().width, y: rect.minY + 5))
    }

    private func updateHighlightedRegion() {
        if !isParametric {
            highlightedRegion = nil
        } else if let draggedRegion {
            highlightedRegion = draggedRegion.index
        } else if let hoverLocation, plotRect.contains(hoverLocation) {
            highlightedRegion = parametric.region(at: curvePoint(at: hoverLocation).x)
        } else {
            highlightedRegion = nil
        }
    }

    /// Input / output in 0…255, as Lightroom shows them.
    static func levels(_ point: ToneCurve.Point) -> (input: Int, output: Int) {
        (Int((point.x * 255).rounded()), Int((point.y * 255).rounded()))
    }

    /// What the corner readout shows: the point being dragged, or the curve's output under the pointer.
    var readoutPoint: ToneCurve.Point? {
        if let draggedIndex, curve.points.indices.contains(draggedIndex) { return curve.points[draggedIndex] }
        guard let hoverLocation, plotRect.contains(hoverLocation) else { return nil }
        let x = curvePoint(at: hoverLocation).x
        return ToneCurve.Point(x: x, y: curve.value(at: x))
    }

    private func drawReadout(in rect: CGRect) {
        guard let point = readoutPoint else { return }
        let levels = Self.levels(point)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: curveColor.withAlphaComponent(0.75),
        ]
        let text = NSAttributedString(string: "\(levels.input) / \(levels.output)", attributes: attributes)
        text.draw(at: CGPoint(x: rect.minX + 6, y: rect.maxY - 6 - text.size().height))
    }

    /// Moves the selected point to a typed input and/or output (0…1), as one final change.
    func moveSelectedPoint(x: Double? = nil, y: Double? = nil) {
        guard let index = selectedIndex else { return }
        let point = curve.points[index]
        curve.movePoint(index, toX: x ?? point.x, y: y ?? point.y)
        onChange?(curve, true)
        onSelectionChange?()
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hoverLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseExited(with event: NSEvent) {
        hoverLocation = nil
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if isParametric {
            if event.clickCount == 2 {
                var reset = ParametricCurve()
                reset.shadowSplit = parametric.shadowSplit
                reset.midtoneSplit = parametric.midtoneSplit
                reset.highlightSplit = parametric.highlightSplit
                parametric = reset
                onParametricChange?(parametric, true)
            } else if plotRect.contains(location) {
                let region = parametric.region(at: curvePoint(at: location).x)
                draggedRegion = (region, parametric[region: region], location.y)
                updateHighlightedRegion()
            }
            return
        }
        let hit = pointIndex(near: location)
        if event.clickCount == 2 {
            selectedIndex = nil
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
        if draggedIndex != nil { selectedIndex = draggedIndex }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if draggedRegion != nil {
            regionDidMove = true
            dragRegion(to: location, isFinal: false)
        } else {
            dragPoint(to: location, isFinal: false)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if draggedRegion != nil {
            // A click alone changes nothing.
            if regionDidMove { dragRegion(to: location, isFinal: true) }
            draggedRegion = nil
            regionDidMove = false
            hoverLocation = location
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

    private func dragPoint(to location: CGPoint, isFinal: Bool) {
        guard let index = draggedIndex, curve.points.indices.contains(index) else { return }
        let rect = plotRect
        let outside = location.x < rect.minX - deleteDistance || location.x > rect.maxX + deleteDistance
            || location.y < rect.minY - deleteDistance || location.y > rect.maxY + deleteDistance
        isDeleting = outside && curve.canRemovePoint
        if isDeleting {
            // The point stays where it was until the mouse is released.
            if isFinal, curve.removePoint(index) {
                selectedIndex = nil
                onChange?(curve, true)
            }
            needsDisplay = true
            return
        }
        let point = curvePoint(at: location)
        curve.movePoint(index, toX: point.x, y: point.y)
        onChange?(curve, isFinal)
        onSelectionChange?()
    }

    /// Dragging the graph's full height moves the region from -1 to 1.
    private func dragRegion(to location: CGPoint, isFinal: Bool) {
        guard let draggedRegion else { return }
        let change = Double((location.y - draggedRegion.startY) / max(plotRect.height, 1)) * 2
        parametric[region: draggedRegion.index] = draggedRegion.startAmount + change
        onParametricChange?(parametric, isFinal)
    }
}
