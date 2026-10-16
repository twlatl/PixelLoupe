import AppKit

/// A rating, flag or color label just applied to photos, for the overlay that confirms it.
nonisolated enum PhotoMark: Equatable, Sendable {
    case rating(Int)
    case flag(PhotoFlag)
    case label(ColorLabel)
    /// A short report, such as an import's ("Imported 34 photos").
    case message(String)

    /// What VoiceOver announces.
    var spokenText: String {
        switch self {
        case .rating(let stars): stars == 0 ? "Rating: none" : "Rating: \(stars) star\(stars == 1 ? "" : "s")"
        case .flag(let flag): "Flag: \(flag.title)"
        case .label(let label): "Label: \(label.title)"
        case .message(let text): text
        }
    }
}

extension PhotoEditing {
    /// Posted (with the store) after a rating, flag or label is applied; `userInfo["mark"]` is the
    /// ``PhotoMark``.
    static let didMarkNotification = Notification.Name("PhotoEditingDidMark")

    func announce(_ mark: PhotoMark) {
        NotificationCenter.default.post(name: Self.didMarkNotification, object: store, userInfo: ["mark": mark])
    }
}

/// The pill that appears briefly over the photos after a rating, flag or label is applied ("Rating
/// ★★★", "Flag ⚑ Rejected", "Label ●"), in Liquid Glass. It never takes clicks.
final class MarkOverlayView: NSView {
    /// How long the pill stays before fading.
    static let displayDuration: Duration = .milliseconds(1200)

    private let glass = NSGlassEffectView()
    private let stack = NSStackView()
    private var hideTask: Task<Void, Never>?
    /// The mark shown (for tests); `nil` once it has faded.
    private(set) var shownMark: PhotoMark?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 26, bottom: 10, right: 26)
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView = stack
        glass.cornerRadius = 30
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 60),
        ])
        alphaValue = 0
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `mark`, replacing any pill still showing, and fades it out after a moment.
    func show(_ mark: PhotoMark) {
        shownMark = mark
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        Self.views(for: mark).forEach(stack.addArrangedSubview)
        hideTask?.cancel()
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
        NSAccessibility.post(element: NSApp.mainWindow as Any, notification: .announcementRequested,
                             userInfo: [.announcement: mark.spokenText, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        // A message has more to read than a mark.
        let duration: Duration = if case .message = mark { .seconds(3) } else { Self.displayDuration }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await self?.fadeOut()
        }
    }

    /// Fades the pill out now.
    func hide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in await self?.fadeOut() }
    }

    /// Fades out, then takes the pill out of the way (unless a new mark is shown meanwhile, which
    /// cancels this).
    private func fadeOut() async {
        shownMark = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            animator().alphaValue = 0
        }, completionHandler: nil)
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, shownMark == nil else { return }
        isHidden = true
    }

    private static func views(for mark: PhotoMark) -> [NSView] {
        func text(_ string: String) -> NSTextField {
            let label = NSTextField(labelWithString: string)
            label.font = .systemFont(ofSize: 28, weight: .regular)
            label.textColor = .labelColor
            return label
        }
        func symbol(_ name: String, _ color: NSColor, size: CGFloat = 26) -> NSImageView {
            let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
                .applying(.init(paletteColors: [color]))
            let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) ?? NSImage())
            return view
        }
        switch mark {
        case .rating(let stars):
            guard stars > 0 else { return [text("Rating"), text("None")] }
            let row = NSStackView(views: (0..<stars).map { _ in symbol("star.fill", .systemYellow) })
            row.spacing = 4
            return [text("Rating"), row]
        case .flag(let flag):
            return [text("Flag"), symbol(flag == .unflagged ? "flag.slash" : "flag.fill", .labelColor), text(flag.title)]
        case .label(let label):
            guard label != .none else { return [text("Label"), text("None")] }
            return [text("Label"), symbol("circle.fill", label.color, size: 30)]
        case .message(let message):
            let label = text(message)
            label.font = .systemFont(ofSize: 20, weight: .regular)
            return [label]
        }
    }
}
