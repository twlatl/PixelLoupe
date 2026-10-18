import AppKit
import CoreData

/// Survey (N): every selected photo side by side, as large as fits, to pick the best (Lightroom's
/// Survey view). The active photo is first in `state.selectedPhotoIDs` (outlined; ratings, flags and
/// the inspector apply to it). Clicking a photo makes it active; its close button drops it from the
/// survey (and the selection). ← and → move the active photo.
///
/// A Library view; the Library shows it while `state.presentation == .survey`. The secondary window
/// shows one for its own view state.
final class SurveyViewController: NSViewController {
    static let spacing: CGFloat = 12
    static let margin: CGFloat = 16

    private let store: CatalogStore
    private let state: LibraryState
    private let container = SurveyContainerView()
    private var cells: [NSManagedObjectID: SurveyPhotoView] = [:]

    /// The photos on show, in grid order.
    private(set) var photoIDs: [NSManagedObjectID] = []

    init(store: CatalogStore, state: LibraryState) {
        self.store = store
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let matte = MatteView()
        matte.setAccessibilityIdentifier("surveyView")
        container.translatesAutoresizingMaskIntoConstraints = false
        container.onLayout = { [weak self] in self?.layoutCells() }
        matte.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: matte.topAnchor),
            container.leadingAnchor.constraint(equalTo: matte.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: matte.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: matte.bottomAnchor),
        ])
        view = matte
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        state.addObserver(self) { [weak self] change in
            switch change {
            case .selection, .photoOrder: self?.reload()
            default: break
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(contextObjectsDidChange(_:)),
            name: .NSManagedObjectContextObjectsDidChange, object: store.viewContext
        )
    }

    /// Called by the host when Survey is shown.
    func refresh() {
        reload()
    }

    /// The selection, in grid order (photos the grid no longer shows are left out).
    static func surveyPhotos<ID: Hashable>(selection: [ID], order: [ID]) -> [ID] {
        let selected = Set(selection)
        let ordered = order.filter(selected.contains)
        return ordered.isEmpty ? selection : ordered
    }

    private var activeID: NSManagedObjectID? { state.selectedPhotoIDs.first }

    private func reload() {
        guard isViewLoaded, !view.isHiddenOrHasHiddenAncestor else { return }
        photoIDs = Self.surveyPhotos(selection: state.selectedPhotoIDs, order: state.photoOrder)
        // Nothing left to survey (the selection was cleared): back to the grid.
        if photoIDs.isEmpty, state.presentation == .survey { state.presentation = .grid }
        let shown = Set(photoIDs)
        for (id, cell) in cells where !shown.contains(id) {
            cell.removeFromSuperview()
            cells[id] = nil
        }
        for id in photoIDs where cells[id] == nil {
            let cell = SurveyPhotoView(store: store)
            cell.onActivate = { [weak self] in self?.activate(id) }
            cell.onRemove = { [weak self] in self?.remove(id) }
            cell.show(id)
            container.addSubview(cell)
            cells[id] = cell
        }
        for (id, cell) in cells { cell.isActive = id == activeID }
        layoutCells()
    }

    private func layoutCells() {
        let bounds = container.bounds.insetBy(dx: Self.margin, dy: Self.margin)
        let aspects = photoIDs.compactMap { cells[$0]?.aspectRatio }
        let aspect = aspects.isEmpty ? 1.5 : aspects.reduce(0, +) / CGFloat(aspects.count)
        let frames = SurveyLayout.cells(count: photoIDs.count, in: bounds, aspectRatio: aspect,
                                        spacing: Self.spacing, captionHeight: SurveyPhotoView.captionHeight)
        for (id, frame) in zip(photoIDs, frames) {
            cells[id]?.frame = frame.integral
        }
    }

    /// Makes `id` the active photo (first in the selection) without changing what's surveyed.
    func activate(_ id: NSManagedObjectID) {
        guard state.selectedPhotoIDs.contains(id), activeID != id else { return }
        state.selectedPhotoIDs = [id] + state.selectedPhotoIDs.filter { $0 != id }
    }

    /// ← and →: the previous or next surveyed photo becomes active.
    func stepActive(by offset: Int) {
        guard let activeID, let index = photoIDs.firstIndex(of: activeID),
              photoIDs.indices.contains(index + offset) else { return }
        activate(photoIDs[index + offset])
    }

    /// The close button: drops the photo from the survey. The next one becomes active if it was.
    func remove(_ id: NSManagedObjectID) {
        guard photoIDs.count > 1, let index = photoIDs.firstIndex(of: id) else { return }
        var remaining = state.selectedPhotoIDs.filter { $0 != id }
        if id == activeID {
            let next = photoIDs[index + 1 < photoIDs.count ? index + 1 : index - 1]
            remaining = [next] + remaining.filter { $0 != next }
        }
        state.selectedPhotoIDs = remaining
    }

    /// The photo views, in grid order (for tests).
    var photoViews: [SurveyPhotoView] { photoIDs.compactMap { cells[$0] } }

    @objc private func contextObjectsDidChange(_ notification: Notification) {
        let changed = [NSUpdatedObjectsKey, NSRefreshedObjectsKey]
            .flatMap { notification.userInfo?[$0] as? Set<NSManagedObject> ?? [] }
            .map(\.objectID)
        for id in changed { cells[id]?.photoDidChange() }
    }
}

/// Lays out Survey's photos from the top left, and tells the controller when its size changes.
final class SurveyContainerView: NSView {
    var onLayout: () -> Void = {}

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        onLayout()
    }
}

/// One photo in Survey: the photo fitted to its cell, outlined while active, its name, rating and
/// flag below, and a close button in the corner while the pointer is over it.
///
/// The grid thumbnail shows at once; when the cell is larger than the thumbnail, a render at the
/// cell's size with the photo's Develop settings replaces it.
final class SurveyPhotoView: NSView {
    static let captionHeight: CGFloat = 24

    private let store: CatalogStore
    var onActivate: () -> Void = {}
    var onRemove: () -> Void = {}

    private(set) var photoID: NSManagedObjectID?
    var isActive = false { didSet { if isActive != oldValue { updateActiveAppearance() } } }

    private let imageLayer = CALayer()
    private let caption = NSTextField(labelWithString: "")
    private let removeButton = NSButton()
    private var loadTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    /// The long side, in pixels, of the image on show (the thumbnail's, or the last render's).
    private var shownPixels: CGFloat = 0

    init(store: CatalogStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(imageLayer)

        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        caption.setAccessibilityIdentifier("surveyCaption")
        addSubview(caption)

        removeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove from Survey")
        removeButton.isBordered = false
        removeButton.imagePosition = .imageOnly
        removeButton.symbolConfiguration = .init(pointSize: 16, weight: .regular)
            .applying(.init(paletteColors: [.white, NSColor.black.withAlphaComponent(0.6)]))
        removeButton.target = self
        removeButton.action = #selector(removeClicked(_:))
        removeButton.toolTip = "Remove from Survey"
        removeButton.setAccessibilityIdentifier("surveyRemove")
        removeButton.isHidden = true
        addSubview(removeButton)

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("surveyPhoto")
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange(_:)), name: AppSettings.didChangeNotification, object: nil
        )
        updateActiveAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var photo: Photo? {
        photoID.flatMap { try? store.viewContext.existingObject(with: $0) as? Photo }
    }

    /// The photo's width ÷ height as shown (after orientation and crop), or nil if unknown.
    var aspectRatio: CGFloat? {
        guard let photo, photo.pixelWidth > 0, photo.pixelHeight > 0 else { return nil }
        let adjustments = photo.adjustments
        var size = CGSize(width: Int(photo.pixelWidth), height: Int(photo.pixelHeight))
        if (photo.orientation >= 5) != adjustments.orientation.swapsDimensions { size = CGSize(width: size.height, height: size.width) }
        let crop = adjustments.crop.rect
        return size.width * crop.width / max(size.height * crop.height, 1)
    }

    func show(_ id: NSManagedObjectID) {
        photoID = id
        shownPixels = 0
        imageLayer.contents = nil
        refreshCaption()
        guard let photo else { return }
        if let cached = store.thumbnails.cachedImage(for: photo.id) { setImage(cached) }
        let uuid = photo.id
        let thumbnails = store.thumbnails
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            if self?.imageLayer.contents == nil, let thumbnail = await thumbnails.image(for: uuid) {
                guard let self, !Task.isCancelled, photoID == id else { return }
                setImage(thumbnail)
            }
            self?.scheduleRender(delay: 0)
        }
    }

    /// The rating, flag or Develop settings changed.
    func photoDidChange() {
        refreshCaption()
        shownPixels = 0
        scheduleRender(delay: 0.05)
    }

    private func setImage(_ image: CGImage) {
        imageLayer.contents = image
        shownPixels = CGFloat(max(image.width, image.height))
    }

    private func refreshCaption() {
        guard let photo else {
            caption.stringValue = ""
            return
        }
        caption.stringValue = [
            photo.fileName,
            photo.rating > 0 ? String(repeating: "★", count: Int(photo.rating)) : nil,
            photo.photoFlag == .unflagged ? nil : photo.photoFlag.title,
        ].compactMap { $0 }.joined(separator: "   ·   ")
        setAccessibilityLabel(photo.fileName)
    }

    private func updateActiveAppearance() {
        imageLayer.borderWidth = isActive ? 2 : 0
        imageLayer.borderColor = Accent.color.cgColor
        setAccessibilityValue(isActive ? "active" : "inactive")
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        updateActiveAppearance()
    }

    // MARK: - Layout and rendering

    /// Where the photo sits: fitted to the cell above the caption, centered.
    var photoFrame: CGRect {
        let area = CGRect(x: 0, y: Self.captionHeight, width: bounds.width, height: max(bounds.height - Self.captionHeight, 0))
        let size = SurveyLayout.fitted(aspect: aspectRatio ?? 1.5, in: area.size)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height).integral
    }

    override func layout() {
        super.layout()
        let photoFrame = photoFrame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = photoFrame
        CATransaction.commit()
        caption.frame = CGRect(x: 4, y: max(photoFrame.minY - Self.captionHeight, 0), width: max(bounds.width - 8, 0), height: 18)
        removeButton.frame = CGRect(x: photoFrame.maxX - 26, y: photoFrame.maxY - 26, width: 22, height: 22)
        scheduleRender(delay: 0.15)
    }

    /// Replaces the thumbnail with a sharper render when the cell shows more pixels than it has.
    private func scheduleRender(delay: TimeInterval) {
        renderTask?.cancel()
        guard let photo, window != nil else { return }
        let scale = window?.backingScaleFactor ?? 2
        let pixels = max(photoFrame.width, photoFrame.height) * scale
        guard pixels > shownPixels * 1.1, pixels > CGFloat(ThumbnailStore.maxPixelSize) else { return }
        let url = photo.fileURL
        let adjustments = photo.adjustments
        let id = photoID
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let source = await CompareSource.load(url),
                  let rendered = await source.render(adjustments: adjustments, region: nil, renderScale: nil, maxPixels: pixels),
                  let self, !Task.isCancelled, photoID == id else { return }
            setImage(rendered.image)
        }
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        removeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        removeButton.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        onActivate()
    }

    @objc private func removeClicked(_ sender: Any?) {
        onRemove()
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate()
        return true
    }

    override var isFlipped: Bool { true }
}
