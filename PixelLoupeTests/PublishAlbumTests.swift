import AppKit
import CoreData
import Synchronization
import Testing
@testable import PixelLoupe

/// Publishes and makes albums, recording each call ("publish P0", "create Harbour P0", "set A1 P0,P1"…).
/// A photo's ID is its file name without the extension; albums are A1, A2…
private final class FakeAlbumPublisher: AlbumPublisher {
    let calls = Mutex<[String]>([])
    private let albums = Mutex(0)

    var recorded: [String] { calls.withLock { $0 } }
    func clear() { calls.withLock { $0 = [] } }

    func publish(_ item: PublishItem) async throws -> RemotePhoto {
        let id = item.export.source.deletingPathExtension().lastPathComponent
        calls.withLock { $0.append("publish \(id)") }
        return RemotePhoto(id: id, url: nil)
    }

    func remove(_ photo: RemotePhoto) async throws {
        calls.withLock { $0.append("remove \(photo.id)") }
    }

    func createAlbum(title: String, description: String, coverID: String) async throws -> String {
        let id = "A" + String(albums.withLock { $0 += 1; return $0 })
        calls.withLock { $0.append("create \(title) \(coverID)") }
        return id
    }

    func editAlbum(_ id: String, title: String, description: String) async throws {
        calls.withLock { $0.append("edit \(id) \(title)") }
    }

    func setAlbumPhotos(_ id: String, photoIDs: [String]) async throws {
        calls.withLock { $0.append("set \(id) \(photoIDs.joined(separator: ","))") }
    }

    func deleteAlbum(_ id: String) async throws {
        calls.withLock { $0.append("delete \(id)") }
    }
}

/// A catalog with a Flickr service and four photos, P0…P3, taken in that order and rated 0…3.
@MainActor
private struct AlbumLibrary {
    let directory: TemporaryDirectory
    let store: CatalogStore
    let service: PublishService
    let photos: [Photo]
    let publisher = FakeAlbumPublisher()
    var context: NSManagedObjectContext { store.viewContext }

    init() throws {
        directory = try TemporaryDirectory()
        store = try CatalogStore.create(at: directory.url.appending(path: "C.pixelloupe", directoryHint: .isDirectory), info: Fixtures.referencedInfo)
        let context = store.viewContext
        let folder = directory.url
        photos = (0..<4).map { index in
            let photo = Photo(context: context)
            photo.id = UUID()
            photo.fileName = "P\(index).JPG"
            photo.filePath = folder.appending(path: photo.fileName).path(percentEncoded: false)
            photo.fileType = "JPG"
            photo.captureDate = Date(timeIntervalSince1970: Double(index))
            photo.importDate = .now
            photo.editDate = Date(timeIntervalSince1970: 0)
            photo.rating = Int16(index)
            return photo
        }
        service = PublishService.make(.flickr, in: store.viewContext)
        store.save()
    }

    func album(_ name: String = "Harbour", _ photos: [Photo] = []) -> PublishAlbum {
        let album = PublishAlbum.make(.album, named: name, in: service)
        album.add(photos)
        store.save()
        return album
    }

    @discardableResult
    func publish() async -> PublishRun.Result {
        publisher.clear()
        return await PublishRun.run(service, store: store, publisher: publisher)
    }

    /// The album calls of the last Publish (the photos are published two at a time, in no fixed order).
    var albumCalls: [String] { publisher.recorded.filter { !$0.hasPrefix("publish") && !$0.hasPrefix("remove") } }
}

@Suite("Flickr albums")
@MainActor
struct PublishAlbumTests {
    @Test func anAlbumsPhotosAreInItsService() throws {
        let library = try AlbumLibrary()
        let album = library.album("Harbour", Array(library.photos.prefix(2)))
        #expect(library.service.publishedPhotos.count == 2, "adding to an album adds to the service")
        #expect(album.photos().map(\.fileName).sorted() == ["P0.JPG", "P1.JPG"])
        album.remove([library.photos[0]])
        #expect(library.service.entry(for: library.photos[0]) != nil, "taken out of the album, it stays in the photostream")
        #expect(album.photos().map(\.fileName) == ["P1.JPG"])
    }

    @Test func publishMakesFillsRenamesAndDeletesAlbums() async throws {
        let library = try AlbumLibrary()
        let album = library.album("Harbour", Array(library.photos.prefix(2)))
        #expect(!album.hasChangesToPublish, "its photos aren't on Flickr yet: they're the service's work")
        await library.publish()
        #expect(Set(library.publisher.recorded.filter { $0.hasPrefix("publish") }) == ["publish P0", "publish P1"])
        #expect(library.albumCalls == ["create Harbour P0", "set A1 P0,P1"])
        #expect(album.remoteID == "A1" && !album.hasChangesToPublish)
        #expect(!library.service.hasAlbumWork)

        await library.publish()
        #expect(library.publisher.recorded.isEmpty, "nothing changed")

        album.name = "Harbours"
        album.remove([library.photos[0]])
        await library.publish()
        #expect(library.albumCalls == ["edit A1 Harbours", "set A1 P1"])

        album.delete()
        #expect(album.isDeletionPending, "it's on Flickr, so it waits for Publish")
        #expect(library.service.visibleAlbums.isEmpty)
        await library.publish()
        #expect(library.albumCalls == ["delete A1"])
        #expect(library.service.albums.isEmpty)
    }

    @Test func anAlbumLeftEmptyIsDeletedAndMadeAgain() async throws {
        let library = try AlbumLibrary()
        let album = library.album("Harbour", [library.photos[0]])
        await library.publish()
        album.remove([library.photos[0]])
        await library.publish()
        #expect(library.albumCalls == ["delete A1"])
        #expect(album.remoteID == nil && !album.isDeleted, "kept, to be made again when it has photos")
        album.add([library.photos[0]])
        await library.publish()
        #expect(library.albumCalls == ["create Harbour P0"], "its only photo is its cover")
    }

    @Test func aPhotoTakenOutOfTheServiceLeavesItsAlbums() async throws {
        let library = try AlbumLibrary()
        let album = library.album("Harbour", Array(library.photos.prefix(2)))
        await library.publish()
        library.service.remove([library.photos[1]])
        #expect(album.photos().map(\.fileName) == ["P0.JPG"])
        await library.publish()
        #expect(library.publisher.recorded.contains("remove P1"))
        #expect(library.albumCalls == ["set A1 P0"])
    }

    @Test func smartAlbumMatchesJoinTheServiceAtPublish() async throws {
        let library = try AlbumLibrary()
        let album = PublishAlbum.make(.smart, named: "Best", in: library.service)
        album.rules = SmartCollectionRules(rules: [.init(field: .rating, operator: .atLeast, value: "2")])
        library.store.save()
        #expect(library.service.smartAlbumPhotosToJoin().map(\.fileName).sorted() == ["P2.JPG", "P3.JPG"])
        #expect(library.service.hasAlbumWork)

        let ids = album.photos().sorted { $0.captureDate < $1.captureDate }.map(\.objectID)
        let groups = PublishGroups(service: library.service, photoIDs: ids, context: library.context)
        #expect(groups.groups.map(\.state) == [.new] && groups.hasWork, "matches not in the service yet are New")

        await library.publish()
        #expect(Set(library.publisher.recorded.filter { $0.hasPrefix("publish") }) == ["publish P2", "publish P3"])
        #expect(library.albumCalls == ["create Best P2", "set A1 P2,P3"])

        // P3 stops matching: it leaves the album, not the photostream.
        library.photos[3].rating = 1
        library.store.save()
        await library.publish()
        #expect(library.albumCalls == ["set A1 P2"])
        #expect(library.publisher.recorded.contains("publish P3"), "its rating changed, so it's sent again")
        #expect(library.service.entry(for: library.photos[3]) != nil)
    }

    @Test func resetExportStatusForgetsAlbums() async throws {
        let library = try AlbumLibrary()
        let album = library.album("Harbour", [library.photos[0]])
        let gone = library.album("Gone", [library.photos[0]])
        await library.publish()
        gone.delete()
        library.service.resetPublishStatus()
        #expect(album.remoteID == nil && album.publishedPhotoIDs == nil)
        #expect(gone.isDeleted, "an album waiting to be deleted is forgotten")
        #expect(album.photos().map(\.fileName) == ["P0.JPG"], "it keeps its photos")
    }

    @Test func theLibraryShowsAnAlbumsPhotos() throws {
        let library = try AlbumLibrary()
        let album = library.album("Harbour", [library.photos[1], library.photos[2]])
        var filter = LibraryFilter()
        filter.scope = try #require(album.scope)
        #expect(filter.scope.publishServiceID == library.service.id && filter.scope.publishAlbumID == album.id)
        let request = Photo.fetchRequest()
        request.predicate = filter.predicate
        #expect(try library.context.fetch(request).map(\.fileName).sorted() == ["P1.JPG", "P2.JPG"])
    }

    @Test func importingLightroomSmartCollectionSettings() throws {
        let library = try AlbumLibrary()
        let controller = CatalogWindowController(store: library.store)
        defer { controller.close() }
        let file = library.directory.url.appending(path: "Three Stars.lrsmcol")
        try #"""
        s = {
            id = "8F7B0D6E-1C1F-4E1A-9E62-6B0C1C5C5F11",
            internalName = "Three Stars",
            title = "Three Stars",
            type = "LibrarySmartCollection",
            value = {
                {
                    criteria = "rating",
                    operation = ">=",
                    value = 3,
                    value2 = 0,
                },
                {
                    criteria = "noSuchCriterion",
                    operation = "==",
                    value = "x",
                },
                combine = "intersect",
            },
            version = 0,
        }
        """#.write(to: file, atomically: true, encoding: .utf8)
        let album = try #require(try controller.importSmartAlbum(from: file, into: library.service.id))
        #expect(album.name == "Three Stars" && album.kind == .smart)
        #expect(album.photos().map(\.fileName) == ["P3.JPG"])
        #expect(album.importWarning?.contains("noSuchCriterion") == true)
        #expect(controller.state.filter.scope.publishAlbumID == album.id)
    }

    // MARK: - In the window

    private func window(_ library: AlbumLibrary) -> CatalogWindowController {
        let controller = CatalogWindowController(store: library.store)
        controller.showWindow(nil)
        controller.window?.layoutIfNeeded()
        return controller
    }

    private func sidebarItems(_ controller: CatalogWindowController) throws -> [SidebarViewController.Item] {
        let outline = try #require(controller.window!.contentView!.descendants.compactMap { $0 as? NSOutlineView }.first)
        return (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SidebarViewController.Item }
    }

    @Test func albumsAreUnderTheirServiceInTheSidebar() throws {
        let library = try AlbumLibrary()
        let album = library.album("Harbour", [library.photos[0], library.photos[1]])
        let controller = window(library)
        defer { controller.close() }
        let items = try sidebarItems(controller)
        let service = try #require(items.firstIndex { $0.publishServiceID == library.service.id })
        #expect(items[service + 1].title == "Harbour" && items[service + 1].count == 2)
        #expect(items[service + 1].scope == album.scope)

        let sidebar = controller.rootViewController.main.sidebar
        let serviceTitles = sidebar.publishServiceMenu(id: library.service.id).items.map(\.title)
        #expect(Array(serviceTitles.prefix(2)) == ["Create Album…", "Create Smart Album…"])
        #expect(serviceTitles.last == "Import Smart Collection Settings…")
        let albumMenu = sidebar.publishAlbumMenu(id: album.id, serviceID: library.service.id)
        #expect(albumMenu.items.map { $0.isSeparatorItem ? "-" : $0.title } == [
            "Set as Target Collection", "-", "Edit Album…", "Rename…", "Delete…", "-", "Publish Now", "Show in Flickr",
        ])
        let publish = try #require(albumMenu.items.first { $0.title == "Publish Now" })
        #expect(publish.representedObject as? UUID == library.service.id, "Publish Now publishes the whole service")
        #expect(controller.validateUserInterfaceItem(publish))
        let show = try #require(albumMenu.items.first { $0.title == "Show in Flickr" })
        #expect(!controller.validateUserInterfaceItem(show), "not on Flickr yet")
    }

    @Test func createAlbumMakesAnAlbumWithTheSelectedPhotos() throws {
        let library = try AlbumLibrary()
        let controller = window(library)
        defer { controller.close() }
        controller.state.selectedPhotoIDs = [library.photos[2].objectID]
        let create = try #require(controller.rootViewController.main.sidebar.publishServiceMenu(id: library.service.id).items.first)
        #expect(controller.validateUserInterfaceItem(create))
        controller.createPublishAlbum(create)
        let dialog = try #require(controller.lastCollectionDialog)
        #expect(dialog.title_ == "Create Album")
        dialog.nameField.stringValue = "Lighthouses"
        dialog.descriptionField.stringValue = "On the coast"
        dialog.create(nil)
        let album = try #require(library.service.visibleAlbums.first)
        #expect(album.name == "Lighthouses" && album.albumDescription == "On the coast")
        #expect(album.photos().map(\.fileName) == ["P2.JPG"])
        #expect(controller.state.filter.scope.publishAlbumID == album.id, "it's shown")
    }

    @Test func anAlbumTakesPhotosByBAndGivesThemBack() throws {
        let library = try AlbumLibrary()
        let album = library.album("Harbour")
        let controller = window(library)
        defer { controller.close() }
        let set = try #require(controller.rootViewController.main.sidebar.publishAlbumMenu(id: album.id, serviceID: library.service.id).items.first)
        controller.setTargetCollection(set)
        controller.state.selectedPhotoIDs = [library.photos[0].objectID]
        controller.addToTargetCollection(nil)
        #expect(album.photos().map(\.fileName) == ["P0.JPG"])

        controller.state.filter.scope = try #require(album.scope)
        controller.state.selectedPhotoIDs = [library.photos[0].objectID]
        let menu = controller.rootViewController.main.library.grid.contextMenu()
        let remove = try #require(menu.items.first { $0.title == "Remove from Album" })
        #expect(controller.validateUserInterfaceItem(remove))
        controller.removeFromPublishService(remove)
        #expect(album.photos().isEmpty)
        #expect(library.service.entry(for: library.photos[0]) != nil, "still in the service")
    }

    @Test func aHardDriveServiceHasNoAlbums() throws {
        let library = try AlbumLibrary()
        let drive = PublishService.make(.hardDrive, in: library.context)
        library.store.save()
        let controller = window(library)
        defer { controller.close() }
        let titles = controller.rootViewController.main.sidebar.publishServiceMenu(id: drive.id).items.map(\.title)
        #expect(!titles.contains("Create Album…") && !titles.contains("Import Smart Collection Settings…"))
    }
}
