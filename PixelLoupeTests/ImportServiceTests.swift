import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Import")
struct ImportServiceTests {
    private func photos(in store: CatalogStore) throws -> [Photo] {
        let request = Photo.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "fileName", ascending: true)]
        return try store.viewContext.fetch(request)
    }

    private func folderPaths(in store: CatalogStore) throws -> [String: String?] {
        let folders = try store.viewContext.fetch(Folder.fetchRequest())
        return Dictionary(uniqueKeysWithValues: folders.map { ($0.path, $0.parent?.path) })
    }

    @Test func managedImportCopiesIntoDateFolders() async throws {
        let directory = try TemporaryDirectory()
        let source = try directory.subdirectory("Card/DCIM")
        let storage = try directory.subdirectory("Storage")
        let original = try Fixtures.writeJPEG(to: source.appending(path: "IMG_0001.jpg"), keywords: ["Beach"])
        try Fixtures.writeJPEG(to: source.appending(path: "IMG_0002.jpg"), captureDate: "2025:12:31 23:59:00")
        try Data("not an image".utf8).write(to: source.appending(path: "README.txt"))

        let store = try CatalogStore.inMemory(info: Fixtures.managedInfo(storage: storage), packageURL: directory.url.appending(path: "Test.pixelloupe"))
        let summary = try await ImportService(store: store).importPhotos(from: [source])

        #expect(summary.imported == 2)
        #expect(summary.failures.isEmpty)

        let storagePath = storage.path(percentEncoded: false).trimmingSuffix("/")
        let imported = try photos(in: store)
        #expect(imported.map(\.filePath) == [
            "\(storagePath)/2026/10-12/IMG_0001.jpg",
            "\(storagePath)/2025/12-31/IMG_0002.jpg",
        ])
        #expect(imported[0].originalPath == original.path(percentEncoded: false))
        #expect(imported[0].fileType == "JPG")
        #expect(imported[0].cameraModel == "EOS R5")
        #expect(imported[0].tagNames == ["Beach"])
        #expect(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)), "source is left untouched")
        for photo in imported {
            #expect(FileManager.default.fileExists(atPath: photo.filePath))
            #expect(FileManager.default.fileExists(atPath: store.thumbnails.url(for: photo.id).path(percentEncoded: false)))
        }

        let folders = try folderPaths(in: store)
        #expect(folders == [
            "\(storagePath)/2026": nil,
            "\(storagePath)/2026/10-12": "\(storagePath)/2026",
            "\(storagePath)/2025": nil,
            "\(storagePath)/2025/12-31": "\(storagePath)/2025",
        ])
    }

    @Test func managedImportSkipsDuplicatesAndRenamesCollisions() async throws {
        let directory = try TemporaryDirectory()
        let cardA = try directory.subdirectory("CardA")
        let cardB = try directory.subdirectory("CardB")
        let storage = try directory.subdirectory("Storage")
        try Fixtures.writeJPEG(to: cardA.appending(path: "IMG_0001.jpg"))
        // Same name and capture date but different content (different size): a different photo.
        try Fixtures.writeJPEG(to: cardB.appending(path: "IMG_0001.jpg"), width: 80)

        let store = try CatalogStore.inMemory(info: Fixtures.managedInfo(storage: storage), packageURL: directory.url.appending(path: "Test.pixelloupe"))
        let service = ImportService(store: store)

        let first = try await service.importPhotos(from: [cardA])
        #expect(first.imported == 1)
        let again = try await service.importPhotos(from: [cardA])
        #expect(again.imported == 0)
        #expect(again.skippedDuplicates == 1)

        let second = try await service.importPhotos(from: [cardB])
        #expect(second.imported == 1)
        #expect(try photos(in: store).map(\.fileName).sorted() == ["IMG_0001-1.jpg", "IMG_0001.jpg"])
    }

    @Test func referencedImportKeepsFilesInPlace() async throws {
        let directory = try TemporaryDirectory()
        let trip = try directory.subdirectory("Pictures/Trip")
        let day = try directory.subdirectory("Pictures/Trip/Day 1")
        let a = try Fixtures.writeJPEG(to: trip.appending(path: "a.jpg"))
        let b = try Fixtures.writeJPEG(to: day.appending(path: "b.jpg"), make: "NIKON", model: "Z 8")

        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "Test.pixelloupe"))
        let service = ImportService(store: store)
        let summary = try await service.importPhotos(from: [trip])

        #expect(summary.imported == 2)
        let imported = try photos(in: store)
        #expect(imported.map(\.filePath) == [a.path(percentEncoded: false), b.path(percentEncoded: false)])
        #expect(imported.allSatisfy { $0.originalPath == nil })

        let tripPath = trip.path(percentEncoded: false).trimmingSuffix("/")
        #expect(try folderPaths(in: store) == [
            tripPath: nil,
            "\(tripPath)/Day 1": tripPath,
        ])

        let again = try await service.importPhotos(from: [trip])
        #expect(again.imported == 0)
        #expect(again.skippedDuplicates == 2)
    }

    @Test func eachImportGivesItsPhotosOneImportID() async throws {
        let directory = try TemporaryDirectory()
        // More photos than one batch saves, so the import spans several saves.
        let first = try directory.subdirectory("First")
        for index in 0..<40 {
            try Fixtures.writeJPEG(to: first.appending(path: String(format: "IMG_%04d.jpg", index)), width: 8, height: 6)
        }
        let second = try directory.subdirectory("Second")
        try Fixtures.writeJPEG(to: second.appending(path: "DSC_0001.jpg"), width: 8, height: 6)

        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "Test.pixelloupe"))
        let service = ImportService(store: store)
        #expect(try await service.importPhotos(from: [first]).imported == 40)
        #expect(try await service.importPhotos(from: [second]).imported == 1)

        let imported = try photos(in: store)
        let firstIDs = Set(imported.filter { $0.fileName.hasPrefix("IMG_") }.map(\.importID))
        let secondIDs = Set(imported.filter { $0.fileName.hasPrefix("DSC_") }.map(\.importID))
        #expect(firstIDs.count == 1 && secondIDs.count == 1)
        let secondID = try #require(secondIDs.first ?? nil)
        #expect(firstIDs != secondIDs && !firstIDs.contains(nil))
        #expect(Photo.latestImportID(in: store.viewContext) == secondID)

        // An import that adds nothing (all duplicates) leaves Previous Import as it was.
        #expect(try await service.importPhotos(from: [first]).imported == 0)
        #expect(Photo.latestImportID(in: store.viewContext) == secondID)
    }

    @Test func folderWithOnlySubfoldersImportsEverythingRecursively() async throws {
        let directory = try TemporaryDirectory()
        let shoots = try directory.subdirectory("Shoots")
        for path in ["Shoots/Iceland", "Shoots/Lisbon/Day 1", "Shoots/Lisbon/Day 2/Evening"] {
            let folder = try directory.subdirectory(path)
            try Fixtures.writeJPEG(to: folder.appending(path: "photo.jpg"))
        }

        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "Test.pixelloupe"))
        let summary = try await ImportService(store: store).importPhotos(from: [shoots])

        #expect(summary.imported == 3)
        let root = shoots.path(percentEncoded: false).trimmingSuffix("/")
        #expect(try folderPaths(in: store) == [
            root: nil,
            "\(root)/Iceland": root,
            "\(root)/Lisbon": root,
            "\(root)/Lisbon/Day 1": "\(root)/Lisbon",
            "\(root)/Lisbon/Day 2": "\(root)/Lisbon",
            "\(root)/Lisbon/Day 2/Evening": "\(root)/Lisbon/Day 2",
        ])
    }

    @Test func importPanelOffersFoldersAndSupportedImagesOnly() throws {
        let directory = try TemporaryDirectory()
        let folder = try directory.subdirectory("Folder")
        let photo = try Fixtures.writeJPEG(to: directory.url.appending(path: "a.jpg"))
        let text = directory.url.appending(path: "notes.txt")
        try Data().write(to: text)
        let package = try directory.subdirectory("Other.pixelloupe")

        #expect(SupportedImageTypes.isImportable(folder))
        #expect(SupportedImageTypes.isImportable(photo))
        #expect(!SupportedImageTypes.isImportable(text))
        #expect(!SupportedImageTypes.isImportable(package))
    }

    @Test func importingParentFolderAdoptsExistingRoot() async throws {
        let directory = try TemporaryDirectory()
        let pictures = try directory.subdirectory("Pictures")
        let trip = try directory.subdirectory("Pictures/Trip")
        try Fixtures.writeJPEG(to: trip.appending(path: "a.jpg"))
        try Fixtures.writeJPEG(to: pictures.appending(path: "b.jpg"))

        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "Test.pixelloupe"))
        let service = ImportService(store: store)
        _ = try await service.importPhotos(from: [trip])
        _ = try await service.importPhotos(from: [pictures])

        let picturesPath = pictures.path(percentEncoded: false).trimmingSuffix("/")
        #expect(try folderPaths(in: store) == [
            picturesPath: nil,
            "\(picturesPath)/Trip": picturesPath,
        ])
    }

    @Test func copyingIntoACatalogFolderNestsTheNewFolders() async throws {
        let directory = try TemporaryDirectory()
        let family = try directory.subdirectory("Pictures/Family Pictures")
        let card = try directory.subdirectory("Card")
        try Fixtures.writeJPEG(to: family.appending(path: "old.jpg"), captureDate: "2025:06:01 12:00:00")
        try Fixtures.writeJPEG(to: card.appending(path: "IMG_0001.jpg"))

        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "Test.pixelloupe"))
        let service = ImportService(store: store)
        _ = try await service.importPhotos(from: [family])

        let files = try await service.scan([card]).files
        let summary = try await service.importPhotos(
            files.map(\.candidate), transfer: .copy,
            destination: ImportDestination(root: family, subfolder: nil, layout: .yearAndMonthDay))
        #expect(summary.imported == 1)

        let familyPath = family.path(percentEncoded: false).trimmingSuffix("/")
        #expect(try photos(in: store).map(\.filePath).contains("\(familyPath)/2026/10-12/IMG_0001.jpg"))
        #expect(try folderPaths(in: store) == [
            familyPath: nil,
            "\(familyPath)/2026": familyPath,
            "\(familyPath)/2026/10-12": "\(familyPath)/2026",
        ])
    }

    @Test func addingASubfolderOfACatalogFolderNestsIt() async throws {
        let directory = try TemporaryDirectory()
        let pictures = try directory.subdirectory("Pictures")
        let trip = try directory.subdirectory("Pictures/Trip")
        try Fixtures.writeJPEG(to: pictures.appending(path: "a.jpg"))
        try Fixtures.writeJPEG(to: trip.appending(path: "b.jpg"))

        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "Test.pixelloupe"))
        let service = ImportService(store: store)
        _ = try await service.importPhotos(try await service.scan([pictures], includeSubfolders: false).files.map(\.candidate))
        _ = try await service.importPhotos(from: [trip])

        let picturesPath = pictures.path(percentEncoded: false).trimmingSuffix("/")
        #expect(try folderPaths(in: store) == [
            picturesPath: nil,
            "\(picturesPath)/Trip": picturesPath,
        ])
    }

    @Test func keywordsBecomeSharedTags() async throws {
        let directory = try TemporaryDirectory()
        let source = try directory.subdirectory("Source")
        try Fixtures.writeJPEG(to: source.appending(path: "a.jpg"), keywords: ["Beach", "Family"])
        try Fixtures.writeJPEG(to: source.appending(path: "b.jpg"), keywords: ["beach"])

        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "Test.pixelloupe"))
        _ = try await ImportService(store: store).importPhotos(from: [source])

        let tags = try store.viewContext.fetch(PixelLoupe.Tag.fetchRequest())
        #expect(tags.map(\.name).sorted() == ["Beach", "Family"])
        #expect(tags.first { $0.name == "Beach" }?.photos.count == 2)
    }

    @Test func dateFolderAndUniqueDestination() throws {
        let directory = try TemporaryDirectory()
        let date = try #require(ImageMetadata.parseExifDate("2026:03:07 12:00:00", offset: nil))
        let folder = ImportService.dateFolder(for: date, under: directory.url)
        #expect(folder.path(percentEncoded: false).hasSuffix("/2026/03-07/"))

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "a.CR3"))
        var reserved = Set<String>()
        let first = ImportService.uniqueDestination(in: folder, fileName: "a.CR3", reserved: &reserved)
        let second = ImportService.uniqueDestination(in: folder, fileName: "a.CR3", reserved: &reserved)
        #expect(first.lastPathComponent == "a-1.CR3")
        #expect(second.lastPathComponent == "a-2.CR3")
    }
}
