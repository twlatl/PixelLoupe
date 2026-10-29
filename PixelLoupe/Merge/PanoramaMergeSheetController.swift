import AppKit

/// Photo ▸ Photo Merge ▸ Panorama's sheet, laid out like the HDR sheet with Lightroom's Panorama
/// Merge Preview options: the merged panorama on the left, updating as the options change, and on
/// the right how many photos merged, the projection (Spherical, Cylindrical, Perspective), Boundary
/// Warp, Auto Crop, Auto Settings, Create Stack and Lightroom's lens profile notice. Merge and Cancel
/// sit centered below. Clicking the panorama zooms to 100% (see ``MergePreviewView``). For HDR Panorama
/// it's the HDR Panorama Merge Preview, each bracket set merged as one photo.
final class PanoramaMergeSheetController: NSWindowController, NSWindowDelegate {
    /// The options to merge with, or nil for Cancel.
    var onFinish: ((PanoramaMergeOptions?) -> Void)?

    let sources: [PhotoMergeSource]
    /// HDR Panorama's bracket sets (``HDRBrackets``), or nil for a panorama of single photos.
    let brackets: [[PhotoMergeSource]]?
    private(set) var options: PanoramaMergeOptions

    /// The well the preview sits in: the user's matte color with a medium gray border, so the sheet keeps
    /// its layout while the first preview loads.
    let previewWell = MatteView()
    let previewView = MergePreviewView()
    let spinner = NSProgressIndicator()
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let statusLabel = NSTextField(labelWithString: "Merging photos…")
    let sphericalButton = NSButton(radioButtonWithTitle: PanoramaProjection.spherical.title, target: nil, action: nil)
    let cylindricalButton = NSButton(radioButtonWithTitle: PanoramaProjection.cylindrical.title, target: nil, action: nil)
    let perspectiveButton = NSButton(radioButtonWithTitle: PanoramaProjection.perspective.title, target: nil, action: nil)
    let perspectiveNote = NSTextField(wrappingLabelWithString: "Perspective can’t show photos spanning more than \(Int(PanoramaProjection.perspectiveLimit))°.")
    let boundaryWarpSlider = MonochromeSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    let boundaryWarpField = NSTextField()
    let autoCropCheckbox = NSButton(checkboxWithTitle: "Auto Crop", target: nil, action: nil)
    let autoSettingsCheckbox = NSButton(checkboxWithTitle: "Auto Settings", target: nil, action: nil)
    let createStackCheckbox = NSButton(checkboxWithTitle: "Create Stack", target: nil, action: nil)
    let lensNotice = NSTextField(wrappingLabelWithString: PanoramaMerger.lensNotice)
    let lensNoticeRow = NSStackView()
    let mergeButton = NSButton(title: "Merge", target: nil, action: nil)

    private var previewer: PanoramaMergePreviewer?
    private var previewTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    /// Why the photos can't be merged, once known.
    private var problem: String?

    var projectionButtons: [(PanoramaProjection, NSButton)] {
        [(.spherical, sphericalButton), (.cylindrical, cylindricalButton), (.perspective, perspectiveButton)]
    }

    init(sources: [PhotoMergeSource], brackets: [[PhotoMergeSource]]? = nil, options: PanoramaMergeOptions) {
        self.sources = sources
        self.brackets = brackets
        self.options = options
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
            styleMask: [.titled, .resizable], backing: .buffered, defer: true
        )
        window.title = brackets == nil ? "Panorama Merge Preview" : "HDR Panorama Merge Preview"
        window.contentMinSize = NSSize(width: 760, height: 480)
        window.setAccessibilityIdentifier("panoramaMergeSheet")
        super.init(window: window)
        window.delegate = self
        buildContent()
        updateControls()
        prepare()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A bigger sheet gets a sharper preview.
    func windowDidEndLiveResize(_ notification: Notification) {
        refreshPreview(debounce: false)
    }

    deinit {
        previewTask?.cancel()
        detailTask?.cancel()
    }

    // MARK: - Layout

    private func buildContent() {
        previewView.setAccessibilityLabel("Merged panorama preview")
        previewView.onDetailNeeded = { [weak self] center, pixels in
            self?.refreshDetail(center: center, pixels: pixels)
        }
        previewView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        previewView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previewView.setContentHuggingPriority(.defaultLow, for: .vertical)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false

        previewWell.layer?.borderColor = NSColor(white: 0.5, alpha: 1).cgColor
        previewWell.layer?.borderWidth = 1
        previewWell.setAccessibilityElement(false)
        for view in [previewView, spinner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            previewWell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: previewWell.leadingAnchor, constant: 12),
            previewView.trailingAnchor.constraint(equalTo: previewWell.trailingAnchor, constant: -12),
            previewView.topAnchor.constraint(equalTo: previewWell.topAnchor, constant: 12),
            previewView.bottomAnchor.constraint(equalTo: previewWell.bottomAnchor, constant: -12),
            spinner.centerXAnchor.constraint(equalTo: previewWell.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: previewWell.centerYAnchor),
            previewWell.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
            previewWell.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        previewWell.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previewWell.setContentHuggingPriority(.defaultLow, for: .vertical)

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.setAccessibilityIdentifier("panoramaMergeMessage")

        let left = NSStackView(views: [previewWell, messageLabel])
        left.orientation = .vertical
        left.alignment = .centerX
        left.spacing = 8
        left.distribution = .fill
        left.setHuggingPriority(.defaultLow, for: .horizontal)
        messageLabel.setContentHuggingPriority(.required, for: .vertical)
        previewWell.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        messageLabel.widthAnchor.constraint(lessThanOrEqualTo: left.widthAnchor).isActive = true

        let heading = NSTextField(labelWithString: "Panorama Options")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityIdentifier("panoramaMergeStatus")

        let projectionLabel = NSTextField(labelWithString: "Projection")
        for (projection, button) in projectionButtons {
            button.target = self
            button.action = #selector(projectionChanged(_:))
            button.setAccessibilityIdentifier("panoramaProjection-\(projection.rawValue)")
        }
        sphericalButton.toolTip = "As if on the inside of a sphere: for very wide or multi-row panoramas."
        cylindricalButton.toolTip = "As if on the inside of a cylinder: for wide panoramas, keeping verticals straight."
        perspectiveButton.toolTip = "As if on a flat surface: keeps straight lines straight, for architecture."
        perspectiveNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        perspectiveNote.textColor = .secondaryLabelColor

        let warpLabel = NSTextField(labelWithString: "Boundary Warp")
        boundaryWarpSlider.isContinuous = true
        boundaryWarpSlider.target = self
        boundaryWarpSlider.action = #selector(boundaryWarpSliderChanged(_:))
        boundaryWarpSlider.setAccessibilityLabel("Boundary Warp")
        boundaryWarpSlider.toolTip = "Bends the panorama to fill its rectangle, keeping what's near the edges."
        let formatter = NumberFormatter()
        formatter.minimum = 0
        formatter.maximum = 100
        formatter.maximumFractionDigits = 0
        boundaryWarpField.formatter = formatter
        boundaryWarpField.alignment = .right
        boundaryWarpField.target = self
        boundaryWarpField.action = #selector(boundaryWarpFieldChanged(_:))
        boundaryWarpField.setAccessibilityLabel("Boundary Warp amount")
        boundaryWarpField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let warpRow = NSStackView(views: [boundaryWarpSlider, boundaryWarpField])
        warpRow.spacing = 8

        for checkbox in [autoCropCheckbox, autoSettingsCheckbox, createStackCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(optionChanged(_:))
        }
        autoCropCheckbox.toolTip = "Crops away the edges the photos don't reach. The crop can be changed in Develop."
        autoSettingsCheckbox.toolTip = "Starts the panorama with automatic tone settings."
        createStackCheckbox.toolTip = "Stacks the panorama on top of the photos it was made from."

        let warning = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "Note") ?? NSImage())
        warning.contentTintColor = .secondaryLabelColor
        warning.setContentHuggingPriority(.required, for: .horizontal)
        lensNotice.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        lensNotice.textColor = .secondaryLabelColor
        lensNotice.setAccessibilityIdentifier("panoramaLensNotice")
        lensNoticeRow.setViews([warning, lensNotice], in: .leading)
        lensNoticeRow.alignment = .top
        lensNoticeRow.spacing = 6
        lensNoticeRow.isHidden = true

        func separator() -> NSBox {
            let box = NSBox()
            box.boxType = .separator
            return box
        }
        let separators = [separator(), separator(), separator()]
        let options = NSStackView(views: [
            heading, statusLabel, separators[0], projectionLabel, sphericalButton, cylindricalButton, perspectiveButton,
            perspectiveNote, warpLabel, warpRow, separators[1], autoCropCheckbox, autoSettingsCheckbox, separators[2],
            createStackCheckbox, lensNoticeRow,
        ])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 10
        options.setCustomSpacing(4, after: heading)
        options.setCustomSpacing(6, after: projectionLabel)
        options.setCustomSpacing(6, after: sphericalButton)
        options.setCustomSpacing(6, after: cylindricalButton)
        options.setCustomSpacing(16, after: perspectiveNote)
        options.setCustomSpacing(6, after: warpLabel)
        options.setCustomSpacing(20, after: createStackCheckbox)
        for view in [warpRow, perspectiveNote, lensNoticeRow] + separators as [NSView] {
            view.widthAnchor.constraint(equalTo: options.widthAnchor).isActive = true
        }
        options.widthAnchor.constraint(equalToConstant: 240).isActive = true
        options.setHuggingPriority(.required, for: .horizontal)

        let optionsColumn = NSStackView(views: [options])
        optionsColumn.orientation = .vertical
        optionsColumn.alignment = .leading
        optionsColumn.setHuggingPriority(.required, for: .horizontal)

        let body = NSStackView(views: [left, optionsColumn])
        body.orientation = .horizontal
        body.alignment = .top
        body.distribution = .fill
        body.spacing = 20
        left.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        mergeButton.target = self
        mergeButton.action = #selector(merge(_:))
        mergeButton.keyEquivalent = "\r"
        mergeButton.setAccessibilityIdentifier("panoramaMergeButton")
        for button in [cancelButton, mergeButton] {
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        }
        let buttons = NSStackView(views: [cancelButton, mergeButton])
        buttons.spacing = 12
        buttons.setHuggingPriority(.required, for: .vertical)

        let root = NSStackView(views: [body, buttons])
        root.orientation = .vertical
        root.alignment = .centerX
        root.distribution = .fill
        root.spacing = 20
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        body.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        body.setHuggingPriority(.defaultLow, for: .vertical)
        window?.contentView = root
    }

    private func updateControls() {
        let enabled = problem == nil && previewer != nil
        let allowsPerspective = previewer?.allowsPerspective ?? true
        for (projection, button) in projectionButtons {
            button.state = options.projection == projection ? .on : .off
            button.isEnabled = enabled && (projection != .perspective || allowsPerspective)
        }
        perspectiveNote.isHidden = allowsPerspective
        boundaryWarpSlider.integerValue = options.boundaryWarp
        boundaryWarpField.integerValue = options.boundaryWarp
        autoCropCheckbox.state = options.autoCrop ? .on : .off
        autoSettingsCheckbox.state = options.autoSettings ? .on : .off
        createStackCheckbox.state = options.createsStack ? .on : .off
        for control in [boundaryWarpSlider, boundaryWarpField, autoCropCheckbox, autoSettingsCheckbox, createStackCheckbox] as [NSControl] {
            control.isEnabled = enabled
        }
        mergeButton.isEnabled = enabled
    }

    // MARK: - Preview

    /// Reads and aligns the photos (off the main thread), then draws the first preview.
    private func prepare() {
        spinner.startAnimation(nil)
        let sources = sources, brackets = brackets
        previewTask = Task { [weak self] in
            let result: Result<PanoramaMergePreviewer, Error>
            do { result = .success(try await Self.makePreviewer(sources, brackets: brackets)) } catch { result = .failure(error) }
            guard let self else { return }
            switch result {
            case .success(let previewer):
                self.previewer = previewer
                let things = brackets == nil ? "photos" : "bracket sets"
                statusLabel.stringValue = previewer.mergedCount == previewer.photoCount
                    ? "All \(previewer.photoCount) \(things) merged"
                    : "\(previewer.mergedCount) of \(previewer.photoCount) \(things) merged"
                lensNoticeRow.isHidden = previewer.lensWarning == nil
                // Perspective can't show these photos: Spherical instead, as a headless merge does.
                if options.projection == .perspective, !previewer.allowsPerspective { options.projection = .spherical }
                updateControls()
                refreshPreview(debounce: false)
            case .failure(let error):
                spinner.stopAnimation(nil)
                problem = error.localizedDescription
                statusLabel.stringValue = "The photos can’t be merged."
                messageLabel.stringValue = error.localizedDescription
                updateControls()
            }
        }
    }

    @concurrent
    private nonisolated static func makePreviewer(
        _ sources: [PhotoMergeSource], brackets: [[PhotoMergeSource]]?
    ) async throws -> PanoramaMergePreviewer {
        try PanoramaMergePreviewer(sources: sources, brackets: brackets)
    }

    /// Redraws the preview with the current options, after a moment so dragging the slider doesn't
    /// queue up merges.
    private func refreshPreview(debounce: Bool = true) {
        guard let previewer else { return }
        previewTask?.cancel()
        detailTask?.cancel()
        spinner.startAnimation(nil)
        let options = options
        let scale = window?.backingScaleFactor ?? 2
        // Rounded so small resizes reuse the merge.
        let maxPixels = (min(2400, max(previewView.bounds.width, previewView.bounds.height, 700) * scale) / 200).rounded(.up) * 200
        previewTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let preview: PanoramaMergePreview?
            let failure: Error?
            do {
                preview = try await previewer.render(options: options, maxPixels: maxPixels)
                failure = nil
            } catch {
                preview = nil
                failure = error
            }
            guard let self, !Task.isCancelled else { return }
            spinner.stopAnimation(nil)
            if let preview {
                messageLabel.stringValue = ""
                previewView.photoSize = preview.photoSize
                previewView.image = NSImage(cgImage: preview.image, size: .zero)
                if previewView.isZoomed { refreshDetail(center: previewView.center, pixels: previewView.detailPixels) }
            } else if let failure, !(failure is CancellationError) {
                messageLabel.stringValue = failure.localizedDescription
            }
        }
    }

    /// Merges the part of the panorama the 100% view shows, at full resolution.
    private func refreshDetail(center: CGPoint, pixels: CGSize) {
        guard let previewer else { return }
        detailTask?.cancel()
        spinner.startAnimation(nil)
        let options = options
        detailTask = Task { [weak self] in
            let preview = try? await previewer.renderDetail(options: options, center: center, pixels: pixels)
            guard let self, !Task.isCancelled else { return }
            spinner.stopAnimation(nil)
            if let preview { previewView.showDetail(NSImage(cgImage: preview.image, size: .zero), center: center) }
        }
    }

    // MARK: - Actions

    @objc private func projectionChanged(_ sender: NSButton) {
        guard let projection = projectionButtons.first(where: { $0.1 === sender })?.0, projection != options.projection else {
            updateControls()
            return
        }
        options.projection = projection
        // A different projection is a different picture: back to the whole of it.
        previewView.zoomToFit()
        updateControls()
        refreshPreview(debounce: false)
    }

    @objc private func boundaryWarpSliderChanged(_ sender: Any?) {
        setBoundaryWarp(boundaryWarpSlider.integerValue)
    }

    @objc private func boundaryWarpFieldChanged(_ sender: Any?) {
        setBoundaryWarp(boundaryWarpField.integerValue)
    }

    private func setBoundaryWarp(_ value: Int) {
        let value = min(max(value, 0), 100)
        guard value != options.boundaryWarp else {
            updateControls()
            return
        }
        options.boundaryWarp = value
        updateControls()
        refreshPreview()
    }

    @objc private func optionChanged(_ sender: Any?) {
        let cropChanged = (autoCropCheckbox.state == .on) != options.autoCrop
        options.autoCrop = autoCropCheckbox.state == .on
        options.autoSettings = autoSettingsCheckbox.state == .on
        options.createsStack = createStackCheckbox.state == .on
        updateControls()
        // Create Stack doesn't change how the merge looks.
        guard sender as AnyObject? !== createStackCheckbox else { return }
        if cropChanged { previewView.zoomToFit() }
        refreshPreview(debounce: false)
    }

    @objc func merge(_ sender: Any?) {
        guard mergeButton.isEnabled else { return }
        previewTask?.cancel()
        detailTask?.cancel()
        onFinish?(options)
    }

    @objc func cancel(_ sender: Any?) {
        previewTask?.cancel()
        detailTask?.cancel()
        onFinish?(nil)
    }
}
