import AppKit
import CoreData
import CoreImage
import MetalKit

/// The Develop module: a Metal preview of the selected photo rendered through Apple's RAW engine,
/// with the Adjust panel on the right. Edits are non-destructive and saved per photo.
final class DevelopViewController: NSViewController, MTKViewDelegate {
    private let store: CatalogStore
    private let state: LibraryState

    private let device = MTLCreateSystemDefaultDevice()
    private lazy var commandQueue = device?.makeCommandQueue()
    private lazy var ciContext: CIContext? = device.map {
        CIContext(mtlDevice: $0, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!])
    }
    private let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    private var metalView: MTKView!
    private let previewContainer = MatteView()
    private let panel = AdjustmentsPanelViewController()
    private let infoLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    /// Shown with the message when the photo's file can't be found.
    private let locateButton = NSButton(title: "Locate…", target: nil, action: #selector(PixelLoupeActions.locateMissingPhoto(_:)))
    private let spinner = NSProgressIndicator()

    private var source: DevelopSource?
    /// A second decoder for the loupe, so its full-resolution renders don't disturb the preview's
    /// reduced-scale RAW decode (and vice versa).
    private var loupeSource: DevelopSource?
    private let loupeSettings = LoupeSettings()
    private lazy var loupeOverlay = LoupeOverlayView(settings: loupeSettings)
    private var geometry: PreviewGeometry?
    /// The Before/After views' labels and Split Screen's line.
    let beforeAfterOverlay = BeforeAfterOverlayView()
    /// Click-to-zoom and panning over the preview (not while a tool's overlay takes the clicks).
    private let zoomClickView = ZoomClickView()
    /// The zoomed view as last drawn (drawable pixels), for panning.
    private var zoomedDraw: (viewport: CompareViewport, imageSize: CGSize, pane: CGRect, backingScale: CGFloat)?
    /// Zooming in or out animates the preview between the two sizes (drawable pixels), as the Library does.
    private var zoomAnimation: (from: CGRect, start: CFTimeInterval)?
    /// Where the photo was last drawn (drawable pixels), where an animation starts.
    private var lastDrawnRect: CGRect?
    /// A zoom change (not a pan) waiting for the next draw to animate it.
    private var pendingZoomAnimation = false
    private var lastZoom = PhotoZoom()
    /// How many zoom animations have started (for tests: one lasts only `zoomAnimationDuration`, so a
    /// test on a busy machine can miss it while it runs, but not that it started).
    private(set) var zoomAnimationsStarted = 0
    /// Whether the photo has been drawn (for tests: a zoom only animates from a photo already on screen).
    var hasDrawnPhoto: Bool { lastDrawnRect != nil }
    private let cropPanel = CropPanelViewController()
    private let cropOverlay = CropOverlayView()
    /// The crop when the crop tool was opened for the current photo, restored by Esc.
    private var cropSessionStart: PhotoAdjustments.Crop?
    private let adjustToolButton = NSButton()
    private let rimLightToolButton = NSButton()
    private let rimLightPanel = RimLightPanelViewController()
    private let presetsToolButton = NSButton()
    private let presetsPanel = PresetsPanelViewController()
    private let cropToolButton = NSButton()
    private let lensToolButton = NSButton()
    private let maskToolButton = NSButton()
    private let retouchToolButton = NSButton()
    private let historyToolButton = NSButton()
    private let historyPanel = HistoryPanelViewController()
    /// The history step the photo was last taken back to; the next edit continues from it.
    private var historyCursor: UUID?
    private let retouchPanel = RetouchPanelViewController()
    private let retouchOverlay = RetouchOverlayView()
    /// The preview as last drawn in the Masking or Spot Removal tool, for finding an eye to click.
    private var lastFrameImage: CIImage?
    private let maskPanel = MaskPanelViewController()
    private let maskOverlay = MaskOverlayView()
    /// Whether the selected mask is painted red over the preview (O).
    private var showsMaskOverlay = false
    private let lensPanel = LensPanelViewController()
    /// What's known about the displayed photo's lens: its built-in profile, the LensFun profile that
    /// matches it, and the profiles that fit its camera.
    private var lensContext: LensContext?
    private var lensContextTask: Task<Void, Never>?
    private let fringePicker = FringePickerView()
    /// While Option-dragging the Masking slider, the preview shows the sharpening mask.
    private var showsSharpenMask = false
    let whiteBalancePicker = WhiteBalancePickerView()
    /// The preview as last drawn, for the defringe eyedropper: the image and where it's shown (points).
    private var lastPreview: (image: CIImage, rect: CGRect)?
    private let histogramView = HistogramView()
    /// The clipping overlays drawn on the preview (switched on, or previewed by hovering).
    private var clippingDisplay: (shadows: Bool, highlights: Bool) = (false, false)
    /// What the histogram was last computed for, so redraws that change nothing (such as the
    /// loupe moving) don't recompute it.
    private var histogramKey: HistogramKey?
    private var histogramTask: Task<Void, Never>?
    /// A newer image to compute once the current computation finishes (drags only ever wait for one).
    private var pendingHistogram: (key: HistogramKey, input: HistogramCalculator.Input)?
    /// The photo's grid thumbnail, shown while the full decode loads so switching to Develop never
    /// flashes an empty preview.
    private var placeholder: CIImage?
    private var keyMonitor: Any?
    private var adjustments = PhotoAdjustments() {
        // However the settings change (an edit, undo, another photo, a preset), the Rim Light panel shows them.
        didSet { if adjustments.rimLight != oldValue.rimLight { rimLightPanel.display(adjustments.rimLight) } }
    }
    private var displayedPhotoID: NSManagedObjectID?
    private var loadTask: Task<Void, Never>?

    init(store: CatalogStore, state: LibraryState) {
        self.store = store
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = NSView()

        metalView = MTKView(frame: .zero, device: device)
        metalView.delegate = self
        metalView.framebufferOnly = false
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.colorspace = colorSpace
        metalView.enableSetNeedsDisplay = true
        metalView.isPaused = true
        // Present in step with Core Animation so the lens moves in the same frame as the loupe
        // graphic drawn over it.
        metalView.presentsWithTransaction = true
        metalView.layer?.isOpaque = false
        metalView.setAccessibilityElement(true)
        metalView.setAccessibilityRole(.image)
        metalView.setAccessibilityIdentifier("developImageView")

        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.setAccessibilityIdentifier("developInfo")
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        locateButton.isHidden = true
        locateButton.setAccessibilityIdentifier("developLocateButton")
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false

        addChild(panel)
        addChild(cropPanel)
        addChild(lensPanel)
        addChild(rimLightPanel)
        // The panel isn't part of this view: it lives in the window's right column, shared with the
        // Library's inspector (see ``MainSplitViewController``).
        sidebarView = makeSidebar()
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(previewContainer)
        cropOverlay.isHidden = true
        fringePicker.isHidden = true
        whiteBalancePicker.isHidden = true
        maskOverlay.isHidden = true
        retouchOverlay.isHidden = true
        for view in [metalView!, beforeAfterOverlay, zoomClickView, loupeOverlay, cropOverlay, maskOverlay, retouchOverlay, fringePicker, whiteBalancePicker, infoLabel, messageLabel, locateButton, spinner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            previewContainer.addSubview(view)
        }
        // Redraw the preview when the theme or Matte Color changes.
        previewContainer.onMatteChange = { [weak self] in self?.metalView.needsDisplay = true }

        NSLayoutConstraint.activate([
            previewContainer.topAnchor.constraint(equalTo: container.topAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            previewContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            metalView.topAnchor.constraint(equalTo: previewContainer.safeAreaLayoutGuide.topAnchor, constant: 12),
            metalView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 12),
            metalView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -12),
            metalView.bottomAnchor.constraint(equalTo: infoLabel.topAnchor, constant: -8),
            beforeAfterOverlay.topAnchor.constraint(equalTo: metalView.topAnchor),
            beforeAfterOverlay.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
            beforeAfterOverlay.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
            beforeAfterOverlay.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
            zoomClickView.topAnchor.constraint(equalTo: metalView.topAnchor),
            zoomClickView.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
            zoomClickView.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
            zoomClickView.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
            cropOverlay.topAnchor.constraint(equalTo: metalView.topAnchor),
            cropOverlay.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
            cropOverlay.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
            cropOverlay.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
            fringePicker.topAnchor.constraint(equalTo: metalView.topAnchor),
            fringePicker.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
            fringePicker.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
            fringePicker.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
            retouchOverlay.topAnchor.constraint(equalTo: metalView.topAnchor),
            retouchOverlay.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
            retouchOverlay.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
            retouchOverlay.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
            maskOverlay.topAnchor.constraint(equalTo: metalView.topAnchor),
            maskOverlay.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
            maskOverlay.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
            maskOverlay.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
            whiteBalancePicker.topAnchor.constraint(equalTo: metalView.topAnchor),
            whiteBalancePicker.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
            whiteBalancePicker.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
            whiteBalancePicker.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
            loupeOverlay.topAnchor.constraint(equalTo: metalView.topAnchor),
            loupeOverlay.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
            loupeOverlay.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
            loupeOverlay.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
            infoLabel.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 12),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: previewContainer.trailingAnchor, constant: -12),
            infoLabel.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -8),
            messageLabel.centerXAnchor.constraint(equalTo: metalView.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: metalView.centerYAnchor),
            locateButton.centerXAnchor.constraint(equalTo: metalView.centerXAnchor),
            locateButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 12),
            spinner.centerXAnchor.constraint(equalTo: metalView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: metalView.centerYAnchor),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        panel.onPreview = { [weak self] adjustments in self?.previewSettings(adjustments) }
        panel.onChange = { [weak self] adjustments, isFinal, actionName in
            self?.adjustmentsChanged(adjustments, isFinal: isFinal, actionName: actionName)
        }
        panel.autoLight = { [weak self] in
            guard let self, let source, let ciContext else { return nil }
            return AdjustmentPipeline.autoLight(for: source, current: adjustments, context: ciContext)
        }
        panel.onPickWhiteBalance = { [weak self] on in
            guard let self else { return }
            whiteBalancePicker.isHidden = !(on && state.developTool == .adjust)
        }
        whiteBalancePicker.onPick = { [weak self] point in self?.pickWhiteBalance(at: point) }
        whiteBalancePicker.sample = { [weak self] point in self?.neutralTargetSample(at: point) }
        panel.autoWhiteBalance = { [weak self] in self?.autoWhiteBalance() }
        panel.onUprightLevel = { [weak self] in self?.levelWithUpright() }
        panel.onSharpenMaskPreview = { [weak self] on in
            guard let self, showsSharpenMask != on else { return }
            showsSharpenMask = on
            metalView.needsDisplay = true
        }
        panel.isEditingEnabled = false
        configureCrop()
        configureMasks()
        configureRetouch()
        configureHistory()
        configureHistogram()
        configurePresets()
        configureLens()
        configureRimLight()

        loupeOverlay.geometry = { [weak self] in self?.geometry }
        loupeOverlay.onChange = { [weak self] in self?.metalView.needsDisplay = true }
        loupeOverlay.onHide = { [weak self] in self?.state.isLoupeVisible = false }
        loupeOverlay.isLoupeVisible = state.isLoupeVisible

        state.addObserver(self) { [weak self] change in
            guard let self else { return }
            switch change {
            case .selection where view.window != nil: loadSelectedPhoto()
            case .loupe: loupeOverlay.isLoupeVisible = state.isLoupeVisible && state.developTool != .crop
            case .developTool:
                // Crop, Masking and Spot Removal show the photo their own way, so they end Before/After.
                if [.crop, .mask, .retouch].contains(state.developTool) { state.beforeAfter = nil }
                updateTool()
                zoomClickView.zoomDidChange()
                retouchOverlay.zoomDidChange()
            case .beforeAfter:
                metalView.needsDisplay = true
            case .zoom:
                let zoom = state.zoom
                if zoom.isZoomed != lastZoom.isZoomed || zoom.fit != lastZoom.fit || (zoom.isZoomed && zoom.ratio != lastZoom.ratio) {
                    pendingZoomAnimation = true
                }
                lastZoom = zoom
                zoomClickView.zoomDidChange()
                retouchOverlay.zoomDidChange()
                metalView.needsDisplay = true
            default: break
            }
        }
        configureZoom()
        NotificationCenter.default.addObserver(
            self, selector: #selector(contextObjectsDidChange(_:)),
            name: .NSManagedObjectContextObjectsDidChange, object: store.viewContext
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(photoFileDidChange(_:)),
            name: ExternalEditMonitor.photoFileDidChangeNotification, object: store.externalEdits
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(sourceStatusDidChange(_:)),
            name: SmartPreviewStore.didChangeNotification, object: store.smartPreviews
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(sourceStatusDidChange(_:)),
            name: FileAvailability.didChangeNotification, object: store.availability
        )
    }

    /// The photo's original went missing or came back, or it got or lost a Smart Preview.
    @objc private func sourceStatusDidChange(_ notification: Notification) {
        histogramView.sourceStatus = displayedPhoto.flatMap(store.sourceStatus)
    }

    /// Another app saved the photo being developed (Photo ▸ Edit In): decode it again. The zoom
    /// stays, since it's kept in the window's state.
    @objc private func photoFileDidChange(_ notification: Notification) {
        guard let uuid = notification.userInfo?["id"] as? UUID, displayedPhoto?.id == uuid else { return }
        displayedPhotoID = nil
        loadSelectedPhoto()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        loadSelectedPhoto()
        installKeyMonitor()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // Leaving Develop closes the crop tool, keeping the crop.
        if state.developTool == .crop { state.developTool = .adjust }
        endFringePicking()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        loupeOverlay.isPlacementKeyDown = false
    }

    /// The right panel (histogram, tools and their controls), shown in the window's right column.
    private(set) var sidebarView: NSView!

    /// Whether ⌘U (Auto Light) can run: the photo must be decoded.
    var canAutoLight: Bool { source != nil }

    func applyAutoLight() {
        panel.applyAutoLight()
    }

    // MARK: - Tools

    /// The header at the top of the sidebar: Adjust (the RAW tools) and Crop & Straighten.
    private func makeSidebar() -> NSView {
        for (button, symbol, title, identifier) in [
            (adjustToolButton, "slider.horizontal.3", "Adjust", "developTool.adjust"),
            (rimLightToolButton, "", "Rim Light", "developTool.rimLight"),
            (presetsToolButton, "photo.on.rectangle.angled", "Presets", "developTool.presets"),
            (cropToolButton, "crop.rotate", "Crop & Straighten (R)", "developTool.crop"),
            (lensToolButton, "camera", "Lens Corrections", "developTool.lens"),
            (maskToolButton, "circle.dashed.inset.filled", "Masking (⇧W)", "developTool.mask"),
            (retouchToolButton, "bandage", "Spot Removal (Q)", "developTool.retouch"),
            (historyToolButton, "clock.arrow.circlepath", "History and Snapshots", "developTool.history"),
        ] {
            button.image = symbol.isEmpty
                ? Self.rimLightIcon(title)
                : NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(.init(pointSize: 24, weight: .regular))
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.toolTip = title
            button.target = self
            button.action = #selector(toolButtonClicked(_:))
            button.setAccessibilityLabel(title)
            button.setAccessibilityIdentifier(identifier)
        }
        let header = NSStackView(views: [adjustToolButton, rimLightToolButton, presetsToolButton, cropToolButton, lensToolButton, maskToolButton, retouchToolButton, historyToolButton])
        // Eight tools fit the narrowest inspector (366 pt) at this spacing.
        header.spacing = 12
        // Exactly as tall as the tallest icon, so the line sits 10pt below the icons and the
        // panels get the rest of the sidebar.
        header.setHuggingPriority(.required, for: .vertical)
        header.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 0, right: 0)
        let headerLine = NSBox()
        headerLine.boxType = .separator

        let sidebar = NSView()
        addChild(presetsPanel)
        let content = [panel.view, rimLightPanel.view, presetsPanel.view, cropPanel.view, lensPanel.view, maskPanel.view, retouchPanel.view, historyPanel.view]
        for view in [histogramView, header, headerLine] + content {
            view.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(view)
        }
        NSLayoutConstraint.activate([
            histogramView.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 12),
            histogramView.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            histogramView.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: histogramView.bottomAnchor, constant: 2),
            header.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            // 10pt between the icons and the separator below them.
            headerLine.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            headerLine.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            headerLine.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            headerLine.heightAnchor.constraint(equalToConstant: 1),
        ])
        for view in content {
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            ])
        }
        // Only the current tool's panel shows (the rest are stacked in the same place). Without this,
        // the Mask, Spot Removal and History panels drew over Adjust until a tool was chosen.
        let tool = state.developTool
        panel.view.isHidden = tool != .adjust
        rimLightPanel.view.isHidden = tool != .rimLight
        presetsPanel.view.isHidden = tool != .presets
        cropPanel.view.isHidden = tool != .crop
        lensPanel.view.isHidden = tool != .lens
        maskPanel.view.isHidden = tool != .mask
        retouchPanel.view.isHidden = tool != .retouch
        historyPanel.view.isHidden = tool != .history
        updateToolButtons()
        Accent.apply(in: sidebar)
        return sidebar
    }

    @objc private func toolButtonClicked(_ sender: NSButton) {
        state.developTool = sender === rimLightToolButton ? .rimLight : sender === presetsToolButton ? .presets : sender === cropToolButton ? .crop : sender === lensToolButton ? .lens : sender === maskToolButton ? .mask : sender === retouchToolButton ? .retouch : sender === historyToolButton ? .history : .adjust
    }

    private func updateToolButtons() {
        for (button, tool) in [(adjustToolButton, DevelopTool.adjust), (rimLightToolButton, .rimLight), (presetsToolButton, .presets), (cropToolButton, .crop), (lensToolButton, .lens), (maskToolButton, .mask), (retouchToolButton, .retouch), (historyToolButton, .history)] {
            let active = state.developTool == tool
            button.contentTintColor = active ? Accent.color : .systemGray
            button.setAccessibilityValue(active ? "active" : "inactive")
        }
    }

    /// The softbox (Design/RimLight-Softbox.svg), a template so it's tinted like the symbols beside it, at their size.
    private static func rimLightIcon(_ title: String) -> NSImage? {
        guard let image = NSImage(named: "RimLight")?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 26, height: 26)
        image.isTemplate = true
        image.accessibilityDescription = title
        return image
    }

    // MARK: - Histogram

    private func configureHistogram() {
        histogramView.adjustments = { [weak self] in self?.adjustments ?? PhotoAdjustments() }
        histogramView.onChange = { [weak self] newValue, isFinal, actionName in
            guard let self, let source else { return }
            panel.display(newValue, asShotWhiteBalance: source.asShotWhiteBalance, isRaw: source.isRaw)
            adjustmentsChanged(newValue, isFinal: isFinal, actionName: actionName)
        }
        histogramView.onClippingDisplayChange = { [weak self] shadows, highlights in
            self?.clippingDisplay = (shadows, highlights)
            self?.metalView.needsDisplay = true
        }
    }

    /// J (Lightroom's Show Clipping): both clipping overlays on, or off if they already are.
    func toggleClipping() {
        histogramView.toggleBothClippingOverlays()
    }

    var isShowingClipping: Bool { histogramView.showsShadowClipping && histogramView.showsHighlightClipping }

    nonisolated private struct HistogramKey: Equatable {
        let photo: NSManagedObjectID
        let adjustments: PhotoAdjustments
        let cropping: Bool
    }

    /// Computes the histogram of the photo as drawn, off the main thread. While one is computing,
    /// only the newest request waits, so slider and histogram drags stay live.
    private func requestHistogram(for image: CIImage, adjustments: PhotoAdjustments, cropping: Bool) {
        guard let photo = displayedPhotoID else { return }
        let key = HistogramKey(photo: photo, adjustments: adjustments, cropping: cropping)
        guard key != histogramKey else { return }
        histogramKey = key
        let input = HistogramCalculator.Input(image: image)
        if histogramTask != nil {
            pendingHistogram = (key, input)
            return
        }
        computeHistogram(input, key: key)
    }

    private func computeHistogram(_ input: HistogramCalculator.Input, key: HistogramKey) {
        histogramTask = Task { [weak self] in
            let histogram = await HistogramCalculator.histogram(of: input)
            guard let self else { return }
            histogramTask = nil
            if key.photo == displayedPhotoID { histogramView.histogram = histogram }
            if let pending = pendingHistogram {
                pendingHistogram = nil
                computeHistogram(pending.input, key: pending.key)
            }
        }
    }

    // MARK: - Lens Corrections

    /// What's known about the displayed photo's lens, found off the main thread.
    nonisolated private struct LensContext: @unchecked Sendable {
        let photo: NSManagedObjectID
        let hasBuiltIn: Bool
        let builtInAlwaysOn: Bool
        /// The LensFun profile matching the camera and lens, resolved for the photo.
        let match: PhotoAdjustments.LensProfile?
        let catalog: LensCatalog
        let cropFactor: Double?
        let shooting: ShootingInfo
    }

    nonisolated private struct LensLookup: Sendable {
        let match: PhotoAdjustments.LensProfile?
        let catalog: LensCatalog
        let cropFactor: Double?
        let shooting: ShootingInfo
    }

    private func configureRimLight() {
        rimLightPanel.display(adjustments.rimLight)
        rimLightPanel.onChange = { [weak self] rimLight, isFinal, actionName in
            guard let self, let source else { return }
            var newValue = adjustments
            newValue.rimLight = rimLight
            // Keep the Adjust panel's copy current, or its next edit would undo this one.
            panel.display(newValue, asShotWhiteBalance: source.asShotWhiteBalance, isRaw: source.isRaw)
            adjustmentsChanged(newValue, isFinal: isFinal, actionName: actionName)
            refreshRimLightStatus()
        }
    }

    /// Tells the Rim Light panel whether the photo's subject has been found (it's found when the light first renders).
    private func refreshRimLightStatus() {
        rimLightPanel.subjectStatus = source.map { $0.subjectMattes.status(for: $0, adjustments: adjustments, refined: true) }
    }

    private func configureLens() {
        lensPanel.onChange = { [weak self] lens, isFinal, actionName in
            self?.lensChanged(lens, isFinal: isFinal, actionName: actionName)
        }
        lensPanel.onSelectProfile = { [weak self] maker, model, variant in
            self?.selectLensProfile(maker: maker, model: model, variant: variant)
        }
        lensPanel.onPickFringe = { [weak self] on in
            guard let self else { return }
            fringePicker.isHidden = !(on && state.developTool == .lens)
        }
        fringePicker.onPick = { [weak self] point in self?.pickFringe(at: point) }
    }

    private func showLens() {
        let context = lensContext.flatMap { $0.photo == displayedPhotoID ? $0 : nil }
        let status: LensPanelViewController.ProfileStatus = if source == nil {
            .unavailable
        } else if let context {
            context.hasBuiltIn ? .builtIn : (adjustments.lens.profile != nil || context.match != nil ? .matched : .noMatch)
        } else {
            .searching
        }
        lensPanel.display(adjustments.lens, status: status, catalog: context?.catalog ?? LensCatalog(),
                          builtInAlwaysOn: context?.builtInAlwaysOn ?? false, onSmartPreview: source?.isSmartPreview ?? false)
    }

    /// Finds the photo's built-in profile, matching LensFun profile and the profiles that fit its
    /// camera (the database loads on first use).
    private func loadLensContext() {
        guard let id = displayedPhotoID, let photo = displayedPhoto, let source, lensContext?.photo != id else {
            showLens()
            return
        }
        let hasBuiltIn = source.hasBuiltInLensProfile
        let builtInAlwaysOn = source.isBuiltInLensProfileApplied(PhotoAdjustments())
        // The file opened: a Smart Preview keeps its original's EXIF.
        let make = photo.cameraMake, model = photo.cameraModel, lensModel = photo.lensModel, url = source.url
        showLens()
        lensContextTask?.cancel()
        lensContextTask = Task { [weak self] in
            let lookup = await Self.lookUpLens(make: make, model: model, lens: lensModel, url: url)
            guard let self, !Task.isCancelled, displayedPhotoID == id else { return }
            lensContextTask = nil
            lensContext = LensContext(
                photo: id, hasBuiltIn: hasBuiltIn, builtInAlwaysOn: builtInAlwaysOn, match: lookup.match,
                catalog: lookup.catalog, cropFactor: lookup.cropFactor, shooting: lookup.shooting
            )
            // A photo set to use the matching profile that doesn't have it yet gets it now.
            var lens = adjustments.lens
            if lens.enableProfileCorrections, lens.setup == .auto, lens.profile == nil, !hasBuiltIn, let match = lookup.match {
                lens.profile = match
                applyLens(lens, isFinal: true, actionName: "Lens Corrections")
            }
            showLens()
        }
    }

    @concurrent
    nonisolated private static func lookUpLens(make: String?, model: String?, lens: String?, url: URL) async -> LensLookup {
        let database = LensFunDatabase.shared
        let shooting = ShootingInfo.read(from: url)
        let camera = database.camera(make: make, model: model)
        let cropFactor = camera?.cropFactor ?? shooting.cropFactor
        let match = database.match(make: make, model: model, lens: lens).map {
            LensFunDatabase.profile(for: $0, cropFactor: cropFactor, focalLength: shooting.focalLength,
                                    aperture: shooting.aperture, distance: shooting.subjectDistance)
        }
        return LensLookup(match: match, catalog: LensCatalog(lenses: database.lenses(for: camera)),
                          cropFactor: cropFactor, shooting: shooting)
    }

    @concurrent
    nonisolated private static func resolveProfile(
        maker: String, model: String, variant: String, cropFactor: Double?, shooting: ShootingInfo
    ) async -> PhotoAdjustments.LensProfile? {
        let candidates = LensFunDatabase.shared.lenses.filter { $0.maker == maker && $0.model == model && $0.hasCorrections }
        guard let lens = candidates.first(where: { $0.variantTitle == variant }) ?? candidates.first else { return nil }
        return LensFunDatabase.profile(for: lens, cropFactor: cropFactor, focalLength: shooting.focalLength,
                                       aperture: shooting.aperture, distance: shooting.subjectDistance)
    }

    private func applyLens(_ lens: PhotoAdjustments.LensCorrections, isFinal: Bool, actionName: String) {
        guard let source else { return }
        var newValue = adjustments
        newValue.lens = lens
        // Keep the Adjust panel's copy current, or its next edit would undo this one.
        panel.display(newValue, asShotWhiteBalance: source.asShotWhiteBalance, isRaw: source.isRaw)
        adjustmentsChanged(newValue, isFinal: isFinal, actionName: actionName)
    }

    private func lensChanged(_ new: PhotoAdjustments.LensCorrections, isFinal: Bool, actionName: String) {
        let old = adjustments.lens
        var lens = new
        let context = lensContext.flatMap { $0.photo == displayedPhotoID ? $0 : nil }
        // Turning on profile corrections with Auto, or switching back to Auto, uses the matching profile.
        if lens.enableProfileCorrections, lens.setup == .auto, !old.enableProfileCorrections || old.setup != .auto,
           let context, !context.hasBuiltIn {
            lens.profile = context.match
        }
        // Remove Chromatic Aberration without profile data measures the photo first; the edit is
        // saved (as one undo step) once that's done.
        let measuring = lens.removeChromaticAberration && !old.removeChromaticAberration && needsMeasuredAberration(lens)
        applyLens(lens, isFinal: isFinal && !measuring, actionName: actionName)
        if measuring { measureChromaticAberration(actionName: actionName) }
    }

    /// Whether Remove Chromatic Aberration has to measure the photo (its profile has no data).
    private func needsMeasuredAberration(_ lens: PhotoAdjustments.LensCorrections) -> Bool {
        let builtIn = source?.isBuiltInLensProfileApplied(adjustments) ?? false
        return !(lens.appliesProfile && !builtIn && !(lens.profile?.tcaRed.isEmpty ?? true))
    }

    private func measureChromaticAberration(actionName: String) {
        guard let source, let id = displayedPhotoID else { return }
        let input = ChromaticAberrationEstimator.Input(image: source.baseImage(with: adjustments, scale: source.scale(toFit: 2000)))
        metalView.needsDisplay = true
        Task { [weak self] in
            let scale = await ChromaticAberrationEstimator.estimate(input)
            guard let self, displayedPhotoID == id, adjustments.lens.removeChromaticAberration else { return }
            var lens = adjustments.lens
            // Nothing measurable leaves the colors as they are (but the setting is still saved).
            lens.chromaticAberration = scale ?? .init()
            applyLens(lens, isFinal: true, actionName: actionName)
        }
    }

    private func selectLensProfile(maker: String, model: String, variant: String) {
        guard let context = lensContext, context.photo == displayedPhotoID else { return }
        Task { [weak self] in
            let profile = await Self.resolveProfile(
                maker: maker, model: model, variant: variant, cropFactor: context.cropFactor, shooting: context.shooting
            )
            guard let self, displayedPhotoID == context.photo, let profile else { return }
            var lens = adjustments.lens
            lens.profile = profile
            lens.setup = .custom
            lens.enableProfileCorrections = true
            applyLens(lens, isFinal: true, actionName: "Lens Profile")
        }
    }

    private func endFringePicking() {
        fringePicker.isHidden = true
        lensPanel.endFringePicking()
        endWhiteBalancePicking()
    }

    private func endWhiteBalancePicking() {
        whiteBalancePicker.isHidden = true
        panel.endWhiteBalancePicking()
    }

    /// W (Lightroom's White Balance Selector): click something that should be neutral gray.
    func toggleWhiteBalancePicker() {
        guard state.developTool == .adjust, source != nil else { return }
        panel.toggleWhiteBalancePicking()
    }

    /// The average color of the preview (display RGB) over `rect` of the image, or the whole image.
    private func previewColor(around point: CGPoint?) -> [Double]? {
        guard let preview = lastPreview, let ciContext else { return nil }
        let extent = preview.image.extent
        var bounds = extent
        if let point {
            guard preview.rect.contains(point) else { return nil }
            let x = extent.minX + (point.x - preview.rect.minX) / preview.rect.width * extent.width
            let y = extent.minY + (point.y - preview.rect.minY) / preview.rect.height * extent.height
            // A 5-point square of the preview, so noise doesn't decide.
            let side = max(3, (5 * extent.width / preview.rect.width).rounded())
            bounds = CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side).intersection(extent).integral
        }
        guard !bounds.isEmpty, let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: preview.image, kCIInputExtentKey: CIVector(cgRect: bounds),
        ]), let average = filter.outputImage else { return nil }
        var pixel = [Float](repeating: 0, count: 4)
        ciContext.render(average, toBitmap: &pixel, rowBytes: 16, bounds: average.extent, format: .RGBAf,
                         colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
        return pixel.prefix(3).map(Double.init)
    }

    /// The 5 × 5 grid of the preview around `point` (one square per screen point) for the White
    /// Balance Selector's loupe, or `nil` off the photo.
    func neutralTargetSample(at point: CGPoint) -> NeutralTargetSample? {
        guard let preview = lastPreview, let ciContext else { return nil }
        return NeutralTargetSample.read(preview.image, shownIn: preview.rect, at: point, context: ciContext)
    }

    /// The white balance eyedropper: makes the clicked spot neutral, as one undoable edit.
    private func pickWhiteBalance(at point: CGPoint) {
        defer { endWhiteBalancePicking() }
        guard let color = neutralTargetSample(at: point)?.average ?? previewColor(around: point),
              let result = WhiteBalanceEstimator.neutralizing(color, current: panel.currentWhiteBalance) else {
            NSSound.beep()
            return
        }
        panel.applyWhiteBalance(temperature: result.temperature, tint: result.tint, preset: nil)
    }

    /// Auto white balance: assumes the photo averages to gray.
    private func autoWhiteBalance() -> (temperature: Double, tint: Double)? {
        previewColor(around: nil).flatMap { WhiteBalanceEstimator.neutralizing($0, current: panel.currentWhiteBalance) }
    }

    /// The defringe eyedropper: sets Purple or Green Hue around the clicked fringe's color.
    private func pickFringe(at point: CGPoint) {
        defer { endFringePicking() }
        guard let preview = lastPreview, preview.rect.contains(point), let ciContext else { return }
        let extent = preview.image.extent
        let x = extent.minX + (point.x - preview.rect.minX) / preview.rect.width * extent.width
        let y = extent.minY + (point.y - preview.rect.minY) / preview.rect.height * extent.height
        var pixels = [Float](repeating: 0, count: 9 * 4)
        ciContext.render(preview.image, toBitmap: &pixels, rowBytes: 3 * 16,
                         bounds: CGRect(x: x.rounded(.down) - 1, y: y.rounded(.down) - 1, width: 3, height: 3),
                         format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
        let color = (0..<3).map { channel in (0..<9).reduce(0.0) { $0 + Double(pixels[$1 * 4 + channel]) } / 9 }
        guard let lens = Self.defringe(adjustments.lens, picking: color) else {
            NSSound.beep()
            return
        }
        applyLens(lens, isFinal: true, actionName: "Defringe")
    }

    /// Defringe settings targeting a picked color (display RGB), or nil when it isn't a fringe color.
    nonisolated static func defringe(_ lens: PhotoAdjustments.LensCorrections, picking color: [Double]) -> PhotoAdjustments.LensCorrections? {
        let high = color.max() ?? 0, low = color.min() ?? 0, chroma = high - low
        guard high > 0, chroma / high > 0.08 else { return nil }
        var hue: Double
        if high == color[0] { hue = (color[1] - color[2]) / chroma }
        else if high == color[1] { hue = (color[2] - color[0]) / chroma + 2 }
        else { hue = (color[0] - color[1]) / chroma + 4 }
        hue = (hue * 60 + 360).truncatingRemainder(dividingBy: 360)
        // Position along each slider: Purple runs 200°–20°, Green 30°–210°.
        let purple = (hue - 200 + 360).truncatingRemainder(dividingBy: 360) / 180
        let green = (hue - 30 + 360).truncatingRemainder(dividingBy: 360) / 180
        func range(around position: Double) -> PhotoAdjustments.LensCorrections.HueRange {
            let lower = (position - 0.1).clamped(to: 0...0.8)
            return .init(lower: (lower * 100).rounded() / 100, upper: ((lower + 0.2) * 100).rounded() / 100)
        }
        var result = lens
        let isPurple = purple <= 1 && (green > 1 || abs(purple - 0.5) <= abs(green - 0.5))
        if isPurple {
            result.purpleHue = range(around: purple)
            result.purpleAmount = max(lens.purpleAmount, 0.25)
        } else if green <= 1 {
            result.greenHue = range(around: green)
            result.greenAmount = max(lens.greenAmount, 0.25)
        } else {
            return nil
        }
        return result
    }

    private func configureCrop() {
        cropPanel.onChange = { [weak self] crop, _ in self?.cropChanged(crop) }
        cropOverlay.onChange = { [weak self] crop, _ in self?.cropChanged(crop) }
        cropOverlay.toolOverlay = cropPanel.toolOverlay
        cropPanel.onOverlayChange = { [weak self] overlay in self?.cropOverlay.toolOverlay = overlay }
        cropPanel.onAspect = { [weak self] aspect in self?.setCropAspect(aspect) }
        cropPanel.onAuto = { [weak self] in self?.autoStraighten() }
        cropPanel.onReset = { [weak self] in self?.cropChanged(PhotoAdjustments.Crop()) }
        cropPanel.onClose = { [weak self] in self?.state.developTool = .adjust }
        cropPanel.onStraightenTool = { [weak self] active in self?.cropOverlay.isStraightening = active }
        cropOverlay.onStraighten = { [weak self] turn in
            guard let self else { return }
            var crop = adjustments.crop
            crop.angle = (((crop.angle + turn) * 100).rounded() / 100).clamped(to: CropGeometry.angleRange)
            cropChanged(crop)
            // Like Lightroom, the straighten tool turns off after use.
            cropOverlay.isStraightening = false
            cropPanel.setStraightenToolActive(false)
        }
    }

    private func updateTool() {
        updateToolButtons()
        let cropping = state.developTool == .crop
        panel.view.isHidden = state.developTool != .adjust
        rimLightPanel.view.isHidden = state.developTool != .rimLight
        if state.developTool == .rimLight { refreshRimLightStatus() }
        presetsPanel.view.isHidden = state.developTool != .presets
        if state.developTool != .presets { endPresetPreview() }
        cropPanel.view.isHidden = !cropping
        lensPanel.view.isHidden = state.developTool != .lens
        maskPanel.view.isHidden = state.developTool != .mask
        maskOverlay.isHidden = state.developTool != .mask
        retouchPanel.view.isHidden = state.developTool != .retouch
        historyPanel.view.isHidden = state.developTool != .history
        if state.developTool == .history { showHistory() }
        retouchOverlay.isHidden = state.developTool != .retouch
        if state.developTool == .mask { showMasks() }
        if state.developTool == .retouch { showRetouch() }
        cropOverlay.isHidden = !cropping
        loupeOverlay.isLoupeVisible = state.isLoupeVisible && !cropping
        if state.developTool == .lens { loadLensContext() } else { endFringePicking() }
        if cropping {
            cropSessionStart = adjustments.crop
            showCrop(adjustments.crop)
        } else {
            commitCrop()
            cropOverlay.isStraightening = false
            cropPanel.setStraightenToolActive(false)
        }
        metalView.needsDisplay = true
    }

    private func showCrop(_ crop: PhotoAdjustments.Crop) {
        cropOverlay.crop = crop
        cropPanel.display(crop)
    }

    /// Live crop edits; saved when the crop tool closes (Close, Return, R or switching tools).
    private func cropChanged(_ crop: PhotoAdjustments.Crop) {
        var crop = crop
        if crop.constrainToImage, let source,
           !CropGeometry.isInsidePhoto(crop.rect, angle: crop.angle, imageSize: source.frameSize(adjustments)) {
            crop.rect = CropGeometry.fit(crop.rect, angle: crop.angle, imageSize: source.frameSize(adjustments))
        }
        adjustments.crop = crop
        showCrop(crop)
        metalView.needsDisplay = true
    }

    /// Saves the crop as one undoable edit.
    func commitCrop() {
        guard let photo = displayedPhoto, photo.adjustments.crop != adjustments.crop else { return }
        var saved = photo.adjustments
        saved.crop = adjustments.crop
        photo.adjustments = saved
        photo.editDate = Date()
        store.viewContext.undoManager?.setActionName("Crop & Straighten")
        store.save()
        cropSessionStart = adjustments.crop
    }

    /// Esc: discards crop changes made since the tool opened, and closes it.
    func cancelCrop() {
        if let cropSessionStart { adjustments.crop = cropSessionStart }
        showCrop(adjustments.crop)
        state.developTool = .adjust
    }

    /// X: swaps the crop between landscape and portrait, keeping its aspect ratio.
    func flipCropOrientation() {
        guard let source else { return }
        var crop = adjustments.crop
        let size = source.frameSize(adjustments)
        let ratio = crop.aspect.landscapeRatio(imageSize: size)
            ?? Double(crop.rect.width * size.width / max(crop.rect.height * size.height, 1))
        let portrait = CropGeometry.isPortrait(crop.rect, imageSize: size)
        crop.rect = CropGeometry.largestRect(ratio: max(ratio, 1 / ratio), portrait: !portrait, angle: crop.angle, imageSize: size)
        cropChanged(crop)
    }

    private func setCropAspect(_ aspect: CropAspect) {
        guard let source else { return }
        let size = source.frameSize(adjustments)
        var crop = adjustments.crop
        crop.aspect = aspect
        crop.isAspectLocked = aspect != .custom
        if let ratio = aspect.landscapeRatio(imageSize: size) {
            // Keep the crop's orientation (the photo's, for Original), filling as much as the ratio allows.
            let portrait = aspect == .original || aspect == .asShot
                ? size.height > size.width
                : CropGeometry.isPortrait(crop.rect, imageSize: size)
            crop.rect = CropGeometry.largestRect(ratio: ratio, portrait: portrait, angle: crop.angle, imageSize: size)
        }
        cropChanged(crop)
    }

    /// Transform ▸ Upright ▸ Level: measures the tilt (horizon, else straight edges) and sets Rotate.
    private func levelWithUpright() {
        guard let source else { return }
        var plain = adjustments
        plain.crop = PhotoAdjustments.Crop()
        plain.transform = PhotoAdjustments.Transform()
        let image = HorizonDetector.Input(image: source.image(with: plain, scale: source.scale(toFit: 1024)))
        Task { [weak self] in
            let angle = await HorizonDetector.straighteningAngle(for: image)
            guard let self else { return }
            guard let angle else {
                NSSound.beep()
                return
            }
            // The detector's angle turns the photo counterclockwise to level it; Rotate is clockwise.
            panel.applyUprightLevel(rotation: (-angle).clamped(to: -10...10))
        }
    }

    /// Auto: levels the photo by its horizon, or failing that its strongest straight edges.
    private func autoStraighten() {
        guard let source else { return }
        var level = adjustments
        level.crop = PhotoAdjustments.Crop()
        let image = HorizonDetector.Input(image: source.image(with: level, scale: source.scale(toFit: 1024)))
        Task { [weak self] in
            let angle = await HorizonDetector.straighteningAngle(for: image)
            guard let self else { return }
            guard let angle else {
                NSSound.beep()
                cropPanel.showAutoStatus("No horizon or straight lines found")
                return
            }
            var crop = adjustments.crop
            crop.angle = ((angle * 100).rounded() / 100).clamped(to: CropGeometry.angleRange)
            // Crop in far enough that the straightened photo has no empty corners, even when
            // Constrain to Image is off.
            if let source = self.source {
                crop.rect = CropGeometry.fit(crop.rect, angle: crop.angle, imageSize: source.frameSize(adjustments))
            }
            cropChanged(crop)
        }
    }

    // MARK: - Masks

    private func configureMasks() {
        maskPanel.onChange = { [weak self] masks, isFinal, actionName in self?.masksChanged(masks, isFinal: isFinal, actionName: actionName) }
        maskPanel.onSelectionChange = { [weak self] id in self?.maskOverlay.adjustment = self?.adjustments.masks.first { $0.id == id } }
        maskPanel.onAdd = { [weak self] kind in self?.addMask(kind) }
        maskPanel.onBrushChange = { [weak self] brush in self?.maskOverlay.brush = brush }
        maskOverlay.onBrushChange = { [weak self] brush in self?.maskPanel.brush = brush }
        maskOverlay.brush = maskPanel.brush
        maskPanel.onOverlayChange = { [weak self] on in
            self?.showsMaskOverlay = on
            self?.metalView.needsDisplay = true
        }
        maskOverlay.onChange = { [weak self] adjustment, isFinal, actionName in
            guard let self, let index = adjustments.masks.firstIndex(where: { $0.id == adjustment.id }) else { return }
            var masks = adjustments.masks
            masks[index] = adjustment
            masksChanged(masks, isFinal: isFinal, actionName: actionName)
        }
        maskOverlay.onClickEmpty = { }
        // The subject a Subject or Background mask needs, found in the background: draw it now.
        subjectObserver = NotificationCenter.default.addObserver(forName: SubjectMatteStore.didFind, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSubjectStatus()
                self?.refreshRimLightStatus()
                self?.metalView.needsDisplay = true
            }
        }
    }

    private var subjectObserver: NSObjectProtocol?

    /// Tells the Masking panel whether the photo's subject has been found, and starts finding it if a mask
    /// needs it.
    private func refreshSubjectStatus() {
        guard let source, adjustments.masks.contains(where: \.usesSubject) else { return }
        let status = source.subjectMattes.status(for: source, adjustments: adjustments)
        if status == .finding { _ = source.subjectMattes.matte(for: source, adjustments: adjustments, waiting: false) }
        maskPanel.subjectStatus = status
    }

    /// Shows the photo's masks in the Masking panel and on the preview.
    private func showMasks() {
        maskPanel.isEditingEnabled = source != nil
        maskPanel.display(masks: adjustments.masks)
        maskOverlay.adjustment = adjustments.masks.first { $0.id == maskPanel.selectedID }
        refreshSubjectStatus()
    }

    private func masksChanged(_ masks: [PhotoAdjustments.LocalAdjustment], isFinal: Bool, actionName: String) {
        var newValue = adjustments
        newValue.masks = masks
        // Keep the Adjust panel's copy current, or its next edit would undo this one.
        if let source { panel.display(newValue, asShotWhiteBalance: source.asShotWhiteBalance, isRaw: source.isRaw) }
        // Likewise the Masking panel's, or a slider touched after moving a mask puts it back (RAW-136).
        maskPanel.update(masks: masks)
        adjustmentsChanged(newValue, isFinal: isFinal, actionName: actionName)
        maskOverlay.adjustment = masks.first { $0.id == maskPanel.selectedID }
    }

    /// M, ⇧M and K, and Select Subject and Select Background: adds a mask (and opens the Masking tool).
    func addMask(_ kind: MaskPanelViewController.MaskKind) {
        guard source != nil else { return }
        var mask = PhotoAdjustments.LocalAdjustment()
        let number = adjustments.masks.count + 1
        switch kind {
        case .linear:
            mask.components = [.init(shape: .linear(MaskGeometry.defaultLinear()))]
            mask.name = "Linear Gradient \(number)"
        case .radial:
            mask.components = [.init(shape: .radial(MaskGeometry.defaultRadial()))]
            mask.name = "Radial Gradient \(number)"
        case .brush:
            mask.components = [.init(shape: .brush(.init()))]
            mask.name = "Brush \(number)"
        case .subject:
            mask.components = [.init(shape: .subject(.init()))]
            mask.name = "Subject \(number)"
        case .background:
            mask.components = [.init(shape: .background(.init()))]
            mask.name = "Background \(number)"
        }
        mask.settings.exposure = -0.5
        if state.developTool != .mask { state.developTool = .mask }
        var masks = adjustments.masks
        masks.append(mask)
        masksChanged(masks, isFinal: true, actionName: "Add Mask")
        maskPanel.display(masks: masks, selecting: mask.id)
        maskOverlay.adjustment = mask
        refreshSubjectStatus()
    }

    /// Whether a brush mask, or a Subject or Background mask the brush refines, is selected in the Masking tool,
    /// so [ ] ⇧[ ⇧] size and soften the brush.
    var isBrushing: Bool {
        guard state.developTool == .mask, let selected = adjustments.masks.first(where: { $0.id == maskPanel.selectedID }) else { return false }
        return selected.usesSubject || selected.components.contains(where: \.shape.isBrush)
    }

    /// [ and ]: a smaller or larger brush.
    func stepBrushSize(_ steps: Int) { maskPanel.brush.stepSize(steps) }

    /// ⇧[ and ⇧]: a harder or softer brush.
    func stepBrushFeather(_ steps: Int) { maskPanel.brush.stepFeather(steps) }

    /// O: paints the selected mask red over the preview.
    func toggleMaskOverlay() {
        guard state.developTool == .mask else { return }
        showsMaskOverlay.toggle()
        maskPanel.overlayVisible = showsMaskOverlay
        metalView.needsDisplay = true
    }

    // MARK: - Spot removal

    private func configureRetouch() {
        retouchPanel.onChange = { [weak self] spots, eyes, isFinal, action in self?.retouchChanged(spots, eyes, isFinal: isFinal, actionName: action) }
        retouchPanel.onSelectionChange = { [weak self] id in self?.retouchOverlay.selectedID = id }
        retouchOverlay.onChange = { [weak self] spots, eyes, isFinal, action in self?.retouchChanged(spots, eyes, isFinal: isFinal, actionName: action) }
        retouchOverlay.onSelect = { [weak self] id in
            self?.retouchPanel.select(id)
            self?.retouchOverlay.selectedID = id
        }
        retouchOverlay.onPlace = { [weak self] point in self?.placeRetouch(at: point) }
    }

    private func showRetouch() {
        retouchPanel.isEditingEnabled = source != nil
        retouchPanel.display(spots: adjustments.spots, redEyes: adjustments.redEyes)
        retouchOverlay.spots = adjustments.spots
        retouchOverlay.redEyes = adjustments.redEyes
        retouchOverlay.selectedID = retouchPanel.selectedID
    }

    private func retouchChanged(_ spots: [PhotoAdjustments.Spot], _ eyes: [PhotoAdjustments.RedEyeSpot], isFinal: Bool, actionName: String) {
        var newValue = adjustments
        newValue.spots = spots
        newValue.redEyes = eyes
        if let source { panel.display(newValue, asShotWhiteBalance: source.asShotWhiteBalance, isRaw: source.isRaw) }
        adjustmentsChanged(newValue, isFinal: isFinal, actionName: actionName)
        retouchOverlay.spots = spots
        retouchOverlay.redEyes = eyes
        retouchPanel.display(spots: spots, redEyes: eyes)
        // Resizing a spot sets the size of the next one, as it looks on screen now.
        if ["Resize Spot", "Spot Size"].contains(actionName), let spot = spots.first(where: { $0.id == retouchPanel.selectedID }) {
            spotBrushRadius = spot.radius * retouchOverlay.zoomFactor
        }
    }

    /// The size of the next heal or clone spot, as a fraction of the photo's long edge while it fits:
    /// zoomed in, a new spot is as big on screen as it would be unzoomed, not as big on the photo.
    private var spotBrushRadius = 0.02

    /// A click in the Spot Removal tool: a heal or clone spot with a source beside it, or a red eye.
    private func placeRetouch(at point: PhotoAdjustments.UnitPoint) {
        guard let source else { return }
        let size = source.frameSize(adjustments)
        var spots = adjustments.spots, eyes = adjustments.redEyes
        let id: UUID
        let action: String
        switch retouchPanel.mode {
        case .heal, .clone:
            var spot = PhotoAdjustments.Spot()
            spot.kind = retouchPanel.mode == .clone ? .clone : .heal
            spot.center = point
            spot.radius = (spotBrushRadius / retouchOverlay.zoomFactor).clamped(to: RetouchOverlayView.radiusRange)
            spot.source = LightroomDevelopMapper.automaticSource(for: point, radius: spot.radius, imageSize: size)
            spots.append(spot)
            id = spot.id
            action = "Add Spot"
        case .redEye:
            var eye = PhotoAdjustments.RedEyeSpot()
            eye.center = point
            if let image = lastFrameImage, let ciContext, let found = RetouchRenderer.findRedEye(near: point, in: image, context: ciContext) {
                eye.center = found.center
                eye.radius = max(found.radius * 1.15, 0.003)
            } else {
                // Nothing red to find: a small eye where it was clicked.
                eye.radius = 0.006
            }
            eyes.append(eye)
            id = eye.id
            action = "Add Red Eye"
        }
        retouchChanged(spots, eyes, isFinal: true, actionName: action)
        retouchPanel.display(spots: spots, redEyes: eyes, selecting: id)
        retouchOverlay.selectedID = id
    }

    /// Delete in Spot Removal: removes the selected spot, if there is one.
    func deleteSelectedSpot() -> Bool {
        state.developTool == .retouch && retouchPanel.deleteSelectedSpot()
    }

    // MARK: - Loupe

    /// The grave accent (`) key: press it to show or hide the loupe, or hold it and click to place
    /// the loupe on a spot.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { (self?.handleHandKey(event) ?? false) || (self?.handleLoupeKey(event) ?? false) }
            return handled ? nil : event
        }
    }

    /// The masks the Masking panel shows.
    var shownMasks: [PhotoAdjustments.LocalAdjustment] { maskPanel.masks }

    /// Whether Space is held for the brush's hand.
    var isBrushHandHeld: Bool { maskOverlay.isHandHeld }

    /// Space held while the brush is active: a hand that moves the photo (as in Lightroom), not Toggle Zoom.
    func handleHandKey(_ event: NSEvent) -> Bool {
        let spaceKeyCode: UInt16 = 49
        guard event.keyCode == spaceKeyCode, event.window === view.window,
              !((view.window?.firstResponder as? NSText)?.isEditable ?? false)
        else { return false }
        if event.type == .keyUp {
            guard maskOverlay.isHandHeld else { return false }
            maskOverlay.isHandHeld = false
            return true
        }
        guard isBrushing, event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty else { return false }
        maskOverlay.isHandHeld = true
        return true
    }

    private func handleLoupeKey(_ event: NSEvent) -> Bool {
        let graveKeyCode: UInt16 = 50
        guard event.keyCode == graveKeyCode,
              event.window === view.window,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty,
              !((view.window?.firstResponder as? NSText)?.isEditable ?? false)
        else { return false }
        if event.type == .keyDown {
            if !event.isARepeat { loupeOverlay.isPlacementKeyDown = true }
        } else {
            // Ignore a key-up without its key-down here, e.g. when ` in Library just opened Develop.
            guard loupeOverlay.isPlacementKeyDown else { return true }
            loupeOverlay.isPlacementKeyDown = false
            if !loupeOverlay.didPlaceDuringKeyHold { state.isLoupeVisible.toggle() }
        }
        return true
    }

    private var displayedPhoto: Photo? {
        displayedPhotoID.flatMap { try? store.viewContext.existingObject(with: $0) as? Photo }
    }

    // MARK: - Editing

    private func adjustmentsChanged(
        _ newValue: PhotoAdjustments, isFinal: Bool, actionName: String, recordsHistory: Bool = true, replacesEverything: Bool = false
    ) {
        // The Adjust panel's copy of the crop may be stale; keep the current one (except on Revert,
        // or when a history step or snapshot replaces the settings).
        var newValue = newValue
        // Any other edit ends the preset's Amount slider (as in Lightroom).
        if !isApplyingPreset { endPresetAmount() }
        endPresetPreview()
        if actionName != "Revert to Original", !replacesEverything { newValue.crop = adjustments.crop }
        let lensChanged = newValue.lens != adjustments.lens
        adjustments = newValue
        if state.developTool == .crop { showCrop(newValue.crop) }
        if lensChanged { showLens() }
        metalView.needsDisplay = true
        guard isFinal, let photo = displayedPhoto, photo.adjustments != newValue else { return }
        if recordsHistory { recordHistory(before: photo.adjustments, after: newValue, name: actionName, photo: photo) }
        photo.adjustments = newValue
        photo.editDate = Date()
        store.viewContext.undoManager?.setActionName(actionName)
        store.save()
        if state.developTool == .history { showHistory() }
    }

    // MARK: - Presets

    private func configurePresets() {
        presetsPanel.onApply = { [weak self] preset in self?.applyPreset(preset) }
        presetsPanel.onAmountChange = { [weak self] amount, isFinal in self?.setPresetAmount(amount, isFinal: isFinal) }
        presetsPanel.currentSettings = { [weak self] in self?.currentAdjustments }
        presetsPanel.onHover = { [weak self] preset in self?.previewPreset(preset) }
    }

    // MARK: Hover preview

    /// The settings a preset under the pointer would give the photo: drawn in place of its own, and in
    /// the Navigator, until the pointer leaves (nothing is saved).
    private var presetPreview: PhotoAdjustments?
    private var navigatorPreviewTask: Task<Void, Never>?

    var isPreviewingPreset: Bool { presetPreview != nil }

    /// Previews a preset on the photo (`nil` ends the preview).
    func previewPreset(_ preset: DevelopPreset?) {
        guard let preset, let photo = displayedPhoto, presetsPanel.isEditingEnabled else {
            endPresetPreview()
            return
        }
        previewSettings(preset.applied(to: adjustments, isRaw: SupportedImageTypes.isRaw(photo.fileURL), cameraModel: photo.cameraModel,
                                       iso: photo.iso > 0 ? Double(photo.iso) : nil))
    }

    /// Shows `previewed` in place of the photo's settings, here and in the Navigator, without saving
    /// anything (a preset under the pointer, a profile highlighted in the Profile menu); `nil` ends it.
    func previewSettings(_ previewed: PhotoAdjustments?) {
        guard let previewed, displayedPhoto != nil, let source else {
            endPresetPreview()
            return
        }
        presetPreview = previewed
        metalView.needsDisplay = true
        // The Navigator's copy, small and off the main thread.
        let image = source.image(with: previewed, scale: source.scale(toFit: 480, adjustments: previewed))
        navigatorPreviewTask?.cancel()
        navigatorPreviewTask = Task { [weak self] in
            let rendered = await Self.renderNavigatorPreview(.init(image: image))
            guard let self, !Task.isCancelled, presetPreview == previewed else { return }
            state.navigatorPreview = rendered
        }
    }

    private func endPresetPreview() {
        navigatorPreviewTask?.cancel()
        navigatorPreviewTask = nil
        if state.navigatorPreview != nil { state.navigatorPreview = nil }
        guard presetPreview != nil else { return }
        presetPreview = nil
        metalView.needsDisplay = true
    }

    nonisolated struct NavigatorPreviewInput: @unchecked Sendable {
        let image: CIImage
    }

    private nonisolated static let navigatorContext = CIContext(options: [.cacheIntermediates: false])

    @concurrent
    private nonisolated static func renderNavigatorPreview(_ input: NavigatorPreviewInput) async -> CGImage? {
        let extent = input.image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return nil }
        return navigatorContext.createCGImage(input.image, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
    }

    /// The Presets panel (for tests).
    var presetsPanelForTesting: PresetsPanelViewController { presetsPanel }

    /// The preset last applied, for its Amount slider: the settings before it and with it at 100%.
    private var presetAmount: (photo: NSManagedObjectID, preset: DevelopPreset, before: PhotoAdjustments, full: PhotoAdjustments)?
    /// Set while the preset or its amount is being applied (so the change doesn't end the slider).
    private var isApplyingPreset = false

    private func endPresetAmount() {
        guard presetAmount != nil else { return }
        presetAmount = nil
        presetsPanel.showAmount(for: nil)
    }

    /// The Amount slider moved: the preset at `amount` (0…2) from the settings before it.
    func setPresetAmount(_ amount: Double, isFinal: Bool) {
        guard let context = presetAmount, context.photo == displayedPhotoID, let source else { return }
        let settings = PresetAmount.settings(before: context.before, full: context.full, amount: amount)
        isApplyingPreset = true
        defer { isApplyingPreset = false }
        panel.display(settings, asShotWhiteBalance: source.asShotWhiteBalance, isRaw: source.isRaw)
        adjustmentsChanged(settings, isFinal: isFinal, actionName: "Preset: \(context.preset.name) \(Int((amount * 100).rounded()))%")
    }

    /// The settings shown (including edits not saved yet, such as a slider being dragged).
    var currentAdjustments: PhotoAdjustments? { displayedPhoto == nil ? nil : adjustments }

    /// Applies a preset to the photo, as one undoable edit and history step named after it.
    func applyPreset(_ preset: DevelopPreset) {
        guard let photo = displayedPhoto, let source else { return }
        let before = adjustments
        let applied = preset.applied(to: before, isRaw: SupportedImageTypes.isRaw(photo.fileURL), cameraModel: photo.cameraModel,
                                     iso: photo.iso > 0 ? Double(photo.iso) : nil)
        guard applied != before else { return }
        isApplyingPreset = true
        defer { isApplyingPreset = false }
        panel.display(applied, asShotWhiteBalance: source.asShotWhiteBalance, isRaw: source.isRaw)
        adjustmentsChanged(applied, isFinal: true, actionName: "Preset: \(preset.name)")
        if preset.supportsAmount, let id = displayedPhotoID {
            presetAmount = (id, preset, before, applied)
            presetsPanel.showAmount(for: preset.name, amount: 1)
        } else {
            endPresetAmount()
        }
    }

    // MARK: - History and snapshots

    private func configureHistory() {
        historyPanel.onSelectStep = { [weak self] id in self?.applyHistoryStep(id) }
        historyPanel.onSelectSnapshot = { [weak self] id in self?.applySnapshot(id) }
        historyPanel.onCreateSnapshot = { [weak self] in self?.createSnapshot() }
        historyPanel.onUpdateSnapshot = { [weak self] id in self?.updateSnapshot(id) }
        historyPanel.onDeleteSnapshot = { [weak self] id in self?.deleteSnapshot(id) }
        historyPanel.onRenameSnapshot = { [weak self] id, name in self?.renameSnapshot(id, to: name) }
        historyPanel.onClearHistory = { [weak self] in self?.clearHistory() }
    }

    /// Adds the step for an edit: the starting point first if the photo has no history yet, and going
    /// forward from a step the photo was taken back to drops the steps after it.
    private func recordHistory(before: PhotoAdjustments, after: PhotoAdjustments, name: String, photo: Photo) {
        if photo.historySteps.isEmpty { DevelopHistory.record(before, name: "Original", for: photo) }
        let cursor = historyCursor.flatMap { id in photo.historySteps.first { $0.id == id } }
        DevelopHistory.record(after, name: name, for: photo, after: cursor)
        historyCursor = nil
    }

    /// Lists the photo's history and snapshots in the panel.
    func showHistory() {
        historyPanel.isEditingEnabled = source != nil
        guard let photo = displayedPhoto else {
            historyPanel.display(steps: [], current: nil, snapshots: [])
            return
        }
        let steps = DevelopHistory.steps(for: photo)
        historyPanel.display(
            steps: steps.map { .init(id: $0.id, name: $0.name, date: $0.date) },
            current: historyCursor ?? steps.last?.id,
            snapshots: DevelopHistory.snapshots(for: photo).map { .init(id: $0.id, name: $0.name) })
    }

    private func applyHistoryStep(_ id: UUID) {
        guard let photo = displayedPhoto, let step = photo.historySteps.first(where: { $0.id == id }),
              let stored = DevelopHistory.adjustments(of: step) else { return }
        historyCursor = id
        if let source { panel.display(stored, asShotWhiteBalance: source.asShotWhiteBalance, isRaw: source.isRaw) }
        adjustmentsChanged(stored, isFinal: true, actionName: "History: \(step.name)", recordsHistory: false, replacesEverything: true)
        showHistory()
    }

    private func applySnapshot(_ id: UUID) {
        guard let photo = displayedPhoto, let snapshot = photo.snapshots.first(where: { $0.id == id }),
              let stored = DevelopHistory.adjustments(of: snapshot) else { return }
        if let source { panel.display(stored, asShotWhiteBalance: source.asShotWhiteBalance, isRaw: source.isRaw) }
        adjustmentsChanged(stored, isFinal: true, actionName: "Snapshot: \(snapshot.name)", replacesEverything: true)
        showHistory()
    }

    /// ⌘N in Develop: saves the current settings as a snapshot named after the time.
    func createSnapshot() {
        guard let photo = displayedPhoto, source != nil else { return }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let name = "Snapshot \(DevelopHistory.snapshots(for: photo).count + 1) – \(formatter.string(from: Date()))"
        DevelopHistory.createSnapshot(named: name, adjustments: adjustments, for: photo)
        store.viewContext.undoManager?.setActionName("Create Snapshot")
        store.save()
        if state.developTool != .history { state.developTool = .history } else { showHistory() }
    }

    private func updateSnapshot(_ id: UUID) {
        guard let photo = displayedPhoto, let snapshot = photo.snapshots.first(where: { $0.id == id }) else { return }
        snapshot.data = DevelopHistory.store(adjustments)
        snapshot.lightroomData = nil
        snapshot.date = Date()
        store.viewContext.undoManager?.setActionName("Update Snapshot")
        store.save()
        showHistory()
    }

    private func deleteSnapshot(_ id: UUID) {
        guard let photo = displayedPhoto, let snapshot = photo.snapshots.first(where: { $0.id == id }) else { return }
        store.viewContext.delete(snapshot)
        store.viewContext.undoManager?.setActionName("Delete Snapshot")
        store.save()
        showHistory()
    }

    private func renameSnapshot(_ id: UUID, to name: String) {
        guard let photo = displayedPhoto, let snapshot = photo.snapshots.first(where: { $0.id == id }) else { return }
        snapshot.name = name
        store.viewContext.undoManager?.setActionName("Rename Snapshot")
        store.save()
        showHistory()
    }

    private func clearHistory() {
        guard let photo = displayedPhoto else { return }
        DevelopHistory.clearHistory(for: photo)
        historyCursor = nil
        store.viewContext.undoManager?.setActionName("Clear History")
        store.save()
        showHistory()
    }

    /// Picks up changes made elsewhere, such as undo, for the photo being shown.
    @objc private func contextObjectsDidChange(_ notification: Notification) {
        guard let photo = displayedPhoto else { return }
        let updated = notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? []
        let refreshed = notification.userInfo?[NSRefreshedObjectsKey] as? Set<NSManagedObject> ?? []
        guard updated.contains(photo) || refreshed.contains(photo) else { return }
        let stored = photo.adjustments
        guard stored != adjustments, let source else { return }
        adjustments = stored
        panel.display(stored, asShotWhiteBalance: source.asShotWhiteBalance, isRaw: source.isRaw)
        if state.developTool == .crop { showCrop(stored.crop) }
        showLens()
        // The masks and spots too, or their panels would show (and their next edit put back) what was undone.
        showMasks()
        showRetouch()
        metalView.needsDisplay = true
    }

    // MARK: - Loading

    private func loadSelectedPhoto() {
        guard let id = state.selectedPhotoIDs.first,
              let photo = try? store.viewContext.existingObject(with: id) as? Photo else {
            endPresetPreview()
            displayedPhotoID = nil
            presetsPanel.photo = nil
            source = nil
            loupeSource = nil
            placeholder = nil
            panel.isEditingEnabled = false
            presetsPanel.isEditingEnabled = false
            panel.display(PhotoAdjustments(), asShotWhiteBalance: (6500, 0))
            lensContext = nil
            lensPanel.isEditingEnabled = false
            lensPanel.display(.init(), status: .unavailable, catalog: LensCatalog())
            rimLightPanel.isEditingEnabled = false
            rimLightPanel.subjectStatus = nil
            endFringePicking()
            histogramView.isEditingEnabled = false
            histogramView.histogram = nil
            histogramView.shootingInfo = ShootingInfo()
            histogramView.sourceStatus = nil
            histogramKey = nil
            show(message: "Select a photo in the Library to develop it.")
            infoLabel.stringValue = ""
            return
        }
        guard id != displayedPhotoID else { return }
        if state.developTool == .crop { commitCrop() }
        endPresetAmount()
        endPresetPreview()
        displayedPhotoID = id
        historyCursor = nil
        source = nil
        loupeSource = nil
        placeholder = store.thumbnails.cachedImage(for: photo.id).map { CIImage(cgImage: $0) }
        adjustments = photo.adjustments
        if state.developTool == .crop {
            cropSessionStart = adjustments.crop
            showCrop(adjustments.crop)
        }
        panel.isEditingEnabled = false
        presetsPanel.isEditingEnabled = false
        histogramView.isEditingEnabled = false
        histogramView.histogram = nil
        histogramView.shootingInfo = ShootingInfo()
        histogramView.sourceStatus = store.sourceStatus(of: photo)
        histogramKey = nil
        endFringePicking()
        lensContext = nil
        lensPanel.isEditingEnabled = false
        rimLightPanel.isEditingEnabled = false
        rimLightPanel.subjectStatus = nil
        showLens()
        panel.cameraModel = photo.cameraModel
        presetsPanel.photo = .init(cameraModel: photo.cameraModel)
        infoLabel.stringValue = [
            photo.fileName,
            [photo.cameraMake, photo.cameraModel].compactMap { $0 }.joined(separator: " "),
            photo.lensModel ?? "",
            photo.pixelWidth > 0 ? "\(photo.pixelWidth) × \(photo.pixelHeight)" : "",
        ].filter { !$0.isEmpty }.joined(separator: "  ·  ")

        let url = photo.fileURL
        let location = store.sourceLocation(of: photo)
        loadTask?.cancel()
        // Videos are shown and played in the Library; there is nothing to develop.
        if photo.isVideo {
            spinner.stopAnimation(nil)
            show(message: "“\(photo.fileName)” is a video. Videos can’t be edited; play it in the Library.")
            return
        }
        show(message: nil)
        spinner.startAnimation(nil)
        let thumbnails = store.thumbnails
        let uuid = photo.id
        loadTask = Task { [weak self] in
            let info = await Self.readShootingInfo(location)
            if self?.displayedPhotoID == id { self?.histogramView.shootingInfo = info }
            if self?.placeholder == nil, let thumbnail = await thumbnails.image(for: uuid) {
                guard let self, displayedPhotoID == id, source == nil else { return }
                placeholder = CIImage(cgImage: thumbnail)
                metalView.needsDisplay = true
            }
            let loaded = await Self.loadSource(location)
            guard let self, !Task.isCancelled, displayedPhotoID == id else { return }
            spinner.stopAnimation(nil)
            guard let source = loaded?.source else {
                if await Self.fileIsMissing(url) {
                    show(message: "The file “\(url.lastPathComponent)” could not be found.", canLocate: true)
                } else {
                    show(message: "Unable to open \(url.lastPathComponent).")
                }
                return
            }
            self.source = source
            panel.display(adjustments, asShotWhiteBalance: source.asShotWhiteBalance, isRaw: source.isRaw)
            panel.isEditingEnabled = true
            presetsPanel.isEditingEnabled = true
            histogramView.isEditingEnabled = true
            lensPanel.isEditingEnabled = true
            rimLightPanel.isEditingEnabled = true
            refreshRimLightStatus()
            if state.developTool == .lens { loadLensContext() }
            metalView.needsDisplay = true

            // The loupe's full-resolution decoder isn't needed to show the photo; load it after.
            let loupe = await Self.loadSource(location)
            guard displayedPhotoID == id else { return }
            loupeSource = loupe?.source
            placeholder = nil
            metalView.needsDisplay = true
        }
    }

    /// Carries a decoded source from the loading task to the main actor, which uses it exclusively.
    nonisolated private struct LoadedSource: @unchecked Sendable {
        let source: DevelopSource
    }

    /// From the original, or the Smart Preview (which keeps its EXIF) when the original is missing.
    @concurrent
    nonisolated private static func readShootingInfo(_ location: PhotoSourceLocation) async -> ShootingInfo {
        if !FileManager.default.isReadableFile(atPath: location.original.path(percentEncoded: false)),
           let smartPreview = location.smartPreview {
            return ShootingInfo.read(from: smartPreview)
        }
        return ShootingInfo.read(from: location.original)
    }

    /// The original, or its Smart Preview when the original can't be read.
    @concurrent
    nonisolated private static func loadSource(_ location: PhotoSourceLocation) async -> LoadedSource? {
        if FileManager.default.isReadableFile(atPath: location.original.path(percentEncoded: false)),
           let source = DevelopSource(url: location.original) {
            return LoadedSource(source: source)
        }
        return location.smartPreview.flatMap { DevelopSource(smartPreview: $0) }.map(LoadedSource.init)
    }

    @concurrent
    nonisolated private static func fileIsMissing(_ url: URL) async -> Bool {
        !FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func show(message: String?, canLocate: Bool = false) {
        messageLabel.stringValue = message ?? ""
        messageLabel.isHidden = message == nil
        locateButton.isHidden = !canLocate
        metalView.needsDisplay = true
    }

    // MARK: - Zoom

    private func configureZoom() {
        zoomClickView.isActive = { [weak self] in
            guard let self, source != nil else { return false }
            // Crop, Masking and Spot Removal use clicks on the photo themselves.
            return [.adjust, .rimLight, .presets, .lens, .history].contains(state.developTool)
        }
        zoomClickView.isZoomed = { [weak self] in self?.state.zoom.isZoomed ?? false }
        zoomClickView.onClick = { [weak self] point in
            guard let self else { return }
            var zoom = state.zoom
            // Side by side, a click on the before zooms to the same spot as one on the after.
            let imageRect: CGRect? = if case .sideBySide(let before, _)? = beforeAfterOverlay.arrangement, before.contains(point) {
                before
            } else {
                geometry?.imageRect
            }
            zoom.toggle(at: imageRect.map { imageRect in
                CGPoint(
                    x: ((point.x - imageRect.minX) / max(imageRect.width, 1)).clamped(to: 0...1),
                    y: ((point.y - imageRect.minY) / max(imageRect.height, 1)).clamped(to: 0...1)
                )
            })
            state.zoom = zoom
        }
        zoomClickView.onPan = { [weak self] delta in self?.pan(by: delta) }
        // Spot Removal takes clicks on the photo itself, but a zoomed photo still pans.
        retouchOverlay.isZoomed = { [weak self] in self?.state.zoom.isZoomed ?? false }
        retouchOverlay.onPan = { [weak self] delta in self?.pan(by: delta) }
        // So does the brush, with Space held.
        maskOverlay.onPan = { [weak self] delta in self?.pan(by: delta) }
    }

    /// Pans the zoomed photo by a drag of this many points.
    private func pan(by delta: CGVector) {
        guard let drawn = zoomedDraw else { return }
        var viewport = drawn.viewport
        viewport.pan(
            by: CGVector(dx: delta.dx * drawn.backingScale, dy: delta.dy * drawn.backingScale),
            imageSize: drawn.imageSize, paneBounds: drawn.pane, backingScale: 1
        )
        state.zoom.center = viewport.center
    }

    /// The viewport (in drawable pixels) for Fill or a zoom ratio; `nil` when the photo just fits.
    private func zoomViewport(imageSize: CGSize, pane: CGRect) -> CompareViewport? {
        let zoom = state.zoom
        guard zoom.isZoomed || zoom.fit == .fill else { return nil }
        var viewport = CompareViewport(zoom: zoom.scale(imageSize: imageSize, paneSize: pane.size), center: zoom.center)
        viewport.clampCenter(imageSize: imageSize, paneBounds: pane, backingScale: 1)
        return viewport
    }

    /// Tells the Navigator which part of the photo shows (`region` in full-resolution pixels).
    private func publishZoomVisibleRect(_ region: CGRect?, of size: CGSize) {
        guard state.mode == .develop, size.width > 0, size.height > 0 else { return }
        state.zoomVisibleRect = region.map {
            CGRect(x: $0.minX / size.width, y: $0.minY / size.height, width: $0.width / size.width, height: $0.height / size.height)
        }
    }

    /// A rect in drawable pixels, in points.
    private func points(_ rect: CGRect, _ backingScale: CGFloat) -> CGRect {
        rect.isNull ? .zero : CGRect(x: rect.minX / backingScale, y: rect.minY / backingScale, width: rect.width / backingScale, height: rect.height / backingScale)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let ciContext else { return }

        let bounds = CGRect(origin: .zero, size: view.drawableSize)
        let matte = CIColor(cgColor: previewContainer.resolvedMatte)
        var output = CIImage(color: matte).cropped(to: bounds)
        var newGeometry: PreviewGeometry?
        var newArrangement: BeforeAfterOverlayView.Arrangement?
        var previewImage: (image: CIImage, scale: CGFloat)?
        /// The settings the loupe magnifies: the before's in Before Only.
        var loupeAdjustments = presetPreview ?? adjustments
        if source == nil, let placeholder, !placeholder.extent.isEmpty {
            // Fill the same rect the decoded photo will, so the swap is seamless.
            let extent = placeholder.extent
            let fit = min(bounds.width / extent.width, bounds.height / extent.height)
            let scaled = placeholder
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(scaleX: fit, y: fit))
            output = scaled.transformed(by: CGAffineTransform(
                translationX: ((bounds.width - scaled.extent.width) / 2).rounded(),
                y: ((bounds.height - scaled.extent.height) / 2).rounded()
            )).composited(over: output)
        }
        if let source {
            // Render at display resolution: RAW decoding at a reduced scale keeps slider drags live.
            let cropping = state.developTool == .crop
            // Masks are placed on the whole frame, so the Masking tool shows it uncropped and unstraightened.
            let masking = state.developTool == .mask || state.developTool == .retouch
            // A preset under the pointer in the Presets panel is previewed.
            var shownAdjustments = presetPreview ?? adjustments
            if masking { shownAdjustments.crop = PhotoAdjustments.Crop() }
            // A cropped photo renders at the size it's shown; the crop tool shows the whole frame.
            let previewScale = cropping
                ? source.scale(toFit: max(bounds.width, bounds.height))
                : source.scale(toFit: max(bounds.width, bounds.height), adjustments: shownAdjustments)
            // View ▸ Before/After (not in the tools that show the photo their own way).
            let beforeAfter = cropping || masking ? nil : state.beforeAfter
            let beforeAdjustments = shownAdjustments.before
            // The photo at `scale` from `source`: as edited, before the edits, or split between them.
            func photo(from source: DevelopSource, scale: CGFloat, showing content: BeforeAfterContent) -> CIImage {
                let after = source.image(with: shownAdjustments, scale: scale, geometry: cropping ? .straightenedOnly : .cropped)
                guard content != .after else { return after }
                return content.compose(before: source.image(with: beforeAdjustments, scale: scale, geometry: .cropped), after: after)
            }
            let content: BeforeAfterContent = switch beforeAfter {
            case .beforeOnly?: .before
            case .split?: .split
            default: .after
            }
            let afterImage = photo(from: source, scale: previewScale, showing: .after)
            let image = content == .after ? afterImage : photo(from: source, scale: previewScale, showing: content)
            if !cropping, !masking { previewImage = (beforeAfter?.isSideBySide == true ? afterImage : image, previewScale) }
            if content == .before { loupeAdjustments = beforeAdjustments }
            if !image.extent.isEmpty, !image.extent.isInfinite {
                // The histogram is always the edited photo's.
                requestHistogram(for: afterImage, adjustments: shownAdjustments, cropping: cropping)
                // The sharpen-mask preview or clipping warnings, and the selected mask in red while masking.
                func decorate(_ image: CIImage, scale: CGFloat) -> CIImage {
                    var shown = showsSharpenMask
                        ? SharpenRenderer.maskPreview(for: image, masking: adjustments.sharpen.masking, scale: scale)
                        : ClippingOverlay.apply(to: image, shadows: clippingDisplay.shadows, highlights: clippingDisplay.highlights)
                    if masking, showsMaskOverlay, let selected = adjustments.masks.first(where: { $0.id == maskPanel.selectedID }),
                       let mask = LocalAdjustmentRenderer.mask(
                           for: selected, extent: image.extent,
                           subject: selected.usesSubject ? source.subjectMattes.matte(for: source, adjustments: adjustments, waiting: false)?.image : nil
                       ) {
                        // The selected mask in red, half strength.
                        let half = mask.applyingFilter("CIColorMatrix", parameters: [
                            "inputRVector": CIVector(x: 0.5, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0.5, y: 0, z: 0, w: 0),
                            "inputBVector": CIVector(x: 0.5, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                        ])
                        let red = CIImage(color: CIColor(red: 1, green: 0.1, blue: 0.1)).cropped(to: image.extent)
                        let blend = CIFilter.blendWithMask()
                        blend.inputImage = red
                        blend.backgroundImage = shown
                        blend.maskImage = half
                        shown = blend.outputImage?.cropped(to: image.extent) ?? shown
                    }
                    return shown
                }
                let backingScale = view.bounds.width > 0 ? bounds.width / view.bounds.width : 2
                // Full-resolution size of what's shown.
                let fullSize = CGSize(width: image.extent.width / previewScale, height: image.extent.height / previewScale)
                // Draws `preview` (the photo showing `content`) in `pane`, fitted or at the zoom, and returns where.
                func place(_ preview: CIImage, showing content: BeforeAfterContent, in pane: CGRect) -> CGRect {
                    if !cropping, let viewport = zoomViewport(imageSize: fullSize, pane: pane) {
                        // Fill or a zoom ratio (the crop tool always shows the whole frame).
                        let rect = viewport.imageRect(imageSize: fullSize, paneBounds: pane, backingScale: 1)
                        // Past the screen-sized preview's detail, render from the full-resolution decoder; Core
                        // Image only computes the part that ends up on screen.
                        var detail = (image: preview, scale: previewScale)
                        let detailScale = CGFloat(min(viewport.zoom, 1))
                        if detailScale > previewScale * 1.01 {
                            detail = (photo(from: loupeSource ?? source, scale: detailScale, showing: content), detailScale)
                        }
                        let extent = detail.image.extent
                        let placed = decorate(detail.image, scale: detail.scale)
                            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                            .transformed(by: CGAffineTransform(scaleX: rect.width / extent.width, y: rect.height / extent.height))
                            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
                            .cropped(to: pane)
                        output = placed.composited(over: output)
                        zoomedDraw = (viewport, fullSize, pane, backingScale)
                        publishZoomVisibleRect(viewport.visibleImageRegion(imageSize: fullSize, paneBounds: pane, backingScale: 1), of: fullSize)
                        return rect
                    }
                    let shown = decorate(preview, scale: previewScale)
                    let fit = min(pane.width / preview.extent.width, pane.height / preview.extent.height, 1)
                    let scaled = shown
                        .transformed(by: CGAffineTransform(translationX: -preview.extent.minX, y: -preview.extent.minY))
                        .transformed(by: CGAffineTransform(scaleX: fit, y: fit))
                    let offset = CGAffineTransform(
                        translationX: pane.minX + ((pane.width - scaled.extent.width) / 2).rounded(),
                        y: pane.minY + ((pane.height - scaled.extent.height) / 2).rounded()
                    )
                    let placed = scaled.transformed(by: offset)
                    output = placed.composited(over: output)
                    zoomedDraw = nil
                    publishZoomVisibleRect(nil, of: fullSize)
                    return placed.extent
                }
                let rect: CGRect
                // Left/Right and Top/Bottom: the before in one pane and the after in the other, zoomed alike.
                // The after goes last, so panning and the Navigator follow it.
                if let panes = beforeAfter?.panes(in: bounds, gap: (8 * backingScale).rounded()) {
                    let before = place(photo(from: source, scale: previewScale, showing: .before), showing: .before, in: panes.before)
                    rect = place(afterImage, showing: .after, in: panes.after)
                    newArrangement = .sideBySide(
                        before: points(before.intersection(panes.before), backingScale), after: points(rect.intersection(panes.after), backingScale)
                    )
                    // The zoom animation moves one photo; side by side, both just change.
                    pendingZoomAnimation = false
                    zoomAnimation = nil
                } else {
                    rect = place(image, showing: content, in: bounds)
                    let visible = points(rect.intersection(bounds), backingScale)
                    switch beforeAfter {
                    case .split?:
                        let left = image.extent.width > 0 ? (image.extent.width / 2).rounded() / image.extent.width : 0.5
                        newArrangement = .split(photo: visible, dividerX: (rect.minX + rect.width * left) / backingScale)
                    case .beforeOnly?: newArrangement = .beforeOnly(photo: visible)
                    default: break
                    }
                }
                // Zooming in or out: move the preview from where it was to `rect` over a moment, drawing the
                // quick screen-sized render on the way, then the sharp one.
                if pendingZoomAnimation, let last = lastDrawnRect,
                   abs(last.width - rect.width) > 1 || abs(last.height - rect.height) > 1 {
                    zoomAnimation = (last, CACurrentMediaTime())
                    zoomAnimationsStarted += 1
                }
                pendingZoomAnimation = false
                if let animation = zoomAnimation {
                    let t = min((CACurrentMediaTime() - animation.start) / PhotoViewer.zoomAnimationDuration, 1)
                    if t < 1 {
                        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                        let from = animation.from
                        let step = CGRect(
                            x: from.minX + (rect.minX - from.minX) * eased, y: from.minY + (rect.minY - from.minY) * eased,
                            width: from.width + (rect.width - from.width) * eased, height: from.height + (rect.height - from.height) * eased
                        )
                        let moving = decorate(image, scale: previewScale)
                            .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                            .transformed(by: CGAffineTransform(scaleX: step.width / image.extent.width, y: step.height / image.extent.height))
                            .transformed(by: CGAffineTransform(translationX: step.minX, y: step.minY))
                            .cropped(to: bounds)
                        output = moving.composited(over: CIImage(color: matte).cropped(to: bounds))
                        lastDrawnRect = step
                        // The next frame.
                        DispatchQueue.main.async { [weak self] in self?.metalView.needsDisplay = true }
                    } else {
                        zoomAnimation = nil
                        lastDrawnRect = rect
                    }
                } else {
                    lastDrawnRect = rect
                }
                // Side by side, the eyedroppers and loupe work on the after.
                lastPreview = (beforeAfter?.isSideBySide == true ? afterImage : image, CGRect(
                    x: rect.minX / backingScale, y: rect.minY / backingScale,
                    width: rect.width / backingScale, height: rect.height / backingScale
                ))
                if cropping {
                    // The crop tool always fits (above), so this is the fitted scale.
                    let cropFit = rect.width / max(image.extent.width, 1)
                    // The photo's frame (its unrotated, uncropped bounds), where the crop is drawn.
                    let frameSize = CGSize(
                        width: source.frameSize(adjustments).width * previewScale,
                        height: source.frameSize(adjustments).height * previewScale
                    )
                    let frame = CGRect(
                        x: rect.midX - frameSize.width * cropFit / 2, y: rect.midY - frameSize.height * cropFit / 2,
                        width: frameSize.width * cropFit, height: frameSize.height * cropFit
                    )
                    cropOverlay.frameRect = CGRect(
                        x: frame.minX / backingScale, y: frame.minY / backingScale,
                        width: frame.width / backingScale, height: frame.height / backingScale
                    )
                    cropOverlay.imageSize = source.frameSize(adjustments)
                } else if masking {
                    let framePoints = CGRect(
                        x: rect.minX / backingScale, y: rect.minY / backingScale,
                        width: rect.width / backingScale, height: rect.height / backingScale
                    )
                    maskOverlay.frameRect = framePoints
                    retouchOverlay.frameRect = framePoints
                    lastFrameImage = image
                } else {
                    newGeometry = PreviewGeometry(
                        imageRect: CGRect(
                            x: rect.minX / backingScale, y: rect.minY / backingScale,
                            width: rect.width / backingScale, height: rect.height / backingScale
                        ),
                        // Full-resolution size of what's shown (after cropping).
                        imageSize: CGSize(width: image.extent.width / previewScale, height: image.extent.height / previewScale),
                        backingScale: backingScale
                    )
                }
            }
        }
        if newGeometry != geometry {
            geometry = newGeometry
            loupeOverlay.needsDisplay = true
        }
        beforeAfterOverlay.arrangement = newArrangement

        if let request = loupeOverlay.renderRequest, request.magnify, let geometry {
            // Full resolution once its decoder is ready; until then, magnify the preview.
            let photo: (image: CIImage, scale: CGFloat)? = if let loupeSource {
                (loupeSource.image(with: loupeAdjustments, scale: LoupeRenderer.renderScale(forZoom: request.zoom)),
                 LoupeRenderer.renderScale(forZoom: request.zoom))
            } else {
                previewImage
            }
            if let photo {
                output = LoupeRenderer.composite(
                    request, photo: photo.image, photoScale: photo.scale, over: output, geometry: geometry, matte: matte
                )
                if loupeSettings.showsColorValue {
                    loupeOverlay.colorValue = LoupeRenderer.colorValue(
                        at: request, photo: photo.image, photoScale: photo.scale, geometry: geometry, context: ciContext
                    )
                }
            }
        }

        ciContext.render(output, to: drawable.texture, commandBuffer: commandBuffer, bounds: bounds, colorSpace: colorSpace)
        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()
        drawable.present()
    }
}
