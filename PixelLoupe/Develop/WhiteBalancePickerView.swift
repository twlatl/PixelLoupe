import AppKit
import CoreImage

/// The colors under the White Balance Selector: a 5 × 5 grid of the preview around the pointer, and
/// their average (display RGB, 0…1).
struct NeutralTargetSample: Equatable {
    static let gridSize = 5

    /// The `gridSize` × `gridSize` colors, row by row from the top left.
    var grid: [[Double]]
    var average: [Double]

    init(grid: [[Double]]) {
        self.grid = grid
        let count = Double(max(grid.count, 1))
        average = (0..<3).map { channel in grid.reduce(0) { $0 + ($1.count > channel ? $1[channel] : 0) } / count }
    }

    /// The 5 × 5 grid of `image` (shown in `rect`, in view points) around `point`, one square per
    /// screen point, or `nil` off the image.
    static func read(_ image: CIImage, shownIn rect: CGRect, at point: CGPoint, context: CIContext) -> NeutralTargetSample? {
        guard rect.contains(point), rect.width > 0 else { return nil }
        let extent = image.extent
        // The image pixels under a screen point, and the grid's square of them centered on the pointer.
        let pixelsPerPoint = extent.width / rect.width
        let x = extent.minX + (point.x - rect.minX) * pixelsPerPoint
        let y = extent.minY + (point.y - rect.minY) * pixelsPerPoint
        let side = CGFloat(gridSize) * max(pixelsPerPoint, 1)
        let region = CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side)
        // Scaled so each grid square is one pixel, then read back.
        let scale = CGFloat(gridSize) / side
        let scaled = image.clampedToExtent().cropped(to: region)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: -region.minX, y: -region.minY))
        var pixels = [Float](repeating: 0, count: gridSize * gridSize * 4)
        context.render(scaled, toBitmap: &pixels, rowBytes: gridSize * 16, bounds: CGRect(x: 0, y: 0, width: gridSize, height: gridSize),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
        // The bitmap, like the grid, starts with the top row.
        let colors = (0..<gridSize).flatMap { row in
            (0..<gridSize).map { column in
                let index = (row * gridSize + column) * 4
                return (0..<3).map { Double(pixels[index + $0]).clamped(to: 0...1) }
            }
        }
        return NeutralTargetSample(grid: colors)
    }

    /// "R 48.2  G 47.9  B 50.1 %", as Lightroom shows the target's values.
    var readout: String {
        let values = zip(["R", "G", "B"], average).map { "\($0) \(($1 * 100).formatted(.number.precision(.fractionLength(1))))" }
        return values.joined(separator: "  ") + " %"
    }
}

/// Lightroom's White Balance Selector over the Develop preview: a floating loupe follows the
/// pointer with "Pick a Neutral Target" above a magnified 5 × 5 grid of the photo and the average
/// of the grid below; a click sets the white balance from that spot.
final class WhiteBalancePickerView: NSView {
    /// The clicked point, in this view's coordinates (which match the preview's).
    var onPick: (CGPoint) -> Void = { _ in }
    /// The colors around a point, or `nil` off the photo.
    var sample: (CGPoint) -> NeutralTargetSample? = { _ in nil }

    let loupe = NeutralTargetLoupe()
    private var trackingArea: NSTrackingArea?
    /// How far the loupe sits from the pointer.
    private static let offset: CGFloat = 18

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Pick a neutral target on the photo")
        setAccessibilityIdentifier("whiteBalancePicker")
        loupe.isHidden = true
        addSubview(loupe)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    override var isHidden: Bool {
        didSet { if isHidden { loupe.isHidden = true } }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateLoupe(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        loupe.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        loupe.isHidden = true
        onPick(convert(event.locationInWindow, from: nil))
    }

    /// Shows the loupe for the pointer at `point`, beside it and inside the view.
    func updateLoupe(at point: CGPoint) {
        guard let sample = sample(point) else {
            loupe.isHidden = true
            return
        }
        loupe.show(sample)
        let size = loupe.fittingSize
        var origin = CGPoint(x: point.x + Self.offset, y: point.y - Self.offset - size.height)
        if origin.x + size.width > bounds.maxX { origin.x = point.x - Self.offset - size.width }
        if origin.y < bounds.minY { origin.y = point.y + Self.offset }
        loupe.frame = CGRect(origin: origin, size: size).integral
        loupe.isHidden = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The loupe never takes the click: it goes to the photo under it.
        let hit = super.hitTest(point)
        return hit == nil ? nil : self
    }
}

/// The loupe's content, in Liquid Glass (it floats over the photo).
final class NeutralTargetLoupe: NSView {
    private let glass = NSGlassEffectView()
    private let title = NSTextField(labelWithString: "Pick a Neutral Target")
    let grid = NeutralTargetGrid()
    let readout = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        readout.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        readout.textColor = .secondaryLabelColor
        readout.setAccessibilityIdentifier("neutralTargetReadout")
        let stack = NSStackView(views: [title, grid, readout])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Padded in a container: the glass sizes its content view to fit without the stack's insets.
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        glass.contentView = content
        glass.cornerRadius = 14
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ sample: NeutralTargetSample) {
        grid.colors = sample.grid
        readout.stringValue = sample.readout
    }
}

/// The magnified 5 × 5 grid, with the center square outlined.
final class NeutralTargetGrid: NSView {
    static let cellSize: CGFloat = 14

    var colors: [[Double]] = [] {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        let side = CGFloat(NeutralTargetSample.gridSize) * Self.cellSize
        return NSSize(width: side, height: side)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let space = NSColorSpace.displayP3
        for (index, color) in colors.prefix(NeutralTargetSample.gridSize * NeutralTargetSample.gridSize).enumerated() {
            let row = index / NeutralTargetSample.gridSize, column = index % NeutralTargetSample.gridSize
            let components = color.map { CGFloat($0) } + [1]
            NSColor(colorSpace: space, components: components, count: 4).setFill()
            CGRect(x: CGFloat(column) * Self.cellSize, y: CGFloat(row) * Self.cellSize, width: Self.cellSize, height: Self.cellSize).fill()
        }
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        // The center square: the spot a click picks.
        let center = CGFloat(NeutralTargetSample.gridSize / 2) * Self.cellSize
        let outline = NSBezierPath(rect: CGRect(x: center, y: center, width: Self.cellSize, height: Self.cellSize).insetBy(dx: 0.5, dy: 0.5))
        NSColor.white.setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }
}
