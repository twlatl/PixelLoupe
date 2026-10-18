import AppKit
import CoreData

/// Which photos a slideshow plays and where it starts, as Lightroom's Impromptu Slideshow chooses:
/// the selected photos when several are selected, otherwise every photo in the grid from the
/// selected one on.
nonisolated enum SlideshowPlaylist {
    static func make<ID: Equatable>(selection: [ID], order: [ID]) -> (photos: [ID], start: Int)? {
        if selection.count > 1 {
            // In grid order, starting from the active (first selected) photo.
            let photos = order.filter(selection.contains)
            let list = photos.isEmpty ? selection : photos
            return (list, list.firstIndex(of: selection[0]) ?? 0)
        }
        guard !order.isEmpty else { return nil }
        return (order, selection.first.flatMap(order.firstIndex(of:)) ?? 0)
    }

    /// The photo `offset` places on, wrapping around at either end (the slideshow repeats).
    static func index(after index: Int, by offset: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + offset) % count + count) % count
    }
}

/// A slideshow (Lightroom's Impromptu Slideshow, ⌘Return): the photos one after another on black,
/// covering a display, fading from one to the next. Esc stops it, Space pauses, ← / → step.
///
/// Two viewers take turns: the next photo loads (and renders at the display's size) in the hidden
/// one while the current one shows, so each fade starts from a sharp photo.
final class SlideshowController: NSWindowController {
    static let slideDuration: TimeInterval = 4
    static let fadeDuration: TimeInterval = 1

    let photos: [NSManagedObjectID]
    private(set) var index: Int
    private(set) var isPaused = false
    /// Whether it plays on the secondary display, leaving the main window key so you can keep working.
    let isSecondary: Bool
    /// Called once the slideshow has stopped and its window is gone.
    var onStop: (() -> Void)?

    private let viewers: [PhotoViewer]
    private var front = 0
    private var timer: Timer?
    private let pausedLabel = NSTextField(labelWithString: "Paused")
    private var previousPresentationOptions: NSApplication.PresentationOptions = []

    private final class SlideshowWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    /// Takes the keys while the slideshow window is key. (⌘Return, the menu item, stops it too.)
    private final class SlideshowView: NSView {
        weak var controller: SlideshowController?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            guard let controller else { return }
            if event.keyCode == 53 { controller.stop(); return }   // Escape
            switch event.specialKey {
            case .leftArrow?: controller.step(by: -1)
            case .rightArrow?: controller.step(by: 1)
            default:
                if event.charactersIgnoringModifiers == " " { controller.togglePause() } else { super.keyDown(with: event) }
            }
        }

        override func cancelOperation(_ sender: Any?) {
            controller?.stop()
        }
    }

    init(store: CatalogStore, photos: [NSManagedObjectID], start: Int, screen: NSScreen, secondary: Bool) {
        self.photos = photos
        index = photos.indices.contains(start) ? start : 0
        isSecondary = secondary
        viewers = [PhotoViewer(store: store, inset: 0), PhotoViewer(store: store, inset: 0)]
        let window = SlideshowWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(secondary ? "secondarySlideshowWindow" : "slideshowWindow")
        if secondary {
            // Over the secondary window, even in its own full-screen space.
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            window.level = .normal
            window.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
        }
        let content = SlideshowView(frame: CGRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.setAccessibilityIdentifier("slideshow")
        content.setAccessibilityLabel("Slideshow")
        content.setAccessibilityRole(.group)
        for viewer in viewers {
            viewer.frame = content.bounds
            viewer.autoresizingMask = [.width, .height]
            viewer.alphaValue = 0
            content.addSubview(viewer)
        }
        pausedLabel.font = .systemFont(ofSize: 15, weight: .medium)
        pausedLabel.textColor = .white
        pausedLabel.drawsBackground = true
        pausedLabel.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        pausedLabel.isHidden = true
        pausedLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pausedLabel)
        NSLayoutConstraint.activate([
            pausedLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            pausedLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -40),
        ])
        window.contentView = content
        window.setFrame(screen.frame, display: false)
        super.init(window: window)
        content.controller = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The photo on show.
    var currentPhotoID: NSManagedObjectID? { photos.indices.contains(index) ? photos[index] : nil }

    /// Shows the window and starts playing.
    func start() {
        guard let window, !photos.isEmpty else { return }
        viewers[front].show(photos[index])
        viewers[front].alphaValue = 1
        prepareNext()
        if isSecondary {
            window.orderFront(nil)
        } else {
            previousPresentationOptions = NSApp.presentationOptions
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(window.contentView)
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        guard let window, window.isVisible else { return }
        window.orderOut(nil)
        if !isSecondary { NSApp.presentationOptions = previousPresentationOptions }
        onStop?()
    }

    func togglePause() {
        isPaused.toggle()
        pausedLabel.isHidden = !isPaused
        if isPaused {
            timer?.invalidate()
            timer = nil
        } else {
            scheduleTimer()
        }
    }

    /// ← / →: the previous or next photo at once (no fade), restarting its time on screen.
    func step(by offset: Int) {
        show(SlideshowPlaylist.index(after: index, by: offset, count: photos.count), fade: false)
        if !isPaused { scheduleTimer() }
    }

    /// The timer: fades to the next photo.
    func advance() {
        show(SlideshowPlaylist.index(after: index, by: 1, count: photos.count), fade: true)
    }

    private func show(_ newIndex: Int, fade: Bool) {
        guard photos.count > 1 else { return }
        let back = 1 - front
        if newIndex != SlideshowPlaylist.index(after: index, by: 1, count: photos.count) {
            viewers[back].show(photos[newIndex])
        }
        index = newIndex
        let (outgoing, incoming) = (viewers[front], viewers[back])
        front = back
        if fade {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                incoming.animator().alphaValue = 1
                outgoing.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.prepareNext() }
            }
        } else {
            incoming.alphaValue = 1
            outgoing.alphaValue = 0
            prepareNext()
        }
    }

    /// Loads the photo after the one on show into the hidden viewer.
    private func prepareNext() {
        guard photos.count > 1 else { return }
        viewers[1 - front].show(photos[SlideshowPlaylist.index(after: index, by: 1, count: photos.count)])
    }

    private func scheduleTimer() {
        timer?.invalidate()
        guard photos.count > 1 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.slideDuration + Self.fadeDuration, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
    }
}
