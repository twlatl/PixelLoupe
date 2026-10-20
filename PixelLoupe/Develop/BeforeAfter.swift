import AppKit
import CoreImage

/// Lightroom's Before/After views of the Develop preview (View ▸ Before/After): the photo as it
/// was before any edits next to it as edited, or in its place.
enum BeforeAfterView: Int, CaseIterable {
    /// Before on the left, after on the right (Y).
    case leftRight
    /// Before above, after below (⌥Y).
    case topBottom
    /// The photo before any edits in place of the edited one (\).
    case beforeOnly
    /// One photo, before left of a line down the middle and after right of it (⇧Y).
    case split

    var title: String {
        switch self {
        case .leftRight: "Left/Right"
        case .topBottom: "Top/Bottom"
        case .beforeOnly: "Before Only"
        case .split: "Split Screen"
        }
    }

    /// Whether the before and after are two photos, each in its own pane.
    var isSideBySide: Bool { self == .leftRight || self == .topBottom }

    /// The before and after panes of a side-by-side view in `bounds` (origin bottom-left), `gap`
    /// apart; `nil` for the views that show one photo.
    func panes(in bounds: CGRect, gap: CGFloat) -> (before: CGRect, after: CGRect)? {
        switch self {
        case .leftRight:
            let width = ((bounds.width - gap) / 2).rounded(.down)
            return (
                CGRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height),
                CGRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height)
            )
        case .topBottom:
            let height = ((bounds.height - gap) / 2).rounded(.down)
            return (
                CGRect(x: bounds.minX, y: bounds.maxY - height, width: bounds.width, height: height),
                CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: height)
            )
        case .beforeOnly, .split:
            return nil
        }
    }
}

/// What a Develop preview shows of the photo.
enum BeforeAfterContent {
    case after
    case before
    /// Before left of the middle, after right of it.
    case split

    /// `before` and `after` (the same photo rendered alike) combined as this content. `before` is
    /// stretched to `after`'s extent if it differs, so the halves of a split always line up.
    func compose(before: CIImage, after: CIImage) -> CIImage {
        guard self != .after else { return after }
        var before = before
        let extent = after.extent
        if before.extent != extent, !before.extent.isEmpty, !extent.isEmpty, !extent.isInfinite {
            before = before
                .transformed(by: CGAffineTransform(translationX: -before.extent.minX, y: -before.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: extent.width / before.extent.width, y: extent.height / before.extent.height))
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        }
        guard self == .split else { return before }
        let left = CGRect(x: extent.minX, y: extent.minY, width: (extent.width / 2).rounded(), height: extent.height)
        return before.cropped(to: left).composited(over: after)
    }
}

extension PhotoAdjustments {
    /// The settings the Before views show: none of the edits, but framed as now (orientation, crop
    /// and straightening, and the Transform sliders), so before and after line up.
    var before: PhotoAdjustments {
        var before = PhotoAdjustments()
        before.orientation = orientation
        before.crop = crop
        before.transform = transform
        return before
    }
}

/// Labels the Before/After views over the Develop preview ("Before", "After" in Liquid Glass) and
/// draws Split Screen's dividing line. It never takes clicks.
final class BeforeAfterOverlayView: NSView {
    /// Where the photos are shown (points, only their visible parts).
    enum Arrangement: Equatable {
        case sideBySide(before: CGRect, after: CGRect)
        /// `photo` is the visible part of the photo; the line is at `dividerX`.
        case split(photo: CGRect, dividerX: CGFloat)
        case beforeOnly(photo: CGRect)
    }

    var arrangement: Arrangement? {
        didSet {
            guard arrangement != oldValue else { return }
            needsLayout = true
            needsDisplay = true
        }
    }

    private let beforeLabel = BeforeAfterLabel(title: "Before")
    private let afterLabel = BeforeAfterLabel(title: "After")
    private static let inset: CGFloat = 10

    override init(frame: NSRect) {
        super.init(frame: frame)
        for label in [beforeLabel, afterLabel] {
            label.isHidden = true
            addSubview(label)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The labels shown (for tests).
    var shownLabels: [String] {
        [beforeLabel, afterLabel].filter { !$0.isHidden }.map(\.title)
    }

    override func layout() {
        super.layout()
        switch arrangement {
        case .sideBySide(let before, let after)?:
            place(beforeLabel, topLeftOf: before)
            place(afterLabel, topLeftOf: after)
        case .split(let photo, let dividerX)?:
            place(beforeLabel, topLeftOf: CGRect(x: photo.minX, y: photo.minY, width: max(dividerX - photo.minX, 0), height: photo.height))
            place(afterLabel, topRightOf: CGRect(x: dividerX, y: photo.minY, width: max(photo.maxX - dividerX, 0), height: photo.height))
        case .beforeOnly(let photo)?:
            place(beforeLabel, topLeftOf: photo)
            afterLabel.isHidden = true
        case nil:
            beforeLabel.isHidden = true
            afterLabel.isHidden = true
        }
    }

    private func place(_ label: BeforeAfterLabel, topLeftOf rect: CGRect) {
        let size = label.fittingSize
        place(label, CGRect(x: rect.minX + Self.inset, y: rect.maxY - Self.inset - size.height, width: size.width, height: size.height), in: rect)
    }

    private func place(_ label: BeforeAfterLabel, topRightOf rect: CGRect) {
        let size = label.fittingSize
        place(label, CGRect(x: rect.maxX - Self.inset - size.width, y: rect.maxY - Self.inset - size.height, width: size.width, height: size.height), in: rect)
    }

    /// Shows the label at `frame` if it fits in `rect` (it doesn't when that part of the photo is off screen).
    private func place(_ label: BeforeAfterLabel, _ frame: CGRect, in rect: CGRect) {
        label.frame = frame.integral
        label.isHidden = !rect.contains(frame)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard case .split(let photo, let dividerX)? = arrangement, photo.minX <= dividerX, dividerX <= photo.maxX else { return }
        // White with a dark edge, so the line shows on any photo in either appearance.
        let line = CGRect(x: dividerX - 1, y: photo.minY, width: 2, height: photo.height)
        NSColor.black.withAlphaComponent(0.35).setFill()
        line.insetBy(dx: -1, dy: 0).fill()
        NSColor.white.setFill()
        line.fill()
    }
}

/// A "Before" or "After" label, in Liquid Glass since it floats over the photo.
private final class BeforeAfterLabel: NSView {
    let title: String
    private let glass = NSGlassEffectView()

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        // Padded in a container: the glass sizes its content view to fit.
        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
        ])
        glass.contentView = content
        glass.cornerRadius = 11
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
