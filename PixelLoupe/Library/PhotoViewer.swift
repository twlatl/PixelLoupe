import AppKit
import AVKit
import CoreData
import QuartzCore

/// Shows one photo as large as fits. The grid thumbnail appears immediately, then is replaced by
/// a render at the view's full pixel size with the photo's Develop settings.
///
/// With ``zoom`` set (the enlarged Library view) it also does Lightroom's Fill and zoom ratios: the
/// fitted render is scaled at once, then a sharp render of just the visible part is laid over it, as
/// Compare does. A click switches between the fit choice and the zoom, and dragging pans.
final class PhotoViewer: NSView {
    private let store: CatalogStore
    /// Clips the zoomed photo to the area inside the inset.
    private let clipLayer = CALayer()
    private let imageLayer = CALayer()
    /// The sharp render of the visible part while zoomed past the fitted render's resolution.
    private let detailLayer = CALayer()
    private let clickView = ZoomClickView()
    private let inset: CGFloat
    private var photoID: NSManagedObjectID?
    private var renderedSize: CGFloat = 0
    private var loadTask: Task<Void, Never>?
    /// Plays a video (the enlarged view and full screen show movies in it).
    private let playerView = AVPlayerView()
    /// "The file … could not be found" with a Locate… button, over the thumbnail.
    private let missingBanner = NSVisualEffectView()
    private let missingLabel = NSTextField(labelWithString: "")

    /// Fill and zoom ratios; `nil` always fits (full screen).
    var zoom: PhotoZoom? {
        didSet {
            guard zoom != oldValue else { return }
            if zoom?.isZoomed != oldValue?.isZoomed || zoom?.fit != oldValue?.fit { clickView.zoomDidChange() }
            // Zooming in or out (not panning) animates, as the Navigator's rectangle does.
            let resized = zoom?.isZoomed != oldValue?.isZoomed || zoom?.fit != oldValue?.fit
                || (zoom?.isZoomed == true && zoom?.ratio != oldValue?.ratio)
            layoutImage(animated: resized && oldValue != nil)
        }
    }

    /// The user zoomed (a click) or panned: the new zoom, for the shared state.
    var onZoomChange: (PhotoZoom) -> Void = { _ in }
    /// The visible part of the photo (unit coordinates), or `nil` when all of it shows.
    var onVisibleRectChange: (CGRect?) -> Void = { _ in }

    private var zoomSource: CompareSource?
    private var zoomSourceTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var detailGeneration = 0

    init(store: CatalogStore, inset: CGFloat) {
        self.store = store
        self.inset = inset
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        clipLayer.masksToBounds = true
        clipLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        for layer in [imageLayer, detailLayer] {
            layer.minificationFilter = .trilinear
            layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            clipLayer.addSublayer(layer)
        }
        imageLayer.contentsGravity = .resizeAspect
        detailLayer.contentsGravity = .resize
        detailLayer.isHidden = true
        layer?.addSublayer(clipLayer)
        clickView.isActive = { [weak self] in
            guard let self, zoom != nil, let photo, !photo.isVideo else { return false }
            return true
        }
        clickView.isZoomed = { [weak self] in self?.zoom?.isZoomed ?? false }
        clickView.onClick = { [weak self] point in self?.clicked(at: point) }
        clickView.onPan = { [weak self] delta in self?.pan(by: delta) }
        addSubview(clickView)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("photoViewer")
        NotificationCenter.default.addObserver(
            self, selector: #selector(thumbnailDidUpdate(_:)),
            name: ThumbnailStore.didUpdateNotification, object: store.thumbnails
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(availabilityDidChange(_:)),
            name: FileAvailability.didChangeNotification, object: store.availability
        )
        makeMissingBanner()
        playerView.controlsStyle = .floating
        playerView.isHidden = true
        playerView.setAccessibilityIdentifier("videoPlayer")
        addSubview(playerView, positioned: .below, relativeTo: missingBanner)
    }

    private func makeMissingBanner() {
        missingBanner.material = .hudWindow
        missingBanner.blendingMode = .withinWindow
        missingBanner.state = .active
        missingBanner.wantsLayer = true
        missingBanner.layer?.cornerRadius = 8
        missingBanner.isHidden = true
        let button = NSButton(title: "Locate…", target: nil, action: #selector(PixelLoupeActions.locateMissingPhoto(_:)))
        button.setAccessibilityIdentifier("viewerLocateButton")
        let stack = NSStackView(views: [missingLabel, button])
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        missingBanner.addSubview(stack)
        missingBanner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(missingBanner)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: missingBanner.topAnchor),
            stack.bottomAnchor.constraint(equalTo: missingBanner.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: missingBanner.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: missingBanner.trailingAnchor),
            missingBanner.centerXAnchor.constraint(equalTo: centerXAnchor),
            missingBanner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            missingBanner.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            missingBanner.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    private func updateMissingBanner() {
        guard let photo, store.availability.isMissing(photo.id) else {
            missingBanner.isHidden = true
            return
        }
        missingLabel.stringValue = "The file “\(photo.fileName)” could not be found."
        missingBanner.isHidden = false
    }

    @objc private func availabilityDidChange(_ notification: Notification) {
        updateMissingBanner()
        if photo.map({ !store.availability.isMissing($0.id) }) == true { renderedSize = 0; loadFullSize() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        clickView.frame = bounds
        playerView.frame = bounds.insetBy(dx: inset, dy: inset)
        layoutImage()
        // Re-render if the view has grown noticeably since the last full-size render.
        if photoID != nil, targetPixels > renderedSize * 1.25 { loadFullSize() }
    }

    private var targetPixels: CGFloat {
        let fitted = max(bounds.width, bounds.height) * backingScale
        // Fill shows the photo larger than fitting does; render it big enough for that.
        guard let zoom, zoom.fit == .fill, let imageSize, imageSize.width > 0, imageSize.height > 0 else { return fitted }
        let pane = paneRect.size
        let fill = max(pane.width / imageSize.width, pane.height / imageSize.height) * backingScale
        return max(fitted, max(imageSize.width, imageSize.height) * fill)
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }

    /// The area the photo is shown in.
    private var paneRect: CGRect { bounds.insetBy(dx: inset, dy: inset) }

    private var photo: Photo? {
        photoID.flatMap { try? store.viewContext.existingObject(with: $0) as? Photo }
    }

    func show(_ id: NSManagedObjectID?) {
        guard id != photoID else { return }
        photoID = id
        renderedSize = 0
        loadTask?.cancel()
        zoomSourceTask?.cancel()
        zoomSource = nil
        detailLayer.contents = nil
        detailLayer.isHidden = true
        stopPlayback()
        guard let photo else {
            imageLayer.contents = nil
            setAccessibilityLabel(nil)
            missingBanner.isHidden = true
            layoutImage()
            return
        }
        if photo.isVideo {
            // A movie plays in place of the picture; its poster frame shows until it loads.
            imageLayer.contents = store.thumbnails.cachedImage(for: photo.id)
            setAccessibilityLabel(photo.fileName)
            updateMissingBanner()
            playerView.player = AVPlayer(url: photo.fileURL)
            playerView.isHidden = false
            return
        }
        setAccessibilityLabel(photo.fileName)
        imageLayer.contents = store.thumbnails.cachedImage(for: photo.id)
        updateMissingBanner()
        loadFullSize()
        layoutImage()
    }

    private func stopPlayback() {
        playerView.player?.pause()
        playerView.player = nil
        playerView.isHidden = true
    }

    private func loadFullSize() {
        guard let photo, !photo.isVideo else { return }
        let id = photoID
        let uuid = photo.id
        let url = photo.fileURL
        let adjustments = photo.adjustments
        let pixels = max(targetPixels, 512)
        let thumbnails = store.thumbnails
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            if self?.imageLayer.contents == nil, let thumbnail = await thumbnails.image(for: uuid) {
                guard let self, !Task.isCancelled, photoID == id else { return }
                imageLayer.contents = thumbnail
            }
            let rendered = await PhotoRenderer.render(url, adjustments: adjustments, maxPixels: pixels)
            guard let self, !Task.isCancelled, photoID == id, let rendered else { return }
            imageLayer.contents = rendered.image
            renderedSize = pixels
        }
    }

    /// The photo was edited elsewhere: render it again.
    @objc private func thumbnailDidUpdate(_ notification: Notification) {
        guard let uuid = notification.userInfo?["id"] as? UUID, uuid == photo?.id else { return }
        renderedSize = 0
        loadFullSize()
        layoutImage()
    }

    // MARK: - Zoom

    /// The photo's full-resolution size after cropping: the decoder's once loaded, else from the catalog.
    private var imageSize: CGSize? {
        guard let photo else { return nil }
        let adjustments = photo.adjustments
        if let zoomSource { return zoomSource.croppedSize(adjustments) }
        guard photo.pixelWidth > 0, photo.pixelHeight > 0 else { return nil }
        var size = CGSize(width: Int(photo.pixelWidth), height: Int(photo.pixelHeight))
        if (photo.orientation >= 5) != adjustments.orientation.swapsDimensions { size = CGSize(width: size.height, height: size.width) }
        return CGSize(width: size.width * adjustments.crop.rect.width, height: size.height * adjustments.crop.rect.height)
    }

    /// Where the photo is drawn and how much of it shows, for the current zoom (`nil` when it simply fits).
    private func currentViewport() -> CompareViewport? {
        guard let zoom, zoom.isZoomed || zoom.fit == .fill, let photo, !photo.isVideo,
              let imageSize, !paneRect.isEmpty else { return nil }
        let pane = CGSize(width: paneRect.width * backingScale, height: paneRect.height * backingScale)
        var viewport = CompareViewport(zoom: zoom.scale(imageSize: imageSize, paneSize: pane), center: zoom.center)
        viewport.clampCenter(imageSize: imageSize, paneBounds: CGRect(origin: .zero, size: paneRect.size), backingScale: backingScale)
        return viewport
    }

    /// How long zooming in or out animates (the same as the Navigator's rectangle).
    static let zoomAnimationDuration: CFTimeInterval = 0.2

    private func layoutImage(animated: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        clipLayer.frame = paneRect
        let pane = CGRect(origin: .zero, size: paneRect.size)
        guard let viewport = currentViewport(), let imageSize else {
            // Fitted. With a known size the frame is the fitted rect itself, so zooming can animate from it.
            if let imageSize, imageSize.width > 0, imageSize.height > 0, photo?.isVideo != true {
                let scale = min(pane.width / imageSize.width, pane.height / imageSize.height)
                let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                imageLayer.contentsGravity = .resize
                setImageFrame(CGRect(x: pane.midX - size.width / 2, y: pane.midY - size.height / 2,
                                     width: size.width, height: size.height), animated: animated)
            } else {
                imageLayer.contentsGravity = .resizeAspect
                imageLayer.frame = pane
            }
            detailLayer.isHidden = true
            detailTask?.cancel()
            onVisibleRectChange(nil)
            return
        }
        imageLayer.contentsGravity = .resize
        setImageFrame(viewport.imageRect(imageSize: imageSize, paneBounds: pane, backingScale: backingScale), animated: animated)
        // A sharp render is only valid for the viewport it was made for.
        detailLayer.isHidden = true
        let region = viewport.visibleImageRegion(imageSize: imageSize, paneBounds: pane, backingScale: backingScale)
        onVisibleRectChange(CGRect(
            x: region.minX / imageSize.width, y: region.minY / imageSize.height,
            width: region.width / imageSize.width, height: region.height / imageSize.height
        ))
        // Sharper than the fitted render can show: render the visible part.
        if viewport.zoom * Double(max(imageSize.width, imageSize.height)) > Double(renderedSize) * 1.02 {
            // After the zoom animation, so the sharp render doesn't appear mid-motion.
            scheduleDetailRender(delay: animated ? Self.zoomAnimationDuration + 0.05 : 0.1)
        }
    }

    /// Moves the photo to `frame`, animating from where it shows now when asked.
    private func setImageFrame(_ frame: CGRect, animated: Bool) {
        let from = imageLayer.presentation()?.frame ?? imageLayer.frame
        imageLayer.frame = frame
        guard animated, from != frame, !from.isEmpty else {
            imageLayer.removeAnimation(forKey: "zoom")
            return
        }
        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = NSValue(rect: CGRect(origin: .zero, size: from.size))
        bounds.toValue = NSValue(rect: CGRect(origin: .zero, size: frame.size))
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: CGPoint(x: from.midX, y: from.midY))
        position.toValue = NSValue(point: CGPoint(x: frame.midX, y: frame.midY))
        let group = CAAnimationGroup()
        group.animations = [bounds, position]
        group.duration = Self.zoomAnimationDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        imageLayer.add(group, forKey: "zoom")
    }

    private func scheduleDetailRender(delay: TimeInterval) {
        detailGeneration += 1
        let generation = detailGeneration
        let previous = detailTask
        detailTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await previous?.value   // one render at a time per decoder
            guard let self, !Task.isCancelled, generation == detailGeneration else { return }
            await renderDetail()
        }
    }

    private func renderDetail() async {
        guard let photo, !photo.isVideo else { return }
        if zoomSource == nil {
            let id = photoID
            let loaded = await CompareSource.load(photo.fileURL)
            guard photoID == id else { return }
            zoomSource = loaded
        }
        guard let zoomSource, let viewport = currentViewport(), let imageSize else { return }
        let pane = CGRect(origin: .zero, size: paneRect.size)
        let scale = backingScale
        let region = viewport.visibleImageRegion(imageSize: imageSize, paneBounds: pane, backingScale: scale)
        let generation = detailGeneration
        guard region.width >= 1, region.height >= 1,
              let image = await zoomSource.render(
                adjustments: photo.adjustments, region: region, renderScale: min(viewport.zoom, 1), maxPixels: nil
              ),
              generation == detailGeneration, let current = currentViewport(), current == viewport else { return }
        let rect = viewport.imageRect(imageSize: imageSize, paneBounds: pane, backingScale: scale)
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

    /// A click: zoom in centered on the clicked point, or back out.
    private func clicked(at point: CGPoint) {
        guard var zoom else { return }
        zoom.toggle(at: photoPoint(at: point))
        onZoomChange(zoom)
    }

    private func pan(by delta: CGVector) {
        guard var zoom, var viewport = currentViewport(), let imageSize else { return }
        let pane = CGRect(origin: .zero, size: paneRect.size)
        viewport.pan(by: delta, imageSize: imageSize, paneBounds: pane, backingScale: backingScale)
        zoom.center = viewport.center
        onZoomChange(zoom)
    }

    /// The photo point (unit coordinates) under a view point, where the photo is drawn now.
    private func photoPoint(at point: CGPoint) -> CGPoint? {
        let frame = imageLayer.frame.offsetBy(dx: paneRect.minX, dy: paneRect.minY)
        var shown = frame
        if imageLayer.contentsGravity == .resizeAspect, let imageSize, imageSize.width > 0, imageSize.height > 0 {
            let fit = min(frame.width / imageSize.width, frame.height / imageSize.height)
            let size = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
            shown = CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        }
        guard shown.width > 0, shown.height > 0 else { return nil }
        return CGPoint(
            x: ((point.x - shown.minX) / shown.width).clamped(to: 0...1),
            y: ((point.y - shown.minY) / shown.height).clamped(to: 0...1)
        )
    }
}

/// The Library's enlarged view: the selected photo filling the grid area on the matte, with its
/// name, rating and flag below.
final class LoupeViewController: NSViewController {
    private let store: CatalogStore
    private let state: LibraryState
    private lazy var viewer = PhotoViewer(store: store, inset: 16)
    private let infoLabel = NSTextField(labelWithString: "")

    /// A photo to show instead of the selected one (the secondary window's Loupe – Live and Locked).
    var pinnedPhotoID: NSManagedObjectID? {
        didSet { if pinnedPhotoID != oldValue, isViewLoaded { refresh() } }
    }

    /// The photo on show.
    var shownPhotoID: NSManagedObjectID? { pinnedPhotoID ?? state.selectedPhotoIDs.first }

    init(store: CatalogStore, state: LibraryState) {
        self.store = store
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let matte = MatteView()
        matte.setAccessibilityIdentifier("loupeView")
        infoLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.alignment = .center
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.setAccessibilityIdentifier("loupeInfo")
        for view in [viewer, infoLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            matte.addSubview(view)
        }
        NSLayoutConstraint.activate([
            viewer.topAnchor.constraint(equalTo: matte.topAnchor),
            viewer.leadingAnchor.constraint(equalTo: matte.leadingAnchor),
            viewer.trailingAnchor.constraint(equalTo: matte.trailingAnchor),
            viewer.bottomAnchor.constraint(equalTo: infoLabel.topAnchor, constant: -4),
            infoLabel.leadingAnchor.constraint(greaterThanOrEqualTo: matte.leadingAnchor, constant: 16),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: matte.trailingAnchor, constant: -16),
            infoLabel.centerXAnchor.constraint(equalTo: matte.centerXAnchor),
            infoLabel.bottomAnchor.constraint(equalTo: matte.bottomAnchor, constant: -8),
        ])
        view = matte
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        viewer.zoom = state.zoom
        viewer.onZoomChange = { [weak self] zoom in self?.state.zoom = zoom }
        viewer.onVisibleRectChange = { [weak self] rect in
            guard let self, state.presentation == .loupe, state.mode == .library else { return }
            state.zoomVisibleRect = rect
        }
        state.addObserver(self) { [weak self] change in
            guard let self else { return }
            switch change {
            case .selection: refresh()
            case .zoom: viewer.zoom = state.zoom
            default: break
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(contextObjectsDidChange(_:)),
            name: .NSManagedObjectContextObjectsDidChange, object: store.viewContext
        )
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    @objc private func contextObjectsDidChange(_ notification: Notification) {
        if !view.isHiddenOrHasHiddenAncestor { refresh() }
    }

    func refresh() {
        let id = shownPhotoID
        viewer.show(id)
        guard let photo = id.flatMap({ try? store.viewContext.existingObject(with: $0) as? Photo }) else {
            infoLabel.stringValue = ""
            return
        }
        let position = state.photoOrder.firstIndex(of: photo.objectID).map { "\($0 + 1) of \(state.photoOrder.count)" }
        infoLabel.stringValue = [
            photo.fileName,
            photo.rating > 0 ? String(repeating: "★", count: Int(photo.rating)) : nil,
            photo.photoFlag == .unflagged ? nil : photo.photoFlag.title,
            position,
        ].compactMap { $0 }.joined(separator: "   ·   ")
    }
}

/// Full-screen photo view (F): a black, borderless window covering the catalog window's display.
final class FullScreenPhotoController: NSWindowController {
    private let state: LibraryState
    private let viewer: PhotoViewer
    private var previousPresentationOptions: NSApplication.PresentationOptions = []

    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    init(store: CatalogStore, state: LibraryState, screen: NSScreen) {
        self.state = state
        viewer = PhotoViewer(store: store, inset: 0)
        let window = KeyableWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.level = .normal
        window.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
        window.identifier = NSUserInterfaceItemIdentifier("fullScreenPhotoWindow")
        window.isReleasedWhenClosed = false
        window.contentView = viewer
        window.setFrame(screen.frame, display: false)
        super.init(window: window)
        state.addObserver(self) { [weak self] change in
            if change == .selection { self?.viewer.show(self?.state.selectedPhotoIDs.first) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        previousPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window?.makeKeyAndOrderFront(nil)
        viewer.show(state.selectedPhotoIDs.first)
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func dismiss() {
        window?.orderOut(nil)
        NSApp.presentationOptions = previousPresentationOptions
    }
}
