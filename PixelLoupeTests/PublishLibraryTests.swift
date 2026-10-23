import AppKit
import CoreData
import Testing
@testable import PixelLoupe

/// A catalog with a Hard Drive service holding a photo in each state, and one photo not in it.
@MainActor
private struct PublishLibrary {
    let directory: TemporaryDirectory
    let store: CatalogStore
    let service: PublishService
    /// By file name.
    let photos: [String: Photo]
    var context: NSManagedObjectContext { store.viewContext }

    init() throws {
        directory = try TemporaryDirectory()
        store = try CatalogStore.create(at: directory.url.appending(path: "C.pixelloupe", directoryHint: .isDirectory), info: Fixtures.referencedInfo)
        let context = store.viewContext
        var photos: [String: Photo] = [:]
        for (index, name) in ["New.jpg", "Modified.jpg", "Published.jpg", "Removed.jpg", "Elsewhere.jpg"].enumerated() {
            let photo = Photo(context: context)
            photo.id = UUID()
            photo.fileName = name
            photo.filePath = directory.url.appending(path: name).path(percentEncoded: false)
            photo.fileType = "JPG"
            photo.captureDate = Date(timeIntervalSince1970: Double(index))
            photo.importDate = .now
            photo.editDate = Date(timeIntervalSince1970: 0)
            photos[name] = photo
        }
        service = PublishService.make(.hardDrive, in: context)
        service.name = "Backup"
        service.add(["New.jpg", "Modified.jpg", "Published.jpg", "Removed.jpg"].map { photos[$0]! })
        for name in ["Modified.jpg", "Published.jpg", "Removed.jpg"] {
            let entry = service.entry(for: photos[name]!)!
            entry.publishedDate = Date(timeIntervalSince1970: 100)
            entry.remoteID = "/Published/\(name)"
            entry.metadataFingerprint = PublishedPhoto.fingerprint(photos[name]!)
        }
        photos["Modified.jpg"]!.editDate = Date(timeIntervalSince1970: 200)
        service.remove([photos["Removed.jpg"]!])
        service.entry(for: photos["New.jpg"]!)!.lastError = "The disk is full."
        self.photos = photos
        store.save()
    }

    func ids(_ names: String...) -> [NSManagedObjectID] { names.map { photos[$0]!.objectID } }
}

@Suite("Publish services in the Library")
@MainActor
struct PublishLibraryTests {
    init() {
        Defaults.store.removeObject(forKey: "CollapsedSidebarHeaders")
    }

    private func names(_ ids: [NSManagedObjectID], _ library: PublishLibrary) -> [String] {
        ids.compactMap { id in library.photos.first { $0.value.objectID == id }?.key }
    }

    @Test func photosAreGroupedByState() throws {
        let library = try PublishLibrary()
        let all = library.ids("New.jpg", "Modified.jpg", "Published.jpg", "Removed.jpg")
        let groups = PublishGroups(service: library.service, photoIDs: all, context: library.context)
        #expect(groups.groups.map(\.state) == [.new, .modified, .published, .deleted])
        #expect(groups.groups.map { names($0.photoIDs, library) } == [["New.jpg"], ["Modified.jpg"], ["Published.jpg"], ["Removed.jpg"]])
        #expect(groups.errors == [library.photos["New.jpg"]!.objectID: "The disk is full."])
        #expect(groups.hasWork)

        library.context.delete(library.photos["Published.jpg"]!)
        library.store.save()
        let afterDelete = PublishGroups(service: library.service, photoIDs: library.ids("New.jpg", "Modified.jpg", "Removed.jpg"), context: library.context)
        #expect(afterDelete.deletedFromCatalog == 1)
        #expect(afterDelete.count(of: .deleted) == 2, "the removed photo, and the one deleted from the catalog")
    }

    @Test func theScopeHoldsEveryPhotoInTheServiceStackedOrNot() throws {
        let library = try PublishLibrary()
        library.photos["Published.jpg"]!.isHiddenInStack = true
        library.store.save()
        var filter = LibraryFilter()
        filter.scope = .publishService(id: library.service.id)
        let request = Photo.fetchRequest()
        request.predicate = filter.predicate
        let names = try library.context.fetch(request).map(\.fileName).sorted()
        #expect(names == ["Modified.jpg", "New.jpg", "Published.jpg", "Removed.jpg"])
    }

    @Test func addingAndRemovingPhotosIsUndoable() throws {
        let library = try PublishLibrary()
        let undo = try #require(library.context.undoManager)
        undo.removeAllActions()
        let editing = PublishEditing(store: library.store)
        editing.add(library.ids("Elsewhere.jpg"), to: library.service.id)
        #expect(undo.undoActionName == "Add to Backup")
        #expect(library.service.entry(for: library.photos["Elsewhere.jpg"]!)?.state == .new)
        undo.undo()
        #expect(library.service.entry(for: library.photos["Elsewhere.jpg"]!) == nil)

        editing.remove(library.ids("Published.jpg", "New.jpg"), from: library.service.id)
        #expect(library.service.entry(for: library.photos["Published.jpg"]!)?.state == .deleted)
        #expect(library.service.entry(for: library.photos["New.jpg"]!) == nil, "never published: it just goes")
    }

    private func window(_ library: PublishLibrary) -> CatalogWindowController {
        let controller = CatalogWindowController(store: library.store)
        controller.showWindow(nil)
        controller.window?.layoutIfNeeded()
        return controller
    }

    @Test func theSidebarListsServicesUnderPublishing() throws {
        let library = try PublishLibrary()
        let controller = window(library)
        defer { controller.close() }
        let outline = try #require(controller.window!.contentView!.descendants.compactMap { $0 as? NSOutlineView }.first)
        let items = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SidebarViewController.Item }
        let titles = items.map(\.title)
        let publishing = try #require(titles.firstIndex(of: "Publishing"))
        #expect(titles[publishing + 1] == "Backup")
        let row = try #require(items.first { $0.publishServiceID == library.service.id })
        #expect(row.count == 3, "the removed photo waits to go, and isn't counted")
        #expect(row.scope == .publishService(id: library.service.id))
    }

    // MARK: - The service's menu (RAW-184)

    @Test func theServiceMenuIsLightrooms() throws {
        let library = try PublishLibrary()
        let controller = window(library)
        defer { controller.close() }
        let menu = controller.rootViewController.main.sidebar.publishServiceMenu(id: library.service.id)
        #expect(menu.items.map { $0.isSeparatorItem ? "-" : $0.title } == [
            "Set as Target Collection", "-", "Reset Export Status…", "-", "Auto Stack…", "-", "Add Color Label to Service", "-",
            "Publish Now", "Mark to Republish", "Show in Finder", "-", "Edit Settings…", "Publishing Manager…",
        ])
        for item in menu.items where item.action != nil && !item.hasSubmenu && item.title != "Publishing Manager…" {
            #expect(item.representedObject as? UUID == library.service.id, "\(item.title)")
        }
        for item in menu.items where item.action != nil && !item.hasSubmenu && item.title != "Publishing Manager…" {
            #expect(controller.validateUserInterfaceItem(item), "\(item.title)")
        }

        let flickr = PublishService.make(.flickr, in: library.context)
        library.store.save()
        let flickrMenu = controller.rootViewController.main.sidebar.publishServiceMenu(id: flickr.id)
        let show = try #require(flickrMenu.items.first { $0.title == "Show in Flickr" })
        #expect(!controller.validateUserInterfaceItem(show), "nobody has signed in")
        let republish = try #require(flickrMenu.items.first { $0.title == "Mark to Republish" })
        #expect(!controller.validateUserInterfaceItem(republish), "nothing has been published")
        let reset = try #require(flickrMenu.items.first { $0.title == "Reset Export Status…" })
        #expect(!controller.validateUserInterfaceItem(reset), "it has no photos")
    }

    @Test func aServiceCanBeTheTargetCollection() throws {
        let library = try PublishLibrary()
        let controller = window(library)
        defer { controller.close() }
        let sidebar = controller.rootViewController.main.sidebar
        let set = try #require(sidebar.publishServiceMenu(id: library.service.id).items.first)
        controller.setTargetCollection(set)
        #expect(library.store.viewState.targetCollectionID == library.service.id)
        #expect(sidebar.publishServiceMenu(id: library.service.id).items.first?.title == "Clear Target Collection")
        let outline = try #require(controller.window!.contentView!.descendants.compactMap { $0 as? NSOutlineView }.first)
        let row = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SidebarViewController.Item }
            .first { $0.publishServiceID == library.service.id }
        #expect(row?.isTarget == true)

        let item = NSMenuItem(title: "", action: #selector(PixelLoupeActions.addToTargetCollection(_:)), keyEquivalent: "")
        controller.state.selectedPhotoIDs = library.ids("Elsewhere.jpg")
        #expect(controller.validateUserInterfaceItem(item))
        #expect(item.title == "Add to Target Collection (Backup)")
        controller.addToTargetCollection(nil)
        #expect(library.service.entry(for: library.photos["Elsewhere.jpg"]!)?.state == .new)
        controller.addToTargetCollection(nil)
        #expect(library.service.entry(for: library.photos["Elsewhere.jpg"]!) == nil, "B again takes it out")
    }

    @Test func resetExportStatusMakesEveryPhotoNewAndUndoes() throws {
        let library = try PublishLibrary()
        let undo = try #require(library.context.undoManager)
        undo.removeAllActions()
        library.service.resetPublishStatus()
        undo.setActionName("Reset Export Status")
        library.store.save()
        let entries = library.service.publishedPhotos
        #expect(entries.count == 3, "the photo waiting to be removed is dropped")
        #expect(entries.allSatisfy { $0.state == .new && $0.remoteID == nil && $0.lastError == nil })
        undo.undo()
        #expect(library.service.entry(for: library.photos["Published.jpg"]!)?.state == .published)
        #expect(library.service.entry(for: library.photos["Removed.jpg"]!)?.state == .deleted)
    }

    @Test func markToRepublishMakesPublishedPhotosModified() throws {
        let library = try PublishLibrary()
        let controller = window(library)
        defer { controller.close() }
        let item = try #require(controller.rootViewController.main.sidebar.publishServiceMenu(id: library.service.id).items
            .first { $0.title == "Mark to Republish" })
        library.context.undoManager?.removeAllActions()
        controller.markToRepublish(item)
        #expect(library.service.entry(for: library.photos["Published.jpg"]!)?.state == .modified)
        #expect(library.service.entry(for: library.photos["New.jpg"]!)?.state == .new)
        #expect(library.context.undoManager?.undoActionName == "Mark to Republish")
        library.context.undoManager?.undo()
        #expect(library.service.entry(for: library.photos["Published.jpg"]!)?.state == .published)
    }

    @Test func aServiceTakesAColorLabel() async throws {
        let library = try PublishLibrary()
        let controller = window(library)
        defer { controller.close() }
        let sidebar = controller.rootViewController.main.sidebar
        let labels = try #require(sidebar.publishServiceMenu(id: library.service.id).items.first { $0.title == "Add Color Label to Service" }?.submenu)
        #expect(labels.items.first?.state == .on, "No Label")
        let red = try #require(labels.items.first { $0.title == ColorLabel.red.title })
        controller.setPublishServiceColorLabel(red)
        #expect(library.service.label == .red)
        try await Task.sleep(for: .seconds(SidebarViewController.reloadDelay + 0.5))
        let outline = try #require(controller.window!.contentView!.descendants.compactMap { $0 as? NSOutlineView }.first)
        let row = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SidebarViewController.Item }
            .first { $0.publishServiceID == library.service.id }
        #expect(row?.label == .red)
        let again = sidebar.publishServiceMenu(id: library.service.id).items.first { $0.title == "Add Color Label to Service" }?.submenu
        #expect(again?.items.first { $0.title == ColorLabel.red.title }?.state == .on)
    }

    @Test func autoStackWorksOnTheServicesPhotos() throws {
        let library = try PublishLibrary()
        let controller = window(library)
        defer { controller.close() }
        controller.state.filter.scope = .publishService(id: library.service.id)
        let photos = controller.rootViewController.main.inspector.autoStackPhotos()
        #expect(photos.photos.map(\.fileName) == ["New.jpg", "Modified.jpg", "Published.jpg", "Removed.jpg"])
        #expect(!photos.isSelection)
    }

    @Test func theGridShowsTheServicesGroupsAndTheyCollapse() throws {
        let library = try PublishLibrary()
        let controller = window(library)
        defer { controller.close() }
        controller.state.filter.scope = .publishService(id: library.service.id)
        let grid = controller.rootViewController.main.library.grid
        #expect(grid.publishGroups?.groups.map(\.state) == [.new, .modified, .published, .deleted])
        #expect(names(controller.state.photoOrder, library) == ["New.jpg", "Modified.jpg", "Published.jpg", "Removed.jpg"])
        grid.togglePublishGroup(.published)
        #expect(names(controller.state.photoOrder, library) == ["New.jpg", "Modified.jpg", "Removed.jpg"])
        grid.togglePublishGroup(.published)

        let bar = controller.rootViewController.main.library.publishBar
        #expect(!bar.view.isHidden && bar.publishButton.isEnabled)

        controller.state.filter.scope = .allPhotos
        #expect(grid.publishGroups == nil)
        #expect(bar.view.isHidden)
        #expect(controller.state.photoOrder.count == 5)
    }

    /// Publishing moves photos from New to Published while the grid shows the service, so its sections
    /// change under it (the first Publish crashed the app here).
    @Test func theGridFollowsAPublishThatChangesItsGroups() async throws {
        let library = try PublishLibrary()
        let only = PublishService.make(.hardDrive, in: library.context)
        only.add([library.photos["Elsewhere.jpg"]!])
        library.store.save()
        let controller = window(library)
        defer { controller.close() }
        controller.state.filter.scope = .publishService(id: only.id)
        let grid = controller.rootViewController.main.library.grid
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        #expect(grid.publishGroups?.groups.map(\.state) == [.new])

        let entry = try #require(only.entry(for: library.photos["Elsewhere.jpg"]!))
        entry.publishedDate = .now
        entry.remoteID = "/Published/Elsewhere.jpg"
        entry.metadataFingerprint = PublishedPhoto.fingerprint(library.photos["Elsewhere.jpg"]!)
        library.store.save()
        grid.regroupPublishService()
        #expect(grid.publishGroups?.groups.map(\.state) == [.published])
        #expect(names(controller.state.photoOrder, library) == ["Elsewhere.jpg"])

        // And back, through the change notification, as an edit does.
        library.photos["Elsewhere.jpg"]!.editDate = .now
        library.store.save()
        for _ in 0..<5 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(grid.publishGroups?.groups.map(\.state) == [.modified])
    }

    @Test func gridItemsShowWhyPublishingFailed() throws {
        let library = try PublishLibrary()
        let controller = window(library)
        defer { controller.close() }
        controller.state.filter.scope = .publishService(id: library.service.id)
        let collectionView = try #require(controller.window!.contentView!.descendants.compactMap { $0 as? NSCollectionView }.first)
        collectionView.layoutSubtreeIfNeeded()
        let cells = collectionView.visibleItems().compactMap { item in
            ([item.view] + item.view.descendants).lazy.compactMap { $0 as? PhotoGridCellView }.first
        }
        #expect(cells.count == 4)
        let badges = cells.filter { !$0.publishErrorBadge.isHidden }
        #expect(badges.count == 1)
        #expect(badges.first?.publishErrorBadge.toolTip == "Couldn’t publish: The disk is full.")
    }

    @Test func theContextMenuAddsToAndRemovesFromServices() throws {
        let library = try PublishLibrary()
        let controller = window(library)
        defer { controller.close() }
        controller.state.selectedPhotoIDs = library.ids("Elsewhere.jpg")
        let menu = controller.rootViewController.main.library.grid.contextMenu()
        let add = try #require(menu.items.first { $0.title == "Add to Publish Service" }?.submenu?.items.first)
        #expect(add.title == "Backup")
        controller.addToPublishService(add)
        #expect(library.service.entry(for: library.photos["Elsewhere.jpg"]!) != nil)
        #expect(!menu.items.contains { $0.title == "Remove from Publish Service" }, "only while showing a service")

        controller.state.filter.scope = .publishService(id: library.service.id)
        controller.state.selectedPhotoIDs = library.ids("Elsewhere.jpg")
        let serviceMenu = controller.rootViewController.main.library.grid.contextMenu()
        #expect(serviceMenu.items.contains { $0.title == "Remove from Publish Service" })
        controller.removeFromPublishService(nil)
        #expect(library.service.entry(for: library.photos["Elsewhere.jpg"]!) == nil)
    }

    @Test func publishSummariesListWhatFailed() {
        var result = PublishRun.Result()
        result.failures = (1...12).map { "IMG_\($0).jpg: Can’t write." }
        let alert = CatalogWindowController.publishSummary(result, service: "Backup")
        #expect(alert.messageText == "12 photos couldn’t be published to Backup.")
        #expect(alert.informativeText.contains("…and 2 more."))
    }
}
