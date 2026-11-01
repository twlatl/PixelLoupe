import AppKit

/// The parametric curve's three region splits, as triangles under a dark-to-light bar beneath the
/// graph (as in Lightroom). Drag a triangle to move its split; double-click it to put it back.
final class ParametricSplitBar: NSView {
    var parametric = ParametricCurve() { didSet { needsDisplay = true; updateAccessibility() } }
    var onChange: ((ParametricCurve, Bool) -> Void)?

    /// The curve graph's inset, so the splits line up with its regions.
    private let inset: CGFloat = 6
    private let barHeight: CGFloat = 5
    private let handleWidth: CGFloat = 10
    private(set) var draggedSplit: Int?
    /// Whether the pointer moved since the mouse went down; a click alone changes nothing.
    private var didDrag = false

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 16) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Region splits")
        setAccessibilityHelp("Drag a triangle to move where two regions meet; double-click it to put it back.")
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateAccessibility() {
        setAccessibilityValue(parametric.splits.map { String(Int(($0 * 100).rounded())) }.joined(separator: ", "))
    }

    private var trackRect: CGRect { CGRect(x: inset, y: bounds.maxY - barHeight, width: bounds.width - inset * 2, height: barHeight) }

    private func x(of split: Double) -> CGFloat { trackRect.minX + split * trackRect.width }

    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSGradient(starting: NSColor(white: 0.05, alpha: 1), ending: NSColor(white: 0.95, alpha: 1))?
            .draw(in: NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5), angle: 0)

        for (index, split) in parametric.splits.enumerated() {
            let x = x(of: split)
            let top = track.minY - 1
            let triangle = NSBezierPath()
            triangle.move(to: CGPoint(x: x, y: top))
            triangle.line(to: CGPoint(x: x - handleWidth / 2, y: top - 8))
            triangle.line(to: CGPoint(x: x + handleWidth / 2, y: top - 8))
            triangle.close()
            (index == draggedSplit ? NSColor.labelColor : NSColor(white: dark ? 0.7 : 0.4, alpha: 1)).setFill()
            triangle.fill()
        }
    }

    // MARK: - Mouse

    private func splitIndex(near location: CGPoint) -> Int? {
        parametric.splits.indices
            .map { ($0, abs(x(of: parametric.splits[$0]) - location.x)) }
            .filter { $0.1 <= handleWidth }
            .min { $0.1 < $1.1 }?.0
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let index = splitIndex(near: location) else { return }
        if event.clickCount == 2 {
            parametric.setSplit(index, to: ParametricCurve.defaultSplits[index])
            onChange?(parametric, true)
            return
        }
        draggedSplit = index
        didDrag = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        drag(to: convert(event.locationInWindow, from: nil), isFinal: false)
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag { drag(to: convert(event.locationInWindow, from: nil), isFinal: true) }
        draggedSplit = nil
        needsDisplay = true
    }

    private func drag(to location: CGPoint, isFinal: Bool) {
        guard let draggedSplit else { return }
        parametric.setSplit(draggedSplit, to: Double((location.x - trackRect.minX) / trackRect.width))
        onChange?(parametric, isFinal)
    }
}
