import AppKit

/// Shown when no catalog is open: the app icon, version, New Catalog… / Open Catalog… / Open Recent
/// on the left, and the featured photo with its credit on the right.
final class WelcomeWindowController: NSWindowController {
    static let size = NSSize(width: 1040, height: 640)
    static let sidebarWidth: CGFloat = 400
    static let tagline = "Create a catalog to start organizing your photos, or pick up where you left off."

    /// The featured photo and its caption.
    enum FeaturedPhoto {
        static let title = "Joshua Tree"
        static let credit = "Photo by TED · Joshua Tree National Park, California"
        static let accessibilityDescription = "A Joshua tree in front of a rock pile, in black and white"
    }

    private let recentMenu = RecentCatalogsMenu(header: "Recent Catalogs", keepingFirst: 1)
    private(set) var openRecentButton: NSPopUpButton!
    /// The Recent Catalogs panel under the buttons (hidden until a catalog has been opened).
    let recentList = RecentCatalogsListView()

    init() {
        let window = Self.makeWindow(title: "Welcome to PixelLoupe", identifier: "welcomeWindow")
        super.init(window: window)
        window.contentView = makeContentView()
        updateOpenRecentButton()
        NotificationCenter.default.addObserver(
            self, selector: #selector(recentCatalogsDidChange(_:)), name: RecentCatalogs.didChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// "Version 0.1 (67)", from the bundle's version and build number.
    static func versionString(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }

    /// "Version 0.1", from the bundle's version alone (the About window's, opened normally).
    static func shortVersionString(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        "Version \(info?["CFBundleShortVersionString"] as? String ?? "?")"
    }

    /// "Build 67", from the bundle's build number (the About window's, opened with ⌥⌘ held).
    static func buildString(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        "Build \(info?["CFBundleVersion"] as? String ?? "?")"
    }

    /// The welcome window's frame, also used by the About window: fixed size, with the content under a
    /// transparent title bar.
    static func makeWindow(title: String, identifier: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = title
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.isReleasedWhenClosed = false
        return window
    }

    /// The app icon at the top of the sidebar.
    static func makeAppIcon() -> NSImageView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 80).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 80).isActive = true
        icon.setAccessibilityLabel("PixelLoupe")
        return icon
    }

    /// The version under the icon, selectable so it can be copied into a bug report.
    static func makeVersionLabel(_ string: String = versionString(), identifier: String) -> NSTextField {
        let version = NSTextField(labelWithString: string)
        version.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        version.textColor = .secondaryLabelColor
        version.isSelectable = true
        version.setAccessibilityIdentifier(identifier)
        return version
    }

    @objc private func recentCatalogsDidChange(_ notification: Notification) {
        updateOpenRecentButton()
        recentList.reload()
    }

    /// Open Recent is disabled until a catalog has been opened.
    private func updateOpenRecentButton() {
        openRecentButton.isEnabled = !RecentCatalogs.shared.entries.isEmpty
    }

    private func makeContentView() -> NSView {
        let container = NSView()
        let sidebar = makeSidebar()
        let photo = WelcomePhotoView()
        for view in [sidebar, photo] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: container.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            photo.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            photo.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            photo.topAnchor.constraint(equalTo: container.topAnchor),
            photo.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func makeSidebar() -> NSView {
        let icon = Self.makeAppIcon()
        let version = Self.makeVersionLabel(identifier: "welcomeVersion")

        let title = NSTextField(labelWithString: "Welcome to PixelLoupe")
        title.font = .systemFont(ofSize: 26, weight: .bold)

        let tagline = NSTextField(wrappingLabelWithString: Self.tagline)
        tagline.alignment = .center
        tagline.textColor = .secondaryLabelColor
        tagline.font = .systemFont(ofSize: 14)
        tagline.preferredMaxLayoutWidth = 300

        let newButton = ProminentButton(label: "New Catalog…", target: nil, action: #selector(PixelLoupeActions.newCatalog(_:)))
        newButton.setAccessibilityIdentifier("newCatalogButton")

        let openButton = NSButton(title: "Open Catalog…", target: nil, action: #selector(PixelLoupeActions.openCatalogDocument(_:)))
        openButton.controlSize = .large
        openButton.setAccessibilityIdentifier("openCatalogButton")

        let recent = NSPopUpButton(frame: .zero, pullsDown: true)
        recent.controlSize = .large
        recent.autoenablesItems = false
        let titleItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        titleItem.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        recent.menu?.addItem(titleItem)
        recent.menu?.delegate = recentMenu
        recent.setAccessibilityIdentifier("openRecentButton")
        recent.setAccessibilityLabel("Open Recent")
        openRecentButton = recent

        let openRow = NSStackView(views: [openButton, recent])
        openRow.distribution = .fillEqually
        openRow.spacing = 10

        let lightroomButton = NSButton(
            title: "Import Lightroom Catalog…", target: nil, action: #selector(PixelLoupeActions.importLightroomCatalog(_:)))
        lightroomButton.bezelStyle = .inline
        lightroomButton.setAccessibilityIdentifier("importLightroomCatalogButton")

        let stack = NSStackView(views: [icon, version, title, tagline, newButton, openRow, recentList, lightroomButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(6, after: version)
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(22, after: tagline)
        stack.setCustomSpacing(12, after: openRow)
        stack.setCustomSpacing(12, after: recentList)
        // Hidden views (an empty recent list) give up their space.
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = NSView()
        sidebar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 44),
            stack.centerXAnchor.constraint(equalTo: sidebar.centerXAnchor),
            newButton.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -88),
            openRow.widthAnchor.constraint(equalTo: newButton.widthAnchor),
            recentList.widthAnchor.constraint(equalTo: newButton.widthAnchor),
        ])
        return sidebar
    }
}

/// The welcome window's featured photo, filling its half of the window, with the caption on a dark
/// gradient along the bottom. The About window shows it too, or its secret photo.
final class WelcomePhotoView: NSView {
    enum Content {
        /// The featured photo, with its caption.
        case featured
        /// The About window's secret photo (About opened with ⌥⌘ held), without a caption.
        case secret
    }

    private static let photo = NSImage(resource: .welcomeScreen)
    private static let secretPhoto = NSImage(resource: .aboutSecret)

    var content = Content.featured {
        didSet {
            guard content != oldValue else { return }
            applyContent()
            needsDisplay = true
        }
    }

    private let shade = GradientView()
    private var caption: NSView?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        shade.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shade)
        NSLayoutConstraint.activate([
            shade.leadingAnchor.constraint(equalTo: leadingAnchor),
            shade.trailingAnchor.constraint(equalTo: trailingAnchor),
            shade.bottomAnchor.constraint(equalTo: bottomAnchor),
            shade.heightAnchor.constraint(equalToConstant: 160),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("welcomePhoto")
        addCaption()
        applyContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        let photo = content == .secret ? Self.secretPhoto : Self.photo
        layer?.contents = photo.layerContents(forContentsScale: window?.backingScaleFactor ?? 2)
    }

    /// The secret photo has no caption, so no shade for one either.
    private func applyContent() {
        shade.isHidden = content == .secret
        caption?.isHidden = content == .secret
        setAccessibilityLabel(content == .secret
            ? AboutWindowController.secretPhotoDescription
            : WelcomeWindowController.FeaturedPhoto.accessibilityDescription)
    }

    /// Clear at the top to translucent black at the bottom, so the white caption reads over the sand.
    private final class GradientView: NSView {
        override func makeBackingLayer() -> CALayer {
            let gradient = CAGradientLayer()
            gradient.colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0.7).cgColor]
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            return gradient
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }

    private func addCaption() {
        let kicker = NSTextField(labelWithAttributedString: NSAttributedString(string: "FEATURED PHOTO", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .kern: 0.8,
            .foregroundColor: NSColor.white.withAlphaComponent(0.75),
        ]))
        let title = NSTextField(labelWithString: WelcomeWindowController.FeaturedPhoto.title)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .white
        let credit = NSTextField(labelWithString: WelcomeWindowController.FeaturedPhoto.credit)
        credit.font = .systemFont(ofSize: 12)
        credit.textColor = NSColor.white.withAlphaComponent(0.8)

        let caption = NSStackView(views: [kicker, title, credit])
        caption.orientation = .vertical
        caption.alignment = .leading
        caption.spacing = 4
        caption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)
        self.caption = caption
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
        ])
    }
}
