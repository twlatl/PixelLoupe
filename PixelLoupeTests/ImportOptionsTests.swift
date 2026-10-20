import AppKit
import CoreData
import ImageIO
import Testing
@testable import PixelLoupe

/// The import window's File Handling and Apply During Import (RAW-80).
@Suite("Import options", .serialized)
struct ImportOptionsTests {
    private struct Setup {
        let directory: TemporaryDirectory
        let card: URL
        let store: CatalogStore
        let service: ImportService
    }

    private func makeSetup(files: Int = 2) throws -> Setup {
        let directory = try TemporaryDirectory()
        let card = try directory.subdirectory("Card/DCIM")
        let storage = try directory.subdirectory("Storage")
        for index in 1...files {
            try Fixtures.writeJPEG(to: card.appending(path: "IMG_000\(index).jpg"), captureDate: "2026:10:12 09:3\(index):00")
        }
        let store = try CatalogStore.inMemory(info: Fixtures.managedInfo(storage: storage), packageURL: directory.url.appending(path: "Test.pixelloupe"))
        return Setup(directory: directory, card: card, store: store, service: ImportService(store: store))
    }

    private func photos(in store: CatalogStore) throws -> [Photo] {
        let request = Photo.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "fileName", ascending: true)]
        return try store.viewContext.fetch(request)
    }

    @Test func readsTheFilesOwnRating() throws {
        let metadata = CGImageMetadataCreateMutable()
        #expect(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, "-1" as CFString))
        #expect(ImageMetadata.xmpRating(metadata) == -1)
        #expect(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, "4" as CFString))
        #expect(ImageMetadata.xmpRating(metadata) == 4)
        #expect(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, "0" as CFString))
        #expect(ImageMetadata.xmpRating(metadata) == nil, "0 is no rating")
    }

    @Test func keywordsMetadataAndRatingsAreAppliedAsPhotosComeIn() async throws {
        let setup = try makeSetup()
        var files = try await setup.service.scan([setup.card]).files
        files[0].candidate.metadata?.rating = 3
        files[1].candidate.metadata?.rating = -1
        var extras = ImportExtras()
        extras.keywords = ["Disneyland", "Family"]
        extras.metadata = MetadataPreset(name: "Me", creator: "Ted Lee", copyright: "© 2026 Ted Lee")
        let summary = try await setup.service.importPhotos(files.map(\.candidate), extras: extras)
        #expect(summary.imported == 2)

        let imported = try photos(in: setup.store)
        #expect(imported.allSatisfy { Set($0.tagNames).isSuperset(of: ["Disneyland", "Family"]) })
        #expect(imported.allSatisfy { $0.creatorText == "Ted Lee" && $0.copyrightText == "© 2026 Ted Lee" })
        #expect(imported[0].rating == 3)
        #expect(imported[1].photoFlag == .rejected, "a file rated -1 comes in rejected, as in Lightroom")
        #expect(Set(imported.map(\.importDate)).count == 1, "one import date for the whole import")
    }

    @Test func rejectedFilesCanBeLeftOut() async throws {
        let setup = try makeSetup()
        var files = try await setup.service.scan([setup.card]).files
        files[1].candidate.metadata?.rating = -1
        var extras = ImportExtras()
        extras.skipsRejected = true
        let summary = try await setup.service.importPhotos(files.map(\.candidate), extras: extras)
        #expect(summary.imported == 1)
        #expect(summary.skippedRejected == 1)
    }

    @Test func duplicatesCanBeImportedAgain() async throws {
        let setup = try makeSetup(files: 1)
        let files = try await setup.service.scan([setup.card]).files
        _ = try await setup.service.importPhotos(files.map(\.candidate))
        #expect(try await setup.service.importPhotos(files.map(\.candidate)).skippedDuplicates == 1)
        var extras = ImportExtras()
        extras.allowsDuplicates = true
        let again = try await setup.service.importPhotos(files.map(\.candidate), extras: extras)
        #expect(again.imported == 1)
        #expect(try photos(in: setup.store).count == 2)
    }

    @Test func aSecondCopyGoesInAnImportedOnFolder() async throws {
        let setup = try makeSetup()
        let backup = try setup.directory.subdirectory("Backup")
        var extras = ImportExtras()
        extras.secondCopy = backup
        let files = try await setup.service.scan([setup.card]).files
        let summary = try await setup.service.importPhotos(files.map(\.candidate), extras: extras)
        #expect(summary.failures.isEmpty)
        let folder = ImportExtras.secondCopyFolder(in: backup, on: summary.importDate)
        #expect(folder.lastPathComponent.hasPrefix("Imported on "))
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
        #expect(copies == ["IMG_0001.jpg", "IMG_0002.jpg"])

        // Adding in place makes no copies.
        let addSetup = try makeSetup(files: 1)
        let addBackup = try addSetup.directory.subdirectory("Backup")
        var addExtras = ImportExtras()
        addExtras.secondCopy = addBackup
        let added = try await addSetup.service.scan([addSetup.card]).files
        _ = try await addSetup.service.importPhotos(added.map(\.candidate), transfer: .add, extras: addExtras)
        #expect(try FileManager.default.contentsOfDirectory(atPath: addBackup.path(percentEncoded: false)).isEmpty)
    }

    @Test func photosGoIntoANewOrExistingCollection() async throws {
        let setup = try makeSetup()
        let files = try await setup.service.scan([setup.card]).files
        var extras = ImportExtras()
        extras.collection = .new(name: "Disneyland")
        _ = try await setup.service.importPhotos([files[0].candidate], extras: extras)
        let collection = try #require(setup.service.collections().first)
        #expect(collection.path == "Disneyland")
        extras.collection = .existing(collection.id)
        _ = try await setup.service.importPhotos([files[1].candidate], extras: extras)
        let saved = try #require(PhotoCollection.with(id: collection.id, in: setup.store.viewContext))
        #expect(saved.photos.count == 2)
        #expect(setup.store.viewContext.undoManager?.canUndo != true, "importing isn't an edit to undo")
    }

    @Test func aDevelopPresetIsAppliedToThePhotosItSuits() async throws {
        let setup = try makeSetup()
        let files = try await setup.service.scan([setup.card]).files
        var extras = ImportExtras()
        extras.developPreset = DevelopPreset.parse(
            PresetFixtures.xmp(name: "Punch", group: "Mine", attributes: ["Contrast2012": "+20"]),
            url: URL(filePath: "/p/punch.xmp"), defaultGroup: "x")
        _ = try await setup.service.importPhotos([files[0].candidate], extras: extras)
        #expect(try photos(in: setup.store)[0].adjustments.light.contrast > 0)

        // One for another camera is left off (the fixtures are from an EOS R5).
        extras.developPreset = DevelopPreset.parse(
            PresetFixtures.xmp(name: "Z8", group: "Mine", attributes: ["Contrast2012": "+20", "CameraModelRestriction": "Nikon Z 8"]),
            url: URL(filePath: "/p/z8.xmp"), defaultGroup: "x")
        _ = try await setup.service.importPhotos([files[1].candidate], extras: extras)
        #expect(try photos(in: setup.store)[1].adjustments.light.contrast == 0)
    }

    @Test func selectionFollowsFileHandling() {
        func file(_ name: String, duplicate: Bool = false, rating: Int? = nil) -> ImportService.ScannedFile {
            var metadata = ImageMetadata()
            metadata.captureDate = Date(timeIntervalSince1970: Double(name.hashValue & 0xFFFF))
            metadata.rating = rating
            return ImportService.ScannedFile(
                candidate: .init(source: .init(url: URL(filePath: "/Card/\(name)"), anchor: URL(filePath: "/")), metadata: metadata, fileSize: 1, fileDate: .distantPast),
                metadata: metadata, isDuplicateWhenCopied: duplicate, isDuplicateWhenAdded: duplicate)
        }
        var selection = ImportSelection(files: [file("A.jpg"), file("B.jpg", duplicate: true), file("C.jpg", rating: -1)])
        #expect(selection.check(1) == .init(isChecked: false, isCheckable: false, badge: "In Library"))
        #expect(selection.check(2) == .init(isChecked: true, isCheckable: true, badge: "Rejected"))

        selection.setAllowsDuplicates(true)
        #expect(selection.check(1).isCheckable && !selection.check(1).isChecked, "duplicates can be checked, but aren't for you")
        selection.setChecked(true, [1])
        #expect(selection.isChecked(1))
        selection.setAllowsDuplicates(false)
        #expect(!selection.isChecked(1))

        selection.setSkipsRejected(true)
        #expect(selection.check(2) == .init(isChecked: false, isCheckable: false, badge: "Rejected"))
        selection.setSkipsRejected(false)
        #expect(selection.isChecked(2))
    }

    @Test func handlingIsRememberedWithTheCatalogsSettings() throws {
        let defaults = try #require(UserDefaults(suiteName: "ImportOptionsTests.settings"))
        defer { defaults.removePersistentDomain(forName: "ImportOptionsTests.settings") }
        let catalog = URL(filePath: "/Catalogs/A.pixelloupe")
        let info = Fixtures.managedInfo(storage: URL(filePath: "/Storage"))
        let model = ImportOptionsModel(settings: .load(for: catalog, info: info, defaults: defaults))
        #expect(model.skipsDuplicates, "on by default")
        #expect(!model.skipsRejected)
        model.skipsRejected = true
        model.addsToCollection = true
        model.keywords = ["Trip"]
        model.settings.save(for: catalog, defaults: defaults)
        let reloaded = ImportOptionsModel(settings: .load(for: catalog, info: info, defaults: defaults))
        #expect(reloaded.skipsRejected && reloaded.addsToCollection)
        #expect(reloaded.keywords.isEmpty, "keywords aren't remembered")
    }

    @Test func metadataPresetsFillOnlyTheirFields() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "Test.pixelloupe"))
        let photo = Photo(context: store.viewContext)
        photo.titleText = "Castle"
        photo.creatorText = "Camera Owner"
        MetadataPreset(name: "Me", creator: "Ted Lee", title: "  ").apply(to: photo)
        #expect(photo.creatorText == "Ted Lee")
        #expect(photo.titleText == "Castle", "a blank field leaves the photo's own")
    }
}
