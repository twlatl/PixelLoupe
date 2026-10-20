import AppKit
import QuartzCore

/// PixelLoupe ▸ About PixelLoupe: laid out like the welcome window, with the app icon, version and
/// credits (`Credits.html`) on the left and the featured photo on the right.
///
/// Opened with ⌥⌘ held, it shows a secret photo instead and the credits roll up from the bottom like a
/// film's, at twice the speed for as long as ⌥⌘ stay held (see ``CreditsRoll``).
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static let secretPhotoDescription = "A camera and a loupe beside strips of color negative film"

    let photoView = WelcomePhotoView()
    private(set) var creditsView: NSTextView!
    private(set) var creditsScrollView: NSScrollView!
    /// Whether the credits are rolling: About was opened with ⌥⌘ held.
    private(set) var rollsCredits = false
    /// The keys held down, read every frame for the roll's speed (a stand-in in tests).
    var modifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval?

    init() {
        let window = WelcomeWindowController.makeWindow(title: "About PixelLoupe", identifier: "aboutWindow")
        // Open over a full-screen catalog window, rather than in a separate space.
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContentView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `Credits.html` in the sidebar's type: the system font in a secondary label color, which follows
    /// light and dark appearance (the HTML gives the text, its links and its centering).
    static func credits(bundle: Bundle = .main) -> NSAttributedString {
        guard let url = bundle.url(forResource: "Credits", withExtension: "html"),
              let data = try? Data(contentsOf: url),
              let credits = NSMutableAttributedString(html: data, documentAttributes: nil)
        else { return NSAttributedString() }
        let all = NSRange(location: 0, length: credits.length)
        credits.addAttributes([.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor], range: all)
        return credits
    }

    /// Shows the window, rolling the credits if `modifiers` (the keys held as About was chosen) include ⌥⌘.
    func show(modifiers: NSEvent.ModifierFlags) {
        let isOpening = window?.isVisible != true
        prepare(openedWith: modifiers)
        showWindow(nil)
        if isOpening { window?.center() }
        if rollsCredits { startRolling() }
    }

    /// Sets the window up for an ordinary opening (the featured photo, the credits from the top) or, with
    /// ⌥⌘ among `modifiers`, a secret one (the secret photo, the credits just below the bottom edge,
    /// ready to roll up).
    func prepare(openedWith modifiers: NSEvent.ModifierFlags) {
        stopRolling()
        let rollingCredits = CreditsRoll.isHoldingKeys(modifiers)
        rollsCredits = rollingCredits
        photoView.content = rollingCredits ? .secret : .featured
        window?.contentView?.layoutSubtreeIfNeeded()
        // A blank screenful above and below the credits, so they roll in from the bottom and out the top.
        let visibleHeight = creditsScrollView.contentView.bounds.height
        creditsView.textContainerInset = NSSize(width: 0, height: rollingCredits ? visibleHeight : 0)
        creditsView.sizeToFit()
        creditsScrollView.hasVerticalScroller = !rollingCredits
        creditsScrollView.layer?.mask = rollingCredits ? Self.edgeFade(in: creditsScrollView.bounds) : nil
        scrollCredits(to: 0)
    }

    /// Rolling credits fade in at the bottom edge and out at the top, rather than being cut off mid-line.
    private static func edgeFade(in bounds: CGRect) -> CALayer {
        let fade = CAGradientLayer()
        fade.frame = bounds
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        let edge = NSNumber(value: min(0.5, 28 / max(bounds.height, 1)))
        fade.locations = [0, edge, NSNumber(value: 1 - edge.doubleValue), 1]
        return fade
    }

    /// How far the credits have scrolled.
    var creditsOffset: CGFloat { creditsScrollView.contentView.bounds.origin.y }

    /// How far the credits scroll: rolling, until the last line has left the top.
    var creditsLength: CGFloat { max(0, creditsView.frame.height - creditsScrollView.contentView.bounds.height) }

    /// Moves the rolling credits on by `elapsed` seconds, twice as far while ⌥⌘ are held. They carry
    /// on from wherever the user has scrolled them.
    func advanceCredits(by elapsed: TimeInterval) {
        guard rollsCredits else { return }
        scrollCredits(to: CreditsRoll.offset(after: elapsed, from: creditsOffset, length: creditsLength, holding: modifierFlags()))
    }

    func windowWillClose(_ notification: Notification) {
        stopRolling()
    }

    private func scrollCredits(to offset: CGFloat) {
        creditsScrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        creditsScrollView.reflectScrolledClipView(creditsScrollView.contentView)
    }

    private func startRolling() {
        guard displayLink == nil, let view = window?.contentView else { return }
        let link = view.displayLink(target: self, selector: #selector(rollCredits(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopRolling() {
        displayLink?.invalidate()
        displayLink = nil
        lastFrameTime = nil
    }

    @objc private func rollCredits(_ link: CADisplayLink) {
        defer { lastFrameTime = link.targetTimestamp }
        guard let lastFrameTime else { return }
        // After a stall (the Mac asleep, the window moved to another display) the credits carry on
        // rather than jump.
        advanceCredits(by: min(link.targetTimestamp - lastFrameTime, 0.1))
    }

    private func makeContentView() -> NSView {
        let container = NSView()
        let sidebar = makeSidebar()
        photoView.setAccessibilityIdentifier("aboutPhoto")
        for view in [sidebar, photoView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: container.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: WelcomeWindowController.sidebarWidth),
            photoView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            photoView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            photoView.topAnchor.constraint(equalTo: container.topAnchor),
            photoView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// The welcome window's icon, version and title, with the credits where its buttons and recent
    /// catalogs are.
    private func makeSidebar() -> NSView {
        let icon = WelcomeWindowController.makeAppIcon()
        let version = WelcomeWindowController.makeVersionLabel(identifier: "aboutVersion")

        let title = NSTextField(labelWithString: "PixelLoupe")
        title.font = .systemFont(ofSize: 26, weight: .bold)

        let header = NSStackView(views: [icon, version, title])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 10
        header.setCustomSpacing(12, after: icon)
        header.setCustomSpacing(6, after: version)

        let scroll = NSTextView.scrollableTextView()
        scroll.wantsLayer = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textStorage?.setAttributedString(Self.credits())
        text.setAccessibilityLabel("Credits")
        text.setAccessibilityIdentifier("aboutCredits")
        creditsScrollView = scroll
        creditsView = text

        let sidebar = NSView()
        for view in [header, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 44),
            header.centerXAnchor.constraint(equalTo: sidebar.centerXAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 22),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 44),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -44),
            scroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -32),
        ])
        return sidebar
    }
}

/// The About window's rolling credits (About opened with ⌥⌘ held): they move up at a steady speed,
/// twice as fast while ⌥⌘ are held, and start over once they've left the top.
enum CreditsRoll {
    /// The keys that, held as About opens, roll the credits, and held after that, speed them up.
    static let keys: NSEvent.ModifierFlags = [.option, .command]
    /// Points a second with ⌥⌘ released.
    static let speed: CGFloat = 30

    /// Whether ⌥⌘ are among `modifiers` (other keys held as well don't matter).
    static func isHoldingKeys(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(keys)
    }

    static func speed(holding modifiers: NSEvent.ModifierFlags) -> CGFloat {
        isHoldingKeys(modifiers) ? 2 * speed : speed
    }

    /// Where credits at `offset` are `elapsed` seconds later, in a roll `length` points long.
    static func offset(after elapsed: TimeInterval, from offset: CGFloat, length: CGFloat, holding modifiers: NSEvent.ModifierFlags) -> CGFloat {
        guard length > 0 else { return 0 }
        let next = offset + speed(holding: modifiers) * elapsed
        return next >= length ? next.truncatingRemainder(dividingBy: length) : next
    }
}
