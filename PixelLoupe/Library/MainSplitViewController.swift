import AppKit

/// Sidebar of catalog folders alongside the active module (Library grid or Develop), and in
/// Library the right sidebar (Histogram, Keywords, Metadata).
final class MainSplitViewController: NSSplitViewController {
    private let store: CatalogStore
    private let state: LibraryState
    private lazy var modeContainer = ModeContainerViewController(store: store, state: state)
    private(set) lazy var inspector = LibraryInspectorViewController(store: store, state: state)
    private(set) lazy var sidebar = SidebarViewController(store: store, state: state)
    private var sidebarItem: NSSplitViewItem?
    private var inspectorItem: NSSplitViewItem?
    private var inspectorHost: InspectorHostViewController?
    private static let inspectorVisibleKey = "LibraryInspectorVisible"
    private static let inspectorMinimumWidth: CGFloat = 366
    private static let inspectorMaximumWidth: CGFloat = 420
    private static let sidebarWidthKey = "LeftSidebarWidth"
    private static let inspectorWidthKey = "RightSidebarWidth"
    /// The sidebar opens as wide as the right column; it can be made as narrow as this.
    static let sidebarMinimumWidth: CGFloat = 200
    private let defaults: UserDefaults
    private var hasRestoredWidths = false

    /// Whether a width change comes from the user dragging a divider: a mouse drag, outside a window
    /// resize. Only those widths are remembered; ones AppKit sets (squeezing a sidebar to fit a
    /// narrower window, or clamping the restored width) aren't. Tests replace this.
    var isDraggingDivider: () -> Bool = {
        guard let event = NSApp.currentEvent else { return false }
        return event.type == .leftMouseDragged || event.type == .leftMouseUp
    }

    /// The Develop module, for commands that act on it from the menu bar.
    var develop: DevelopViewController { modeContainer.develop }
    var library: LibraryViewController { modeContainer.library }
    /// The pill confirming a rating, flag or label.
    var markOverlay: MarkOverlayView { modeContainer.markOverlay }

    init(store: CatalogStore, state: LibraryState, defaults: UserDefaults = Defaults.store) {
        self.store = store
        self.state = state
        self.defaults = defaults
        super.init(nibName: nil, bundle: nil)
        Self.forgetWidthsRecordedBeforeDragOnly(in: defaults)
    }

    private static let dragOnlyWidthsKey = "SidebarWidthsRecordedByDragOnly"

    /// Before RAW-72, widths AppKit squeezed a sidebar to (a window too narrow for both) were saved as
    /// if the user had dragged them, leaving the left sidebar stuck near its minimum. Those saved widths
    /// are dropped once, so both sidebars open at their default widths again.
    static func forgetWidthsRecordedBeforeDragOnly(in defaults: UserDefaults) {
        guard !defaults.bool(forKey: dragOnlyWidthsKey) else { return }
        defaults.removeObject(forKey: sidebarWidthKey)
        defaults.removeObject(forKey: inspectorWidthKey)
        defaults.set(true, forKey: dragOnlyWidthsKey)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Widths are remembered in the app's own defaults (see `restoreWidths`), not with the split
        // view's autosave, which writes to the standard domain even while hosting tests.
        let sidebar = NSSplitViewItem(sidebarWithViewController: self.sidebar)
        sidebar.minimumThickness = Self.sidebarMinimumWidth
        sidebar.maximumThickness = Self.inspectorMaximumWidth
        sidebar.canCollapse = true
        addSplitViewItem(sidebar)

        let content = NSSplitViewItem(viewController: modeContainer)
        content.minimumThickness = 600
        addSplitViewItem(content)

        // The right column is shared: the Library's inspector, or Develop's panel. Keeping it open in both
        // modules leaves the content area the same width, so the toolbar's Library/Develop control (which
        // is centered over that area) doesn't move when switching.
        let host = InspectorHostViewController(library: inspector, develop: { [weak self] in
            self?.develop.loadViewIfNeeded()
            return self?.develop.sidebarView
        })
        let inspectorSplit = NSSplitViewItem(inspectorWithViewController: host)
        // Wide enough for Develop's panel, so the column is the same width in both modules.
        inspectorSplit.minimumThickness = Self.inspectorMinimumWidth
        inspectorSplit.maximumThickness = Self.inspectorMaximumWidth
        inspectorSplit.canCollapse = true
        inspectorSplit.isCollapsed = !isRightSidebarVisible
        addSplitViewItem(inspectorSplit)
        sidebarItem = sidebar
        inspectorItem = inspectorSplit
        inspectorHost = host
        host.show(state.mode)

        state.addObserver(self) { [weak self] change in
            guard let self, change == .mode else { return }
            inspectorHost?.show(state.mode)
            inspectorItem?.isCollapsed = !isRightSidebarVisible
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // After this layout pass: divider positions set during one are lost.
        guard !hasRestoredWidths, !isRestoreScheduled else { return }
        isRestoreScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isRestoreScheduled = false
            self?.restoreWidths()
        }
    }

    private var isRestoreScheduled = false

    /// The left sidebar's width: the one the user last set, else the right column's width.
    var sidebarWidth: CGFloat {
        let stored = defaults.object(forKey: Self.sidebarWidthKey) as? Double
        return CGFloat(stored ?? Double(inspectorWidth)).clamped(to: Self.sidebarMinimumWidth...Self.inspectorMaximumWidth)
    }

    /// The right column's width, as last set.
    var inspectorWidth: CGFloat {
        let stored = defaults.object(forKey: Self.inspectorWidthKey) as? Double
        return CGFloat(stored ?? Double(Self.inspectorMinimumWidth)).clamped(to: Self.inspectorMinimumWidth...Self.inspectorMaximumWidth)
    }

    /// Sets both sidebars to their remembered widths, once the window has its size (positions set
    /// before then are clamped to the split view's provisional width).
    func restoreWidths() {
        guard !hasRestoredWidths, splitView.bounds.width >= Self.sidebarMinimumWidth + Self.inspectorMinimumWidth + 600 else { return }
        hasRestoredWidths = true
        // Read both first: moving one divider records that sidebar's width.
        let (left, right) = (sidebarWidth, inspectorWidth)
        if let item = inspectorItem, !item.isCollapsed {
            splitView.setPosition(splitView.bounds.width - right - splitView.dividerThickness, ofDividerAt: 1)
        }
        if let item = sidebarItem, !item.isCollapsed {
            splitView.setPosition(left, ofDividerAt: 0)
        }
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        // Remember widths the user sets by dragging a divider (AppKit names the divider then), not ones
        // a window resize, the first layout or restoring the widths produces.
        guard hasRestoredWidths, !view.inLiveResize, isDraggingDivider(),
              let divider = notification.userInfo?["NSSplitViewDividerIndex"] as? Int else { return }
        // Divider 0 is the left sidebar's edge, divider 1 the right column's.
        let (item, key, minimum) = divider == 0
            ? (sidebarItem, Self.sidebarWidthKey, Self.sidebarMinimumWidth)
            : (inspectorItem, Self.inspectorWidthKey, Self.inspectorMinimumWidth)
        guard let item, !item.isCollapsed, item.viewController.view.frame.width >= minimum else { return }
        defaults.set(Double(item.viewController.view.frame.width), forKey: key)
    }

    /// Whether the Library's right sidebar is shown (remembered while in Develop and across launches).
    var isLibraryInspectorVisible: Bool {
        get { Defaults.store.object(forKey: Self.inspectorVisibleKey) as? Bool ?? true }
        set {
            Defaults.store.set(newValue, forKey: Self.inspectorVisibleKey)
            if state.mode == .library { inspectorItem?.animator().isCollapsed = !newValue }
        }
    }

    /// Whether Develop's panel is shown (for this run; Tab or the toolbar button hides it).
    var isDevelopPanelVisible = true {
        didSet {
            if state.mode == .develop { inspectorItem?.animator().isCollapsed = !isDevelopPanelVisible }
        }
    }

    var isSidebarVisible: Bool { !(sidebarItem?.isCollapsed ?? true) }

    /// Photo ▸ Add Keywords: shows the right sidebar (in Library) and the cursor in Keywords.
    func addKeywords() {
        if !isLibraryInspectorVisible {
            isLibraryInspectorVisible = true
            inspectorItem?.isCollapsed = false
        }
        view.layoutSubtreeIfNeeded()
        inspector.focusKeywords()
    }

    /// The toolbar's right-sidebar button.
    func toggleLibraryInspector() {
        isLibraryInspectorVisible.toggle()
    }

    /// Whether the right sidebar of the current module (the Library's inspector, or Develop's panel) is showing.
    var isRightSidebarVisible: Bool {
        state.mode == .library ? isLibraryInspectorVisible : isDevelopPanelVisible
    }

    /// The toolbar's right-sidebar button, in either module.
    func toggleRightSidebar() {
        if state.mode == .library {
            toggleLibraryInspector()
        } else {
            isDevelopPanelVisible.toggle()
        }
    }

    /// Tab: hides both sidebars, or shows both when either is hidden (as in Lightroom). In Develop
    /// the right sidebar is Develop's panel.
    func toggleSidebars() {
        let rightVisible = isRightSidebarVisible
        let show = !(isSidebarVisible && rightVisible)
        sidebarItem?.animator().isCollapsed = !show
        if state.mode == .library {
            isLibraryInspectorVisible = show
        } else {
            isDevelopPanelVisible = show
        }
    }
}

/// The right column's content: the Library's inspector in Library, Develop's panel in Develop.
final class InspectorHostViewController: NSViewController {
    private let library: LibraryInspectorViewController
    private let develop: () -> NSView?
    private weak var shown: NSView?

    init(library: LibraryInspectorViewController, develop: @escaping () -> NSView?) {
        self.library = library
        self.develop = develop
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = NSView()
    }

    func show(_ mode: AppMode) {
        loadViewIfNeeded()
        if !children.contains(library) { addChild(library) }
        guard let content = mode == .library ? library.view : develop(), content !== shown else { return }
        shown?.removeFromSuperview()
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        shown = content
        // It was out of the window while the other module showed, so it missed any Monochrome Mode change.
        Accent.apply(in: content, redraw: true)
    }
}

/// Swaps between the Library and Develop modules.
final class ModeContainerViewController: NSViewController {
    private let store: CatalogStore
    private let state: LibraryState
    private(set) lazy var library = LibraryViewController(store: store, state: state)
    private(set) lazy var develop = DevelopViewController(store: store, state: state)

    init(store: CatalogStore, state: LibraryState) {
        self.store = store
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Confirms a rating, flag or label just applied, over the photos.
    let markOverlay = MarkOverlayView()

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        show(library)
        // Centered, in the lower third of the content area.
        view.addSubview(markOverlay, positioned: .above, relativeTo: nil)
        let upper = NSLayoutGuide()
        view.addLayoutGuide(upper)
        NSLayoutConstraint.activate([
            upper.topAnchor.constraint(equalTo: view.topAnchor),
            upper.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.8),
            markOverlay.centerYAnchor.constraint(equalTo: upper.bottomAnchor),
            markOverlay.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(didMark(_:)), name: PhotoEditing.didMarkNotification, object: store)
        state.addObserver(self) { [weak self] change in
            guard let self, change == .mode else { return }
            switch state.mode {
            case .library: show(library)
            case .develop: show(develop)
            }
        }
    }

    private func show(_ child: NSViewController) {
        guard !children.contains(child) else { return }
        for existing in children {
            existing.view.removeFromSuperview()
            existing.removeFromParent()
        }
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        // Under the rating overlay.
        view.addSubview(child.view, positioned: .below, relativeTo: markOverlay.superview == view ? markOverlay : nil)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // The module was out of the window while the other one showed (see InspectorHostViewController).
        Accent.apply(in: child.view, redraw: true)
        view.window?.makeFirstResponder(child.preferredFirstResponder)
    }

    @objc private func didMark(_ notification: Notification) {
        guard let mark = notification.userInfo?["mark"] as? PhotoMark, view.window != nil else { return }
        markOverlay.show(mark)
    }
}

extension NSViewController {
    /// The view that should receive keyboard focus when this controller becomes visible.
    @objc var preferredFirstResponder: NSResponder? { view }
}
