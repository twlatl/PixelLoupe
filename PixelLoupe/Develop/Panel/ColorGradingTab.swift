import AppKit

/// What the Color Grading section shows, picked at its top as in Lightroom: the three tonal wheels together (All),
/// or one wheel large with its Hue, Saturation and Luminance sliders.
nonisolated enum ColorGradingTab: Int, CaseIterable {
    case all, shadows, midtones, highlights, global

    var title: String {
        switch self {
        case .all: "All"
        case .shadows: "Shadows"
        case .midtones: "Midtones"
        case .highlights: "Highlights"
        case .global: "Global"
        }
    }

    /// The wheel the tab shows on its own; All shows three.
    var wheel: WritableKeyPath<PhotoAdjustments.ColorGrading, PhotoAdjustments.ColorWheel>? {
        switch self {
        case .all: nil
        case .shadows: \.shadows
        case .midtones: \.midtones
        case .highlights: \.highlights
        case .global: \.global
        }
    }

    /// The tonal tabs, in the order their wheels sit side by side (`ColorWheelCarouselView`).
    static let carousel: [ColorGradingTab] = [.shadows, .midtones, .highlights]

    /// Where the tab's wheel sits among the tonal wheels; All and Global aren't among them.
    var carouselIndex: Int? { Self.carousel.firstIndex(of: self) }

    /// The tonal tabs whose wheels peek in beside this one's: Midtones beside Shadows, both beside Midtones.
    var neighbours: [ColorGradingTab] {
        guard let index = carouselIndex else { return [] }
        return [index - 1, index + 1].filter(Self.carousel.indices.contains).map { Self.carousel[$0] }
    }

    /// Blending and Balance shape the three tonal wheels, so Global's view leaves them out.
    var showsBlending: Bool { self != .global }

    /// Whether the tab's segment gets a dot: its wheel is set. All never does, as in Lightroom.
    func isMarked(in color: PhotoAdjustments.ColorGrading) -> Bool {
        wheel.map { color[keyPath: $0].isSet } ?? false
    }

    /// A wheel's values as the All tab shows them while the pointer is over it, in Lightroom's units: "H:189 S:14 L:-5".
    static func readout(_ wheel: PhotoAdjustments.ColorWheel) -> String {
        func whole(_ value: Double) -> Int {
            let rounded = Int(value.rounded())
            return rounded == 0 ? 0 : rounded
        }
        return "H:\(whole(wheel.hue * 360) % 360) S:\(whole(wheel.amount * 100)) L:\(whole(wheel.luminance * 100))"
    }

    /// `color` with `tabs`' wheels left out, for previewing without them (their eye buttons).
    static func muting(_ tabs: Set<ColorGradingTab>, in color: PhotoAdjustments.ColorGrading) -> PhotoAdjustments.ColorGrading {
        var color = color
        for tab in tabs { if let wheel = tab.wheel { color[keyPath: wheel] = .init() } }
        return color
    }

    // MARK: - Remembered tab

    static let defaultsKey = "ColorGradingTab"
    /// Posted when `current` changes, so the photo's panel and the masks' show the same tab.
    static let didChangeNotification = Notification.Name("ColorGradingTabDidChange")

    /// The tab last picked: one for the app, shared by the photo and its masks.
    static var current: ColorGradingTab {
        get { ColorGradingTab(rawValue: Defaults.store.integer(forKey: defaultsKey)) ?? .all }
        set {
            guard newValue != current else { return }
            Defaults.store.set(newValue.rawValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    // MARK: - Icon

    /// The segment's icon: discs filled with the tones the tab grades, as in Lightroom's picker. The fills are
    /// tones, not theme colors, so they stay put in light and dark mode; only the outline follows the appearance.
    var image: NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { [self] rect in
            let dark = NSColor(white: 0.15, alpha: 1), mid = NSColor(white: 0.5, alpha: 1), light = NSColor(white: 0.92, alpha: 1)
            func disc(_ frame: CGRect, _ fill: NSColor) {
                let path = NSBezierPath(ovalIn: frame)
                fill.setFill()
                path.fill()
                NSColor.labelColor.withAlphaComponent(0.55).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            let full = rect.insetBy(dx: 1.5, dy: 1.5)
            switch self {
            case .all:
                let side = 6.5
                disc(CGRect(x: rect.midX - side / 2, y: rect.maxY - side - 1, width: side, height: side), mid)
                disc(CGRect(x: rect.minX + 1, y: rect.minY + 1.5, width: side, height: side), dark)
                disc(CGRect(x: rect.maxX - side - 1, y: rect.minY + 1.5, width: side, height: side), light)
            case .shadows: disc(full, dark)
            case .midtones: disc(full, mid)
            case .highlights: disc(full, light)
            case .global:
                disc(full, light)
                let left = NSBezierPath()
                left.appendArc(withCenter: CGPoint(x: full.midX, y: full.midY), radius: full.width / 2, startAngle: 90, endAngle: 270)
                left.close()
                dark.setFill()
                left.fill()
                NSColor.labelColor.withAlphaComponent(0.55).setStroke()
                NSBezierPath(ovalIn: full).stroke()
            }
            return true
        }
        image.accessibilityDescription = title
        return image
    }
}

/// Dots under a segmented control's equally wide segments, marking the ones that are set (Color Grading's wheels).
final class SegmentDotsView: NSView {
    var marked: [Bool] = [] {
        didSet { if marked != oldValue { needsDisplay = true } }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 5) }

    override func draw(_ dirtyRect: NSRect) {
        guard !marked.isEmpty else { return }
        NSColor.secondaryLabelColor.setFill()
        for (index, isMarked) in marked.enumerated() where isMarked {
            let x = bounds.width * (Double(index) + 0.5) / Double(marked.count)
            NSBezierPath(ovalIn: CGRect(x: x - 2, y: bounds.midY - 2, width: 4, height: 4)).fill()
        }
    }
}
