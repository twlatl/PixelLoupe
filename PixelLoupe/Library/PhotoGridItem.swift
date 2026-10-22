import AppKit
import CoreData
import QuartzCore

/// A grid cell. Drawing is done entirely with Core Animation layers (composited by the GPU via
/// Metal) so scrolling and resizing never redraw thumbnails on the CPU.
final class PhotoGridItem: NSCollectionViewItem {
    /// The pill at the bottom right: a video's length, or "CR3 + JPG" for a raw file with its JPEG.
    static func infoBadge(for photo: Photo) -> PhotoGridCellView.InfoBadge? {
        if photo.isVideo {
            return .init(text: photo.duration > 0 ? VideoSupport.durationText(photo.duration) : "Video", symbol: "video.fill")
        }
        let sidecars = photo.imageSidecars
        guard !sidecars.isEmpty else { return nil }
        return .init(text: ([photo.fileType.uppercased()] + sidecars).joined(separator: " + "), symbol: nil)
    }

    /// What the cell shows about a photo's stack: its size, and whether the stack is collapsed.
    static func stackInfo(for photo: Photo) -> PhotoGridCellView.StackInfo? {
        guard let stack = photo.stack else { return nil }
        return .init(count: stack.photos.count, isCollapsed: stack.isCollapsed, isTop: photo.stackPosition == 1)
    }

    static let identifier = NSUserInterfaceItemIdentifier("PhotoGridItem")
    static let footerHeight: CGFloat = 20

    private var cellView: PhotoGridCellView { view as! PhotoGridCellView }
    private var representedPhotoID: UUID?
    private var loadTask: Task<Void, Never>?

    override func loadView() {
        view = PhotoGridCellView()
    }

    override var isSelected: Bool {
        didSet { cellView.isSelected = isSelected }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { cellView.isHighlighted = highlightState == .forSelection }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        representedPhotoID = nil
        cellView.setImage(nil, animated: false)
    }

    func configure(with photo: Photo, thumbnails: ThumbnailStore, isMissing: Bool = false, reloadThumbnail: Bool = false) {
        cellView.update(rating: Int(photo.rating), flag: photo.photoFlag, fileType: photo.fileType)
        cellView.setMissing(isMissing)
        cellView.setColorLabel(photo.label)
        cellView.photoObjectID = photo.objectID
        cellView.setInfoBadge(Self.infoBadge(for: photo))
        cellView.setStack(Self.stackInfo(for: photo))
        cellView.setCopy(name: photo.isVirtualCopy ? (photo.copyName ?? "Copy") : nil, fileName: photo.fileName)

        let id = photo.id
        guard id != representedPhotoID || reloadThumbnail else { return }
        representedPhotoID = id
        loadTask?.cancel()

        if let cached = thumbnails.cachedImage(for: id) {
            cellView.setImage(cached, animated: false)
            return
        }
        if !reloadThumbnail { cellView.setImage(nil, animated: false) }
        loadTask = Task { [weak self] in
            let image = await thumbnails.image(for: id)
            guard let self, !Task.isCancelled, representedPhotoID == id else { return }
            cellView.setImage(image, animated: true)
        }
    }
}

final class PhotoGridCellView: NSView {
    /// The photo shown, for the stack badge's click.
    var photoObjectID: NSManagedObjectID?

    /// The cell `view` is in (or is).
    static func enclosing(_ view: NSView?) -> PhotoGridCellView? {
        guard let view else { return nil }
        return sequence(first: view, next: \.superview).lazy.compactMap { $0 as? PhotoGridCellView }.first
    }

    var isSelected = false { didSet { updateAppearance() } }
    var isHighlighted = false { didSet { updateAppearance() } }

    private let imageLayer = CALayer()
    private let placeholder = NSTextField(labelWithString: "")
    private let ratingLabel = NSTextField(labelWithString: "")
    private let flagView = NSImageView()
    private let missingBadge = NSImageView()
    private let copyBadge = NSImageView()
    /// A stack's size on its top photo; clicking it sends `toggleStackFromBadge(_:)` up the responder chain.
    let stackBadge = NSButton()
    private let infoBadge = NSButton()
    private var infoValue: InfoBadge?
    private var stackInfo: StackInfo?
    private let copyLabel = NSTextField(labelWithString: "")
    private var isRejected = false
    private var isMissing = false
    private var colorLabel = ColorLabel.none
    private var ratingDescription = "Unrated"
    private var flagDescription: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.cornerRadius = 4
        layer?.borderWidth = 2
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("photoCell")

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(imageLayer)

        placeholder.font = .systemFont(ofSize: 11, weight: .medium)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center

        ratingLabel.font = .systemFont(ofSize: 10)
        ratingLabel.textColor = .secondaryLabelColor
        ratingLabel.lineBreakMode = .byClipping

        flagView.imageScaling = .scaleProportionallyDown

        // Shown when the photo's file can't be found (offline drive or moved folder).
        missingBadge.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Missing")
        missingBadge.contentTintColor = .systemYellow
        missingBadge.imageScaling = .scaleProportionallyDown
        missingBadge.toolTip = "The file can’t be found"
        missingBadge.isHidden = true
        missingBadge.setAccessibilityElement(false)

        // Virtual copies show a badge and their name.
        copyBadge.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Virtual copy")
        copyBadge.contentTintColor = .secondaryLabelColor
        copyBadge.imageScaling = .scaleProportionallyDown
        copyBadge.isHidden = true
        copyBadge.setAccessibilityElement(false)
        copyLabel.font = .systemFont(ofSize: 9)
        copyLabel.textColor = .secondaryLabelColor
        copyLabel.lineBreakMode = .byTruncatingTail
        copyLabel.isHidden = true

        // A stack's size at the bottom left of its top photo; clicking it collapses or expands the stack.
        stackBadge.bezelStyle = .inline
        stackBadge.isBordered = false
        stackBadge.wantsLayer = true
        stackBadge.layer?.cornerRadius = 8
        stackBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        stackBadge.font = .systemFont(ofSize: 10, weight: .semibold)
        stackBadge.contentTintColor = .white
        stackBadge.imagePosition = .imageLeading
        stackBadge.target = nil
        stackBadge.action = #selector(PixelLoupeActions.toggleStackFromBadge(_:))
        stackBadge.isHidden = true

        // A video's length, or a raw+JPEG pair's types, bottom right of the picture.
        infoBadge.isBordered = false
        infoBadge.isEnabled = false
        infoBadge.wantsLayer = true
        infoBadge.layer?.cornerRadius = 7
        infoBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        infoBadge.font = .systemFont(ofSize: 9, weight: .semibold)
        infoBadge.contentTintColor = .white
        infoBadge.imagePosition = .imageLeading
        infoBadge.isHidden = true
        infoBadge.setAccessibilityElement(false)

        for view in [placeholder, ratingLabel, flagView, missingBadge, copyBadge, copyLabel, stackBadge, infoBadge] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -PhotoGridItem.footerHeight / 2),
            ratingLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            ratingLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            ratingLabel.trailingAnchor.constraint(lessThanOrEqualTo: flagView.leadingAnchor, constant: -4),
            flagView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            flagView.centerYAnchor.constraint(equalTo: ratingLabel.centerYAnchor),
            flagView.widthAnchor.constraint(equalToConstant: 12),
            flagView.heightAnchor.constraint(equalToConstant: 12),
            missingBadge.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            missingBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            infoBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            infoBadge.bottomAnchor.constraint(equalTo: ratingLabel.topAnchor, constant: -4),
            infoBadge.heightAnchor.constraint(equalToConstant: 14),
            stackBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stackBadge.bottomAnchor.constraint(equalTo: ratingLabel.topAnchor, constant: -4),
            stackBadge.heightAnchor.constraint(equalToConstant: 16),
            copyBadge.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            copyBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            copyBadge.widthAnchor.constraint(equalToConstant: 14),
            copyBadge.heightAnchor.constraint(equalToConstant: 14),
            copyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            copyLabel.centerYAnchor.constraint(equalTo: ratingLabel.centerYAnchor),
            copyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: ratingLabel.trailingAnchor, constant: 4),
            copyLabel.trailingAnchor.constraint(lessThanOrEqualTo: flagView.leadingAnchor, constant: -4),
            missingBadge.widthAnchor.constraint(equalToConstant: 16),
            missingBadge.heightAnchor.constraint(equalToConstant: 16),
        ])
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        updateAppearance()
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 6
        imageLayer.frame = CGRect(
            x: inset,
            y: PhotoGridItem.footerHeight,
            width: max(0, bounds.width - inset * 2),
            height: max(0, bounds.height - PhotoGridItem.footerHeight - inset)
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

    /// Tints the cell in the photo's color label, as Lightroom does.
    func setColorLabel(_ label: ColorLabel) {
        guard label != colorLabel else { return }
        colorLabel = label
        updateAccessibilityValue()
        updateAppearance()
    }

    /// Marks a virtual copy: a badge, its name in the footer, and a tooltip.
    func setCopy(name: String?, fileName: String) {
        copyBadge.isHidden = name == nil
        copyLabel.isHidden = name == nil
        copyLabel.stringValue = name ?? ""
        toolTip = name.map { "\(fileName) — \($0) (virtual copy)" } ?? fileName
        copyName = name
        setAccessibilityLabel(name.map { "\(fileName), \($0)" } ?? fileName)
    }

    private var copyName: String?

    private func updateAccessibilityValue() {
        setAccessibilityValue([
            ratingDescription, flagDescription, colorLabel == .none ? nil : "\(colorLabel.title) label", copyName.map { "Virtual copy \($0)" }, infoValue.map { $0.symbol != nil ? "Video, \($0.text)" : $0.text }, stackInfo.map { $0.isTop ? "Top of a stack of \($0.count)" : "In a stack" },
        ].compactMap { $0 }.joined(separator: ", "))
    }

    struct InfoBadge: Equatable {
        var text: String
        var symbol: String?
    }

    func setInfoBadge(_ badge: InfoBadge?) {
        guard badge != infoValue else { return }
        infoValue = badge
        infoBadge.isHidden = badge == nil
        guard let badge else { return }
        infoBadge.title = badge.symbol == nil ? badge.text : " " + badge.text
        infoBadge.image = badge.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        infoBadge.toolTip = badge.symbol == nil ? "A RAW file and its JPEG, as one photo" : "Video"
        updateAccessibilityValue()
    }

    struct StackInfo: Equatable {
        var count: Int
        var isCollapsed: Bool
        var isTop: Bool
    }

    /// Shows a stack's count on its top photo, and tints the members of an open stack.
    func setStack(_ info: StackInfo?) {
        guard info != stackInfo else { return }
        stackInfo = info
        stackBadge.isHidden = info?.isTop != true
        if let info, info.isTop {
            stackBadge.title = " \(info.count)"
            stackBadge.image = NSImage(systemSymbolName: info.isCollapsed ? "square.stack.3d.up.fill" : "square.stack.3d.up", accessibilityDescription: nil)
            stackBadge.toolTip = info.isCollapsed ? "Stack of \(info.count) photos. Click to expand" : "Stack of \(info.count) photos. Click to collapse"
            stackBadge.setAccessibilityLabel(info.isCollapsed ? "Expand stack of \(info.count) photos" : "Collapse stack of \(info.count) photos")
        }
        updateAccessibilityValue()
        updateAppearance()
    }

    func setMissing(_ missing: Bool) {
        guard missing != isMissing else { return }
        isMissing = missing
        missingBadge.isHidden = !missing
        setAccessibilityLabel((accessibilityLabel() ?? "").replacingOccurrences(of: " (missing)", with: "") + (missing ? " (missing)" : ""))
    }

    func update(rating: Int, flag: PhotoFlag, fileType: String) {
        ratingLabel.stringValue = rating > 0 ? String(repeating: "★", count: rating) : ""
        placeholder.stringValue = fileType
        isRejected = flag == .rejected
        ratingDescription = rating > 0 ? "\(rating) star\(rating == 1 ? "" : "s")" : "Unrated"
        flagDescription = flag == .unflagged ? nil : flag.title
        updateAccessibilityValue()
        switch flag {
        case .picked:
            flagView.image = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: "Picked")
            flagView.contentTintColor = .labelColor
        case .rejected:
            flagView.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Rejected")
            flagView.contentTintColor = .systemRed
        case .unflagged:
            flagView.image = nil
        }
        updateAppearance()
    }

    private func updateAppearance() {
        let selected = isSelected || isHighlighted
        let appearance = effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            var background = selected ? GridColors.selectedCell(for: appearance) : GridColors.cell(for: appearance)
            if colorLabel != .none {
                // The label color over the cell color, stronger when selected.
                background = background.blended(withFraction: selected ? 0.55 : 0.4, of: colorLabel.color) ?? background
            }
            // The members of an open stack are tinted, as in Lightroom.
            if let info = stackInfo, !info.isCollapsed, info.count > 1 {
                background = background.blended(withFraction: 0.18, of: Accent.color) ?? background
            }
            layer?.backgroundColor = background.cgColor
            layer?.borderColor = selected ? Accent.color.cgColor : NSColor.clear.cgColor
        }
        imageLayer.opacity = isRejected ? 0.35 : 1
    }
}
