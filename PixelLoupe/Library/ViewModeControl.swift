import AppKit

/// The Library views a photo can be shown in, as the bottom toolbar's view buttons list them.
enum LibraryView: Int, CaseIterable {
    case grid, loupe, compare, survey

    var title: String {
        switch self {
        case .grid: "Grid"
        case .loupe: "Loupe"
        case .compare: "Compare"
        case .survey: "Survey"
        }
    }

    var symbolName: String {
        switch self {
        case .grid: "square.grid.3x3.square"
        case .loupe: "plus.magnifyingglass"
        case .compare: "square.on.square"
        case .survey: "square.grid.3x2.fill"
        }
    }

    /// Lightroom's key for the view.
    var key: String {
        switch self {
        case .grid: "G"
        case .loupe: "E"
        case .compare: "C"
        case .survey: "N"
        }
    }

    /// The command its button sends (the same as its key).
    var command: KeyCommand {
        switch self {
        case .grid: .showLibrary
        case .loupe: .enlarge
        case .compare: .compare
        case .survey: .survey
        }
    }

    /// The view showing, or nil in full screen.
    init?(_ presentation: PhotoPresentation) {
        switch presentation {
        case .grid: self = .grid
        case .loupe: self = .loupe
        case .compare: self = .compare
        case .survey: self = .survey
        case .fullScreen: return nil
        }
    }
}

/// The Library's view buttons (Grid, Loupe, Compare, Survey), on the left of the bottom toolbar as
/// in Lightroom. The selected one follows the view on show; each is enabled only when its view has
/// something to show.
final class ViewModeControl: NSSegmentedControl {
    private let state: LibraryState
    /// The view last clicked; the catalog window (`chooseLibraryView(_:)`) performs its command like the key.
    private(set) var chosenView: LibraryView?

    init(state: LibraryState) {
        self.state = state
        super.init(frame: .zero)
        segmentCount = LibraryView.allCases.count
        trackingMode = .selectOne
        segmentStyle = .automatic
        controlSize = .small
        for view in LibraryView.allCases {
            let image = NSImage(systemSymbolName: view.symbolName, accessibilityDescription: view.title)
            setImage(image, forSegment: view.rawValue)
            setToolTip("\(view.title) (\(view.key))", forSegment: view.rawValue)
            setWidth(28, forSegment: view.rawValue)
        }
        setAccessibilityLabel("View")
        setAccessibilityIdentifier("viewModeControl")
        target = self
        action = #selector(chose(_:))
        update()
        state.addObserver(self) { [weak self] change in
            switch change {
            case .presentation, .selection, .photoOrder, .mode: self?.update()
            default: break
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update() {
        let selection = state.selectedPhotoIDs
        setEnabled(true, forSegment: LibraryView.grid.rawValue)
        setEnabled(!selection.isEmpty, forSegment: LibraryView.loupe.rawValue)
        setEnabled(state.presentation == .compare || ComparePair.make(selection: selection, order: state.photoOrder) != nil,
                   forSegment: LibraryView.compare.rawValue)
        setEnabled(!selection.isEmpty, forSegment: LibraryView.survey.rawValue)
        if let shown = LibraryView(state.presentation) {
            selectedSegment = shown.rawValue
        } else {
            selectedSegment = -1
        }
    }

    @objc private func chose(_ sender: Any?) {
        guard let chosen = LibraryView(rawValue: selectedSegment) else { return }
        // Clicking the view already on show leaves it as it is (C and N would otherwise leave it).
        if LibraryView(state.presentation) != chosen {
            chosenView = chosen
            // Up this control's own responder chain to its catalog window, even when another window is key.
            tryToPerform(#selector(PixelLoupeActions.chooseLibraryView(_:)), with: self)
        }
        update()
    }
}
