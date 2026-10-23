import AppKit

/// Above the grid while it shows a publish service (RAW-179), as in Lightroom: the service, where it
/// publishes, and Publish.
final class PublishBarViewController: NSViewController {
    static let height: CGFloat = 36

    private let store: CatalogStore
    private let state: LibraryState
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    let locationButton = NSButton(title: "", target: nil, action: nil)
    let publishButton = NSButton(title: "Publish", target: nil, action: #selector(PixelLoupeActions.publishNow(_:)))
    /// The grid's grouping of the service's photos, for whether Publish has anything to do.
    var groups: PublishGroups? {
        didSet { update() }
    }

    init(store: CatalogStore, state: LibraryState) {
        self.store = store
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        locationButton.isBordered = false
        locationButton.contentTintColor = .secondaryLabelColor
        locationButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        locationButton.lineBreakMode = .byTruncatingMiddle
        locationButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        locationButton.target = self
        locationButton.action = #selector(openLocation(_:))
        publishButton.bezelStyle = .push
        publishButton.keyEquivalent = ""
        publishButton.setAccessibilityIdentifier("publishButton")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, nameLabel, spacer, locationButton, publishButton])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 12)
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        view = stack
        view.heightAnchor.constraint(equalToConstant: Self.height).isActive = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        state.addObserver(self) { [weak self] change in
            if change == .filter || change == .importStatus { self?.update() }
        }
        update()
    }

    private var service: PublishService? {
        state.filter.scope.publishServiceID.flatMap { PublishService.with(id: $0, in: store.viewContext) }
    }

    func update() {
        guard isViewLoaded, let service else { return }
        icon.image = NSImage(systemSymbolName: service.kind.symbolName, accessibilityDescription: service.kind.title)
        nameLabel.stringValue = service.displayName
        let location: String? = switch service.kind {
        case .hardDrive:
            HardDrivePublisher(settings: service.settings, watermark: nil).folder.map { ($0.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath }
        case .flickr:
            service.accountName.map { "flickr.com: \($0)" }
        }
        locationButton.title = location ?? ""
        locationButton.isHidden = location == nil
        locationButton.toolTip = service.kind == .hardDrive ? "Show in Finder" : "Open your photostream on flickr.com"
        let isPublishing = state.publishStatus != nil
        publishButton.isEnabled = !isPublishing && (groups?.hasWork ?? false)
        publishButton.toolTip = isPublishing ? "Publishing…" : publishButton.isEnabled ? nil : "Every photo is published."
    }

    @objc private func openLocation(_ sender: Any?) {
        guard let service else { return }
        switch service.kind {
        case .hardDrive:
            HardDrivePublisher(settings: service.settings, watermark: nil).folder.map { _ = NSWorkspace.shared.open($0) }
        case .flickr:
            guard let account = KeychainFlickrCredentialStore.shared.credentials(for: service.id),
                  let photostream = URL(string: "https://www.flickr.com/photos/\(account.userID)/") else { return }
            NSWorkspace.shared.open(photostream)
        }
    }
}
