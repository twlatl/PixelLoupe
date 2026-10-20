import AppKit

/// Lightroom-style histogram at the top of Develop's sidebar: overlapping red, green and blue
/// channels, clipping indicators in the top corners, and the shooting settings underneath, then
/// what the photo is drawn from ("Original + Smart Preview").
///
/// Dragging across the histogram adjusts the zone under the pointer (Black Point, Shadows,
/// Exposure, Highlights, White Point); hovering names the zone and its value in place of the
/// shooting settings.
final class HistogramView: NSView {
    static let plotHeight: CGFloat = 96

    var histogram: Histogram? {
        didSet {
            guard histogram != oldValue else { return }
            plot.needsDisplay = true
            updateClipIndicators()
        }
    }

    var shootingInfo = ShootingInfo() {
        didSet { updateInfo() }
    }

    /// Nil when there's no photo, or for a video.
    var sourceStatus: PhotoSourceStatus? {
        didSet { statusLabel.stringValue = sourceStatus?.title ?? "" }
    }

    /// Whether there's a photo to adjust; dragging does nothing otherwise.
    var isEditingEnabled = false {
        didSet {
            if !isEditingEnabled { hoveredZone = nil }
            plot.needsDisplay = true
        }
    }

    /// The clipping triangles (Develop only; the Library's histogram just shows the photo).
    var showsClippingIndicators = true {
        didSet {
            shadowButton.isHidden = !showsClippingIndicators
            highlightButton.isHidden = !showsClippingIndicators
        }
    }

    /// The current settings, read when a drag starts and to show zone values.
    var adjustments: () -> PhotoAdjustments = { PhotoAdjustments() }
    /// A drag changed the settings (`isFinal` on mouse up).
    var onChange: (_ adjustments: PhotoAdjustments, _ isFinal: Bool, _ actionName: String) -> Void = { _, _, _ in }
    /// The clipping overlays to show on the preview changed (toggled, or previewed while hovering).
    var onClippingDisplayChange: (_ shadows: Bool, _ highlights: Bool) -> Void = { _, _ in }

    /// Clipping overlays switched on (click a triangle, or J for both).
    var showsShadowClipping = false {
        didSet { clippingDisplayChanged() }
    }
    var showsHighlightClipping = false {
        didSet { clippingDisplayChanged() }
    }

    private let plot = HistogramPlotView()
    private let shadowButton = ClippingButton(isShadows: true)
    private let highlightButton = ClippingButton(isShadows: false)
    private let infoLabels = (0..<4).map { _ in NSTextField(labelWithString: "") }
    private let infoRow = NSStackView()
    private let zoneLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var hoveredZone: HistogramZone? {
        didSet {
            guard hoveredZone != oldValue else { return }
            plot.highlightedZone = hoveredZone
            updateInfo()
        }
    }
    private var drag: (zone: HistogramZone, startX: CGFloat, start: PhotoAdjustments, moved: Bool)?
    private var previewedClipping: (shadows: Bool, highlights: Bool) = (false, false)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Histogram")
        setAccessibilityIdentifier("histogram")

        plot.source = self
        plot.wantsLayer = true
        plot.layer?.cornerRadius = 6
        plot.layer?.masksToBounds = true
        plot.setAccessibilityElement(false)

        for button in [shadowButton, highlightButton] {
            button.target = self
            button.action = #selector(toggleClipping(_:))
            button.onHover = { [weak self] hovering in self?.previewClipping(button, hovering) }
        }

        for (index, label) in infoLabels.enumerated() {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.alignment = index == 0 ? .left : index == infoLabels.count - 1 ? .right : .center
            label.setAccessibilityIdentifier(["histogramISO", "histogramFocalLength", "histogramAperture", "histogramShutter"][index])
            infoRow.addArrangedSubview(label)
        }
        infoRow.distribution = .equalSpacing
        zoneLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        zoneLabel.textColor = .labelColor
        zoneLabel.alignment = .center
        zoneLabel.isHidden = true
        zoneLabel.setAccessibilityIdentifier("histogramZone")
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.setAccessibilityIdentifier("histogramSourceStatus")

        for view in [plot, shadowButton, highlightButton, infoRow, zoneLabel, statusLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            plot.topAnchor.constraint(equalTo: topAnchor),
            plot.leadingAnchor.constraint(equalTo: leadingAnchor),
            plot.trailingAnchor.constraint(equalTo: trailingAnchor),
            plot.heightAnchor.constraint(equalToConstant: Self.plotHeight),
            shadowButton.topAnchor.constraint(equalTo: plot.topAnchor, constant: 4),
            shadowButton.leadingAnchor.constraint(equalTo: plot.leadingAnchor, constant: 4),
            highlightButton.topAnchor.constraint(equalTo: plot.topAnchor, constant: 4),
            highlightButton.trailingAnchor.constraint(equalTo: plot.trailingAnchor, constant: -4),
            infoRow.topAnchor.constraint(equalTo: plot.bottomAnchor, constant: 6),
            infoRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            infoRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            // Fixed heights, so the histogram never stretches to take the sidebar's space.
            infoRow.heightAnchor.constraint(equalToConstant: 16),
            statusLabel.topAnchor.constraint(equalTo: infoRow.bottomAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusLabel.heightAnchor.constraint(equalToConstant: 16),
            zoneLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            zoneLabel.centerYAnchor.constraint(equalTo: infoRow.centerYAnchor),
        ])
        updateInfo()
        updateClipIndicators()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Drags adjust the photo; they must never move the window (which a click on a plain,
    /// transparent view in this window otherwise does).
    override var mouseDownCanMoveWindow: Bool { false }


    /// J: both overlays on, or both off if they already are.
    func toggleBothClippingOverlays() {
        let on = !(showsShadowClipping && showsHighlightClipping)
        showsShadowClipping = on
        showsHighlightClipping = on
    }

    // MARK: - Display

    private func updateInfo() {
        let texts = [shootingInfo.isoText, shootingInfo.focalLengthText, shootingInfo.apertureText, shootingInfo.exposureTimeText]
        for (label, text) in zip(infoLabels, texts) { label.stringValue = text ?? "" }
        if let zone = drag?.zone ?? hoveredZone {
            zoneLabel.stringValue = "\(zone.title)   \(zone.displayValue(in: adjustments()))"
            zoneLabel.isHidden = false
            infoRow.isHidden = true
        } else {
            zoneLabel.isHidden = true
            infoRow.isHidden = false
        }
    }

    private func updateClipIndicators() {
        shadowButton.clipped = histogram?.clippedChannels(atBlack: true) ?? []
        highlightButton.clipped = histogram?.clippedChannels(atBlack: false) ?? []
    }

    @objc private func toggleClipping(_ sender: ClippingButton) {
        if sender.isShadows { showsShadowClipping.toggle() } else { showsHighlightClipping.toggle() }
    }

    private func previewClipping(_ button: ClippingButton, _ hovering: Bool) {
        if button.isShadows { previewedClipping.shadows = hovering } else { previewedClipping.highlights = hovering }
        clippingDisplayChanged()
    }

    private func clippingDisplayChanged() {
        shadowButton.isOn = showsShadowClipping
        highlightButton.isOn = showsHighlightClipping
        onClippingDisplayChange(showsShadowClipping || previewedClipping.shadows,
                                showsHighlightClipping || previewedClipping.highlights)
    }

    // MARK: - Dragging

    private func zone(at event: NSEvent) -> HistogramZone? {
        let point = plot.convert(event.locationInWindow, from: nil)
        guard isEditingEnabled, plot.bounds.contains(point), plot.bounds.width > 0 else { return nil }
        return HistogramZone.at(fraction: Double(point.x / plot.bounds.width))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        hoveredZone = zone(at: event)
    }

    override func mouseExited(with event: NSEvent) {
        if drag == nil { hoveredZone = nil }
    }

    override func cursorUpdate(with event: NSEvent) {
        if zone(at: event) != nil { NSCursor.resizeLeftRight.set() } else { super.cursorUpdate(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let zone = zone(at: event) else { return }
        drag = (zone, convert(event.locationInWindow, from: nil).x, adjustments(), false)
        hoveredZone = zone
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag, plot.bounds.width > 0 else { return }
        let distance = (convert(event.locationInWindow, from: nil).x - drag.startX) / plot.bounds.width
        drag.moved = true
        self.drag = drag
        onChange(drag.zone.applying(Double(distance), to: drag.start), false, drag.zone.actionName)
        updateInfo()
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        if drag.moved, plot.bounds.width > 0 {
            let distance = (convert(event.locationInWindow, from: nil).x - drag.startX) / plot.bounds.width
            onChange(drag.zone.applying(Double(distance), to: drag.start), true, drag.zone.actionName)
        }
        hoveredZone = zone(at: event)
        updateInfo()
    }

    /// Lets the plot read the histogram it draws.
    fileprivate var plotHistogram: Histogram? { histogram }
}

/// Draws the channels: where all three overlap in gray, two in their mix (yellow, cyan, magenta),
/// one in its own color.
private final class HistogramPlotView: NSView {
    weak var source: HistogramView?
    var highlightedZone: HistogramZone? {
        didSet { if highlightedZone != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.86, alpha: 1)).setFill()
        bounds.fill()

        if let zone = highlightedZone {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSRect(x: bounds.width * zone.range.lowerBound, y: 0,
                   width: bounds.width * (zone.range.upperBound - zone.range.lowerBound), height: bounds.height).fill()
        }

        guard let histogram = source?.plotHistogram, let context = NSGraphicsContext.current?.cgContext else { return }
        let heights = Self.normalizedHeights(histogram)
        let scale = window?.backingScaleFactor ?? 2
        let columns = max(1, Int(bounds.width * scale))
        let columnWidth = bounds.width / CGFloat(columns)
        let maxHeight = bounds.height * 0.94

        // Colors for which channels cover a point: index bits are red 1, green 2, blue 4.
        let alpha: CGFloat = dark ? 0.9 : 0.85
        let colors: [CGColor] = [
            NSColor.clear, NSColor(red: 0.84, green: 0.24, blue: 0.24, alpha: alpha),
            NSColor(red: 0.22, green: 0.70, blue: 0.30, alpha: alpha), NSColor(red: 0.82, green: 0.74, blue: 0.22, alpha: alpha),
            NSColor(red: 0.24, green: 0.40, blue: 0.86, alpha: alpha), NSColor(red: 0.70, green: 0.30, blue: 0.78, alpha: alpha),
            NSColor(red: 0.22, green: 0.68, blue: 0.76, alpha: alpha),
            dark ? NSColor(white: 0.78, alpha: 1) : NSColor(white: 0.45, alpha: 1),
        ].map(\.cgColor)

        for column in 0..<columns {
            let position = (Double(column) + 0.5) / Double(columns) * Double(Histogram.binCount - 1)
            let lower = Int(position), upper = min(lower + 1, Histogram.binCount - 1), t = position - Double(lower)
            let channelHeights = (0..<3).map { channel in
                CGFloat(heights[channel][lower] * (1 - t) + heights[channel][upper] * t) * maxHeight
            }
            // Fill from the bottom up: the band below the lowest channel is covered by all three, etc.
            let ordered = channelHeights.enumerated().sorted { $0.element < $1.element }
            var covered = 7, bottom: CGFloat = 0
            for (channel, height) in ordered {
                if height > bottom {
                    context.setFillColor(colors[covered])
                    context.fill(CGRect(x: CGFloat(column) * columnWidth, y: bottom, width: columnWidth, height: height - bottom))
                    bottom = height
                }
                covered &= ~(1 << channel)
            }
        }
    }

    /// Each channel's bins as 0…1, lightly smoothed. Scaled so a few very tall bins (a blown sky,
    /// a black background) run off the top, like Lightroom's, rather than flattening everything else.
    static func normalizedHeights(_ histogram: Histogram) -> [[Double]] {
        let smoothed = histogram.channels.map { counts in
            counts.indices.map { i -> Double in
                let window = max(0, i - 1)...min(counts.count - 1, i + 1)
                return window.reduce(0) { $0 + Double(counts[$1]) } / Double(window.count)
            }
        }
        // The 5th-tallest bin of each channel, ignoring the end bins (where clipped pixels pile up).
        let peak = smoothed.map { Array($0[1..<(Histogram.binCount - 1)].sorted().suffix(5)).first ?? 0 }.max() ?? 0
        guard peak > 0 else { return smoothed.map { $0.map { _ in 0 } } }
        return smoothed.map { $0.map { min(1, $0 / peak) } }
    }
}

/// A clipping indicator: a triangle that lights up in the clipped channels' color (white when all
/// three are clipped). Click to show the clipping on the photo; hover to preview it.
private final class ClippingButton: NSButton {
    let isShadows: Bool
    var onHover: (Bool) -> Void = { _ in }

    var clipped: Histogram.ClippedChannels = [] {
        didSet { if clipped != oldValue { updateAppearance() } }
    }

    var isOn = false {
        didSet { if isOn != oldValue { updateAppearance() } }
    }

    init(isShadows: Bool) {
        self.isShadows = isShadows
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.borderWidth = 1
        let title = isShadows ? "Shadow clipping" : "Highlight clipping"
        setAccessibilityLabel(title)
        setAccessibilityIdentifier(isShadows ? "clipShadows" : "clipHighlights")
        toolTip = "\(title): click to show it on the photo (J shows both)"
        widthAnchor.constraint(equalToConstant: 16).isActive = true
        heightAnchor.constraint(equalToConstant: 16).isActive = true
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateAppearance() {
        let color: NSColor = switch clipped {
        case []: .tertiaryLabelColor
        case [.red, .green, .blue]: .white
        default: NSColor(
            red: clipped.contains(.red) ? 0.95 : 0.2,
            green: clipped.contains(.green) ? 0.85 : 0.2,
            blue: clipped.contains(.blue) ? 0.95 : 0.2, alpha: 1
        )
        }
        contentTintColor = color
        layer?.borderColor = (isOn ? NSColor.white : NSColor.black.withAlphaComponent(0.35)).cgColor
        layer?.backgroundColor = NSColor.black.withAlphaComponent(isOn ? 0.55 : 0.3).cgColor
        setAccessibilityValue([
            isOn ? "shown" : "hidden",
            clipped.isEmpty ? "no clipping" : "clipped",
        ].joined(separator: ", "))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}
