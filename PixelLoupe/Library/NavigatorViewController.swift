import AppKit
import CoreData

/// Lightroom's Navigator, at the top of the left sidebar: the selected photo, with a rectangle around
/// the part the enlarged view or Develop shows, and the zoom choices above it — FIT, FILL, 1:1 and a
/// menu of other ratios. Clicking a choice zooms to it; clicking or dragging in the preview moves the
/// view there (zooming in first if the photo fits).
final class NavigatorViewController: NSViewController {
    private let store: CatalogStore
    private let state: LibraryState
    private let titleLabel = NSTextField(labelWithString: "Navigator")
    let zoomControl = NSSegmentedControl()
    let preview = NavigatorPreviewView()
    private var thumbnailTask: Task<Void, Never>?
    private var shownPhotoID: UUID?

    private enum Segment: Int { case fit, fill, oneToOne, menu }

    init(store: CatalogStore, state: LibraryState) {
        self.store = store
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        zoomControl.segmentCount = 4
        zoomControl.trackingMode = .selectOne
        zoomControl.controlSize = .mini
        zoomControl.font = .systemFont(ofSize: NSFont.systemFontSize(for: .mini), weight: .medium)
        for (segment, title) in [(Segment.fit, "FIT"), (.fill, "FILL"), (.oneToOne, "1:1")] {
            zoomControl.setLabel(title, forSegment: segment.rawValue)
            zoomControl.setWidth(0, forSegment: segment.rawValue)
        }
        zoomControl.setToolTip("Fit the whole photo", forSegment: Segment.fit.rawValue)
        zoomControl.setToolTip("Fill the view", forSegment: Segment.fill.rawValue)
        zoomControl.setToolTip("Actual pixels", forSegment: Segment.oneToOne.rawValue)
        zoomControl.setToolTip("Other zoom ratios", forSegment: Segment.menu.rawValue)
        zoomControl.setMenu(ratioMenu(), forSegment: Segment.menu.rawValue)
        zoomControl.setShowsMenuIndicator(true, forSegment: Segment.menu.rawValue)
        zoomControl.target = self
        zoomControl.action = #selector(zoomChosen(_:))
        zoomControl.setAccessibilityLabel("Zoom")
        zoomControl.setAccessibilityIdentifier("navigatorZoom")

        preview.onMove = { [weak self] point, isFinal in self?.moveView(to: point, isFinal: isFinal) }

        let header = NSStackView(views: [titleLabel, NSView(), zoomControl])
        header.orientation = .horizontal
        header.spacing = 6
        let stack = NSStackView(views: [header, preview])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 8, right: 12)
        for view in [header, preview] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        // Lightroom's Navigator is about as tall as a 3:2 photo is at its width.
        preview.heightAnchor.constraint(equalTo: preview.widthAnchor, multiplier: 2.0 / 3).isActive = true
        stack.setAccessibilityIdentifier("navigator")
        view = stack
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        update()
        state.addObserver(self) { [weak self] change in
            guard let self else { return }
            switch change {
            case .zoom, .presentation, .mode: update()
            case .zoomVisibleRect: updateRectangle()
            case .navigatorPreview: showPreview()
            case .selection: showSelectedPhoto()
            default: break
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(thumbnailDidUpdate(_:)),
            name: ThumbnailStore.didUpdateNotification, object: store.thumbnails
        )
        showSelectedPhoto()
    }

    private func ratioMenu() -> NSMenu {
        let menu = NSMenu()
        for ratio in ZoomRatio.menu {
            let item = NSMenuItem(title: ratio.title, action: #selector(ratioChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ratio.rawValue
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - State

    private func update() {
        let zoom = state.zoom
        zoomControl.setLabel(zoom.menuRatio.title, forSegment: Segment.menu.rawValue)
        zoomControl.setWidth(0, forSegment: Segment.menu.rawValue)
        let selected: Segment = zoom.isZoomed
            ? (zoom.ratio == .oneToOne ? .oneToOne : .menu)
            : (zoom.fit == .fit ? .fit : .fill)
        zoomControl.selectedSegment = selected.rawValue
        for item in zoomControl.menu(forSegment: Segment.menu.rawValue)?.items ?? [] {
            item.state = item.representedObject as? String == zoom.menuRatio.rawValue ? .on : .off
        }
        updateRectangle()
    }

    /// The rectangle shows only where a zoomable view is on screen: Develop, or the enlarged Library view.
    private var showsZoomedView: Bool {
        state.mode == .develop || state.presentation == .loupe
    }

    private func updateRectangle() {
        preview.showsOutline = showsZoomedView
        preview.shownRect = state.zoomVisibleRect
    }

    private func showSelectedPhoto() {
        let photo = state.selectedPhotoIDs.first.flatMap { try? store.viewContext.existingObject(with: $0) as? Photo }
        guard let photo, !photo.isDeleted else {
            shownPhotoID = nil
            preview.image = nil
            preview.setAccessibilityLabel("No photo")
            return
        }
        preview.setAccessibilityLabel(photo.fileName)
        guard photo.id != shownPhotoID else { return }
        shownPhotoID = photo.id
        loadThumbnail(for: photo.id)
    }

    /// A preset being previewed in Develop, or back to the thumbnail.
    private func showPreview() {
        if let preview = state.navigatorPreview {
            thumbnailTask?.cancel()
            self.preview.image = preview
        } else if let shownPhotoID {
            loadThumbnail(for: shownPhotoID)
        }
    }

    private func loadThumbnail(for id: UUID) {
        if let preview = state.navigatorPreview {
            self.preview.image = preview
            return
        }
        thumbnailTask?.cancel()
        if let cached = store.thumbnails.cachedImage(for: id) {
            preview.image = cached
            return
        }
        preview.image = nil
        let thumbnails = store.thumbnails
        thumbnailTask = Task { [weak self] in
            let image = await thumbnails.image(for: id)
            guard let self, !Task.isCancelled, shownPhotoID == id else { return }
            preview.image = image
        }
    }

    @objc private func thumbnailDidUpdate(_ notification: Notification) {
        guard let id = notification.userInfo?["id"] as? UUID, id == shownPhotoID else { return }
        loadThumbnail(for: id)
    }

    // MARK: - Actions

    @objc private func zoomChosen(_ sender: NSSegmentedControl) {
        var zoom = state.zoom
        switch Segment(rawValue: sender.selectedSegment) {
        case .fit?: zoom.fit = .fit; zoom.isZoomed = false
        case .fill?: zoom.fit = .fill; zoom.isZoomed = false
        case .oneToOne?: zoom.ratio = .oneToOne; zoom.isZoomed = true
        case .menu?: zoom.ratio = zoom.menuRatio; zoom.isZoomed = true
        case nil: return
        }
        apply(zoom)
    }

    @objc private func ratioChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let ratio = ZoomRatio(rawValue: raw) else { return }
        var zoom = state.zoom
        zoom.menuRatio = ratio
        zoom.ratio = ratio
        zoom.isZoomed = true
        apply(zoom)
    }

    /// Clicking or dragging in the preview: center the view on `point`, zooming in if the photo fits.
    private func moveView(to point: CGPoint, isFinal: Bool) {
        var zoom = state.zoom
        zoom.center = point
        if !zoom.isZoomed, zoom.fit == .fit { zoom.isZoomed = true }
        apply(zoom)
    }

    /// As in Lightroom, choosing a zoom in the Library grid enlarges the selected photo.
    private func apply(_ zoom: PhotoZoom) {
        state.zoom = zoom
        if state.mode == .library, state.presentation == .grid, !state.selectedPhotoIDs.isEmpty {
            state.presentation = .loupe
        }
        update()
    }
}

/// The Navigator's picture: the photo fitted in the box, with a white rectangle around the part on
/// screen — the whole photo when it fits — that animates as the zoom changes, as in Lightroom.
final class NavigatorPreviewView: NSView {
    var image: CGImage? { didSet { needsDisplay = true; updateOutline(animated: false) } }
    /// Whether to show the rectangle (only where a zoomable view is on screen).
    var showsOutline = false { didSet { if showsOutline != oldValue { updateOutline(animated: false) } } }
    /// The visible part of the photo, in unit photo coordinates; `nil` when all of it shows.
    var shownRect: CGRect? { didSet { if shownRect != oldValue { updateOutline(animated: true) } } }
    /// Called with a unit photo point while the user clicks or drags (`isFinal` on mouse up).
    var onMove: (CGPoint, Bool) -> Void = { _, _ in }

    /// The rectangle, a layer so it can animate between sizes.
    let outlineLayer = CAShapeLayer()
    static let outlineAnimationKey = "resize"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        outlineLayer.fillColor = nil
        outlineLayer.strokeColor = NSColor.white.cgColor
        outlineLayer.lineWidth = 1
        outlineLayer.actions = ["path": NSNull(), "hidden": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(outlineLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("navigatorPreview")
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange(_:)), name: AppSettings.didChangeNotification, object: nil
        )
    }

    /// Matte Color changed.
    @objc private func settingsDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The color behind the photo: the matte, resolved for this view's appearance.
    var matteColor: NSColor { GridColors.background(for: effectiveAppearance) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        updateOutline(animated: false)
    }

    /// Where the photo is drawn in the box.
    var photoRect: CGRect {
        guard let image, image.width > 0, image.height > 0, !bounds.isEmpty else { return .zero }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height).integral
    }

    /// The rectangle in view points: around the visible part, or the whole photo when it all shows.
    var outlineRect: CGRect? {
        let rect = photoRect
        guard showsOutline, rect.width > 0 else { return nil }
        let visible = shownRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return CGRect(
            x: rect.minX + visible.minX * rect.width, y: rect.minY + visible.minY * rect.height,
            width: visible.width * rect.width, height: visible.height * rect.height
        ).insetBy(dx: 0.5, dy: 0.5)
    }

    /// Animates when the rectangle changes size (Fit, Fill, a ratio); follows panning at once.
    private func updateOutline(animated: Bool) {
        guard let outline = outlineRect else {
            outlineLayer.isHidden = true
            outlineLayer.path = nil
            return
        }
        let newPath = CGPath(rect: outline, transform: nil)
        let oldBox = outlineLayer.path?.boundingBox
        outlineLayer.isHidden = false
        outlineLayer.frame = bounds
        let resized = oldBox.map { abs($0.width - outline.width) > 1 || abs($0.height - outline.height) > 1 } ?? false
        if animated, resized, let oldPath = outlineLayer.presentation()?.path ?? outlineLayer.path {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = oldPath
            animation.toValue = newPath
            animation.duration = 0.2
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            outlineLayer.add(animation, forKey: Self.outlineAnimationKey)
        } else if !animated || !resized {
            outlineLayer.removeAnimation(forKey: Self.outlineAnimationKey)
        }
        outlineLayer.path = newPath
    }

    override func draw(_ dirtyRect: NSRect) {
        // The matte behind photos (Settings ▸ Appearance ▸ Matte Color), as in the grid and Develop.
        GridColors.background(for: effectiveAppearance).setFill()
        bounds.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(image, in: photoRect)
    }

    private func unitPoint(for event: NSEvent) -> CGPoint? {
        let rect = photoRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: ((point.x - rect.minX) / rect.width).clamped(to: 0...1),
            y: ((point.y - rect.minY) / rect.height).clamped(to: 0...1)
        )
    }

    override func mouseDown(with event: NSEvent) {
        if let point = unitPoint(for: event) { onMove(point, false) }
    }

    override func mouseDragged(with event: NSEvent) {
        if let point = unitPoint(for: event) { onMove(point, false) }
    }

    override func mouseUp(with event: NSEvent) {
        if let point = unitPoint(for: event) { onMove(point, true) }
    }
}
