import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Catalog store")
struct CatalogStoreTests {
    @Test func createAndReopenRoundTrip() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "Family.pixelloupe", directoryHint: .isDirectory)
        let storage = directory.url.appending(path: "Family Photos", directoryHint: .isDirectory)
        let info = CatalogInfo(name: "Family", storageMode: .managed, storagePath: storage.path(percentEncoded: false))

        do {
            let store = try CatalogStore.create(at: packageURL, info: info)
            let photo = Photo(context: store.viewContext)
            photo.id = UUID()
            photo.fileName = "a.jpg"
            photo.captureDate = Date()
            photo.importDate = Date()
            photo.editDate = Date()
            photo.rating = 4
            try store.viewContext.save()
        }

        #expect(FileManager.default.fileExists(atPath: storage.path(percentEncoded: false)), "managed storage folder is created")
        #expect(FileManager.default.fileExists(atPath: CatalogPackage.databaseURL(in: packageURL).path(percentEncoded: false)))

        let reopened = try CatalogStore.open(at: packageURL)
        #expect(reopened.info == info)
        let photos = try reopened.viewContext.fetch(Photo.fetchRequest())
        #expect(photos.map(\.rating) == [4])
    }

    @Test func createFailsWhenCatalogExists() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "Existing.pixelloupe", directoryHint: .isDirectory)
        _ = try CatalogStore.create(at: packageURL, info: Fixtures.referencedInfo)
        #expect(throws: CatalogError.self) {
            try CatalogStore.create(at: packageURL, info: Fixtures.referencedInfo)
        }
    }

    @Test func openRejectsNonCatalogFolder() throws {
        let directory = try TemporaryDirectory()
        #expect(throws: CatalogError.self) {
            try CatalogStore.open(at: directory.url)
        }
    }

    @Test func openRejectsNewerFormat() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "Future.pixelloupe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        var info = Fixtures.referencedInfo
        info.formatVersion = CatalogInfo.currentFormatVersion + 1
        try PropertyListEncoder().encode(info).write(to: CatalogPackage.infoURL(in: packageURL))
        #expect(throws: CatalogError.self) {
            try CatalogStore.open(at: packageURL)
        }
    }

    @Test func thumbnailStoreLoadsAndCaches() async throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url)
        let source = try Fixtures.writeJPEG(to: directory.url.appending(path: "big.jpg"), width: 2000, height: 1000)
        let id = UUID()
        try ThumbnailStore.generateThumbnail(from: source, to: store.thumbnails.url(for: id))

        #expect(store.thumbnails.cachedImage(for: id) == nil)
        let image = try #require(await store.thumbnails.image(for: id))
        #expect(max(image.width, image.height) == ThumbnailStore.maxPixelSize)
        #expect(store.thumbnails.cachedImage(for: id) != nil)
    }
}
