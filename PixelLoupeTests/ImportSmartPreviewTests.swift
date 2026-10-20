import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

/// File Handling ▸ Build Smart Previews in the import window (RAW-123).
@Suite("Import: Build Smart Previews", .serialized)
struct ImportSmartPreviewTests {
    @Test func theChoiceIsRememberedAndKeptInPresets() throws {
        let defaults = try #require(UserDefaults(suiteName: "ImportSmartPreviewTests.settings"))
        defer { defaults.removePersistentDomain(forName: "ImportSmartPreviewTests.settings") }
        let catalog = URL(filePath: "/Catalogs/A.pixelloupe")
        let info = Fixtures.managedInfo(storage: URL(filePath: "/Storage"))
        let model = ImportOptionsModel(settings: .load(for: catalog, info: info, defaults: defaults))
        #expect(!model.buildsSmartPreviews, "off by default")
        #expect(!model.extras.buildsSmartPreviews)

        model.buildsSmartPreviews = true
        #expect(model.extras.buildsSmartPreviews)
        model.settings.save(for: catalog, defaults: defaults)
        #expect(ImportOptionsModel(settings: .load(for: catalog, info: info, defaults: defaults)).buildsSmartPreviews,
                "remembered with the catalog's import settings")

        // A preset carries it, both ways.
        let preset = ImportPreset(name: "Travel", settings: model.settings)
        let decoded = try JSONDecoder().decode(ImportPreset.self, from: JSONEncoder().encode(preset))
        let other = ImportOptionsModel(settings: .load(for: URL(filePath: "/Catalogs/B.pixelloupe"), info: info, defaults: defaults))
        #expect(!other.buildsSmartPreviews)
        other.apply(decoded.settings)
        #expect(other.buildsSmartPreviews)
    }

    @Test func settingsSavedBeforeTheChoiceExistedStillLoad() throws {
        var handling = ImportHandling()
        handling.skipsRejected = true
        handling.metadataPresetID = UUID()
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(handling)) as? [String: Any])
        #expect(json.removeValue(forKey: "buildsSmartPreviews") != nil)
        let decoded = try JSONDecoder().decode(ImportHandling.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == handling, "everything else is kept, and Build Smart Previews is off")
    }

    @Test func importedPhotosGetSmartPreviewsAfterTheImport() async throws {
        let directory = try TemporaryDirectory()
        let card = try directory.subdirectory("Card/DCIM")
        for index in 1...2 {
            try Fixtures.writeJPEG(to: card.appending(path: "IMG_000\(index).jpg"), width: 320, height: 240)
        }
        let store = try CatalogStore.inMemory(
            info: Fixtures.managedInfo(storage: try directory.subdirectory("Storage")), packageURL: directory.url.appending(path: "Test.pixelloupe")
        )
        let service = ImportService(store: store)
        let files = try await service.scan([card]).files.map(\.candidate)
        store.smartPreviewBuilder.start(after: .zero)
        defer { store.smartPreviewBuilder.stop() }

        _ = try await service.importPhotos([files[0]])
        var extras = ImportExtras()
        extras.buildsSmartPreviews = true
        _ = try await service.importPhotos([files[1]], extras: extras)
        await store.smartPreviewBuilder.waitUntilIdle()

        let photos = try store.viewContext.fetch(Photo.fetchRequest()).sorted { $0.fileName < $1.fileName }
        #expect(photos.map(\.fileName) == ["IMG_0001.jpg", "IMG_0002.jpg"])
        #expect(!store.smartPreviews.contains(photos[0]), "only when asked for")
        #expect(store.smartPreviews.contains(photos[1]))
        #expect(store.sourceStatus(of: photos[1]) == .originalAndSmartPreview)
    }
}
