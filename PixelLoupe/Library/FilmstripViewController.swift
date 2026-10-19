import AppKit
import CoreData

/// The filmstrip along the bottom of the window, shown in both Library and Develop.
///
/// It shows the same photos as the grid, in the same order (the current folder and filters), with
/// selection kept in sync. The header shows the folder, photo count, selection and the selected
/// photo's path, with flag and star filters on the right.
final class FilmstripViewController: NSViewController, NSCollectionViewDelegate {
    static let height: CGFloat = 140
    private static let itemSize = NSSize(width: 100, height: 96)

    private let store: CatalogStore
    private let state: LibraryState
    private let collectionView = RangeSelectingCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private var dataSource: NSCollectionViewDiffableDataSource<Int, NSManagedObjectID>!
    private let infoLabel = NSTextField(labelWithString: "")
    private var isApplyingSelection = false

    init(store: CatalogStore, state: LibraryState) {
        self.store = store
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        infoLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        infoLabel.setAccessibilityIdentifier("filmstripInfo")

        let filterLabel = NSTextField(labelWithString: "Filter:")
        filterLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        filterLabel.textColor = .secondaryLabelColor
        let divider = NSBox()
        divider.boxType = .separator
        divider.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let divider2 = NSBox()
        divider2.boxType = .separator
        divider2.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [
            infoLabel, spacer, filterLabel, FlagFilterControl(state: state), divider,
            ColorLabelFilterControl(state: state, identifierPrefix: "filmstrip."), divider2,
            RatingFilterControl(state: state, identifierPrefix: "filmstrip."),
        ])
        header.spacing = 8
        header.setCustomSpacing(16, after: spacer)
        // Don't let the header's natural width shrink the window.
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        header.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 0, right: 12)

        layout.scrollDirection = .horizontal
        layout.itemSize = Self.itemSize
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        // Photos drag onto collections in the sidebar.
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: true)
        // …and out of the app, as JPEGs (the Desktop, Finder, Mail…).
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.delegate = self
        collectionView.register(PhotoGridItem.self, forItemWithIdentifier: PhotoGridItem.identifier)
        collectionView.setAccessibilityIdentifier("filmstrip")

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false

        let topLine = NSBox()
        topLine.boxType = .separator

        let matte = MatteView()
        matte.setAccessibilityIdentifier("filmstripView")
        for view in [topLine, header, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            matte.addSubview(view)
        }
        NSLayoutConstraint.activate([
            topLine.topAnchor.constraint(equalTo: matte.topAnchor),
            topLine.leadingAnchor.constraint(equalTo: matte.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: matte.trailingAnchor),
            header.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: matte.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: matte.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: matte.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: matte.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: matte.bottomAnchor),
        ])
        matte.onMatteChange = { [weak self] in
            self?.collectionView.visibleItems().forEach { $0.view.needsDisplay = true }
        }
        view = matte
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let thumbnails = store.thumbnails
        let context = store.viewContext
        let availability = store.availability
        dataSource = NSCollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, objectID in
            let item = collectionView.makeItem(withIdentifier: PhotoGridItem.identifier, for: indexPath)
            if let item = item as? PhotoGridItem, let photo = try? context.existingObject(with: objectID) as? Photo {
                item.configure(with: photo, thumbnails: thumbnails, isMissing: availability.isMissing(photo.id))
            }
            return item
        }
        applyPhotoOrder()
        updateHoverTracking()

        state.addObserver(self) { [weak self] change in
            guard let self else { return }
            switch change {
            case .hoverTracking: updateHoverTracking()
            case .photoOrder: applyPhotoOrder()
            case .selection: followSelection()
            case .filter, .photoCount: updateInfo()
            default: break
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(contextObjectsDidChange(_:)),
            name: .NSManagedObjectContextObjectsDidChange, object: context
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(thumbnailDidUpdate(_:)),
            name: ThumbnailStore.didUpdateNotification, object: thumbnails
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(availabilityDidChange(_:)),
            name: FileAvailability.didChangeNotification, object: store.availability
        )
    }

    /// Reports the photo under the pointer while ``LibraryState/tracksHover`` is on.
    private func updateHoverTracking() {
        collectionView.onHover = state.tracksHover ? { [weak self] indexPath in
            guard let self else { return }
            state.hoveredPhotoID = indexPath.flatMap { self.dataSource.itemIdentifier(for: $0) }
        } : nil
    }

    @objc private func availabilityDidChange(_ notification: Notification) {
        reconfigureVisibleItems { _ in true }
    }

    // MARK: - Content

    private func applyPhotoOrder() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, NSManagedObjectID>()
        snapshot.appendSections([0])
        snapshot.appendItems(state.photoOrder)
        dataSource.apply(snapshot, animatingDifferences: false)
        followSelection()
    }

    private func followSelection() {
        let indexPaths = Set(state.selectedPhotoIDs.compactMap { dataSource.indexPath(for: $0) })
        if indexPaths != collectionView.selectionIndexPaths {
            isApplyingSelection = true
            collectionView.selectionIndexPaths = indexPaths
            isApplyingSelection = false
        }
        if let first = state.selectedPhotoIDs.first, let indexPath = dataSource.indexPath(for: first),
           !collectionView.indexPathsForVisibleItems().contains(indexPath) || view.window == nil {
            collectionView.scrollToItems(at: [indexPath], scrollPosition: .centeredHorizontally)
        }
        updateInfo()
    }

    /// "Folder: 2026-09-07 · 88 photos / 1 selected / ~/Pictures/…/DSC0001.ARW"
    private func updateInfo() {
        let scope = switch state.filter.scope {
        case .allPhotos: "All Photographs"
        case .previousImport: "Previous Import"
        case .folder(let path): "Folder: \((path as NSString).lastPathComponent)"
        case .collection(let id, _): "Collection: \(PhotoCollection.with(id: id, in: store.viewContext)?.name ?? "")"
        case .importDifference(let reason): "Lightroom import: \(LightroomImportReport.title(forReason: reason))"
        }
        var parts = [scope, "\(state.photoCount.formatted()) photo\(state.photoCount == 1 ? "" : "s")"]
        let selected = state.selectedPhotoIDs
        if !selected.isEmpty {
            parts[1] += " / \(selected.count.formatted()) selected"
            if let photo = try? store.viewContext.existingObject(with: selected[0]) as? Photo {
                parts.append((photo.filePath as NSString).abbreviatingWithTildeInPath)
            }
        }
        infoLabel.stringValue = parts.joined(separator: "  ·  ")
        infoLabel.toolTip = infoLabel.stringValue
    }

    /// Refreshes visible cells whose rating, flag or edits changed.
    @objc private func contextObjectsDidChange(_ notification: Notification) {
        var changed = Set<NSManagedObjectID>()
        for key in [NSUpdatedObjectsKey, NSRefreshedObjectsKey] {
            for object in notification.userInfo?[key] as? Set<NSManagedObject> ?? [] where object is Photo {
                changed.insert(object.objectID)
            }
        }
        guard !changed.isEmpty else { return }
        reconfigureVisibleItems { changed.contains($0.objectID) }
    }

    @objc private func thumbnailDidUpdate(_ notification: Notification) {
        guard let id = notification.userInfo?["id"] as? UUID else { return }
        reconfigureVisibleItems(reloadThumbnail: true) { $0.id == id }
    }

    private func reconfigureVisibleItems(reloadThumbnail: Bool = false, where matches: (Photo) -> Bool) {
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard let objectID = dataSource.itemIdentifier(for: indexPath),
                  let photo = try? store.viewContext.existingObject(with: objectID) as? Photo,
                  matches(photo),
                  let item = collectionView.item(at: indexPath) as? PhotoGridItem else { continue }
            item.configure(with: photo, thumbnails: store.thumbnails, isMissing: store.availability.isMissing(photo.id), reloadThumbnail: reloadThumbnail)
        }
    }

    // MARK: - Selection

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        true
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        dataSource.itemIdentifier(for: indexPath).map { PhotoDrag.pasteboardWriter(for: $0, store: store) }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        syncSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        syncSelection()
    }

    private func syncSelection() {
        guard !isApplyingSelection else { return }
        state.selectedPhotoIDs = collectionView.selectionIndexPaths.sorted().compactMap {
            dataSource.itemIdentifier(for: $0)
        }
    }
}

/// The window's root: the sidebar + module split above, and the filmstrip across the full width
/// below (F6 shows or hides it).
///
/// A plain container rather than an outer split-view controller: an `NSSplitViewController` with
/// horizontal dividers shrinks the window to its children's minimum width.
final class RootViewController: NSViewController {
    let main: MainSplitViewController
    private let filmstrip: FilmstripViewController
    private let state: LibraryState
    private var filmstripHeight: NSLayoutConstraint!

    init(store: CatalogStore, state: LibraryState) {
        self.state = state
        main = MainSplitViewController(store: store, state: state)
        filmstrip = FilmstripViewController(store: store, state: state)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = NSView()
        addChild(main)
        addChild(filmstrip)
        for view in [main.view, filmstrip.view] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        filmstripHeight = filmstrip.view.heightAnchor.constraint(equalToConstant: currentFilmstripHeight)
        NSLayoutConstraint.activate([
            main.view.topAnchor.constraint(equalTo: container.topAnchor),
            main.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            main.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            filmstrip.view.topAnchor.constraint(equalTo: main.view.bottomAnchor),
            filmstrip.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            filmstrip.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            filmstrip.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            filmstripHeight,
        ])
        filmstrip.view.isHidden = !state.isFilmstripVisible
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        state.addObserver(self) { [weak self] change in
            if change == .filmstrip { self?.updateFilmstrip() }
        }
    }

    private var currentFilmstripHeight: CGFloat {
        state.isFilmstripVisible ? FilmstripViewController.height : 0
    }

    private func updateFilmstrip() {
        let visible = state.isFilmstripVisible
        if visible { filmstrip.view.isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            filmstripHeight.constant = currentFilmstripHeight
            view.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            // Animation completion handlers run on the main thread.
            MainActor.assumeIsolated {
                guard let self, !self.state.isFilmstripVisible else { return }
                self.filmstrip.view.isHidden = true
            }
        }
    }

    /// The sidebar belongs to the inner split view; route the toolbar and menu toggle to it.
    @objc func toggleSidebar(_ sender: Any?) {
        main.toggleSidebar(sender)
    }
}
