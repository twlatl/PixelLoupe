import AppKit

/// Photo ▸ Photo Merge ▸ Focus Stack's sheet, laid out like the other merges': the stacked photo on the
/// left, updating as the settings change, and on the right the source photos (each with a checkbox to
/// leave it out), the rendering method with its Radius and Smoothing, Create Stack and Reset. Merge and
/// Cancel sit centered below.
///
/// Under the preview, Original / Rendered / Depth Map chooses what it shows: the photo selected in the
/// list, the stack, or which frame is sharpest where. Clicking a photo in the list shows it. While the
/// stack is worked out with the Depth Map method, its depth map is shown building, a frame at a time.
/// Clicking the stack zooms to 100% to check its detail (see ``MergePreviewView``).
final class FocusStackSheetController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// What the preview shows.
    enum Showing: Int {
        case original, rendered, depthMap
    }

    /// The settings to stack with and the photos to leave out, or nil for Cancel.
    var onFinish: (((options: FocusStackOptions, excluding: Set<URL>)?) -> Void)?

    /// The photos, in the order they were taken once they've been read (the list's order).
    private(set) var sources: [PhotoMergeSource]
    private(set) var options: FocusStackOptions
    /// The photos unchecked in the list.
    private(set) var excluded: Set<URL> = []
    /// The photos that don't line up with the others, once known.
    private(set) var skipped: Set<URL> = []
    private(set) var showing = Showing.rendered

    let previewWell = MatteView()
    let previewView = MergePreviewView()
    let spinner = NSProgressIndicator()
    let showingControl = NSSegmentedControl(
        labels: ["Original", "Rendered", "Depth Map"], trackingMode: .selectOne, target: nil, action: nil
    )
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let sourcesHeading = NSTextField(labelWithString: "Source Photos")
    let tableView = NSTableView()
    let methodButtons = FocusStackOptions.Method.allCases.map { NSButton(radioButtonWithTitle: $0.title, target: nil, action: nil) }
    let radiusSlider = MonochromeSlider()
    let radiusField = NSTextField()
    let smoothingSlider = MonochromeSlider()
    let smoothingField = NSTextField()
    let createStackCheckbox = NSButton(checkboxWithTitle: "Create Stack", target: nil, action: nil)
    let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    let mergeButton = NSButton(title: "Merge", target: nil, action: nil)

    private var previewer: FocusStackPreviewer?
    private var previewTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var originalTask: Task<Void, Never>?
    private var previewPixels: CGFloat = 1400
    private var rendered: FocusStackPreview?
    private var original: (url: URL, image: NSImage)?
    private var thumbnails: [URL: NSImage] = [:]
    /// Why the photos can't be stacked, once known.
    private var problem: String?
    private var isAligned = false
    /// Whether a stack is being worked out for the preview.
    private var isRendering = false

    init(sources: [PhotoMergeSource], options: FocusStackOptions) {
        self.sources = FocusStackMerger.ordered(sources)
        self.options = options
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
            styleMask: [.titled, .resizable], backing: .buffered, defer: true
        )
        window.title = "Focus Stack Preview"
        window.contentMinSize = NSSize(width: 860, height: 560)
        window.setAccessibilityIdentifier("focusStackSheet")
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
        originalTask?.cancel()
    }

    /// Whether the stack has been drawn with the current settings.
    var hasRenderedPreview: Bool { rendered != nil && !isRendering }

    /// The photos that would go into the stack: checked, and lined up.
    var stackedCount: Int {
        sources.count { !excluded.contains($0.url) && !skipped.contains($0.url) }
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
        previewView.setAccessibilityLabel("Focus stack preview")

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

        showingControl.target = self
        showingControl.action = #selector(showingChanged(_:))
        showingControl.setAccessibilityLabel("Preview shows")
        showingControl.setAccessibilityIdentifier("focusStackShowing")
        showingControl.setToolTip("The photo selected in the list", forSegment: Showing.original.rawValue)
        showingControl.setToolTip("The stacked photo", forSegment: Showing.rendered.rawValue)
        showingControl.setToolTip("Which photo is sharpest where: the first black, the last white", forSegment: Showing.depthMap.rawValue)

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.setAccessibilityIdentifier("focusStackMessage")

        let left = NSStackView(views: [previewWell, showingControl, messageLabel])
        left.orientation = .vertical
        left.alignment = .centerX
        left.spacing = 8
        left.distribution = .fill
        left.setHuggingPriority(.defaultLow, for: .horizontal)
        showingControl.setContentHuggingPriority(.required, for: .vertical)
        messageLabel.setContentHuggingPriority(.required, for: .vertical)
        previewWell.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        messageLabel.widthAnchor.constraint(lessThanOrEqualTo: left.widthAnchor).isActive = true

        // The source photos.
        sourcesHeading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("photo"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 40
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("Source photos")
        tableView.setAccessibilityIdentifier("focusStackSources")
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        // The method and its sliders.
        let methodLabel = NSTextField(labelWithString: "Rendering Method")
        methodLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        for (button, method) in zip(methodButtons, FocusStackOptions.Method.allCases) {
            button.target = self
            button.action = #selector(methodChanged(_:))
            button.tag = method.rawValue
        }
        methodButtons[FocusStackOptions.Method.weightedAverage.rawValue].toolTip
            = "Averages the photos by how sharp each is at every point. Natural color and contrast, best on short stacks."
        methodButtons[FocusStackOptions.Method.depthMap.rawValue].toolTip
            = "Takes every point from the photo where it's sharpest. The best choice for most stacks."
        methodButtons[FocusStackOptions.Method.pyramid.rawValue].toolTip
            = "Puts fine and coarse detail together separately. For deep stacks and overlapping detail such as hairs."

        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 0
        func configure(_ slider: MonochromeSlider, _ field: NSTextField, range: ClosedRange<Int>, label: String, help: String) -> NSView {
            slider.minValue = Double(range.lowerBound)
            slider.maxValue = Double(range.upperBound)
            slider.numberOfTickMarks = 0
            slider.target = self
            slider.action = #selector(sliderChanged(_:))
            slider.setAccessibilityLabel(label)
            slider.toolTip = help
            field.formatter = formatter
            field.alignment = .right
            field.target = self
            field.action = #selector(fieldChanged(_:))
            field.setAccessibilityLabel(label)
            field.widthAnchor.constraint(equalToConstant: 44).isActive = true
            let row = NSStackView(views: [slider, field])
            row.spacing = 8
            return row
        }
        let radiusLabel = NSTextField(labelWithString: "Radius")
        let radiusRow = configure(
            radiusSlider, radiusField, range: FocusStackOptions.radiusRange, label: "Radius",
            help: "The area around each point its sharpness is judged over. Smaller keeps fine texture; larger reduces halos around strong edges."
        )
        let smoothingLabel = NSTextField(labelWithString: "Smoothing")
        let smoothingRow = configure(
            smoothingSlider, smoothingField, range: FocusStackOptions.smoothingRange, label: "Smoothing",
            help: "How softly the sharp areas of different photos run into each other. Higher hides seams; lower keeps the most crispness."
        )

        createStackCheckbox.target = self
        createStackCheckbox.action = #selector(createStackChanged(_:))
        createStackCheckbox.toolTip = "Stacks the result on top of the photos it was made from."
        resetButton.target = self
        resetButton.action = #selector(reset(_:))
        resetButton.toolTip = "Sets the method, Radius and Smoothing back to their defaults."
        resetButton.setAccessibilityIdentifier("focusStackReset")

        let separators = (0..<2).map { _ -> NSBox in
            let box = NSBox()
            box.boxType = .separator
            return box
        }
        let options = NSStackView(views: [sourcesHeading, scrollView, separators[0], methodLabel] + methodButtons + [
            radiusLabel, radiusRow, smoothingLabel, smoothingRow, separators[1], createStackCheckbox, resetButton,
        ])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 8
        options.setCustomSpacing(12, after: scrollView)
        options.setCustomSpacing(12, after: methodButtons[methodButtons.count - 1])
        options.setCustomSpacing(4, after: radiusLabel)
        options.setCustomSpacing(4, after: smoothingLabel)
        options.setCustomSpacing(12, after: smoothingRow)
        for view in [scrollView, radiusRow, smoothingRow] + separators as [NSView] {
            view.widthAnchor.constraint(equalTo: options.widthAnchor).isActive = true
        }
        options.widthAnchor.constraint(equalToConstant: 280).isActive = true
        options.setHuggingPriority(.required, for: .horizontal)

        let body = NSStackView(views: [left, options])
        body.orientation = .horizontal
        body.alignment = .top
        body.distribution = .fill
        body.spacing = 20
        left.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        options.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        mergeButton.target = self
        mergeButton.action = #selector(merge(_:))
        mergeButton.keyEquivalent = "\r"
        mergeButton.setAccessibilityIdentifier("focusStackMergeButton")
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
        let ready = problem == nil && isAligned
        sourcesHeading.stringValue = "Source Photos (\(sources.count))"
        for (button, method) in zip(methodButtons, FocusStackOptions.Method.allCases) {
            button.state = options.method == method ? .on : .off
            button.isEnabled = ready
        }
        // Pyramid has no Radius or Smoothing: they keep their values, grayed out.
        let hasSliders = options.method != .pyramid
        radiusSlider.integerValue = options.radius
        radiusField.integerValue = options.radius
        smoothingSlider.integerValue = options.smoothing
        smoothingField.integerValue = options.smoothing
        for control in [radiusSlider, radiusField, smoothingSlider, smoothingField] as [NSControl] {
            control.isEnabled = ready && hasSliders
        }
        createStackCheckbox.state = options.createsStack ? .on : .off
        createStackCheckbox.isEnabled = ready
        resetButton.isEnabled = ready
        tableView.isEnabled = ready

        showingControl.selectedSegment = showing.rawValue
        showingControl.setEnabled(ready && tableView.selectedRow >= 0, forSegment: Showing.original.rawValue)
        showingControl.setEnabled(ready, forSegment: Showing.rendered.rawValue)
        // Only the Depth Map method has a depth map.
        showingControl.setEnabled(ready && options.method == .depthMap, forSegment: Showing.depthMap.rawValue)

        mergeButton.isEnabled = ready && stackedCount >= 2
        updateMessage()
    }

    private func updateMessage() {
        if let problem {
            messageLabel.stringValue = problem
        } else if !isAligned {
            // Set as the photos are lined up.
        } else if stackedCount < 2 {
            messageLabel.stringValue = "Check at least two photos to stack."
        } else if !skipped.isEmpty {
            let checked = sources.count { !excluded.contains($0.url) }
            messageLabel.stringValue = "\(stackedCount) of \(checked) photos merged. The others don’t line up with them."
        } else {
            messageLabel.stringValue = ""
        }
    }

    // MARK: - Source photos

    func numberOfRows(in tableView: NSTableView) -> Int { sources.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("FocusStackSourceCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? FocusStackSourceCell ?? {
            let cell = FocusStackSourceCell()
            cell.identifier = identifier
            return cell
        }()
        let source = sources[row]
        let isSkipped = skipped.contains(source.url)
        cell.checkbox.state = excluded.contains(source.url) || isSkipped ? .off : .on
        cell.checkbox.isEnabled = !isSkipped && tableView.isEnabled
        cell.checkbox.tag = row
        cell.checkbox.target = self
        cell.checkbox.action = #selector(sourceToggled(_:))
        cell.checkbox.setAccessibilityLabel("Include \(source.name)")
        cell.nameLabel.stringValue = source.name
        cell.nameLabel.textColor = isSkipped ? .tertiaryLabelColor : .labelColor
        cell.noteLabel.stringValue = isSkipped ? "Doesn’t line up" : ""
        cell.noteLabel.isHidden = !isSkipped
        cell.thumbnail.image = thumbnails[source.url]
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Clicking a photo shows it; with nothing selected there's no Original to show.
        if tableView.selectedRow >= 0 {
            showing = .original
        } else if showing == .original {
            showing = .rendered
        }
        updateControls()
        show()
    }

    @objc private func sourceToggled(_ sender: NSButton) {
        guard sources.indices.contains(sender.tag) else { return }
        let url = sources[sender.tag].url
        if sender.state == .on { excluded.remove(url) } else { excluded.insert(url) }
        updateControls()
        refreshPreview()
    }

    /// Small pictures for the list, read off the main thread.
    private func loadThumbnails() {
        let urls = sources.map(\.url)
        Task { [weak self] in
            for (row, url) in urls.enumerated() {
                guard let image = await Self.thumbnail(url) else { continue }
                guard let self else { return }
                thumbnails[url] = NSImage(cgImage: image, size: .zero)
                tableView.reloadData(forRowIndexes: [row], columnIndexes: [0])
            }
        }
    }

    @concurrent
    private nonisolated static func thumbnail(_ url: URL) async -> CGImage? {
        guard let file = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 120,
        ]
        return CGImageSourceCreateThumbnailAtIndex(file, 0, options as CFDictionary)
    }

    // MARK: - Preview

    /// Reads the photos and lines them up (off the main thread), then draws the first preview.
    private func prepare() {
        spinner.startAnimation(nil)
        messageLabel.stringValue = "Reading the photos…"
        loadThumbnails()
        let sources = sources
        previewTask = Task { [weak self] in
            let result: Result<(FocusStackPreviewer, [URL]), Error>
            do {
                let previewer = try await Self.makePreviewer(sources)
                let count = sources.count
                let skipped = try await previewer.align { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, !self.isAligned else { return }
                        self.messageLabel.stringValue = "Lining up the photos… \(min(count, Int(fraction * Double(count)) + 1)) of \(count)"
                    }
                }
                result = .success((previewer, skipped))
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let (previewer, skipped)):
                self.previewer = previewer
                self.skipped = Set(skipped)
                self.sources = previewer.sources
                previewView.photoSize = previewer.photoSize
                isAligned = true
                tableView.reloadData()
                updateControls()
                refreshPreview(debounce: false)
            case .failure(let error):
                spinner.stopAnimation(nil)
                problem = error.localizedDescription
                updateControls()
            }
        }
    }

    @concurrent
    private nonisolated static func makePreviewer(_ sources: [PhotoMergeSource]) async throws -> FocusStackPreviewer {
        try FocusStackPreviewer(sources: sources)
    }

    /// Puts what `showing` asks for in the preview.
    private func show() {
        switch showing {
        case .rendered:
            if let rendered { setPreview(NSImage(cgImage: rendered.image, size: .zero)) }
        case .depthMap:
            if let map = rendered?.depthMap { setPreview(NSImage(cgImage: map, size: .zero)) }
        case .original:
            showOriginal()
        }
    }

    private func setPreview(_ image: NSImage) {
        if previewView.isZoomed, showing != .rendered { previewView.zoomToFit() }
        previewView.image = image
    }

    private func showOriginal() {
        guard let previewer, sources.indices.contains(tableView.selectedRow) else { return }
        let url = sources[tableView.selectedRow].url
        if let original, original.url == url {
            setPreview(original.image)
            return
        }
        originalTask?.cancel()
        let maxPixels = previewPixels
        originalTask = Task { [weak self] in
            let image = await Self.original(url, previewer: previewer, maxPixels: maxPixels)
            guard let self, !Task.isCancelled, let image else { return }
            original = (url, NSImage(cgImage: image, size: .zero))
            if showing == .original, sources.indices.contains(tableView.selectedRow), sources[tableView.selectedRow].url == url {
                setPreview(NSImage(cgImage: image, size: .zero))
            }
        }
    }

    @concurrent
    private nonisolated static func original(_ url: URL, previewer: FocusStackPreviewer, maxPixels: CGFloat) async -> CGImage? {
        previewer.original(url, maxPixels: maxPixels)
    }

    /// Redraws the stack with the current settings, after a moment so dragging a slider doesn't queue
    /// up stacks.
    private func refreshPreview(debounce: Bool = true) {
        guard let previewer, isAligned else { return }
        previewTask?.cancel()
        detailTask?.cancel()
        guard stackedCount >= 2 else {
            spinner.stopAnimation(nil)
            isRendering = false
            rendered = nil
            if showing != .original { previewView.image = nil }
            return
        }
        spinner.startAnimation(nil)
        isRendering = true
        let options = options, excluded = excluded
        let scale = window?.backingScaleFactor ?? 2
        // Rounded so small resizes reuse the stack.
        let maxPixels = (min(2400, max(previewView.bounds.width, previewView.bounds.height, 700) * scale) / 200).rounded(.up) * 200
        previewPixels = maxPixels
        previewTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let preview: FocusStackPreview?
            let failure: Error?
            do {
                preview = try await previewer.render(options: options, excluding: excluded, maxPixels: maxPixels) { [weak self] depth in
                    // The depth map as it builds, in place of the stack that isn't there yet.
                    let depth = FocusStackPreviewer.Picture(depth)
                    Task { @MainActor [weak self] in
                        guard let self, isRendering, showing != .original, self.options == options, self.excluded == excluded else { return }
                        previewView.image = NSImage(cgImage: depth.image, size: .zero)
                    }
                }
                failure = nil
            } catch {
                preview = nil
                failure = error
            }
            guard let self, !Task.isCancelled else { return }
            spinner.stopAnimation(nil)
            isRendering = false
            if let preview {
                rendered = preview
                show()
                if showing == .rendered, previewView.isZoomed {
                    refreshDetail(center: previewView.center, pixels: previewView.detailPixels)
                }
            } else if let failure, !(failure is CancellationError) {
                messageLabel.stringValue = failure.localizedDescription
            }
        }
    }

    /// Stacks the part of the photo the 100% view shows, at full resolution.
    private func refreshDetail(center: CGPoint, pixels: CGSize) {
        guard let previewer, showing == .rendered, rendered != nil else { return }
        detailTask?.cancel()
        spinner.startAnimation(nil)
        let options = options, excluded = excluded, maxPixels = previewPixels
        detailTask = Task { [weak self] in
            let image = try? await previewer.renderDetail(
                options: options, excluding: excluded, center: center, pixels: pixels, maxPixels: maxPixels
            )
            guard let self, !Task.isCancelled else { return }
            spinner.stopAnimation(nil)
            if let image, showing == .rendered { previewView.showDetail(NSImage(cgImage: image, size: .zero), center: center) }
        }
    }

    // MARK: - Actions

    @objc private func showingChanged(_ sender: Any?) {
        showing = Showing(rawValue: showingControl.selectedSegment) ?? .rendered
        updateControls()
        show()
    }

    @objc private func methodChanged(_ sender: NSButton) {
        guard let method = FocusStackOptions.Method(rawValue: sender.tag) else { return }
        options.method = method
        if showing == .depthMap, method != .depthMap { showing = .rendered }
        updateControls()
        refreshPreview()
    }

    @objc private func sliderChanged(_ sender: Any?) {
        options.radius = radiusSlider.integerValue
        options.smoothing = smoothingSlider.integerValue
        updateControls()
        refreshPreview()
    }

    @objc private func fieldChanged(_ sender: Any?) {
        let radius = FocusStackOptions.radiusRange, smoothing = FocusStackOptions.smoothingRange
        options.radius = min(max(radiusField.integerValue, radius.lowerBound), radius.upperBound)
        options.smoothing = min(max(smoothingField.integerValue, smoothing.lowerBound), smoothing.upperBound)
        updateControls()
        refreshPreview()
    }

    @objc private func createStackChanged(_ sender: Any?) {
        // Create Stack doesn't change how the stack looks.
        options.createsStack = createStackCheckbox.state == .on
    }

    @objc func reset(_ sender: Any?) {
        options.resetRendering()
        updateControls()
        refreshPreview()
    }

    @objc func merge(_ sender: Any?) {
        guard mergeButton.isEnabled else { return }
        window?.makeFirstResponder(nil)
        previewTask?.cancel()
        detailTask?.cancel()
        onFinish?((options, excluded))
    }

    @objc func cancel(_ sender: Any?) {
        previewTask?.cancel()
        detailTask?.cancel()
        onFinish?(nil)
    }
}

/// A row of the focus stack sheet's source list: a checkbox, a small picture and the file's name.
final class FocusStackSourceCell: NSTableCellView {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let thumbnail = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    let noteLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.setAccessibilityElement(false)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.textColor = .secondaryLabelColor
        let names = NSStackView(views: [nameLabel, noteLabel])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 1
        let row = NSStackView(views: [checkbox, thumbnail, names])
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            thumbnail.widthAnchor.constraint(equalToConstant: 48),
            thumbnail.heightAnchor.constraint(equalToConstant: 32),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = nameLabel
        imageView = thumbnail
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
