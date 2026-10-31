import AppKit

/// The tonal color wheels side by side, as on Lightroom's Shadows, Midtones and Highlights tabs: the shown wheel
/// centered, its neighbours peeking in at the edges. Clicking a peek asks for its tab (`onSelect`); moving between
/// tabs slides the strip (`scrollPosition` is animatable).
final class ColorWheelCarouselView: NSView {
    /// How much of a neighbouring wheel shows at each edge.
    nonisolated static let peekWidth = 14.0
    /// How long moving between tabs slides for (none with Reduce Motion).
    static let slideDuration = 0.2

    let wheels: [ColorWheelView]
    /// Shown at the centered wheel's lower right (its eye).
    let accessory: NSView?
    /// Called with a peeking wheel's index when it's clicked.
    var onSelect: ((Int) -> Void)?

    /// Which wheel is centered; fractional while sliding.
    @objc dynamic var scrollPosition: CGFloat = 0 {
        didSet { needsLayout = true }
    }

    /// `wheels` in carousel order; the one at `index` is the tab's own (editable), the others peeks.
    init(wheels: [ColorWheelView], index: Int, accessory: NSView? = nil) {
        self.wheels = wheels
        self.accessory = accessory
        super.init(frame: .zero)
        clipsToBounds = true
        scrollPosition = CGFloat(index)
        for (position, wheel) in wheels.enumerated() {
            wheel.translatesAutoresizingMaskIntoConstraints = true
            addSubview(wheel)
            guard position != index else { continue }
            wheel.onPeek = { [weak self] in self?.onSelect?(position) }
        }
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = true
            addSubview(accessory)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "scrollPosition" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    override func layout() {
        super.layout()
        for (index, frame) in Self.wheelFrames(count: wheels.count, position: scrollPosition, in: bounds).enumerated() {
            wheels[index].frame = frame
        }
        if let accessory {
            let size = accessory.fittingSize
            let side = bounds.height
            accessory.frame = CGRect(x: bounds.midX + side / 2 + 2, y: 0, width: size.width, height: size.height)
        }
    }

    /// Where each wheel goes: as tall as the strip, the one at `position` centered, the others a wheel and a gap
    /// apart, the gap leaving `peekWidth` of each neighbour inside the edges.
    nonisolated static func wheelFrames(count: Int, position: CGFloat, in bounds: CGRect) -> [CGRect] {
        let side = bounds.height
        let gap = max(0, (bounds.width - side) / 2 - peekWidth)
        return (0..<count).map { index in
            let x = bounds.midX - side / 2 + (CGFloat(index) - position) * (side + gap)
            return CGRect(x: x, y: bounds.minY, width: side, height: side)
        }
    }
}
