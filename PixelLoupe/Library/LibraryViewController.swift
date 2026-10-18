import AppKit

/// The Library module: filter bar across the top, photo grid, and size/sort toolbar below.
final class LibraryViewController: NSViewController {
    private let store: CatalogStore
    private let state: LibraryState
    private lazy var filterBar = FilterBarViewController(store: store, state: state)
    private(set) lazy var grid = GridViewController(store: store, state: state)
    private lazy var bottomBar = BottomBarViewController(state: state)
    private lazy var loupe = LoupeViewController(store: store, state: state)
    private lazy var compare: CompareViewController = {
        let compare = CompareViewController(store: store, state: state)
        compare.showsViewModes = true
        return compare
    }()
    private lazy var survey = SurveyViewController(store: store, state: state)

    init(store: CatalogStore, state: LibraryState) {
        self.store = store
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var preferredFirstResponder: NSResponder? { grid.preferredFirstResponder }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for child in [filterBar, grid, bottomBar] as [NSViewController] {
            addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child.view)
        }
        let topSeparator = separator()
        let bottomSeparator = separator()

        NSLayoutConstraint.activate([
            filterBar.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            filterBar.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filterBar.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            topSeparator.topAnchor.constraint(equalTo: filterBar.view.bottomAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            grid.view.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            grid.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            bottomSeparator.topAnchor.constraint(equalTo: grid.view.bottomAnchor),
            bottomSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            bottomBar.view.topAnchor.constraint(equalTo: bottomSeparator.bottomAnchor),
            bottomBar.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // The enlarged view and Survey cover the grid area between the toolbars; Compare covers the
        // grid and its bottom toolbar (it has its own).
        let covers: [(NSViewController, NSLayoutYAxisAnchor)] = [
            (loupe, grid.view.bottomAnchor), (survey, grid.view.bottomAnchor), (compare, view.bottomAnchor),
        ]
        for (child, bottom) in covers {
            addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            child.view.isHidden = true
            view.addSubview(child.view)
            NSLayoutConstraint.activate([
                child.view.topAnchor.constraint(equalTo: grid.view.topAnchor),
                child.view.leadingAnchor.constraint(equalTo: grid.view.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: grid.view.trailingAnchor),
                child.view.bottomAnchor.constraint(equalTo: bottom),
            ])
        }
        state.addObserver(self) { [weak self] change in
            if change == .presentation { self?.updatePresentation() }
        }
    }

    private func updatePresentation() {
        let showLoupe = state.presentation == .loupe
        let showCompare = state.presentation == .compare
        let showSurvey = state.presentation == .survey
        let gridWasHidden = grid.view.isHidden
        loupe.view.isHidden = !showLoupe
        compare.view.isHidden = !showCompare
        survey.view.isHidden = !showSurvey
        grid.view.isHidden = showLoupe || showCompare || showSurvey
        if showLoupe { loupe.refresh() }
        if showCompare { compare.refresh() }
        if showSurvey { survey.refresh() }
        if gridWasHidden, !grid.view.isHidden { view.window?.makeFirstResponder(grid.preferredFirstResponder) }
    }

    /// Lets the window controller drive Compare's ← → while comparing in Library.
    var compareController: CompareViewController { compare }

    /// Lets the window controller drive Survey's ← →.
    var surveyController: SurveyViewController { survey }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(box)
        return box
    }

    @objc func focusSearch(_ sender: Any?) {
        filterBar.focusSearch()
    }

    @objc func increaseThumbnailSize(_ sender: Any?) {
        state.thumbnailSize += 40
    }

    @objc func decreaseThumbnailSize(_ sender: Any?) {
        state.thumbnailSize -= 40
    }
}
