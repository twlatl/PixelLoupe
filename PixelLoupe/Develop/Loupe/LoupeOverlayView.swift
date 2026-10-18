import AppKit

/// What the Develop preview needs to draw the magnified photo inside the lens.
nonisolated struct LoupeRenderRequest: Equatable {
    /// Lens center and radius, in view points.
    var lensCenter: CGPoint
    var lensRadius: CGFloat
    /// The magnified photo extends under the ring to this radius so no seam shows.
    var coverRadius: CGFloat
    /// The preview point being magnified.
    var focus: CGPoint
    var zoom: Double
    /// False while the loupe is being repositioned from its center: the lens shows the photo
    /// unmagnified with an outline of the area that will be magnified.
    var magnify: Bool
}

/// Draws the loupe over the Develop preview and handles its interactions:
/// - ` + click places the loupe on the clicked point.
/// - Drag the ring or tab to move it while magnifying.
/// - Drag from the lens to reposition it with an outline of the area it will magnify.
/// - Drag the grip to resize; click the zoom value for options.
/// The magnified pixels themselves are rendered by the preview's Metal view underneath.
final class LoupeOverlayView: NSView {
    let settings: LoupeSettings

    var isLoupeVisible = false {
        didSet {
            guard isLoupeVisible != oldValue else { return }
            // Placed on first layout if the view hasn't been sized yet.
            if isLoupeVisible, placement == nil, !bounds.isEmpty { placement = defaultPlacement() }
            zoomButton.isHidden = !isLoupeVisible
            changed()
        }
    }

    /// Set while ` is held, so a click places the loupe.
    var isPlacementKeyDown = false {
        didSet { if isPlacementKeyDown { didPlaceDuringKeyHold = false } }
    }
    /// Whether a click placed the loupe while ` was held (so releasing ` shouldn't also toggle it).
    private(set) var didPlaceDuringKeyHold = false

    /// Supplied by the owner for converting between the preview and the photo.
    var geometry: () -> PreviewGeometry? = { nil }
    /// Called whenever what the preview must draw changes.
    var onChange: () -> Void = {}
    /// Called when the user hides the loupe from its menu.
    var onHide: () -> Void = {}

    /// RGB (0–255) of the magnified point, shown when Color Value is on.
    var colorValue: (r: Int, g: Int, b: Int)? {
        didSet { if settings.showsColorValue { needsDisplay = true } }
    }

    private(set) var placement: LoupePlacement?
    private var cursorPoint: CGPoint?
    private var drag: Drag?
    private let zoomButton = NSButton(title: "", target: nil, action: nil)

    private enum Drag {
        case move(offset: CGPoint)
        case reposition(offset: CGPoint)
        case resize
    }

    init(settings: LoupeSettings) {
        self.settings = settings
        super.init(frame: .zero)
        zoomButton.bezelStyle = .inline
        zoomButton.controlSize = .small
        zoomButton.font = .systemFont(ofSize: 10, weight: .semibold)
        zoomButton.target = self
        zoomButton.action = #selector(showMenu(_:))
        zoomButton.isHidden = true
        zoomButton.setAccessibilityIdentifier("loupeZoomButton")
        zoomButton.appearance = NSAppearance(named: .darkAqua)
        addSubview(zoomButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Loupe")
        setAccessibilityIdentifier("loupe")
        updateZoomButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func isAccessibilityElement() -> Bool { isLoupeVisible }

    // MARK: - Render request

    var renderRequest: LoupeRenderRequest? {
        guard isLoupeVisible, let placement else { return nil }
        let focus = settings.focusOnCursor
            ? (cursorPoint ?? placement.focusPoint(centered: settings.centered))
            : placement.focusPoint(centered: settings.centered)
        let repositioning = if case .reposition = drag { true } else { false }
        return LoupeRenderRequest(
            lensCenter: placement.lensCenter,
            lensRadius: placement.lensRadius,
            coverRadius: placement.coverRadius,
            focus: focus,
            zoom: settings.zoom,
            magnify: !repositioning
        )
    }

    private func changed() {
        if let placement {
            zoomButton.sizeToFit()
            // Just left of the grip, at a fixed distance like the grip itself.
            let grip = placement.gripCenter
            zoomButton.frame.origin = CGPoint(
                x: (grip.x - 16 - zoomButton.frame.width).rounded(),
                y: (grip.y - zoomButton.frame.height / 2 - 2).rounded()
            )
        }
        needsDisplay = true
        onChange()
    }

    private func defaultPlacement() -> LoupePlacement {
        let size = settings.size
        let center = CGPoint(x: bounds.midX - size * 0.1, y: bounds.midY + size * 0.1)
        return LoupePlacement(lensCenter: center, size: size)
    }

    override func layout() {
        super.layout()
        guard !bounds.isEmpty else { return }
        if isLoupeVisible, placement == nil {
            placement = defaultPlacement()
            changed()
        }
        // Keep the lens reachable when the preview shrinks.
        if var placement {
            placement.lensCenter.x = placement.lensCenter.x.clamped(to: bounds.minX...max(bounds.minX, bounds.maxX))
            placement.lensCenter.y = placement.lensCenter.y.clamped(to: bounds.minY...max(bounds.minY, bounds.maxY))
            if placement != self.placement {
                self.placement = placement
                changed()
            }
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard isLoupeVisible, let placement, let context = NSGraphicsContext.current?.cgContext else { return }
        let request = renderRequest

        // Pixel grid and color value, inside the lens.
        context.saveGState()
        context.addEllipse(in: CGRect(
            x: placement.lensCenter.x - placement.lensRadius, y: placement.lensCenter.y - placement.lensRadius,
            width: placement.lensRadius * 2, height: placement.lensRadius * 2
        ))
        context.clip()
        if let request, request.magnify {
            if settings.showsPixelGrid { drawPixelGrid(request, in: context) }
        } else if let request, let geometry = geometry() {
            // Repositioning: outline the area that will be magnified.
            let diameter = geometry.previewDiameter(ofLens: placement.lensRadius * 2, zoom: request.zoom)
            let outline = NSBezierPath(ovalIn: CGRect(
                x: request.focus.x - diameter / 2, y: request.focus.y - diameter / 2, width: diameter, height: diameter
            ))
            outline.lineWidth = 1.5
            NSColor.white.setStroke()
            outline.stroke()
        }
        context.restoreGState()

        // The loupe graphic from the design, in artboard coordinates.
        context.saveGState()
        context.concatenate(placement.transform)
        let ink = CGColor(red: 5 / 255, green: 5 / 255, blue: 5 / 255, alpha: 1)

        let tab = CGPath(
            roundedRect: LoupeShape.tabRect, cornerWidth: LoupeShape.tabCornerRadius,
            cornerHeight: LoupeShape.tabCornerRadius, transform: nil
        )
        let lens = CGPath(ellipseIn: CGRect(
            x: LoupeShape.center.x - LoupeShape.ringRadius, y: LoupeShape.center.y - LoupeShape.ringRadius,
            width: LoupeShape.ringRadius * 2, height: LoupeShape.ringRadius * 2
        ), transform: nil)
        // The tab sits behind the lens.
        context.saveGState()
        context.addRect(CGRect(x: -100, y: -100, width: 900, height: 900))
        context.addPath(lens)
        context.clip(using: .evenOdd)
        context.addPath(tab)
        context.setFillColor(ink)
        context.fillPath()
        context.restoreGState()

        context.addPath(lens)
        context.setStrokeColor(ink)
        context.setLineWidth(LoupeShape.ringWidth)
        context.strokePath()

        if !settings.centered {
            // Target the offset loupe magnifies.
            let target = LoupeShape.target
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            context.setLineWidth(3)
            context.strokeEllipse(in: CGRect(x: target.x - 12, y: target.y - 12, width: 24, height: 24))
            context.setStrokeColor(ink)
            context.setLineWidth(2)
            context.strokeEllipse(in: CGRect(x: target.x - 15, y: target.y - 15, width: 30, height: 30))
        }
        context.restoreGState()

        // The grip stays the same size however large the loupe is.
        context.setStrokeColor(CGColor(gray: 130 / 255, alpha: 1))
        context.setLineWidth(LoupeShape.gripLineWidth)
        context.setLineCap(.round)
        for (start, end) in placement.gripLines {
            context.move(to: start)
            context.addLine(to: end)
        }
        context.strokePath()

        if settings.showsColorValue, request?.magnify == true {
            drawCrosshair(at: placement.lensCenter)
            if let colorValue { drawColorValue(colorValue, placement: placement) }
        }
    }

    private func drawPixelGrid(_ request: LoupeRenderRequest, in context: CGContext) {
        guard let geometry = geometry() else { return }
        let step = geometry.pointsPerImagePixel(zoom: request.zoom)
        guard step >= 6 else { return }   // Too dense to be useful below ~6 points per pixel.
        let focus = geometry.imagePoint(forViewPoint: request.focus)
        let radius = request.lensRadius
        let path = CGMutablePath()
        // Image pixel boundaries are at whole-number coordinates.
        let firstX = (focus.x - radius / step).rounded(.down), lastX = (focus.x + radius / step).rounded(.up)
        let firstY = (focus.y - radius / step).rounded(.down), lastY = (focus.y + radius / step).rounded(.up)
        for u in stride(from: firstX, through: lastX, by: 1) {
            let x = request.lensCenter.x + (u - focus.x) * step
            path.move(to: CGPoint(x: x, y: request.lensCenter.y - radius))
            path.addLine(to: CGPoint(x: x, y: request.lensCenter.y + radius))
        }
        for v in stride(from: firstY, through: lastY, by: 1) {
            let y = request.lensCenter.y + (v - focus.y) * step
            path.move(to: CGPoint(x: request.lensCenter.x - radius, y: y))
            path.addLine(to: CGPoint(x: request.lensCenter.x + radius, y: y))
        }
        context.addPath(path)
        context.setStrokeColor(CGColor(gray: 0.5, alpha: 0.45))
        context.setLineWidth(1 / (window?.backingScaleFactor ?? 2))
        context.strokePath()
    }

    /// Marks the sampled pixel, which the lens always centers on.
    private func drawCrosshair(at center: CGPoint) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            .applying(.init(paletteColors: [NSColor(white: 0.5, alpha: 1)]))
        guard let symbol = NSImage(systemSymbolName: "scope", accessibilityDescription: "Sampled pixel")?
            .withSymbolConfiguration(configuration) else { return }
        let size = symbol.size
        symbol.draw(in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
    }

    private func drawColorValue(_ value: (r: Int, g: Int, b: Int), placement: LoupePlacement) {
        let text = "R \(value.r)   G \(value.g)   B \(value.b)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let origin = CGPoint(
            x: placement.lensCenter.x - size.width / 2,
            y: placement.lensCenter.y - placement.lensRadius * 0.72 - size.height / 2
        )
        let background = NSBezierPath(
            roundedRect: CGRect(origin: origin, size: size).insetBy(dx: -8, dy: -3), xRadius: 9, yRadius: 9
        )
        NSColor.black.withAlphaComponent(0.6).setFill()
        background.fill()
        text.draw(at: origin, withAttributes: attributes)
        setAccessibilityValue(text as String)
    }

    // MARK: - Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if isPlacementKeyDown { return self }
        guard isLoupeVisible, let placement else { return nil }
        if !zoomButton.isHidden, zoomButton.frame.contains(local) { return zoomButton }
        return placement.region(at: local) == .none ? nil : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        guard isLoupeVisible else { return }
        let point = convert(event.locationInWindow, from: nil)
        if settings.focusOnCursor {
            cursorPoint = point
            changed()
        }
        switch placement?.region(at: point) {
        case .edge?: NSCursor.openHand.set()
        case .grip?: NSCursor.frameResize(position: .bottomRight, directions: .all).set()
        default: NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isPlacementKeyDown {
            var placement = placement ?? LoupePlacement(lensCenter: point, size: settings.size)
            placement.focus(on: point, centered: settings.centered)
            self.placement = placement
            cursorPoint = point
            didPlaceDuringKeyHold = true
            isLoupeVisible = true
            drag = .move(offset: CGPoint(x: placement.lensCenter.x - point.x, y: placement.lensCenter.y - point.y))
            changed()
            return
        }
        guard let placement else { return }
        let offset = CGPoint(x: placement.lensCenter.x - point.x, y: placement.lensCenter.y - point.y)
        switch placement.region(at: point) {
        case .edge:
            drag = .move(offset: offset)
            NSCursor.closedHand.set()
        case .lens:
            drag = .reposition(offset: offset)
        case .grip:
            drag = .resize
        case .none:
            drag = nil
        }
        changed()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, var placement else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .move(let offset), .reposition(let offset):
            placement.lensCenter = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
        case .resize:
            // Keep the tab's corner near the pointer: it sits about 299 artboard units right of
            // and below the lens center.
            let cornerOffset = (LoupeShape.gripAnchor.x - LoupeShape.center.x) + (LoupeShape.gripAnchor.y - LoupeShape.center.y)
            let scale = ((point.x - placement.lensCenter.x) + (placement.lensCenter.y - point.y) + 24) / cornerOffset
            placement.size = (scale * LoupeShape.artboard).clamped(to: LoupeSettings.sizeRange)
            settings.size = placement.size
        }
        self.placement = placement
        cursorPoint = point
        changed()
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        NSCursor.arrow.set()
        changed()
    }

    // MARK: - Menu

    private func updateZoomButton() {
        zoomButton.attributedTitle = NSAttributedString(
            string: "\(LoupeSettings.title(forZoom: settings.zoom)) ▾",
            attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white]
        )
        zoomButton.setAccessibilityLabel("Loupe zoom \(LoupeSettings.title(forZoom: settings.zoom))%")
    }

    @objc private func showMenu(_ sender: NSButton) {
        menu(for: sender).popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.minY - 4), in: sender)
    }

    func menu(for sender: NSView? = nil) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, state: Bool, tag: Int = 0) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = state ? .on : .off
            item.tag = tag
            menu.addItem(item)
        }
        add("Focus on Loupe", #selector(setFocusMode(_:)), state: !settings.focusOnCursor, tag: 0)
        add("Focus on Cursor", #selector(setFocusMode(_:)), state: settings.focusOnCursor, tag: 1)
        menu.addItem(.separator())
        for (index, zoom) in LoupeSettings.zoomLevels.enumerated() {
            add("\(LoupeSettings.title(forZoom: zoom))%", #selector(setZoom(_:)), state: settings.zoom == zoom, tag: index)
        }
        menu.addItem(.separator())
        add("Pixel Grid", #selector(togglePixelGrid(_:)), state: settings.showsPixelGrid)
        add("Color Value", #selector(toggleColorValue(_:)), state: settings.showsColorValue)
        menu.addItem(.separator())
        add("Use Centered Loupe", #selector(toggleCentered(_:)), state: settings.centered)
        add("Hide Loupe", #selector(hideLoupe(_:)), state: false)
        return menu
    }

    @objc private func setFocusMode(_ sender: NSMenuItem) {
        settings.focusOnCursor = sender.tag == 1
        cursorPoint = nil
        changed()
    }

    @objc private func setZoom(_ sender: NSMenuItem) {
        settings.zoom = LoupeSettings.zoomLevels[sender.tag]
        updateZoomButton()
        changed()
    }

    @objc private func togglePixelGrid(_ sender: NSMenuItem) {
        settings.showsPixelGrid.toggle()
        changed()
    }

    @objc private func toggleColorValue(_ sender: NSMenuItem) {
        settings.showsColorValue.toggle()
        changed()
    }

    @objc private func toggleCentered(_ sender: NSMenuItem) {
        guard var placement else { return }
        // Keep magnifying the same spot when switching styles.
        let focus = placement.focusPoint(centered: settings.centered)
        settings.centered.toggle()
        placement.focus(on: focus, centered: settings.centered)
        self.placement = placement
        changed()
    }

    @objc private func hideLoupe(_ sender: Any?) {
        onHide()
    }
}
