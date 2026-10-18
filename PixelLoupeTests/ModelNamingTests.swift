import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Model naming")
@MainActor
struct ModelNamingTests {
    /// `@NSManaged var copyName` made every read of a virtual copy's name over-release its string, and
    /// Core Data crashed freeing the row (Objective-C treats a getter named `copy…`, `new…`, `alloc…`,
    /// `init…` or `mutableCopy…` as returning an owned object; Core Data's accessor doesn't). Photo
    /// reads `copyName` through key-value coding instead. Any other such name is a bug waiting to happen.
    @Test func noPropertyNameIsAnObjectiveCMethodFamily() {
        let handledByKeyValueCoding: Set<String> = ["Photo.copyName"]
        let family = /^(copy|new|alloc|init|mutableCopy)([A-Z_].*)?$/
        for entity in CatalogStore.managedObjectModel.entities {
            for name in entity.propertiesByName.keys where !handledByKeyValueCoding.contains("\(entity.name ?? "").\(name)") {
                #expect(name.wholeMatch(of: family) == nil, "\(entity.name ?? "?").\(name) starts with a reserved Objective-C method family")
            }
        }
    }

    /// A virtual copy's name survives a save and a fresh read from the store.
    @Test func copyNameRoundTripsThroughTheStore() throws {
        let directory = try TemporaryDirectory()
        let package = directory.url.appending(path: "Names.pixelloupe", directoryHint: .isDirectory)
        var store: CatalogStore? = try CatalogStore.create(at: package, info: CatalogInfo(name: "Names", storageMode: .referenced))
        let context = try #require(store).viewContext
        let photo = Photo(context: context)
        photo.id = UUID()
        photo.fileName = "a.jpg"
        photo.filePath = "/tmp/a.jpg"
        photo.fileType = "jpg"
        photo.captureDate = Date()
        photo.editDate = Date()
        photo.importDate = Date()
        photo.copyName = "AdobeRGB, Perceptual"
        try context.save()
        context.reset()
        let fetched = try #require(try context.fetch(Photo.fetchRequest()).first)
        #expect(fetched.copyName == "AdobeRGB, Perceptual")
        context.reset()
        store = nil
    }
}
