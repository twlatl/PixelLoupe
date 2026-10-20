import AppKit
import CoreData
import CoreImage
import QuartzCore

/// One Compare pane: a label tab ("Select" or "Candidate"), the zoomable photo, and its name, rating
/// and flag below.
///
/// Zooming and panning move the image already on screen immediately (Core Animation), then a sharp
/// render of just the visible area replaces it, so interaction stays fluid with large RAW files.
final class ComparePhotoView: NSView {
    enum Role {
        case select, candidate

        var title: String { self == .select ? "Select" : "Candidate" }
    }

    static let infoHeight: CGFloat = 28
    /// Space kept around a fitted photo so it clears the edges and the label tab.
    static let fitMargin = CGSize(width: 16, height: 40)

    let role: Role
    private let store: CatalogStore

    var onActivate: () -> Void = {}
    /// Called with the new viewport after the user pans this pane.
    var onPan: (CompareViewport) -> Void = { _ in }

    private(set) var photoID: NSManagedObjectID?
    private(set) var viewport: CompareViewport?
    /// Whether the photo fits the pane (the default), re-fitting whenever the pane resizes.
    private(set) var isFitted = true

    var isActive = false { didSet { updateActiveAppearance() } }

    private let imageArea = MatteView()
    private let baseLayer = CALayer()
    private let detailLayer = CALayer()
    private let tab = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let ratingLabel = NSTextField(labelWithString: "")
    private let flagView = NSImageView()

    private var source: CompareSource?
    private var loadTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var renderGeneration = 0
    private var lastDragPoint: CGPoint?

    init(role: Role, store: CatalogStore) {
        self.role = role
        self.store = store
        super.init(frame: .zero)

        imageArea.wantsLayer = true
        imageArea.layer?.masksToBounds = true
        for layer in [baseLayer, detailLayer] {
            layer.contentsGravity = .resize
            layer.minificationFilter = .trilinear
            layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            imageArea.layer?.addSublayer(layer)
        }
        detailLayer.magnificationFilter = .nearest
        imageArea.layer?.borderWidth = 2
        imageArea.setAccessibilityElement(true)
        imageArea.setAccessibilityRole(.image)
        imageArea.setAccessibilityIdentifier("compare.\(role.title)")
        imageArea.onMatteChange = { [weak self] in self?.updateActiveAppearance() }

        tab.stringValue = role.title
        tab.font = .systemFont(ofSize: 13, weight: .medium)
        tab.textColor = .white
        tab.drawsBackground = true
        tab.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        tab.alignment = .center
        tab.setAccessibilityIdentifier("compareTab.\(role.title)")

        nameLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setAccessibilityIdentifier("compareName.\(role.title)")
        ratingLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        ratingLabel.textColor = .secondaryLabelColor
        ratingLabel.setAccessibilityIdentifier("compareRating.\(role.title)")
        flagView.imageScaling = .scaleProportionallyDown

        let info = NSStackView(views: [nameLabel, ratingLabel, flagView])
        info.spacing = 10
        info.alignment = .centerY

        for view in [imageArea, tab, info] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let tabEdge = role == .select
            ? tab.trailingAnchor.constraint(equalTo: imageArea.trailingAnchor, constant: -8)
            : tab.leadingAnchor.constraint(equalTo: imageArea.leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            imageArea.topAnchor.constraint(equalTo: topAnchor),
            imageArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageArea.bottomAnchor.constraint(equalTo: info.topAnchor),
            tab.topAnchor.constraint(equalTo: imageArea.topAnchor, constant: 8),
            tabEdge,
            tab.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
            info.centerXAnchor.constraint(equalTo: centerXAnchor),
            info.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            info.heightAnchor.constraint(equalToConstant: Self.infoHeight),
            info.bottomAnchor.constraint(equalTo: bottomAnchor),
            flagView.widthAnchor.constraint(equalToConstant: 14),
            flagView.heightAnchor.constraint(equalToConstant: 14),
        ])
        updateActiveAppearance()
        // Monochrome Mode changes the active border's color.
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange(_:)), name: AppSettings.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(photoFileDidChange(_:)),
            name: ExternalEditMonitor.photoFileDidChangeNotification, object: store.externalEdits
        )
    }

    /// Another app saved this photo's file (Photo ▸ Edit In): load it again.
    @objc private func photoFileDidChange(_ notification: Notification) {
        guard let uuid = notification.userInfo?["id"] as? UUID, photo?.id == uuid, let id = photoID else { return }
        photoID = nil
        show(id)
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        updateActiveAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }

    /// Full-resolution size of the photo (after orientation), or an estimate until it's decoded.
    /// Full-resolution size of the photo as shown (after orientation and its crop), or an estimate
    /// until it's decoded.
    var imageSize: CGSize? {
        guard let photo else { return nil }
        let adjustments = photo.adjustments
        let crop = adjustments.crop.rect
        if let source { return source.croppedSize(adjustments) }
        guard photo.pixelWidth > 0, photo.pixelHeight > 0 else { return nil }
        var size = CGSize(width: Int(photo.pixelWidth), height: Int(photo.pixelHeight))
        if (photo.orientation >= 5) != adjustments.orientation.swapsDimensions { size = CGSize(width: size.height, height: size.width) }
        return CGSize(width: size.width * crop.width, height: size.height * crop.height)
    }

    var fitZoom: Double? {
        guard let imageSize, !imageArea.bounds.isEmpty else { return nil }
        return CompareViewport.fitZoom(imageSize: imageSize, paneSize: fitSize(imageArea.bounds.size), backingScale: backingScale)
    }

    private var photo: Photo? {
        photoID.flatMap { try? store.viewContext.existingObject(with: $0) as? Photo }
    }

    // MARK: - Content

    func show(_ id: NSManagedObjectID?) {
        guard id != photoID else { return }
        photoID = id
        source = nil
        viewport = nil
        isFitted = true
        baseLayer.contents = nil
        detailLayer.contents = nil
        loadTask?.cancel()
        refreshInfo()
        guard let photo else { return }
        baseLayer.contents = store.thumbnails.cachedImage(for: photo.id)
        layoutLayers()

        let location = store.sourceLocation(of: photo)
        let uuid = photo.id
        let thumbnails = store.thumbnails
        loadTask = Task { [weak self] in
            if self?.baseLayer.contents == nil, let thumbnail = await thumbnails.image(for: uuid) {
                guard let self, photoID == id else { return }
                baseLayer.contents = thumbnail
            }
            let loaded = await CompareSource.load(location)
            guard let self, !Task.isCancelled, photoID == id else { return }
            source = loaded
            if isFitted, let fitZoom {
                viewport = CompareViewport(zoom: fitZoom)   // the decoded size may differ from the estimate
            } else if let viewport {
                setViewport(viewport)   // re-clamp with the decoded size
            }
            layoutLayers()
            scheduleRender(delay: 0)
        }
    }

    /// Fits the whole photo in the pane, and keeps it fitted as the pane resizes.
    func fitToPane() {
        isFitted = true
        viewport = fitZoom.map { CompareViewport(zoom: $0) }
        layoutLayers()
        scheduleRender()
    }

    func setViewport(_ newValue: CompareViewport) {
        isFitted = false
        var viewport = newValue
        if let imageSize {
            viewport.clampCenter(imageSize: imageSize, paneBounds: imageArea.bounds, backingScale: backingScale)
        }
        self.viewport = viewport
        layoutLayers()
        scheduleRender()
    }

    /// Re-reads the rating and flag, and re-renders if the saved Develop settings changed.
    func photoDidChange() {
        refreshInfo()
        scheduleRender(delay: 0.05)
    }

    private func refreshInfo() {
        guard let photo else {
            nameLabel.stringValue = ""
            ratingLabel.stringValue = ""
            flagView.image = nil
            return
        }
        nameLabel.stringValue = photo.fileName
        ratingLabel.stringValue = RatingFormatter.stars(Int(photo.rating))
        ratingLabel.setAccessibilityValue("\(photo.rating) stars")
        switch photo.photoFlag {
        case .picked:
            flagView.image = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: "Picked")
            flagView.contentTintColor = .labelColor
        case .rejected:
            flagView.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Rejected")
            flagView.contentTintColor = .systemRed
        case .unflagged:
            flagView.image = nil
        }
        imageArea.setAccessibilityLabel("\(role.title): \(photo.fileName)")
    }

    private func updateActiveAppearance() {
        imageArea.layer?.borderColor = isActive ? Accent.color.cgColor : NSColor.clear.cgColor
        imageArea.setAccessibilityValue(isActive ? "active" : "inactive")
    }

    // MARK: - Layout and rendering

    private func fitSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width - Self.fitMargin.width * 2, 1), height: max(size.height - Self.fitMargin.height * 2, 1))
    }

    override func layout() {
        super.layout()
        if isFitted || viewport == nil, let fitZoom {
            viewport = CompareViewport(zoom: fitZoom)
        }
        layoutLayers()
        scheduleRender()
    }

    private func layoutLayers() {
        guard let imageSize, let viewport else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = viewport.imageRect(imageSize: imageSize, paneBounds: imageArea.bounds, backingScale: backingScale)
        baseLayer.frame = rect
        // The sharp detail render is only valid for the viewport it was made for.
        detailLayer.isHidden = true
        CATransaction.commit()
    }

    private func scheduleRender(delay: TimeInterval = 0.12) {
        renderGeneration += 1
        let generation = renderGeneration
        let previous = renderTask
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await previous?.value   // one render at a time per decoder
            guard let self, !Task.isCancelled, generation == renderGeneration else { return }
            await render()
        }
    }

    private func render() async {
        guard let source, let photo, let viewport, let imageSize, !imageArea.bounds.isEmpty else { return }
        let adjustments = photo.adjustments
        let paneBounds = imageArea.bounds
        let scale = backingScale
        let fit = CompareViewport.fitZoom(imageSize: imageSize, paneSize: fitSize(paneBounds.size), backingScale: scale)
        let generation = renderGeneration

        if viewport.zoom <= fit * 1.02 {
            // Whole photo visible: render it at the size it's shown.
            let pixels = max(paneBounds.width, paneBounds.height) * scale
            guard let image = await source.render(adjustments: adjustments, region: nil, renderScale: nil, maxPixels: pixels),
                  generation == renderGeneration else { return }
            baseLayer.contents = image.image
        } else {
            // Zoomed in: render only the visible part, at the zoom's resolution (at most 1:1).
            let region = viewport.visibleImageRegion(imageSize: imageSize, paneBounds: paneBounds, backingScale: scale)
            guard region.width >= 1, region.height >= 1,
                  let image = await source.render(
                    adjustments: adjustments, region: region, renderScale: min(viewport.zoom, 1), maxPixels: nil
                  ),
                  generation == renderGeneration else { return }
            let rect = viewport.imageRect(imageSize: imageSize, paneBounds: paneBounds, backingScale: scale)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            detailLayer.frame = CGRect(
                x: rect.minX + region.minX / imageSize.width * rect.width,
                y: rect.minY + region.minY / imageSize.height * rect.height,
                width: region.width / imageSize.width * rect.width,
                height: region.height / imageSize.height * rect.height
            )
            detailLayer.contents = image.image
            detailLayer.isHidden = false
            CATransaction.commit()
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        onActivate()
        lastDragPoint = convert(event.locationInWindow, from: nil)
        if canPan { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { lastDragPoint = point }
        guard canPan, let last = lastDragPoint, var viewport, let imageSize else { return }
        viewport.pan(
            by: CGVector(dx: point.x - last.x, dy: point.y - last.y),
            imageSize: imageSize, paneBounds: imageArea.bounds, backingScale: backingScale
        )
        self.viewport = viewport
        layoutLayers()
        scheduleRender()
        onPan(viewport)
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
        NSCursor.arrow.set()
    }

    private var canPan: Bool {
        guard let viewport, let fitZoom else { return false }
        return viewport.zoom > fitZoom * 1.02
    }
}

/// A decoder for one Compare pane, used by one render at a time off the main thread.
nonisolated final class CompareSource: @unchecked Sendable {
    private let source: DevelopSource
    let nativeSize: CGSize

    private init(source: DevelopSource) {
        self.source = source
        nativeSize = source.nativeSize
    }

    func croppedSize(_ adjustments: PhotoAdjustments) -> CGSize {
        source.croppedSize(adjustments)
    }

    @concurrent
    static func load(_ location: PhotoSourceLocation) async -> CompareSource? {
        DevelopSource.open(location).map(CompareSource.init)
    }

    /// Renders the whole photo to fit `maxPixels`, or `region` (full-resolution pixels) at `renderScale`.
    @concurrent
    func render(
        adjustments: PhotoAdjustments, region: CGRect?, renderScale: Double?, maxPixels: CGFloat?
    ) async -> PhotoRenderer.Rendered? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        if let region, let renderScale {
            let scale = CGFloat(renderScale)
            let image = source.image(with: adjustments, scale: scale)
            let crop = CGRect(
                x: region.minX * scale, y: region.minY * scale,
                width: region.width * scale, height: region.height * scale
            ).integral.intersection(image.extent)
            guard !crop.isEmpty,
                  let cgImage = PhotoRenderer.context.createCGImage(image, from: crop, format: .RGBA8, colorSpace: colorSpace)
            else { return nil }
            return PhotoRenderer.Rendered(image: cgImage)
        }
        let image = source.image(with: adjustments, scale: source.scale(toFit: maxPixels ?? 1024, adjustments: adjustments))
        guard let cgImage = PhotoRenderer.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace)
        else { return nil }
        return PhotoRenderer.Rendered(image: cgImage)
    }
}
