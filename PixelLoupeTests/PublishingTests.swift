import CoreData
import Foundation
import Synchronization
import Testing
@testable import PixelLoupe

/// Records what it's asked to publish and remove, and fails the photos it's told to.
private final class FakePublisher: Publisher {
    let published = Mutex<[PublishItem]>([])
    let removed = Mutex<[RemotePhoto]>([])
    let failing: Set<String>
    /// Run on the main actor while each photo publishes, to change the catalog mid-publish.
    let during: (@MainActor () -> Void)?

    init(failing: Set<String> = [], during: (@MainActor () -> Void)? = nil) {
        self.failing = failing
        self.during = during
    }

    func publish(_ item: PublishItem) async throws -> RemotePhoto {
        if let during { await during() }
        if failing.contains(item.export.fileName) { throw CocoaError(.fileReadCorruptFile) }
        published.withLock { $0.append(item) }
        return RemotePhoto(id: "remote-\(item.export.fileName)", url: URL(string: "https://example.com/\(item.export.fileName)"))
    }

    func remove(_ photo: RemotePhoto) async throws {
        removed.withLock { $0.append(photo) }
    }
}

@MainActor
private struct Catalog {
    let directory: TemporaryDirectory
    let store: CatalogStore
    var context: NSManagedObjectContext { store.viewContext }

    init() throws {
        directory = try TemporaryDirectory()
        store = try CatalogStore.create(at: directory.url.appending(path: "C.pixelloupe", directoryHint: .isDirectory), info: Fixtures.referencedInfo)
    }

    /// A photo whose original is a small JPEG in the catalog's folder.
    func photo(_ name: String, edited: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws -> Photo {
        let url = try Fixtures.writeJPEG(to: directory.url.appending(path: name))
        let photo = Photo(context: context)
        photo.id = UUID()
        photo.fileName = name
        photo.filePath = url.path(percentEncoded: false)
        photo.fileType = "JPG"
        photo.pixelWidth = 64
        photo.pixelHeight = 48
        photo.captureDate = Date(timeIntervalSince1970: 1_791_000_000)
        photo.importDate = edited
        photo.editDate = edited
        return photo
    }

    func states(_ service: PublishService) -> [PublishedPhoto.State: [String]] {
        Dictionary(uniqueKeysWithValues: PublishedPhoto.State.allCases.map { state in
            (state, service.entries(in: state).map(\.fileName))
        }).filter { !$0.value.isEmpty }
    }
}

@Suite("Publish settings")
struct PublishSettingsTests {
    @Test func newServicesStartWithTheirKindsDefaults() {
        let flickr = PublishSettings(.flickr)
        #expect(flickr.export.format == .jpeg && flickr.export.quality == 60 && flickr.export.colorSpace == .sRGB)
        #expect(flickr.isPublic && flickr.safety == .safe && flickr.contentType == .photo)
        let hardDrive = PublishSettings(.hardDrive)
        #expect(hardDrive.export.destination == .specificFolder)
        #expect(hardDrive.export.usesSubfolder && hardDrive.export.subfolderName == "Published")
    }

    @Test func decodingKeepsDefaultsForMissingOptions() throws {
        let decoded = try JSONDecoder().decode(PublishSettings.self, from: Data(#"{"isPublic": false, "export": {"quality": 85}}"#.utf8))
        #expect(!decoded.isPublic)
        #expect(decoded.export.quality == 85)
        #expect(decoded.titleSource == .title && decoded.safety == .safe)
        var settings = PublishSettings(.flickr)
        settings.titleSource = .caption
        settings.isVisibleToFamily = true
        #expect(try JSONDecoder().decode(PublishSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func titlesComeFromTheChosenFieldElseTheFileName() {
        var metadata = PhotoMetadata()
        metadata[.title] = "Harbour at dawn"
        metadata[.caption] = "  "
        let item = ExportItem(source: URL(filePath: "/Photos/IMG_0001.CR3"), adjustments: PhotoAdjustments(), metadata: metadata,
                              keywords: [], rating: 0, captureDate: .now)
        var settings = PublishSettings()
        #expect(settings.title(for: item) == "Harbour at dawn")
        settings.titleSource = .caption
        #expect(settings.title(for: item) == "IMG_0001.CR3", "an empty field falls back to the file name")
        settings.titleSource = .filenameWithoutExtension
        #expect(settings.title(for: item) == "IMG_0001")
        settings.titleSource = .none
        #expect(settings.title(for: item) == nil)
    }
}

@Suite("Publish services")
@MainActor
struct PublishServiceTests {
    @Test func servicesKeepTheirOrderNameAndSettings() throws {
        let catalog = try Catalog()
        let flickr = PublishService.make(.flickr, in: catalog.context)
        let drive = PublishService.make(.hardDrive, in: catalog.context)
        #expect(PublishService.all(in: catalog.context) == [flickr, drive])
        #expect(flickr.displayName == "Flickr")
        flickr.name = "  "
        #expect(flickr.displayName == "Flickr", "a blank Description shows the kind")
        var settings = drive.settings
        settings.export.folderPath = "/Volumes/Backup"
        drive.settings = settings
        catalog.store.save()
        #expect(PublishService.with(id: drive.id, in: catalog.context)?.settings.export.folderPath == "/Volumes/Backup")
    }

    @Test func photosMoveThroughNewPublishedModifiedAndDeleted() async throws {
        let catalog = try Catalog()
        let service = PublishService.make(.hardDrive, in: catalog.context)
        let a = try catalog.photo("A.jpg"), b = try catalog.photo("B.jpg"), c = try catalog.photo("C.jpg")
        service.add([a, b, c])
        service.add([a])
        #expect(catalog.states(service) == [.new: ["A.jpg", "B.jpg", "C.jpg"]], "adding twice doesn't duplicate")

        _ = await PublishRun.run(service, store: catalog.store, publisher: FakePublisher())
        #expect(catalog.states(service) == [.published: ["A.jpg", "B.jpg", "C.jpg"]])

        a.editDate = Date()
        var metadata = b.metadata
        metadata[.caption] = "New caption"
        b.metadata = metadata
        #expect(catalog.states(service) == [.modified: ["A.jpg", "B.jpg"], .published: ["C.jpg"]])
        #expect(service.entry(for: a)?.hasEditsSincePublished == true)
        #expect(service.entry(for: b)?.hasEditsSincePublished == false, "only its metadata changed")

        service.remove([c])
        #expect(service.entries(in: .deleted).map(\.fileName) == ["C.jpg"])
        service.add([c])
        #expect(service.entries(in: .published).map(\.fileName) == ["C.jpg"], "adding it back keeps it published")
    }

    @Test func removingOrDeletingAPhotoBeforeItsPublishedForgetsIt() throws {
        let catalog = try Catalog()
        let service = PublishService.make(.hardDrive, in: catalog.context)
        let a = try catalog.photo("A.jpg"), b = try catalog.photo("B.jpg")
        service.add([a, b])
        service.remove([a])
        catalog.context.delete(b)
        catalog.store.save()
        service.pruneUnpublishedOrphans()
        #expect(catalog.states(service).isEmpty)
    }

    @Test func aPublishedPhotoDeletedFromTheCatalogWaitsToBeRemoved() async throws {
        let catalog = try Catalog()
        let service = PublishService.make(.hardDrive, in: catalog.context)
        let a = try catalog.photo("A.jpg")
        service.add([a])
        let publisher = FakePublisher()
        _ = await PublishRun.run(service, store: catalog.store, publisher: publisher)
        catalog.context.delete(a)
        catalog.store.save()
        #expect(catalog.states(service) == [.deleted: ["A.jpg"]])

        let result = await PublishRun.run(service, store: catalog.store, publisher: publisher)
        #expect(result.removed == 1)
        #expect(publisher.removed.withLock { $0.map(\.id) } == ["remote-A.jpg"])
        #expect(service.publishedPhotos.isEmpty)
    }

    @Test func publishRecordsWhereEachPhotoWentAndWhatFailed() async throws {
        let catalog = try Catalog()
        let service = PublishService.make(.flickr, in: catalog.context)
        var settings = service.settings
        settings.titleSource = .filenameWithoutExtension
        service.settings = settings
        let good = try catalog.photo("Good.jpg"), bad = try catalog.photo("Bad.jpg"), video = try catalog.photo("Clip.jpg")
        video.isVideo = true
        service.add([good, bad, video])
        catalog.store.save()
        catalog.context.undoManager?.removeAllActions()
        var progress: [Int] = []
        let publisher = FakePublisher(failing: ["Bad.jpg"])
        let result = await PublishRun.run(service, store: catalog.store, publisher: publisher) { completed, _ in progress.append(completed) }

        #expect(result.published == 1)
        #expect(result.failures.count == 2)
        #expect(progress == [1, 2], "the video never starts")
        let entry = try #require(service.entry(for: good))
        #expect(entry.remoteID == "remote-Good.jpg" && entry.remoteURL == "https://example.com/Good.jpg" && entry.lastError == nil)
        #expect(publisher.published.withLock { $0.first?.title } == "Good")
        #expect(service.entry(for: bad)?.lastError != nil)
        #expect(service.entry(for: video)?.lastError == "Videos can’t be published yet.")
        #expect(catalog.states(service) == [.new: ["Bad.jpg", "Clip.jpg"], .published: ["Good.jpg"]])
        #expect(catalog.context.undoManager?.canUndo == false, "publishing's bookkeeping isn't undoable")
    }

    /// The record of a photo already on the service is saved as soon as it's there (a crash part way
    /// through once left photos on Flickr that the catalog still thought were new).
    @Test func eachPhotosResultIsSavedAsItFinishes() async throws {
        let catalog = try Catalog()
        let service = PublishService.make(.hardDrive, in: catalog.context)
        service.add(try (0..<4).map { try catalog.photo("P\($0).jpg") })
        catalog.store.save()
        var unsaved: [Bool] = []
        _ = await PublishRun.run(service, store: catalog.store, publisher: FakePublisher()) { _, _ in
            unsaved.append(catalog.context.hasChanges)
        }
        #expect(unsaved == [false, false, false, false])
    }

    @Test func anEditMadeWhilePublishingLeavesThePhotoModified() async throws {
        let catalog = try Catalog()
        let service = PublishService.make(.hardDrive, in: catalog.context)
        let a = try catalog.photo("A.jpg")
        service.add([a])
        _ = await PublishRun.run(service, store: catalog.store, publisher: FakePublisher { a.editDate = Date() })
        #expect(catalog.states(service) == [.modified: ["A.jpg"]])
    }

    @Test func republishingSendsWhereThePhotoWentBefore() async throws {
        let catalog = try Catalog()
        let service = PublishService.make(.hardDrive, in: catalog.context)
        let a = try catalog.photo("A.jpg")
        service.add([a])
        _ = await PublishRun.run(service, store: catalog.store, publisher: FakePublisher())
        a.rating = 4
        let publisher = FakePublisher()
        _ = await PublishRun.run(service, store: catalog.store, publisher: publisher)
        let item = try #require(publisher.published.withLock { $0.first })
        #expect(item.remote?.id == "remote-A.jpg")
        #expect(!item.hasEdits, "a rating change is metadata only")
        #expect(catalog.states(service) == [.published: ["A.jpg"]])
    }

    @Test("Opens a version seventeen catalog")
    func migratesVersionSeventeen() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "V17.pixelloupe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(Fixtures.referencedInfo).write(to: CatalogPackage.infoURL(in: packageURL))
        let momd = try #require(Bundle(for: Photo.self).url(forResource: "PixelLoupe", withExtension: "momd"))
        let v17 = try #require(NSManagedObjectModel(contentsOf: momd.appending(path: "PixelLoupe 17.mom")))
        #expect(v17.entitiesByName["PublishService"] == nil)
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: v17)
            _ = try coordinator.addPersistentStore(type: .sqlite, at: CatalogPackage.databaseURL(in: packageURL))
            let context = NSManagedObjectContext(.mainQueue)
            context.persistentStoreCoordinator = coordinator
            let photo = NSEntityDescription.insertNewObject(forEntityName: "Photo", into: context)
            photo.setValue(UUID(), forKey: "id")
            photo.setValue("v17.jpg", forKey: "fileName")
            photo.setValue(Date(), forKey: "captureDate"); photo.setValue(Date(), forKey: "importDate"); photo.setValue(Date(), forKey: "editDate")
            try context.save()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }
        let store = try CatalogStore.open(at: packageURL)
        let photo = try #require(try store.viewContext.fetch(Photo.fetchRequest()).first)
        #expect(photo.publications.isEmpty)
        let service = PublishService.make(.hardDrive, in: store.viewContext)
        service.add([photo])
        store.save()
        #expect(service.entries(in: .new).count == 1)
    }
}

@Suite("Hard Drive publishing")
@MainActor
struct HardDrivePublisherTests {
    private func settings(folder: URL, format: ExportSettings.Format = .jpeg) -> PublishSettings {
        var settings = PublishSettings(.hardDrive)
        settings.export.folderPath = folder.path(percentEncoded: false)
        settings.export.format = format
        return settings
    }

    private func item(_ catalog: Catalog, _ photo: Photo, remote: RemotePhoto? = nil, index: Int = 0) -> PublishItem {
        PublishItem(export: ExportItem(photo), title: nil, remote: remote, hasEdits: true, index: index, total: 1)
    }

    private static let delete: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }

    @Test func publishesIntoTheSubfolderAndRepublishesOverTheSameFile() async throws {
        let catalog = try Catalog()
        let output = try catalog.directory.subdirectory("Out")
        let photo = try catalog.photo("IMG_0001.jpg")
        let publisher = HardDrivePublisher(settings: settings(folder: output), watermark: nil, discard: Self.delete)
        let first = try await publisher.publish(item(catalog, photo))
        let expected = output.appending(path: "Published/IMG_0001.jpg")
        #expect(first.id == expected.path(percentEncoded: false))
        #expect(FileManager.default.fileExists(atPath: first.id))

        let second = try await publisher.publish(item(catalog, photo, remote: first))
        #expect(second == first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.appending(path: "Published").path(percentEncoded: false)) == ["IMG_0001.jpg"])

        try await publisher.remove(second)
        #expect(!FileManager.default.fileExists(atPath: first.id))
        try await publisher.remove(second)   // already gone: not an error
    }

    @Test func anotherFormatReplacesTheOldFile() async throws {
        let catalog = try Catalog()
        let output = try catalog.directory.subdirectory("Out")
        let photo = try catalog.photo("IMG_0001.jpg")
        let jpeg = try await HardDrivePublisher(settings: settings(folder: output), watermark: nil, discard: Self.delete)
            .publish(item(catalog, photo))
        let png = try await HardDrivePublisher(settings: settings(folder: output, format: .png), watermark: nil, discard: Self.delete)
            .publish(item(catalog, photo, remote: jpeg))
        #expect(png.id.hasSuffix("/Published/IMG_0001.png"))
        #expect(!FileManager.default.fileExists(atPath: jpeg.id))
        #expect(FileManager.default.fileExists(atPath: png.id))
    }

    @Test func namesAlreadyTakenGetANumber() async throws {
        let catalog = try Catalog()
        let output = try catalog.directory.subdirectory("Out")
        _ = try catalog.directory.subdirectory("Out/Published")
        try Data("someone else's".utf8).write(to: output.appending(path: "Published/IMG_0001.jpg"))
        // Two photos with one name, published at once.
        let first = try catalog.photo("IMG_0001.jpg")
        let other = try catalog.directory.subdirectory("Card2")
        let second = try catalog.photo("Card2-IMG_0001.jpg")
        let moved = other.appending(path: "IMG_0001.jpg")
        try FileManager.default.moveItem(atPath: second.filePath, toPath: moved.path(percentEncoded: false))
        second.filePath = moved.path(percentEncoded: false)
        let publisher = HardDrivePublisher(settings: settings(folder: output), watermark: nil, discard: Self.delete)
        let items = (item(catalog, first), item(catalog, second, index: 1))
        async let a = publisher.publish(items.0)
        async let b = publisher.publish(items.1)
        let names = try await [a, b].map { URL(filePath: $0.id).lastPathComponent }.sorted()
        #expect(names == ["IMG_0001-2.jpg", "IMG_0001-3.jpg"])
        #expect(try String(contentsOf: output.appending(path: "Published/IMG_0001.jpg"), encoding: .utf8) == "someone else's")
    }

    @Test func publishRunsTheServicesPublisher() async throws {
        let catalog = try Catalog()
        let output = try catalog.directory.subdirectory("Out")
        let service = PublishService.make(.hardDrive, in: catalog.context)
        service.settings = settings(folder: output)
        let photo = try catalog.photo("IMG_0001.jpg")
        service.add([photo])
        let result = await PublishRun.run(service, store: catalog.store)
        #expect(result.published == 1 && result.failures.isEmpty)
        let entry = try #require(service.entry(for: photo))
        #expect(entry.remoteURL == output.appending(path: "Published/IMG_0001.jpg").absoluteString)
        #expect(catalog.states(service) == [.published: ["IMG_0001.jpg"]])
    }
}
