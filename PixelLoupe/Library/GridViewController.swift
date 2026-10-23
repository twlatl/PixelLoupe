import AppKit
import CoreData

/// The Library photo grid.
///
/// Backed by an `NSFetchedResultsController` whose diffable snapshots drive an
/// `NSCollectionViewDiffableDataSource`, so imports, filter changes and re-sorting animate
/// without reloading the whole grid. Rows are batch-faulted to keep memory flat for large catalogs.
final class GridViewController: NSViewController, NSCollectionViewDelegate, NSFetchedResultsControllerDelegate,
                                NSMenuItemValidation, PhotoCollectionViewDelegate {
    private let store: CatalogStore
    private let state: LibraryState
    private let collectionView = PhotoCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private var dataSource: NSCollectionViewDiffableDataSource<String, NSManagedObjectID>!
    private var fetchedResultsController: NSFetchedResultsController<Photo>!
    private var isRefetching = false
    /// A publish service's photos grouped by state, while the grid shows one (RAW-179).
    private(set) var publishGroups: PublishGroups?
    /// The publish groups collapsed to their heading (for this window, until it closes).
    private(set) var collapsedPublishGroups: Set<PublishedPhoto.State> = []
    private var publishRegroupScheduled = false
    /// Called with the publish groups each time they change (nil when the grid leaves a publish service).
    var onPublishGroupsChange: ((PublishGroups?) -> Void)?
    private var editing: PhotoEditing { PhotoEditing(store: store) }

    init(store: CatalogStore, state: LibraryState) {
        self.store = store
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var preferredFirstResponder: NSResponder? { collectionView }

    override func loadView() {
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

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
        collectionView.photoDelegate = self
        collectionView.register(PhotoGridItem.self, forItemWithIdentifier: PhotoGridItem.identifier)
        collectionView.setAccessibilityIdentifier("photoGrid")

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // The grid floats on the matte, which follows the theme and the Matte Color setting.
        let matte = MatteView()
        matte.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: matte.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: matte.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: matte.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: matte.bottomAnchor),
        ])
        matte.onMatteChange = { [weak self] in self?.refreshCellColors() }
        view = matte
    }

    private var hasScrolledToRestoredSelection = false

    /// Brings a selection restored from the last session into view.
    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasScrolledToRestoredSelection else { return }
        hasScrolledToRestoredSelection = true
        view.layoutSubtreeIfNeeded()
        scrollToSelection()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateItemSize()

        let thumbnails = store.thumbnails
        let context = store.viewContext
        let availability = store.availability
        dataSource = NSCollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, objectID in
            let item = collectionView.makeItem(withIdentifier: PhotoGridItem.identifier, for: indexPath)
            if let item = item as? PhotoGridItem, let photo = try? context.existingObject(with: objectID) as? Photo {
                item.configure(with: photo, thumbnails: thumbnails, isMissing: availability.isMissing(photo.id),
                               publishError: self?.publishGroups?.errors[objectID])
            }
            return item
        }
        collectionView.register(PublishSectionHeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: PublishSectionHeaderView.identifier)
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: PublishSectionHeaderView.identifier, for: indexPath)
            let header = view as? PublishSectionHeaderView ?? PublishSectionHeaderView()
            self?.configure(header, section: indexPath.section)
            return header
        }

        let request = Photo.fetchRequest()
        request.fetchBatchSize = 300
        request.predicate = state.filter.predicate
        request.sortDescriptors = state.filter.sortDescriptors
        fetchedResultsController = NSFetchedResultsController(
            fetchRequest: request, managedObjectContext: context, sectionNameKeyPath: nil, cacheName: nil
        )
        fetchedResultsController.delegate = self
        refetch()

        state.addObserver(self) { [weak self] change in
            switch change {
            case .filter: self?.refetch()
            case .thumbnailSize: self?.updateItemSize()
            case .selection: self?.followSelection()
            case .presentation: if self?.state.presentation == .grid { self?.scrollToSelection() }
            case .hoverTracking: self?.updateHoverTracking()
            default: break
            }
        }
        collectionView.registerForDraggedTypes([.pixelLoupePhotos])
        updateHoverTracking()
        NotificationCenter.default.addObserver(
            self, selector: #selector(contextObjectsDidChange(_:)),
            name: .NSManagedObjectContextObjectsDidChange, object: context
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(thumbnailDidUpdate(_:)),
            name: ThumbnailStore.didUpdateNotification, object: store.thumbnails
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

    /// Repaints cells after a theme or Matte Color change.
    private func refreshCellColors() {
        for item in collectionView.visibleItems() {
            item.view.needsDisplay = true
        }
    }

    /// Shows a re-rendered thumbnail after its photo is edited in Develop.
    @objc private func thumbnailDidUpdate(_ notification: Notification) {
        guard let id = notification.userInfo?["id"] as? UUID else { return }
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard let objectID = dataSource.itemIdentifier(for: indexPath),
                  let photo = try? store.viewContext.existingObject(with: objectID) as? Photo,
                  photo.id == id,
                  let item = collectionView.item(at: indexPath) as? PhotoGridItem else { continue }
            item.configure(with: photo, thumbnails: store.thumbnails, isMissing: store.availability.isMissing(photo.id), reloadThumbnail: true,
                           publishError: publishGroups?.errors[objectID])
        }
    }

    // MARK: - Fetching

    private func refetch() {
        fetchedResultsController.fetchRequest.predicate = state.filter.predicate
        fetchedResultsController.fetchRequest.sortDescriptors = state.filter.sortDescriptors
        isRefetching = true
        defer { isRefetching = false }
        do {
            try fetchedResultsController.performFetch()
        } catch {
            NSApp.presentError(error)
        }
        apply(snapshot(of: customOrdered(fetchedResultsController.fetchedObjects?.map(\.objectID) ?? [])), animated: false)
    }

    /// The grid's photos in one section, or for a publish service, in a section for each of its groups.
    private func snapshot(of ids: [NSManagedObjectID]) -> NSDiffableDataSourceSnapshot<String, NSManagedObjectID> {
        var snapshot = NSDiffableDataSourceSnapshot<String, NSManagedObjectID>()
        guard let serviceID = state.filter.scope.publishServiceID,
              let service = PublishService.with(id: serviceID, in: store.viewContext) else {
            publishGroups = nil
            onPublishGroupsChange?(nil)
            layout.headerReferenceSize = .zero
            snapshot.appendSections([""])
            snapshot.appendItems(ids)
            return snapshot
        }
        let groups = PublishGroups(service: service, photoIDs: ids, context: store.viewContext)
        publishGroups = groups
        onPublishGroupsChange?(groups)
        layout.headerReferenceSize = NSSize(width: 0, height: PublishSectionHeaderView.height)
        for state in PublishedPhoto.State.allCases where groups.count(of: state) > 0 {
            let section = Self.section(for: state)
            snapshot.appendSections([section])
            if !collapsedPublishGroups.contains(state) {
                snapshot.appendItems(groups.groups.first { $0.state == state }?.photoIDs ?? [], toSection: section)
            }
        }
        return snapshot
    }

    /// Shows a publish group's heading: its title, count and whether it's collapsed.
    private func configure(_ header: PublishSectionHeaderView, section index: Int) {
        guard let section = dataSource.snapshot().sectionIdentifiers.dropFirst(index).first,
              let state = Self.publishState(forSection: section), let groups = publishGroups else { return }
        let orphans = state == .deleted && groups.deletedFromCatalog > 0
            ? "\(groups.deletedFromCatalog.formatted()) no longer in the catalog" : nil
        header.show(state, count: groups.count(of: state), isCollapsed: collapsedPublishGroups.contains(state), note: orphans)
        header.onToggle = { [weak self] in self?.togglePublishGroup(state) }
    }

    /// Brings the visible headings' counts and the photos' error badges up to date after a regroup.
    /// (Not with the snapshot's `reloadSections`: reloading a group that's only now appearing, as Published
    /// does after the first Publish, makes the collection view throw.)
    private func refreshPublishDecorations() {
        guard publishGroups != nil else { return }
        let kind = NSCollectionView.elementKindSectionHeader
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let header = collectionView.supplementaryView(forElementKind: kind, at: indexPath) as? PublishSectionHeaderView else { continue }
            configure(header, section: indexPath.section)
        }
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard let id = dataSource.itemIdentifier(for: indexPath),
                  let item = collectionView.item(at: indexPath) as? PhotoGridItem else { continue }
            item.cellView.setPublishError(publishGroups?.errors[id])
        }
    }

    private static func section(for state: PublishedPhoto.State) -> String { "publish.\(state)" }

    private static func publishState(forSection section: String) -> PublishedPhoto.State? {
        PublishedPhoto.State.allCases.first { Self.section(for: $0) == section }
    }

    /// Collapses or expands a publish group.
    func togglePublishGroup(_ state: PublishedPhoto.State) {
        if collapsedPublishGroups.contains(state) { collapsedPublishGroups.remove(state) } else { collapsedPublishGroups.insert(state) }
        regroupPublishService()
    }

    /// Regroups a publish service's photos after their states changed (an edit, a Publish).
    func regroupPublishService() {
        guard state.filter.scope.publishServiceID != nil else { return }
        apply(snapshot(of: customOrdered(fetchedResultsController.fetchedObjects?.map(\.objectID) ?? [])), animated: true)
    }

    func controller(
        _ controller: NSFetchedResultsController<any NSFetchRequestResult>,
        didChangeContentWith snapshot: NSDiffableDataSourceSnapshotReference
    ) {
        guard !isRefetching else { return }
        var snapshot = snapshot as NSDiffableDataSourceSnapshot<String, NSManagedObjectID>
        if state.filter.scope.publishServiceID != nil {
            apply(self.snapshot(of: snapshot.itemIdentifiers), animated: true)
            return
        }
        if state.filter.sortKey == .customOrder {
            let items = customOrdered(snapshot.itemIdentifiers)
            snapshot.deleteItems(snapshot.itemIdentifiers)
            snapshot.appendItems(items)
        }
        apply(snapshot, animated: true)
    }

    // MARK: - Custom order

    /// The collection whose custom order the grid is showing, if that's the sort.
    private var customOrderCollection: PhotoCollection? {
        guard state.filter.sortKey == .customOrder, let id = state.filter.scope.membersCollectionID else { return nil }
        return PhotoCollection.with(id: id, in: store.viewContext)
    }

    /// `ids` in the collection's custom order (reversed when sorting descending). Elsewhere, as given.
    private func customOrdered(_ ids: [NSManagedObjectID]) -> [NSManagedObjectID] {
        guard let collection = customOrderCollection else { return ids }
        // Work from the ascending (capture time) order, so unlisted photos fall in a fixed place and
        // descending is exactly the reverse.
        let ascending = state.filter.ascending ? ids : ids.reversed()
        let photos = ascending.compactMap { id in (try? store.viewContext.existingObject(with: id) as? Photo).map { (item: id, id: $0.id) } }
        let sorted = CustomOrder.sorted(photos, by: collection.customOrder)
        return state.filter.ascending ? sorted : sorted.reversed()
    }

    /// The photos being dragged within the grid, for reordering.
    private var draggedIndexPaths: Set<IndexPath> = []

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        draggedIndexPaths = indexPaths
    }

    func collectionView(
        _ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        // Only dragging within the grid, in a collection sorted by Custom Order.
        guard customOrderCollection != nil, draggingInfo.draggingSource as? NSCollectionView === collectionView else { return [] }
        proposedDropOperation.pointee = .before
        return .move
    }

    func collectionView(
        _ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard let collection = customOrderCollection else { return false }
        let ids = state.photoOrder
        let current = ids.compactMap { try? store.viewContext.existingObject(with: $0) as? Photo }.map(\.id)
        guard current.count == ids.count else { return false }
        // Display order may be reversed: work in the order the grid shows, then store ascending.
        let moving = draggedIndexPaths.map(\.item).sorted().filter { $0 < current.count }.map { current[$0] }
        guard !moving.isEmpty else { return false }
        var shown = CustomOrder.moved(moving, to: indexPath.item, in: current)
        if !state.filter.ascending { shown.reverse() }
        editing.performUndoable("Reorder Photos") { collection.customOrder = shown }
        draggedIndexPaths = []
        refetch()
        return true
    }

    /// The source's photo count before the filter bar's criteria: the photos shown when nothing
    /// filters, or a count query (no objects fetched) when something does.
    private func updateScopePhotoCount(shown: Int) {
        guard state.filter.isFiltering else {
            state.scopePhotoCount = shown
            return
        }
        let request = Photo.fetchRequest()
        request.predicate = state.filter.scopePredicate
        state.scopePhotoCount = (try? store.viewContext.count(for: request)) ?? shown
    }

    private func apply(_ snapshot: NSDiffableDataSourceSnapshot<String, NSManagedObjectID>, animated: Bool) {
        let selected = Set(state.selectedPhotoIDs)
        dataSource.apply(snapshot, animatingDifferences: animated && view.window != nil)
        refreshPublishDecorations()
        updateScopePhotoCount(shown: snapshot.numberOfItems)
        state.photoOrder = snapshot.itemIdentifiers

        // Preserve selection across re-sorts and filter changes where those photos remain visible.
        let indexPaths = Set(selected.compactMap { dataSource.indexPath(for: $0) })
        collectionView.selectionIndexPaths = indexPaths
        syncSelection()
    }

    /// Refreshes visible cells for photos whose rating, flag or tags changed (including via undo
    /// and merges from background contexts).
    @objc private func contextObjectsDidChange(_ notification: Notification) {
        if state.filter.scope.publishServiceID != nil, !publishRegroupScheduled,
           [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey, NSRefreshedObjectsKey].contains(where: { key in
               (notification.userInfo?[key] as? Set<NSManagedObject>)?.contains { $0 is PublishedPhoto || $0 is PublishService || $0 is Photo } ?? false
           }) {
            // A Publish changes many photos' states at once: regroup once, after them.
            publishRegroupScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.publishRegroupScheduled = false
                self?.regroupPublishService()
            }
        }
        var changed = Set<NSManagedObjectID>()
        for key in [NSUpdatedObjectsKey, NSRefreshedObjectsKey] {
            for object in notification.userInfo?[key] as? Set<NSManagedObject> ?? [] {
                if object is Photo {
                    changed.insert(object.objectID)
                } else if let stack = object as? PhotoStack, !stack.isDeleted {
                    // A stack's count badge is on its top photo, which the change may not have touched.
                    stack.photos.forEach { changed.insert($0.objectID) }
                }
            }
        }
        guard !changed.isEmpty else { return }
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard let id = dataSource.itemIdentifier(for: indexPath), changed.contains(id),
                  let item = collectionView.item(at: indexPath) as? PhotoGridItem,
                  let photo = try? store.viewContext.existingObject(with: id) as? Photo else { continue }
            item.configure(with: photo, thumbnails: store.thumbnails, isMissing: store.availability.isMissing(photo.id),
                           publishError: publishGroups?.errors[id])
        }
    }

    /// Shows or clears the missing badges after the files' availability changed.
    @objc private func availabilityDidChange(_ notification: Notification) {
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard let id = dataSource.itemIdentifier(for: indexPath),
                  let photo = try? store.viewContext.existingObject(with: id) as? Photo,
                  let item = collectionView.item(at: indexPath) as? PhotoGridItem else { continue }
            item.configure(with: photo, thumbnails: store.thumbnails, isMissing: store.availability.isMissing(photo.id),
                           publishError: publishGroups?.errors[id])
        }
    }

    // MARK: - Layout

    private func updateItemSize() {
        let side = state.thumbnailSize.rounded()
        layout.itemSize = NSSize(width: side, height: side + PhotoGridItem.footerHeight)
        layout.invalidateLayout()
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
        state.selectedPhotoIDs = collectionView.selectionIndexPaths.sorted().compactMap {
            dataSource.itemIdentifier(for: $0)
        }
    }

    /// Mirrors selection changes made elsewhere, such as stepping through photos while enlarged.
    private func followSelection() {
        let indexPaths = Set(state.selectedPhotoIDs.compactMap { dataSource.indexPath(for: $0) })
        guard indexPaths != collectionView.selectionIndexPaths else { return }
        collectionView.selectionIndexPaths = indexPaths
        scrollToSelection()
    }

    private func scrollToSelection() {
        guard let first = state.selectedPhotoIDs.first, let indexPath = dataSource.indexPath(for: first) else { return }
        collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestHorizontalEdge)
    }

    private var selectedPhotos: [Photo] {
        state.selectedPhotoIDs.compactMap { try? store.viewContext.existingObject(with: $0) as? Photo }
    }

    // MARK: - PhotoCollectionViewDelegate

    func collectionView(_ collectionView: PhotoCollectionView, menuForItemAt indexPath: IndexPath) -> NSMenu? {
        if !collectionView.selectionIndexPaths.contains(indexPath) {
            collectionView.selectionIndexPaths = [indexPath]
            syncSelection()
        }
        return contextMenu(clickedPhoto: dataSource.itemIdentifier(for: indexPath))
    }

    /// Double-click enlarges the photo to fill the grid area, like Return.
    func collectionView(_ collectionView: PhotoCollectionView, didDoubleClickItemAt indexPath: IndexPath) {
        collectionView.selectionIndexPaths = [indexPath]
        syncSelection()
        state.presentation = .loupe
    }

    // MARK: - Editing

    /// `clickedPhoto`: the photo the menu was opened on (Sync Settings copies from it).
    func contextMenu(clickedPhoto: NSManagedObjectID? = nil) -> NSMenu {
        let photos = selectedPhotos
        let menu = NSMenu()

        let ratings = Set(photos.map(\.rating))
        let ratingMenu = NSMenu(title: "Rating")
        for item in RatingFormatter.ratingItems(target: self) {
            if item.action == #selector(setRatingFromMenu(_:)) { item.state = ratings == [Int16(item.tag)] ? .on : .off }
            ratingMenu.addItem(item)
        }
        let ratingItem = NSMenuItem(title: "Rating", action: nil, keyEquivalent: "")
        ratingItem.submenu = ratingMenu
        menu.addItem(ratingItem)

        let flags = Set(photos.map(\.photoFlag))
        let labels = Set(photos.map(\.label))
        let labelMenu = NSMenu(title: "Color Label")
        for label in ColorLabel.allCases {
            let item = NSMenuItem(title: label.title, action: #selector(setColorLabelFromMenu(_:)), keyEquivalent: "")
            item.tag = Int(label.rawValue)
            item.target = self
            item.state = labels == [label] ? .on : .off
            if label != .none {
                item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: label.title)?
                    .withSymbolConfiguration(.init(paletteColors: [label.color]))
            }
            labelMenu.addItem(item)
        }
        let labelItem = NSMenuItem(title: "Color Label", action: nil, keyEquivalent: "")
        labelItem.submenu = labelMenu
        menu.addItem(labelItem)

        menu.addItem(.separator())
        for item in RatingFormatter.flagItems(target: self) {
            item.state = flags == [PhotoFlag(rawValue: Int16(item.tag)) ?? .unflagged] ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Create Virtual Copy", action: #selector(PixelLoupeActions.createVirtualCopy(_:)), keyEquivalent: ""))
        if photos.count == 1, photos[0].isVirtualCopy {
            menu.addItem(NSMenuItem(title: "Set Copy as Master", action: #selector(PixelLoupeActions.setCopyAsMaster(_:)), keyEquivalent: ""))
        }
        // Handled by the catalog window, like Photo ▸ Photo Merge.
        menu.addItem(MainMenu.photoMergeItem())
        menu.addItem(MainMenu.editInItem())
        menu.addItem(.separator())
        // Handled by the catalog window: the cursor goes to the right sidebar's Keywords field.
        menu.addItem(NSMenuItem(title: "Add Keywords…", action: #selector(PixelLoupeActions.addKeywords(_:)), keyEquivalent: ""))
        let tagPaths = Set(photos.flatMap(\.tagPaths)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if !tagPaths.isEmpty {
            let removeMenu = NSMenu(title: "Remove Keyword")
            for path in tagPaths {
                let item = NSMenuItem(title: path, action: #selector(removeTag(_:)), keyEquivalent: "")
                item.representedObject = path
                item.target = self
                removeMenu.addItem(item)
            }
            let removeItem = NSMenuItem(title: "Remove Keyword", action: nil, keyEquivalent: "")
            removeItem.submenu = removeMenu
            menu.addItem(removeItem)
        }

        menu.addItem(.separator())
        // Collections, handled by the catalog window.
        if let windowController = view.window?.windowController as? CatalogWindowController {
            let add = NSMenuItem(title: "Add to Collection", action: nil, keyEquivalent: "")
            add.submenu = windowController.addToCollectionMenu()
            menu.addItem(add)
            if windowController.isShowingCollection {
                menu.addItem(NSMenuItem(title: "Remove from Collection", action: #selector(PixelLoupeActions.removeFromCollection(_:)), keyEquivalent: ""))
            }
            let services = windowController.addToPublishServiceMenu()
            if !services.items.isEmpty {
                let publish = NSMenuItem(title: "Add to Publish Service", action: nil, keyEquivalent: "")
                publish.submenu = services
                menu.addItem(publish)
            }
            if state.filter.scope.publishServiceID != nil {
                menu.addItem(NSMenuItem(title: "Remove from Publish Service", action: #selector(PixelLoupeActions.removeFromPublishService(_:)),
                                        keyEquivalent: ""))
            }
            let develop = NSMenuItem(title: "Develop Settings", action: nil, keyEquivalent: "")
            develop.submenu = windowController.developSettingsMenu(clickedPhoto: clickedPhoto)
            develop.setAccessibilityIdentifier("contextDevelopSettings")
            menu.addItem(develop)
        }

        menu.addItem(.separator())
        // Handled (and confirmed) by the catalog window, like Photo ▸ Remove Photo.
        let remove = NSMenuItem(title: "Remove Photo…", action: #selector(PixelLoupeActions.removePhoto(_:)), keyEquivalent: "")
        remove.setAccessibilityIdentifier("contextRemovePhoto")
        menu.addItem(remove)
        let reveal = NSMenuItem(title: "Show in Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        return menu
    }

    @objc func setRatingFromMenu(_ sender: NSMenuItem) {
        editing.setRating(sender.tag, for: state.selectedPhotoIDs)
    }

    @objc func setColorLabelFromMenu(_ sender: NSMenuItem) {
        editing.setColorLabel(ColorLabel(rawValue: Int16(sender.tag)) ?? .none, for: state.selectedPhotoIDs)
    }

    @objc func decreaseRating(_ sender: Any?) {
        editing.adjustRating(by: -1, for: state.selectedPhotoIDs)
    }

    @objc func increaseRating(_ sender: Any?) {
        editing.adjustRating(by: 1, for: state.selectedPhotoIDs)
    }

    @objc func setFlagFromMenu(_ sender: NSMenuItem) {
        editing.setFlag(PhotoFlag(rawValue: Int16(sender.tag)) ?? .unflagged, for: state.selectedPhotoIDs)
    }

    @objc private func removeTag(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        edit(actionName: "Remove Keyword") { photo in
            for tag in photo.tags where tag.displayPath == path { photo.tags.remove(tag) }
        }
    }

    @objc func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting(selectedPhotos.map(\.fileURL))
    }

    private func edit(actionName: String, _ change: (Photo) -> Void) {
        editing.edit(state.selectedPhotoIDs, actionName: actionName, change)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(setRatingFromMenu(_:)), #selector(setFlagFromMenu(_:)), #selector(decreaseRating(_:)),
             #selector(increaseRating(_:)), #selector(revealInFinder(_:)):
            return !state.selectedPhotoIDs.isEmpty
        default:
            return true
        }
    }
}
