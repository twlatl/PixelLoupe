import CoreData
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PixelLoupe

/// The app was RawLoupe (until RAW-52), then LightLoupe (until RAW-98). Catalogs, preferences and
/// presets from before each rename keep working.
@Suite("Rename compatibility")
@MainActor
struct RenameCompatibilityTests {
    @Test(arguments: ["Family Photos.lightloupe", "Family Photos.rawloupe"])
    func catalogsFromBeforeARenameStillOpen(name: String) throws {
        let directory = try TemporaryDirectory()
        let legacy = directory.url.appending(path: name, directoryHint: .isDirectory)
        var store: CatalogStore? = try CatalogStore.create(at: legacy, info: Fixtures.referencedInfo)
        let photo = Photo(context: try #require(store).viewContext)
        photo.id = UUID()
        photo.fileName = "a.jpg"
        photo.filePath = "/tmp/a.jpg"
        photo.fileType = "JPG"
        photo.captureDate = Date()
        photo.importDate = Date()
        photo.editDate = Date()
        try store?.viewContext.save()
        store = nil

        let reopened = try CatalogStore.open(at: legacy)
        #expect(try reopened.viewContext.count(for: Photo.fetchRequest()) == 1)
        #expect(CatalogPackage.isCatalog(legacy))
    }

    @Test func catalogTypes() {
        for name in ["New.pixelloupe", "Old.lightloupe", "Older.rawloupe", "UPPER.LIGHTLOUPE"] {
            #expect(CatalogPackage.isCatalog(URL(filePath: "/x/\(name)")), "\(name)")
        }
        #expect(!CatalogPackage.isCatalog(URL(filePath: "/x/photo.jpg")))
        #expect(CatalogPackage.fileExtension == "pixelloupe", "new catalogs use the new name")
        #expect(UTType.catalogTypes.map(\.identifier)
            == ["net.pixegen.pixelloupe.catalog", "net.tedlee.lightloupe.catalog", "net.tedlee.rawloupe.catalog"])
        #expect(UTType.catalogTypes.allSatisfy { $0.conforms(to: .package) })
    }

    @Test func preferencesComeAcrossOnceWithoutOverwriting() throws {
        let suite = "net.pixegen.PixelLoupe.RenameTest.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/new/path.pixelloupe", forKey: "Keep")

        // LightLoupe's preferences first, then RawLoupe's fill in only what's still missing.
        Defaults.migrate(from: ["LastCatalogPath": "/Users/me/Pictures/Family Photos.lightloupe", "MatteColor": 0.4, "Keep": "old"],
                         into: defaults, marker: "MigratedLightLoupePreferences")
        Defaults.migrate(from: ["LastCatalogPath": "/Users/me/Pictures/Family Photos.rawloupe", "ThumbnailSize": 180],
                         into: defaults, marker: "MigratedRawLoupePreferences")
        #expect(defaults.string(forKey: "LastCatalogPath") == "/Users/me/Pictures/Family Photos.lightloupe")
        #expect(defaults.double(forKey: "MatteColor") == 0.4 && defaults.integer(forKey: "ThumbnailSize") == 180)
        #expect(defaults.string(forKey: "Keep") == "/new/path.pixelloupe", "settings made since aren't overwritten")

        // Only once: a later launch doesn't copy again.
        defaults.removeObject(forKey: "MatteColor")
        Defaults.migrate(from: ["MatteColor": 0.9], into: defaults, marker: "MigratedLightLoupePreferences")
        #expect(defaults.object(forKey: "MatteColor") == nil)
        #expect(Defaults.legacyDomains.map(\.domain) == ["net.pixegen.loupe", "net.tedlee.LightLoupe", "net.tedlee.RawLoupe"])
    }

    @Test func presetsAndProfilesFolderIsCopiedOnce() throws {
        let directory = try TemporaryDirectory()
        let old = try directory.subdirectory("Pixegen/LightLoupe/Settings/My Looks")
        try Data("preset".utf8).write(to: old.appending(path: "Warm.xmp"))
        let oldRoot = directory.url.appending(path: "Pixegen/LightLoupe", directoryHint: .isDirectory)
        let new = directory.url.appending(path: "Pixegen/PixelLoupe", directoryHint: .isDirectory)

        #expect(AppSupport.migrate(from: oldRoot, to: new))
        let copied = new.appending(path: "Settings/My Looks/Warm.xmp")
        #expect(try String(contentsOf: copied, encoding: .utf8) == "preset")
        #expect(FileManager.default.fileExists(atPath: old.appending(path: "Warm.xmp").path(percentEncoded: false)), "the old folder stays")

        // Not again once the new folder exists, and not when there's nothing to copy.
        #expect(!AppSupport.migrate(from: oldRoot, to: new))
        #expect(!AppSupport.migrate(from: directory.url.appending(path: "Missing"), to: directory.url.appending(path: "Other")))
        #expect(AppSupport.directory.path(percentEncoded: false).hasSuffix("Pixegen/PixelLoupe/"))
    }
}
