import AppKit
import CoreData
import Foundation
import ImageIO
import Testing
@testable import PixelLoupe

/// Standard previews and Import ▸ File Handling ▸ Build Previews (RAW-84).
@Suite("Standard previews", .serialized)
@MainActor
struct StandardPreviewTests {
    private struct Setup {
        let directory: TemporaryDirectory
        let store: CatalogStore
        /// A camera RAW file (a DNG) and a JPEG.
        let raw: Photo
        let jpeg: Photo
    }

    private static let metadata = DNGMetadata(
        make: "Canon", model: "EOS R5", lensModel: nil, captureDate: Date(timeIntervalSince1970: 1_791_000_000),
        timeZone: nil, exposureTime: 1.0 / 125, aperture: 8, iso: 200, focalLength: 35
    )

    private static func writeDNG(to url: URL) throws {
        try LinearDNGWriter.write(
            DNGFixtures.image(width: 3200, height: 1800) { x, y in
                SIMD3(0.05 + 0.4 * Float(x) / 3199, 0.05 + 0.4 * Float(y) / 1799, 0.25)
            },
            metadata: metadata, to: url
        )
    }

    private func makeSetup() throws -> Setup {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.create(
            at: directory.url.appending(path: "C.pixelloupe", directoryHint: .isDirectory), info: Fixtures.referencedInfo
        )
        let folder = try directory.subdirectory("Photos")
        let rawURL = folder.appending(path: "IMG_1.dng"), jpegURL = folder.appending(path: "IMG_2.jpg")
        try Self.writeDNG(to: rawURL)
        try Fixtures.writeJPEG(to: jpegURL, width: 320, height: 240)
        let raw = makePhoto(in: store, url: rawURL), jpeg = makePhoto(in: store, url: jpegURL)
        try store.viewContext.save()
        // Not Auto, which would follow the test machine's displays.
        store.settings.standardPreviewSize = .pixels2560
        return Setup(directory: directory, store: store, raw: raw, jpeg: jpeg)
    }

    private func makePhoto(in store: CatalogStore, url: URL) -> Photo {
        let photo = Photo(context: store.viewContext)
        photo.id = UUID()
        photo.fileName = url.lastPathComponent
        photo.filePath = url.path(percentEncoded: false)
        photo.fileType = url.pathExtension.uppercased()
        photo.captureDate = Date()
        photo.importDate = Date()
        photo.editDate = Date()
        return photo
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    private func image(at url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test func buildingDrawsAP3PreviewAndThumbnailForRAWFilesOnly() async throws {
        let setup = try makeSetup()
        let store = setup.store
        let builder = store.standardPreviewBuilder
        var reported: [LibraryState.ImportStatus?] = []
        builder.onProgress = { reported.append($0) }
        builder.start(after: .zero)
        defer { builder.stop() }

        #expect(StandardPreviewBuilder.isEligible(setup.raw))
        #expect(!StandardPreviewBuilder.isEligible(setup.jpeg))
        builder.build([setup.raw, setup.jpeg])
        await builder.waitUntilIdle()

        let previews = store.standardPreviews
        #expect(previews.isCurrent(setup.raw.id))
        #expect(!previews.contains(setup.jpeg.id), "only camera RAW files")
        #expect(!exists(previews.url(for: setup.jpeg.id)))

        let preview = try image(at: previews.url(for: setup.raw.id))
        #expect(max(preview.width, preview.height) == StandardPreviewFormat.original.pixelSize)
        #expect(preview.colorSpace?.name == CGColorSpace.displayP3, "matches the loupe's render")

        let thumbnail = try image(at: store.thumbnails.url(for: setup.raw.id))
        #expect(max(thumbnail.width, thumbnail.height) == ThumbnailStore.maxPixelSize, "drawn from the same render")
        #expect(thumbnail.colorSpace?.name == CGColorSpace.sRGB)

        #expect(reported.first == LibraryState.ImportStatus(completed: 0, total: 1), "the JPEG isn't counted")
        #expect(reported.last == .some(nil), "idle again")
        let decoded = await previews.image(for: setup.raw.id)
        #expect(decoded?.width == preview.width)
        #expect(previews.cachedImage(for: setup.raw.id) != nil)
    }

    /// Catalog Settings ▸ Previews (RAW-267): a preview drawn at another size or quality is still shown, and drawn
    /// again when it's next viewed.
    @Test func changingSizeOrQualityRedrawsPreviewsWhenViewed() async throws {
        let setup = try makeSetup()
        let store = setup.store
        let builder = store.standardPreviewBuilder
        builder.start(after: .zero)
        defer { builder.stop() }
        builder.build([setup.raw])
        await builder.waitUntilIdle()
        let previews = store.standardPreviews
        let id = setup.raw.id
        #expect(Self.recordedFormat(at: previews.url(for: id)) == StandardPreviewFormat(pixelSize: 2560, quality: 0.8))

        store.settings.standardPreviewSize = .pixels1024
        store.settings.previewQuality = .high
        #expect(previews.format == StandardPreviewFormat(pixelSize: 1024, quality: 0.9))
        #expect(previews.isCurrent(id), "the old preview still counts")
        #expect(try image(at: previews.url(for: id)).width == 2560, "changing the setting leaves the files alone")

        let shown = await previews.image(for: id)
        #expect(shown?.width == 2560, "the outdated preview is shown")
        #expect(previews.outdated.contains(id))
        await builder.waitUntilIdle()

        #expect(!previews.outdated.contains(id))
        let redrawn = try image(at: previews.url(for: id))
        #expect(max(redrawn.width, redrawn.height) == 1024, "drawn again at the new size")
        #expect(Self.recordedFormat(at: previews.url(for: id)) == StandardPreviewFormat(pixelSize: 1024, quality: 0.9))
        #expect(await previews.image(for: id)?.width == 1024)
        #expect(!previews.outdated.contains(id), "current once drawn again")
    }

    /// Previews drawn before RAW-267 have no recorded format and count as 2560 px at Medium.
    @Test func previewsWithoutARecordedFormatCountAsTheOriginal() async throws {
        let setup = try makeSetup()
        let previews = setup.store.standardPreviews
        let id = setup.raw.id
        try FileManager.default.createDirectory(at: previews.directory, withIntermediateDirectories: true)
        try Fixtures.writeJPEG(to: previews.url(for: id), width: 2560, height: 1440)
        await previews.load()
        var redrawn: [UUID] = []
        previews.onOutdated = { redrawn.append($0) }

        #expect(await previews.image(for: id) != nil)
        #expect(redrawn.isEmpty, "at 2560 and Medium it's current")

        setup.store.settings.previewQuality = .low
        previews.onOutdated = { redrawn.append($0) }
        #expect(await previews.image(for: id) != nil)
        #expect(redrawn == [id])
    }

    private static func recordedFormat(at url: URL) -> StandardPreviewFormat? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return nil }
        return StandardPreviewFormat(tag: exif[kCGImagePropertyExifUserComment] as? String)
    }

    @Test func anEditMakesThePreviewStaleUntilItIsDrawnAgain() async throws {
        let setup = try makeSetup()
        let store = setup.store
        let builder = store.standardPreviewBuilder
        builder.rebuildDelay = .milliseconds(50)
        builder.start(after: .zero)
        defer { builder.stop() }
        builder.build([setup.raw])
        await builder.waitUntilIdle()
        let previews = store.standardPreviews
        let id = setup.raw.id
        let before = try Data(contentsOf: previews.url(for: id))
        #expect(store.thumbnails.rendersThroughDevelop(id), "its thumbnail is rendered even with default settings")
        #expect(!store.thumbnails.rendersThroughDevelop(setup.jpeg.id))

        var adjustments = setup.raw.adjustments
        adjustments.light.exposure = 1
        setup.raw.adjustments = adjustments
        store.viewContext.processPendingChanges()

        #expect(previews.contains(id), "it still has one")
        #expect(!previews.isCurrent(id), "but it isn't shown")
        #expect(previews.cachedImage(for: id) == nil)
        #expect(await previews.image(for: id) == nil)
        #expect(!exists(previews.url(for: id)))
        #expect(exists(StandardPreviewStore.staleURL(for: id, in: previews.directory)), "kept as stale across restarts")

        await builder.waitUntilIdle()
        #expect(previews.isCurrent(id), "drawn again once editing stopped")
        #expect(!exists(StandardPreviewStore.staleURL(for: id, in: previews.directory)))
        #expect(try Data(contentsOf: previews.url(for: id)) != before, "with the new settings")
    }

    @Test func editingAPhotoWithoutOneDoesNothing() async throws {
        let setup = try makeSetup()
        var adjustments = setup.raw.adjustments
        adjustments.light.exposure = 1
        setup.raw.adjustments = adjustments
        setup.store.viewContext.processPendingChanges()
        #expect(!setup.store.standardPreviews.contains(setup.raw.id), "viewing or editing never makes one")
        #expect(!exists(setup.store.standardPreviews.directory))
    }

    @Test func theFolderIsTheRecordAndStalePreviewsAreRedrawnWhenTheCatalogOpens() async throws {
        let setup = try makeSetup()
        let directory = setup.store.standardPreviews.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0]).write(to: StandardPreviewStore.url(for: setup.jpeg.id, in: directory))
        try Data([0]).write(to: StandardPreviewStore.staleURL(for: setup.raw.id, in: directory))
        try Data([0]).write(to: directory.appending(path: ".\(UUID().uuidString).jpg"))

        let previews = setup.store.standardPreviews
        await previews.load()
        #expect(previews.ids == [setup.jpeg.id, setup.raw.id])
        #expect(previews.stale == [setup.raw.id])

        let builder = setup.store.standardPreviewBuilder
        builder.start(after: .zero)
        defer { builder.stop() }
        await builder.waitUntilIdle()
        #expect(previews.isCurrent(setup.raw.id))
        #expect(previews.stale.isEmpty)
    }

    @Test func discardingAndPruningDeleteThePreviews() async throws {
        let setup = try makeSetup()
        let previews = setup.store.standardPreviews
        let directory = previews.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let orphan = UUID()
        for id in [setup.raw.id, setup.jpeg.id, orphan] {
            try Data([0]).write(to: StandardPreviewStore.url(for: id, in: directory))
        }
        try Data([0]).write(to: StandardPreviewStore.staleURL(for: orphan, in: directory))
        await previews.load()

        previews.discard([setup.jpeg.id])
        #expect(!previews.contains(setup.jpeg.id))
        #expect(!exists(StandardPreviewStore.url(for: setup.jpeg.id, in: directory)))

        StandardPreviewStore.pruneOrphans(in: directory, keeping: [setup.raw.id, setup.jpeg.id])
        #expect(exists(StandardPreviewStore.url(for: setup.raw.id, in: directory)))
        #expect(!exists(StandardPreviewStore.url(for: orphan, in: directory)))
        #expect(!exists(StandardPreviewStore.staleURL(for: orphan, in: directory)))
    }

    // MARK: - Import

    @Test func buildPreviewsIsMinimalByDefaultRememberedAndKeptInPresets() throws {
        let suite = "StandardPreviewTests.settings"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = URL(filePath: "/Catalogs/A.pixelloupe")
        let info = Fixtures.managedInfo(storage: URL(filePath: "/Storage"))
        let model = ImportOptionsModel(settings: .load(for: catalog, info: info, defaults: defaults))
        #expect(model.previews == .minimal)
        #expect(model.extras.previews == .minimal)

        model.previews = .standard
        #expect(model.extras.previews == .standard)
        model.settings.save(for: catalog, defaults: defaults)
        #expect(ImportOptionsModel(settings: .load(for: catalog, info: info, defaults: defaults)).previews == .standard)

        let preset = ImportPreset(name: "Wedding", settings: model.settings)
        let decoded = try JSONDecoder().decode(ImportPreset.self, from: JSONEncoder().encode(preset))
        let other = ImportOptionsModel(settings: .load(for: URL(filePath: "/Catalogs/B.pixelloupe"), info: info, defaults: defaults))
        #expect(other.previews == .minimal)
        other.apply(decoded.settings)
        #expect(other.previews == .standard)
    }

    @Test func settingsSavedBeforeBuildPreviewsExistedStillLoad() throws {
        var handling = ImportHandling()
        handling.buildsSmartPreviews = true
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(handling)) as? [String: Any])
        #expect(json.removeValue(forKey: "previews") != nil)
        let decoded = try JSONDecoder().decode(ImportHandling.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == handling)
        #expect(decoded.previews == .minimal)
    }

    @Test func importingWithStandardBuildsThemAfterTheImport() async throws {
        let directory = try TemporaryDirectory()
        let card = try directory.subdirectory("Card/DCIM")
        try Self.writeDNG(to: card.appending(path: "IMG_0001.dng"))
        try Self.writeDNG(to: card.appending(path: "IMG_0002.dng"))
        let store = try CatalogStore.inMemory(
            info: Fixtures.managedInfo(storage: try directory.subdirectory("Storage")), packageURL: directory.url.appending(path: "Test.pixelloupe")
        )
        let service = ImportService(store: store)
        let files = try await service.scan([card]).files.map(\.candidate).sorted { $0.source.url.lastPathComponent < $1.source.url.lastPathComponent }
        store.standardPreviewBuilder.start(after: .zero)
        defer { store.standardPreviewBuilder.stop() }

        _ = try await service.importPhotos([files[0]])
        var extras = ImportExtras()
        extras.previews = .standard
        _ = try await service.importPhotos([files[1]], extras: extras)
        await store.standardPreviewBuilder.waitUntilIdle()

        let photos = try store.viewContext.fetch(Photo.fetchRequest()).sorted { $0.fileName < $1.fileName }
        #expect(photos.map(\.fileName) == ["IMG_0001.dng", "IMG_0002.dng"])
        #expect(!store.standardPreviews.contains(photos[0].id), "Minimal")
        #expect(store.standardPreviews.isCurrent(photos[1].id))
    }
}
