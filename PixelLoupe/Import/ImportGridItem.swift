import AppKit
import QuartzCore

/// A cell in the import window's grid: a checkbox, the photo's number (or "In Library" when the
/// catalog already has it), the photo, and its file name. Drawn with layers, like the library grid.
final class ImportGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ImportGridItem")
    static let footerHeight: CGFloat = 30
    static let headerHeight: CGFloat = 30

    /// Called when the checkbox is clicked, with whether Shift was held (to check a range).
    var onToggle: ((_ extendsRange: Bool) -> Void)?

    private var cell: ImportGridCellView { view as! ImportGridCellView }
    private var loadTask: Task<Void, Never>?
    private var representedURL: URL?

    override func loadView() {
        let cell = ImportGridCellView()
        cell.checkbox.target = self
        cell.checkbox.action = #selector(toggle(_:))
        view = cell
    }

    override var isSelected: Bool {
        didSet { cell.isSelected = isSelected }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { cell.isHighlighted = highlightState == .forSelection }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        representedURL = nil
        cell.setImage(nil, animated: false)
    }

    func configure(with file: ImportService.ScannedFile, number: Int, isChecked: Bool, isDuplicate: Bool, previews: ImportPreviewLoader) {
        let url = file.candidate.source.url
        cell.fileName.stringValue = url.lastPathComponent
        cell.placeholder.stringValue = url.pathExtension.uppercased()
        cell.info.stringValue = Self.info(for: file) ?? ""
        cell.info.isHidden = cell.info.stringValue.isEmpty
        cell.number.stringValue = "\(number)"
        cell.toolTip = isDuplicate ? "\(url.lastPathComponent) is already in this catalog" : url.path(percentEncoded: false)
        setChecked(isChecked, isDuplicate: isDuplicate)

        guard representedURL != url else { return }
        representedURL = url
        if let cached = previews.cachedImage(for: url) {
            cell.setImage(cached, animated: false)
            return
        }
        cell.setImage(nil, animated: false)
        loadTask = Task { [weak self] in
            let image = await previews.image(for: url, isVideo: file.metadata.isVideo)
            guard let self, !Task.isCancelled, representedURL == url else { return }
            cell.setImage(image, animated: true)
        }
    }

    func setChecked(_ isChecked: Bool, isDuplicate: Bool) {
        cell.checkbox.state = isChecked ? .on : .off
        cell.checkbox.isEnabled = !isDuplicate
        cell.isDuplicate = isDuplicate
        let name = cell.fileName.stringValue
        cell.checkbox.setAccessibilityLabel(isDuplicate ? "\(name), in library" : "Import \(name)")
        cell.setAccessibilityLabel(isDuplicate ? "\(name), in library" : name)
    }

    /// A movie's length, or "+ JPG" for a raw file with its JPEG.
    static func info(for file: ImportService.ScannedFile) -> String? {
        if file.metadata.isVideo {
            return file.metadata.duration > 0 ? VideoSupport.durationText(file.metadata.duration) : "Video"
        }
        let sidecars = file.candidate.source.sidecars
        return sidecars.isEmpty ? nil : "+ " + sidecars.joined(separator: " + ")
    }

    @objc private func toggle(_ sender: NSButton) {
        onToggle?(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
    }
}

final class ImportGridCellView: NSView {
    var isSelected = false { didSet { needsDisplay = true } }
    var isHighlighted = false { didSet { needsDisplay = true } }
    var isDuplicate = false {
        didSet {
            badge.isHidden = !isDuplicate
            number.isHidden = isDuplicate
            imageLayer.opacity = isDuplicate ? 0.45 : 1
            fileName.textColor = isDuplicate ? .tertiaryLabelColor : .secondaryLabelColor
        }
    }

    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let number = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "In Library")
    let fileName = NSTextField(labelWithString: "")
    let info = NSTextField(labelWithString: "")
    let placeholder = NSTextField(labelWithString: "")
    private let imageLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 8
        layer?.borderWidth = 2
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("importCell")

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
        layer?.addSublayer(imageLayer)

        number.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        number.textColor = .tertiaryLabelColor
        number.alignment = .right

        // A capsule outline, as in the mockups.
        badge.font = .systemFont(ofSize: 10, weight: .medium)
        badge.textColor = .secondaryLabelColor
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 7
        badge.layer?.borderWidth = 1
        badge.isHidden = true

        fileName.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        fileName.textColor = .secondaryLabelColor
        fileName.alignment = .center
        fileName.lineBreakMode = .byTruncatingMiddle

        info.font = .systemFont(ofSize: 10, weight: .medium)
        info.textColor = .tertiaryLabelColor

        placeholder.font = .systemFont(ofSize: 11, weight: .medium)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center

        for view in [checkbox, number, badge, fileName, info, placeholder] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            checkbox.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            number.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            number.centerYAnchor.constraint(equalTo: checkbox.centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: checkbox.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 62),
            badge.heightAnchor.constraint(equalToConstant: 15),
            info.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 4),
            info.centerYAnchor.constraint(equalTo: checkbox.centerYAnchor),
            fileName.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            fileName.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            fileName.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let selected = isSelected || isHighlighted
        let appearance = effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (selected ? GridColors.selectedCell(for: appearance) : GridColors.cell(for: appearance)).cgColor
            layer?.borderColor = selected ? Accent.color.cgColor : NSColor.clear.cgColor
            badge.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
        }
    }

    override func layout() {
        super.layout()
        let top: CGFloat = 32, side: CGFloat = 12
        imageLayer.frame = CGRect(
            x: side, y: ImportGridItem.footerHeight,
            width: max(0, bounds.width - side * 2),
            height: max(0, bounds.height - ImportGridItem.footerHeight - top)
        )
    }

    func setImage(_ image: CGImage?, animated: Bool) {
        if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.12
            imageLayer.add(fade, forKey: "contents")
        }
        imageLayer.contents = image
        placeholder.isHidden = image != nil
    }
}

/// The heading over each folder's photos when the grid shows Destination Folders.
final class ImportFolderHeaderView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("ImportFolderHeader")

    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let icon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage())

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        title.lineBreakMode = .byTruncatingHead
        count.textColor = .secondaryLabelColor
        count.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        icon.contentTintColor = .secondaryLabelColor
        for view in [icon, title, count] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            count.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            count.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Opaque, so photos scrolling under a pinned heading don't show through.
        layer?.backgroundColor = GridColors.background(for: effectiveAppearance).cgColor
    }

    func configure(title text: String, count photos: Int) {
        title.stringValue = text
        count.stringValue = photos == 1 ? "1 photo" : "\(photos) photos"
    }
}

/// One photo filling the grid's space (double-click a photo, or the loupe button), with its
/// checkbox, to look closer before importing.
final class ImportEnlargedView: NSView {
    var onToggle: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private let imageLayer = CALayer()
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let caption = NSTextField(labelWithString: "")
    private var loadTask: Task<Void, Never>?
    private var shownURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("importEnlarged")
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(imageLayer)

        checkbox.target = self
        checkbox.action = #selector(toggle(_:))
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        for view in [checkbox, caption] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            checkbox.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            caption.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            caption.centerXAnchor.constraint(equalTo: centerXAnchor),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds.insetBy(dx: 20, dy: 0)
            .divided(atDistance: 40, from: .minYEdge).remainder
            .divided(atDistance: 30, from: .maxYEdge).remainder
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
    }

    func show(_ file: ImportService.ScannedFile, number: Int, isChecked: Bool, isDuplicate: Bool, previews: ImportPreviewLoader) {
        let url = file.candidate.source.url
        setChecked(isChecked, isDuplicate: isDuplicate)
        caption.stringValue = "\(number). \(url.lastPathComponent) — \(file.captureDate.formatted(date: .abbreviated, time: .shortened))"
        setAccessibilityLabel(url.lastPathComponent)
        guard url != shownURL else { return }
        shownURL = url
        loadTask?.cancel()
        // The grid's preview at once, then a sharper one.
        imageLayer.contents = previews.cachedImage(for: url, pixelSize: ImportPreviewLoader.enlargedPixelSize)
            ?? previews.cachedImage(for: url)
        loadTask = Task { [weak self] in
            let image = await previews.image(for: url, isVideo: file.metadata.isVideo, pixelSize: ImportPreviewLoader.enlargedPixelSize)
            guard let self, !Task.isCancelled, shownURL == url, let image else { return }
            imageLayer.contents = image
        }
    }

    func setChecked(_ isChecked: Bool, isDuplicate: Bool) {
        checkbox.state = isChecked ? .on : .off
        checkbox.isEnabled = !isDuplicate
        checkbox.title = isDuplicate ? "In Library" : "Import"
    }

    func clear() {
        loadTask?.cancel()
        shownURL = nil
        imageLayer.contents = nil
    }

    @objc private func toggle(_ sender: NSButton) {
        onToggle?()
    }
}
