import AppKit

/// Photo ▸ Photo Merge ▸ HDR's sheet, laid out like Lightroom's HDR Merge Preview: the merged photo on
/// the left, updating as the options change, and the options on the right (Auto Align, Auto
/// Settings, Deghost Amount, Show Deghost Overlay, Create Stack). Merge and Cancel sit centered below.
/// Clicking the photo zooms to 100% to check the merge's detail (see ``MergePreviewView``).
final class HDRMergeSheetController: NSWindowController, NSWindowDelegate {
    /// The options to merge with, or nil for Cancel.
    var onFinish: ((HDRMergeOptions?) -> Void)?

    let sources: [PhotoMergeSource]
    private(set) var options: HDRMergeOptions

    /// The well the preview sits in: the user's matte color with a medium gray border, so the sheet keeps
    /// its layout while the first preview loads.
    let previewWell = MatteView()
    let previewView = MergePreviewView()
    let spinner = NSProgressIndicator()
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let autoAlignCheckbox = NSButton(checkboxWithTitle: "Auto Align", target: nil, action: nil)
    let autoSettingsCheckbox = NSButton(checkboxWithTitle: "Auto Settings", target: nil, action: nil)
    let deghostSlider = NSSlider()
    let overlayCheckbox = NSButton(checkboxWithTitle: "Show Deghost Overlay", target: nil, action: nil)
    let createStackCheckbox = NSButton(checkboxWithTitle: "Create Stack", target: nil, action: nil)
    let mergeButton = NSButton(title: "Merge", target: nil, action: nil)

    private var previewer: HDRMergePreviewer?
    private var previewTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    /// The size the whole-photo preview is merged at (the 100% view uses its headroom).
    private var previewPixels: CGFloat = 1400
    /// Why the photos can't be merged, once known.
    private var problem: String?

    init(sources: [PhotoMergeSource], options: HDRMergeOptions) {
        self.sources = sources
        self.options = options
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
            styleMask: [.titled, .resizable], backing: .buffered, defer: true
        )
        window.title = "HDR Merge Preview"
        window.contentMinSize = NSSize(width: 760, height: 480)
        window.setAccessibilityIdentifier("hdrMergeSheet")
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
        messageLabel.setAccessibilityIdentifier("hdrMergeMessage")

        let left = NSStackView(views: [previewWell, messageLabel])
        left.orientation = .vertical
        left.alignment = .centerX
        left.spacing = 8
        left.distribution = .fill
        left.setHuggingPriority(.defaultLow, for: .horizontal)
        messageLabel.setContentHuggingPriority(.required, for: .vertical)
        previewWell.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        messageLabel.widthAnchor.constraint(lessThanOrEqualTo: left.widthAnchor).isActive = true

        for checkbox in [autoAlignCheckbox, autoSettingsCheckbox, overlayCheckbox, createStackCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(optionChanged(_:))
        }
        autoAlignCheckbox.toolTip = "Lines the photos up, for brackets shot without a tripod."
        autoSettingsCheckbox.toolTip = "Starts the merged photo with automatic light and white balance."
        overlayCheckbox.toolTip = "Outlines in red where Deghost uses one photo alone."
        createStackCheckbox.toolTip = "Stacks the merged photo on top of the photos it was made from."

        deghostSlider.minValue = 0
        deghostSlider.maxValue = Double(HDRMergeOptions.Deghost.allCases.count - 1)
        deghostSlider.numberOfTickMarks = HDRMergeOptions.Deghost.allCases.count
        deghostSlider.allowsTickMarkValuesOnly = true
        deghostSlider.tickMarkPosition = .below
        deghostSlider.target = self
        deghostSlider.action = #selector(optionChanged(_:))
        deghostSlider.setAccessibilityLabel("Deghost Amount")
        deghostSlider.toolTip = "Removes things that moved between the photos. Higher finds smaller movements."

        let tickLabels = NSStackView(views: HDRMergeOptions.Deghost.allCases.map { amount in
            let label = NSTextField(labelWithString: amount.title)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            return label
        })
        tickLabels.distribution = .equalSpacing

        let heading = NSTextField(labelWithString: "HDR Options")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let deghostLabel = NSTextField(labelWithString: "Deghost Amount")
        let separator = NSBox()
        separator.boxType = .separator

        let options = NSStackView(views: [
            heading, autoAlignCheckbox, autoSettingsCheckbox, deghostLabel, deghostSlider, tickLabels,
            overlayCheckbox, separator, createStackCheckbox,
        ])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 10
        options.setCustomSpacing(16, after: autoSettingsCheckbox)
        options.setCustomSpacing(2, after: deghostSlider)
        options.setCustomSpacing(16, after: tickLabels)
        for view in [deghostSlider, tickLabels, separator] {
            view.widthAnchor.constraint(equalTo: options.widthAnchor).isActive = true
        }
        options.widthAnchor.constraint(equalToConstant: 220).isActive = true
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
        mergeButton.setAccessibilityIdentifier("hdrMergeButton")
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
        autoAlignCheckbox.state = options.autoAlign ? .on : .off
        autoSettingsCheckbox.state = options.autoSettings ? .on : .off
        deghostSlider.integerValue = options.deghost.rawValue
        overlayCheckbox.state = options.showsDeghostOverlay ? .on : .off
        createStackCheckbox.state = options.createsStack ? .on : .off
        for control in [autoAlignCheckbox, autoSettingsCheckbox, deghostSlider, createStackCheckbox] as [NSControl] {
            control.isEnabled = enabled
        }
        // Nothing to outline until Deghost is on.
        overlayCheckbox.isEnabled = enabled && options.deghost != .none
        mergeButton.isEnabled = enabled
    }

    // MARK: - Preview

    /// Reads the photos (off the main thread), then draws the first preview.
    private func prepare() {
        spinner.startAnimation(nil)
        let sources = sources
        previewTask = Task { [weak self] in
            let result: Result<HDRMergePreviewer, Error>
            do { result = .success(try await Self.makePreviewer(sources)) } catch { result = .failure(error) }
            guard let self else { return }
            switch result {
            case .success(let previewer):
                self.previewer = previewer
                previewView.photoSize = previewer.photoSize
                messageLabel.stringValue = previewer.warning ?? ""
                updateControls()
                refreshPreview(debounce: false)
            case .failure(let error):
                spinner.stopAnimation(nil)
                problem = error.localizedDescription
                messageLabel.stringValue = error.localizedDescription
                updateControls()
            }
        }
    }

    @concurrent
    private nonisolated static func makePreviewer(_ sources: [PhotoMergeSource]) async throws -> HDRMergePreviewer {
        try HDRMergePreviewer(sources: sources)
    }

    /// Redraws the preview with the current options, after a moment so dragging the slider doesn't
    /// queue up merges.
    private func refreshPreview(debounce: Bool = true) {
        guard let previewer else { return }
        previewTask?.cancel()
        spinner.startAnimation(nil)
        let options = options
        let scale = window?.backingScaleFactor ?? 2
        // Rounded so small resizes reuse the merge.
        let maxPixels = (min(2400, max(previewView.bounds.width, previewView.bounds.height, 700) * scale) / 200).rounded(.up) * 200
        previewPixels = maxPixels
        previewTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let preview: HDRMergePreview?
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
                previewView.image = NSImage(cgImage: preview.image, size: .zero)
                if previewView.isZoomed { refreshDetail(center: previewView.center, pixels: previewView.detailPixels) }
            } else if let failure, !(failure is CancellationError) {
                messageLabel.stringValue = failure.localizedDescription
            }
        }
    }

    /// Merges the part of the photo the 100% view shows, at full resolution.
    private func refreshDetail(center: CGPoint, pixels: CGSize) {
        guard let previewer else { return }
        detailTask?.cancel()
        spinner.startAnimation(nil)
        let options = options, maxPixels = previewPixels
        detailTask = Task { [weak self] in
            let preview = try? await previewer.renderDetail(options: options, center: center, pixels: pixels, maxPixels: maxPixels)
            guard let self, !Task.isCancelled else { return }
            spinner.stopAnimation(nil)
            if let preview { previewView.showDetail(NSImage(cgImage: preview.image, size: .zero), center: center) }
        }
    }

    // MARK: - Actions

    @objc private func optionChanged(_ sender: Any?) {
        options.autoAlign = autoAlignCheckbox.state == .on
        options.autoSettings = autoSettingsCheckbox.state == .on
        options.deghost = HDRMergeOptions.Deghost(rawValue: deghostSlider.integerValue) ?? .none
        options.showsDeghostOverlay = overlayCheckbox.state == .on
        options.createsStack = createStackCheckbox.state == .on
        updateControls()
        // Create Stack doesn't change how the merge looks.
        if sender as AnyObject? !== createStackCheckbox { refreshPreview() }
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
