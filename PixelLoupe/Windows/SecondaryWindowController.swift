import AppKit
import CoreData

/// What the secondary window (and its preview) shows: the grid, one photo, Compare or Survey, for a view
/// state of its own. The loupe shows the selected photo unless ``pinnedPhotoID`` is set.
final class SecondaryContentViewController: NSViewController {
    private let store: CatalogStore
    private let state: LibraryState
    private(set) var current: NSViewController?
    private lazy var grid = GridViewController(store: store, state: state)
    private(set) lazy var loupeHost = SecondaryLoupeViewController(store: store, state: state)
    var loupe: LoupeViewController { loupeHost.loupe }
    private(set) lazy var compare = CompareViewController(store: store, state: state)
    private(set) lazy var survey = SurveyViewController(store: store, state: state)

    var mode: SecondaryView = .grid {
        didSet { if mode != oldValue, isViewLoaded { showMode() } }
    }

    /// The photo Loupe – Live or Locked shows instead of the selected one.
    var pinnedPhotoID: NSManagedObjectID? {
        didSet { loupe.pinnedPhotoID = pinnedPhotoID }
    }

    init(store: CatalogStore, state: LibraryState) {
        self.store = store
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The size the window opens at before it's placed on its display.
    static let initialSize = NSSize(width: 1200, height: 800)

    override func loadView() {
        // A real size, so the window doesn't shrink to fit an empty view when it adopts this one.
        view = MatteView(frame: NSRect(origin: .zero, size: Self.initialSize))
        showMode()
    }

    private func showMode() {
        let next: NSViewController = switch mode {
        case .grid: grid
        case .loupe, .liveLoupe, .lockedLoupe: loupeHost
        case .compare: compare
        case .survey: survey
        }
        guard next !== current else { return }
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        addChild(next)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.width, .height]
        view.addSubview(next.view)
        current = next
        if next === compare { compare.refresh() }
        if next === survey { survey.refresh() }
        view.window?.makeFirstResponder(next.preferredFirstResponder ?? next.view)
    }
}

/// Lightroom's secondary window: a second view of the catalog on another display, showing the main
/// window's folder or collection as a grid, one photo (the active one, the one under the pointer in
/// the main window, or a locked one), Compare or Survey. It has its own view state, kept in step with the
/// main window's folder, filter and selection (both ways) but with its own thumbnail size, scroll
/// position and Compare.
final class SecondaryWindowController: NSWindowController, NSWindowDelegate {
    let state = LibraryState(thumbnailSizeKey: SecondaryDisplaySettings.thumbnailSizeKey)
    private let store: CatalogStore
    private let main: LibraryState
    let content: SecondaryContentViewController
    /// Show Second Monitor Preview: the same content in a small panel on the main window's display.
    private(set) var preview: SecondaryPreviewController?

    /// The catalog window controller: menu commands sent while this window is key (ratings, flags,
    /// the Secondary Window menu…) go to it, as if the main window were key.
    weak var actionTarget: NSResponder?
    /// Called when the user closes the window (not when the app closes it).
    var onUserClose: (() -> Void)?
    /// Called when the window enters or leaves full screen.
    var onFullScreenChange: ((Bool) -> Void)?
    /// Called when the window changes its own view (Compare's Done goes back to the grid).
    var onViewChange: ((SecondaryView) -> Void)?
    private var isClosingQuietly = false

    var view: SecondaryView {
        didSet {
            guard view != oldValue else { return }
            enter(view, from: oldValue)
        }
    }

    var isFullScreen: Bool {
        window?.styleMask.contains(.fullScreen) ?? false
    }

    /// The photo the loupe shows, whichever loupe it is.
    var shownPhotoID: NSManagedObjectID? { content.loupe.shownPhotoID }

    init(store: CatalogStore, main: LibraryState, view: SecondaryView) {
        self.store = store
        self.main = main
        // Compare needs a pair; without one it opens as the grid.
        self.view = view == .compare ? .grid : view
        content = SecondaryContentViewController(store: store, state: state)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SecondaryContentViewController.initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Secondary Window"
        window.subtitle = store.name
        window.identifier = NSUserInterfaceItemIdentifier("secondaryWindow")
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 480, height: 320)
        window.tabbingMode = .disallowed
        // The app places and restores it (SecondaryDisplaySettings); macOS restoring an old frame on
        // relaunch would undo that.
        window.isRestorable = false
        super.init(window: window)
        window.contentViewController = content
        window.delegate = self

        state.filter = main.filter
        state.photoOrder = main.photoOrder
        state.selectedPhotoIDs = main.selectedPhotoIDs
        main.addObserver(self) { [weak self] change in
            guard let self else { return }
            switch change {
            case .filter: state.filter = main.filter
            case .photoOrder: state.photoOrder = main.photoOrder
            case .selection: state.selectedPhotoIDs = main.selectedPhotoIDs
            case .hover: followPointer()
            default: break
            }
        }
        state.addObserver(self) { [weak self] change in
            guard let self else { return }
            switch change {
            case .selection: main.selectedPhotoIDs = state.selectedPhotoIDs
            case .presentation where state.presentation == .grid && self.view == .compare:
                // Compare's Done.
                self.view = .grid
                onViewChange?(.grid)
            default: break
            }
        }
        // (Setting `view` in the initializer doesn't run its observer.)
        if view == .compare, enterCompare() { self.view = .compare }
        enter(self.view, from: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Whether Compare has something to compare: two selected photos, or one and the next.
    var canCompare: Bool {
        view == .compare || ComparePair.make(selection: state.selectedPhotoIDs, order: state.photoOrder) != nil
    }

    private func enter(_ view: SecondaryView, from old: SecondaryView?) {
        main.tracksHover = view == .liveLoupe
        switch view {
        case .liveLoupe:
            content.pinnedPhotoID = main.hoveredPhotoID ?? content.loupe.shownPhotoID
        case .lockedLoupe:
            // Locks the photo on show (the one under the pointer if it was Live).
            content.pinnedPhotoID = content.loupe.shownPhotoID
        case .compare:
            if old != nil, !enterCompare() {
                self.view = old ?? .grid
                return
            }
            content.pinnedPhotoID = nil
        case .grid, .loupe, .survey:
            content.pinnedPhotoID = nil
        }
        if old == .compare, state.presentation == .compare { state.presentation = .grid }
        content.mode = view
        preview?.content.mode = view
        preview?.content.pinnedPhotoID = content.pinnedPhotoID
    }

    /// Compares the first two selected photos, or the selected photo and the next (as C does).
    @discardableResult
    private func enterCompare() -> Bool {
        guard let pair = ComparePair.make(selection: state.selectedPhotoIDs, order: state.photoOrder) else { return false }
        state.comparePhotos = pair
        state.activeCompareIndex = 0
        state.selectedPhotoIDs = [pair.select, pair.candidate]
        state.presentation = .compare
        return true
    }

    /// Loupe – Live: the photo under the pointer in the main window's grid or filmstrip. Moving off
    /// the photos keeps the last one.
    private func followPointer() {
        guard view == .liveLoupe, let hovered = main.hoveredPhotoID else { return }
        content.pinnedPhotoID = hovered
        preview?.content.pinnedPhotoID = hovered
    }

    // MARK: - Second monitor preview

    var isShowingPreview: Bool { preview != nil }

    /// Shows or hides the preview panel (on the main window's display). Only while full screen.
    func setPreviewShown(_ shown: Bool, on screen: NSScreen?) {
        if shown {
            guard preview == nil, isFullScreen else { return }
            let controller = SecondaryPreviewController(store: store, state: state)
            controller.content.mode = view
            controller.content.pinnedPhotoID = content.pinnedPhotoID
            controller.actionTarget = actionTarget
            controller.onClose = { [weak self] in self?.preview = nil }
            preview = controller
            controller.present(on: screen ?? NSScreen.main)
        } else {
            let controller = preview
            preview = nil
            controller?.close()
        }
    }

    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let actionTarget, actionTarget.responds(to: action) { return actionTarget }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    /// Shows the window on `screen`: at its last size if that was on this display, otherwise filling
    /// most of it. With `fullScreen`, it then goes full screen there.
    func present(on screen: NSScreen, fullScreen: Bool) {
        guard let window else { return }
        move(to: screen)
        window.orderFront(nil)
        if fullScreen != isFullScreen { window.toggleFullScreen(nil) }
    }

    /// Moves the window to another display. A full-screen window leaves full screen, moves, and goes
    /// full screen again on the new display.
    func move(to screen: NSScreen) {
        guard let window else { return }
        if isFullScreen {
            guard window.screen != screen else { return }
            screenAfterFullScreen = screen
            window.toggleFullScreen(nil)
            return
        }
        // The first time, fill most of the display; after that keep the size the user gave it.
        let current = hasBeenPlaced ? window.frame : .zero
        hasBeenPlaced = true
        window.setFrame(Self.frame(for: current, on: screen.visibleFrame), display: true)
    }

    private var hasBeenPlaced = false
    private var screenAfterFullScreen: NSScreen?

    /// Keeps a frame that already fits on the display; otherwise (or with no frame yet) 80% of it,
    /// centered.
    static func frame(for current: CGRect, on visible: CGRect) -> CGRect {
        if !current.isEmpty, visible.contains(current) { return current }
        let size = CGSize(width: (visible.width * 0.8).rounded(), height: (visible.height * 0.8).rounded())
        return CGRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    func setFullScreen(_ fullScreen: Bool) {
        guard fullScreen != isFullScreen else { return }
        if window?.isVisible != true { window?.orderFront(nil) }
        window?.toggleFullScreen(nil)
    }

    /// Closes the window without counting as the user hiding it: the catalog closed, or its display
    /// was unplugged.
    func closeQuietly() {
        isClosingQuietly = true
        close()
    }

    override func close() {
        setPreviewShown(false, on: nil)
        main.tracksHover = false
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        if !isClosingQuietly { onUserClose?() }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        onFullScreenChange?(true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if let screen = screenAfterFullScreen, let window {
            screenAfterFullScreen = nil
            window.setFrame(Self.frame(for: window.frame, on: screen.visibleFrame), display: true)
            window.toggleFullScreen(nil)
            return
        }
        setPreviewShown(false, on: nil)
        if !isClosingQuietly { onFullScreenChange?(false) }
    }
}

/// Show Second Monitor Preview: a small floating panel on the main window's display showing what the
/// full-screen secondary window shows, live, so you can see it without turning to the other display.
final class SecondaryPreviewController: NSWindowController, NSWindowDelegate {
    let content: SecondaryContentViewController
    weak var actionTarget: NSResponder?
    var onClose: (() -> Void)?

    static let defaultSize = NSSize(width: 400, height: 260)

    init(store: CatalogStore, state: LibraryState) {
        content = SecondaryContentViewController(store: store, state: state)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Second Monitor Preview"
        panel.identifier = NSUserInterfaceItemIdentifier("secondaryPreviewPanel")
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 240, height: 160)
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.isRestorable = false
        super.init(window: panel)
        panel.contentViewController = content
        panel.setContentSize(Self.defaultSize)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the panel in the bottom-right corner of `screen`.
    func present(on screen: NSScreen?) {
        guard let window else { return }
        if let visible = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visible.maxX - window.frame.width - 20, y: visible.minY + 20))
        }
        window.orderFront(nil)
    }

    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let actionTarget, actionTarget.responds(to: action) { return actionTarget }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
