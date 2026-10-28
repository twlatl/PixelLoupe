import AppKit
import CoreData

/// Compare (C): the Select and Candidate photos side by side, with a bar for zooming them together
/// or separately, syncing, swapping, changing the candidate and leaving Compare.
///
/// A Library view (as in Lightroom); the Library shows it while `state.presentation == .compare`.
final class CompareViewController: NSViewController {
    private let store: CatalogStore
    private let state: LibraryState

    private lazy var panes = [
        ComparePhotoView(role: .select, store: store),
        ComparePhotoView(role: .candidate, store: store),
    ]
    private let lockButton = NSButton()
    private let zoomSlider = MonochromeSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let zoomLabel = NSTextField(labelWithString: "")
    /// While locked (the default), zooming and panning apply to both photos.
    private(set) var isLocked = true
    /// Whether the bar starts with the Library's view buttons (it covers the bottom toolbar that has
    /// them). Off in the secondary window, which has its own views. Set before the view loads.
    var showsViewModes = false

    init(store: CatalogStore, state: LibraryState) {
        self.store = store
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let divider = NSBox()
        divider.boxType = .separator
        // Keep the divider a 1pt vertical line; otherwise it soaks up extra width (e.g. in full
        // screen) and squeezes both photos to the edges.
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.setContentHuggingPriority(.required, for: .horizontal)
        let photos = NSStackView(views: [panes[0], divider, panes[1]])
        photos.distribution = .fill
        photos.spacing = 0
        panes[0].widthAnchor.constraint(equalTo: panes[1].widthAnchor).isActive = true

        for (index, pane) in panes.enumerated() {
            pane.onActivate = { [weak self] in self?.activate(index) }
            pane.onPan = { [weak self] viewport in self?.paneDidPan(index, viewport) }
        }

        lockButton.setButtonType(.momentaryPushIn)
        lockButton.bezelStyle = .toolbar
        lockButton.isBordered = false
        lockButton.imagePosition = .imageOnly
        lockButton.target = self
        lockButton.action = #selector(toggleLock(_:))
        lockButton.setAccessibilityIdentifier("compareLock")

        let zoomTitle = NSTextField(labelWithString: "Zoom")
        zoomTitle.textColor = .secondaryLabelColor
        zoomTitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        zoomSlider.controlSize = .small
        zoomSlider.numberOfTickMarks = 0
        zoomSlider.isContinuous = true
        zoomSlider.target = self
        zoomSlider.action = #selector(zoomChanged(_:))
        zoomSlider.setAccessibilityLabel("Zoom")
        zoomSlider.setAccessibilityIdentifier("compareZoom")
        zoomSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        zoomLabel.textColor = .secondaryLabelColor
        zoomLabel.alignment = .right
        zoomLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        zoomLabel.setAccessibilityIdentifier("compareZoomValue")

        let sync = button(title: "Sync", symbol: nil, action: #selector(sync(_:)), identifier: "compareSync",
                          help: "Zoom and position both photos like the Select photo")
        let swap = button(title: "Swap", symbol: "arrow.left.arrow.right", action: #selector(swap(_:)),
                          identifier: "compareSwap", help: "Swap the Select and Candidate photos")
        let previous = button(title: "Previous Candidate", symbol: "arrow.left", action: #selector(previousCandidate(_:)),
                              identifier: "comparePrevious", help: "Previous candidate (←)")
        let next = button(title: "Next Candidate", symbol: "arrow.right", action: #selector(nextCandidate(_:)),
                          identifier: "compareNext", help: "Next candidate (→)")
        let done = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        done.controlSize = .small
        done.keyEquivalent = ""
        done.setAccessibilityIdentifier("compareDone")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var barViews: [NSView] = [lockButton, zoomTitle, zoomSlider, zoomLabel, sync, swap, spacer, previous, next, done]
        if showsViewModes { barViews.insert(ViewModeControl(state: state), at: 0) }
        let bar = NSStackView(views: barViews)
        bar.spacing = 8
        if let viewModes = barViews.first as? ViewModeControl { bar.setCustomSpacing(16, after: viewModes) }
        bar.setCustomSpacing(16, after: zoomLabel)
        bar.setCustomSpacing(16, after: swap)
        bar.setCustomSpacing(16, after: next)
        bar.setHuggingPriority(.defaultLow, for: .horizontal)
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

        let barLine = NSBox()
        barLine.boxType = .separator
        let container = MatteView()
        container.setAccessibilityIdentifier("compareView")
        for view in [photos, barLine, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            photos.topAnchor.constraint(equalTo: container.topAnchor),
            photos.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            photos.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            barLine.topAnchor.constraint(equalTo: photos.bottomAnchor),
            barLine.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            barLine.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.topAnchor.constraint(equalTo: barLine.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        updateLock()
    }

    private func button(title: String, symbol: String?, action: Selector, identifier: String, help: String) -> NSButton {
        let button: NSButton
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            button = NSButton(image: image, target: self, action: action)
            button.isBordered = false
            button.bezelStyle = .toolbar
        } else {
            button = NSButton(title: title, target: self, action: action)
            button.controlSize = .small
        }
        button.toolTip = help
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        state.addObserver(self) { [weak self] change in
            if change == .compare { self?.reload() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(contextObjectsDidChange(_:)),
            name: .NSManagedObjectContextObjectsDidChange, object: store.viewContext
        )
    }

    /// Called by the host when Compare is shown.
    func refresh() {
        reload()
    }

    private func reload() {
        guard isViewLoaded, !view.isHiddenOrHasHiddenAncestor else { return }
        panes[0].show(state.comparePhotos?.select)
        panes[1].show(state.comparePhotos?.candidate)
        for (index, pane) in panes.enumerated() { pane.isActive = index == state.activeCompareIndex }
        view.layoutSubtreeIfNeeded()
        updateZoomControls()
    }

    // MARK: - Zoom

    private var activePane: ComparePhotoView { panes[state.activeCompareIndex] }

    /// The slider's low end fits both photos.
    private var sliderFit: Double {
        panes.compactMap(\.fitZoom).min() ?? 0.1
    }

    private func updateZoomControls() {
        let zoom = activePane.viewport?.zoom ?? sliderFit
        zoomSlider.doubleValue = CompareViewport.sliderValue(forZoom: zoom, fit: sliderFit)
        zoomLabel.stringValue = String(format: "%.1f%%", zoom * 100)
    }

    @objc private func zoomChanged(_ sender: NSSlider) {
        // At the low end each photo fits its pane, and keeps fitting as the window resizes.
        let fitted = sender.doubleValue <= 0.001
        let zoom = CompareViewport.zoom(forSliderValue: sender.doubleValue, fit: sliderFit)
        for pane in isLocked ? panes : [activePane] {
            if fitted {
                pane.fitToPane()
            } else {
                var viewport = pane.viewport ?? CompareViewport(zoom: zoom)
                viewport.zoom = zoom
                pane.setViewport(viewport)
            }
        }
        zoomLabel.stringValue = String(format: "%.1f%%", (activePane.viewport?.zoom ?? zoom) * 100)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateZoomControls()
    }

    private func paneDidPan(_ index: Int, _ viewport: CompareViewport) {
        guard isLocked else { return }
        let other = panes[1 - index]
        guard var otherViewport = other.viewport else { return }
        otherViewport.center = viewport.center
        other.setViewport(otherViewport)
    }

    @objc private func toggleLock(_ sender: Any?) {
        isLocked.toggle()
        updateLock()
    }

    private func updateLock() {
        lockButton.image = NSImage(
            systemSymbolName: isLocked ? "lock.fill" : "lock.open.fill",
            accessibilityDescription: isLocked ? "Locked" : "Unlocked"
        )
        lockButton.toolTip = isLocked
            ? "Zoom and pan both photos together. Click to zoom only the active photo."
            : "Zoom and pan only the active photo. Click to lock them together."
        lockButton.setAccessibilityLabel("Lock zoom")
        lockButton.setAccessibilityValue(isLocked ? "locked" : "unlocked")
    }

    /// Zooms and positions the Candidate like the Select photo.
    @objc private func sync(_ sender: Any?) {
        guard let viewport = panes[0].viewport else { return }
        if panes[0].isFitted {
            panes[1].fitToPane()
        } else {
            panes[1].setViewport(viewport)
        }
        updateZoomControls()
    }

    // MARK: - Photos

    private func activate(_ index: Int) {
        guard let pair = state.comparePhotos else { return }
        state.activeCompareIndex = index
        let active = index == 0 ? pair.select : pair.candidate
        let other = index == 0 ? pair.candidate : pair.select
        state.selectedPhotoIDs = [active, other]
        for (paneIndex, pane) in panes.enumerated() { pane.isActive = paneIndex == index }
        updateZoomControls()
    }

    @objc func swap(_ sender: Any?) {
        guard let pair = state.comparePhotos else { return }
        let views = panes.map { ($0.viewport, $0.isFitted) }
        state.comparePhotos = (pair.candidate, pair.select)
        for (pane, (viewport, fitted)) in zip(panes, views.reversed()) {
            if fitted { pane.fitToPane() } else if let viewport { pane.setViewport(viewport) }
        }
        activate(1 - state.activeCompareIndex)
    }

    @objc func previousCandidate(_ sender: Any?) {
        stepCandidate(by: -1)
    }

    @objc func nextCandidate(_ sender: Any?) {
        stepCandidate(by: 1)
    }

    /// ← and → change the candidate, as in Lightroom; zoom and position carry over.
    func stepCandidate(by offset: Int) {
        guard let pair = state.comparePhotos,
              let next = ComparePair.step(candidate: pair.candidate, select: pair.select, by: offset, order: state.photoOrder)
        else { return }
        let viewport = panes[1].viewport
        let fitted = panes[1].isFitted
        state.comparePhotos = (pair.select, next)
        if fitted { panes[1].fitToPane() } else if let viewport { panes[1].setViewport(viewport) }
        activate(state.activeCompareIndex)
    }

    @objc private func done(_ sender: Any?) {
        state.presentation = .grid
    }

    @objc private func contextObjectsDidChange(_ notification: Notification) {
        let changed = [NSUpdatedObjectsKey, NSRefreshedObjectsKey]
            .flatMap { notification.userInfo?[$0] as? Set<NSManagedObject> ?? [] }
            .map(\.objectID)
        for pane in panes where pane.photoID.map(changed.contains) == true {
            pane.photoDidChange()
        }
    }
}
