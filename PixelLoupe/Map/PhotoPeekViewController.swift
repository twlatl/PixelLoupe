import AppKit

/// What a map pin shows in its popover (hovered or clicked): its photo's thumbnail and name, or for a
/// pin with several photos (a cluster), each in turn with arrows on either side to step through them.
final class PhotoPeekViewController: NSViewController {
    struct Item: Equatable {
        var photoID: UUID
        var name: String
    }

    private let thumbnails: ThumbnailStore
    let items: [Item]
    private(set) var index = 0
    let imageView = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    let previousButton = NSButton()
    let nextButton = NSButton()
    /// Changed with each photo shown, so a thumbnail that loads late doesn't replace a newer one.
    private var generation = 0

    static let imageSize = NSSize(width: 220, height: 165)

    init(thumbnails: ThumbnailStore, items: [Item]) {
        self.thumbnails = thumbnails
        self.items = items
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityIdentifier("photoPeekImage")
        nameLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setAccessibilityIdentifier("photoPeekName")

        for (button, symbol, label, action) in [
            (previousButton, "arrow.backward.circle.fill", "Previous photo", #selector(showPrevious(_:))),
            (nextButton, "arrow.right.circle.fill", "Next photo", #selector(showNext(_:))),
        ] {
            // A white arrow on a dark disc reads over any photo.
            let configuration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
                .applying(.init(paletteColors: [.white, NSColor.black.withAlphaComponent(0.5)]))
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(configuration)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label)
            button.isHidden = items.count < 2
        }
        previousButton.setAccessibilityIdentifier("photoPeekPrevious")
        nextButton.setAccessibilityIdentifier("photoPeekNext")

        let root = NSView()
        for subview in [imageView, nameLabel, previousButton, nextButton] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            imageView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            imageView.widthAnchor.constraint(equalToConstant: Self.imageSize.width),
            imageView.heightAnchor.constraint(equalToConstant: Self.imageSize.height),
            nameLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            nameLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            previousButton.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 6),
            previousButton.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -6),
            nextButton.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
        ])
        view = root
        show(0)
    }

    /// Shows the photo at `index`, wrapping around from either end.
    func show(_ index: Int) {
        guard !items.isEmpty else { return }
        self.index = (index % items.count + items.count) % items.count
        let item = items[self.index]
        nameLabel.stringValue = items.count > 1
            ? "\(item.name)  ·  \((self.index + 1).formatted()) of \(items.count.formatted())"
            : item.name
        generation += 1
        if let cached = thumbnails.cachedImage(for: item.photoID) {
            imageView.image = NSImage(cgImage: cached, size: .zero)
            return
        }
        imageView.image = nil
        let generation = generation, thumbnails = thumbnails
        Task { [weak self] in
            let image = await thumbnails.image(for: item.photoID)
            guard let self, self.generation == generation, let image else { return }
            imageView.image = NSImage(cgImage: image, size: .zero)
        }
    }

    @objc func showPrevious(_ sender: Any?) {
        show(index - 1)
    }

    @objc func showNext(_ sender: Any?) {
        show(index + 1)
    }

    // ← → step through the photos while the popover has the keyboard.
    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow where items.count > 1: showPrevious(nil)
        case .rightArrow where items.count > 1: showNext(nil)
        default: super.keyDown(with: event)
        }
    }
}
