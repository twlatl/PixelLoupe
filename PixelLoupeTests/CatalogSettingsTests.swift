import AppKit
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Catalog Settings")
struct CatalogSettingsTests {
    @Test func missingFileReadsAsDefaultsAndRoundTrips() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "Family.pixelloupe", directoryHint: .isDirectory)
        _ = try CatalogStore.create(at: packageURL, info: Fixtures.referencedInfo)

        #expect(!FileManager.default.fileExists(atPath: CatalogPackage.settingsURL(in: packageURL).path(percentEncoded: false)),
                "the file is only written once a setting changes")
        #expect(CatalogSettings.load(from: packageURL) == CatalogSettings())

        try CatalogSettings().save(to: packageURL)
        #expect(CatalogSettings.load(from: packageURL) == CatalogSettings())
        #expect(try CatalogStore.open(at: packageURL).settings == CatalogSettings())
    }

    @Test func unreadableFileReadsAsDefaults() throws {
        let directory = try TemporaryDirectory()
        try Data("not a plist".utf8).write(to: CatalogPackage.settingsURL(in: directory.url))
        #expect(CatalogSettings.load(from: directory.url) == CatalogSettings())
    }

    /// Size counts the database and the package's plists, not thumbnails or previews.
    @Test func generalPaneSizeCountsOnlyTheDatabase() async throws {
        let directory = try TemporaryDirectory()
        let package = directory.url
        func write(_ bytes: Int, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: url)
        }
        let database = CatalogPackage.databaseURL(in: package)
        try write(1000, to: database)
        try write(200, to: URL(filePath: database.path(percentEncoded: false) + "-wal"))
        try write(30, to: URL(filePath: database.path(percentEncoded: false) + "-shm"))
        try write(4, to: CatalogPackage.infoURL(in: package))
        try write(5, to: CatalogPackage.viewStateURL(in: package))
        try write(6, to: CatalogPackage.settingsURL(in: package))
        try write(50_000, to: CatalogPackage.thumbnailsURL(in: package).appending(path: "a.jpg"))
        try write(60_000, to: CatalogPackage.standardPreviewsURL(in: package).appending(path: "b.jpg"))
        try write(70_000, to: CatalogPackage.smartPreviewsURL(in: package).appending(path: "c.dng"))

        #expect(await CatalogGeneralSettingsView.databaseSize(of: package) == 1245)
    }

    @Test func menuItemIsUnderSettingsWithLightroomShortcut() throws {
        let appMenu = try #require(MainMenu.make().items.first?.submenu)
        let titles = appMenu.items.map(\.title)
        let index = try #require(titles.firstIndex(of: "Catalog Settings…"))
        #expect(titles[index - 1] == "Settings…")
        let item = appMenu.items[index]
        #expect(item.keyEquivalent == ",")
        #expect(item.keyEquivalentModifierMask == [.command, .option])
    }

    // MARK: Previews (RAW-267)

    @Test func previewSettingsDefaultToAutoMediumAndNoLimit() throws {
        let settings = CatalogSettings()
        #expect(settings.standardPreviewSize == .auto)
        #expect(settings.previewQuality == .medium)
        #expect(settings.previewCacheLimitBytes == nil)
        #expect(settings.standardPreviewFormat(autoPixelSize: 5120) == StandardPreviewFormat(pixelSize: 5120, quality: 0.8))
    }

    @Test func previewSettingsRoundTripAndUnknownValuesReadAsDefaults() throws {
        let directory = try TemporaryDirectory()
        var settings = CatalogSettings()
        settings.standardPreviewSize = .pixels1440
        settings.previewQuality = .low
        settings.previewCacheLimitGB = 2.5
        try settings.save(to: directory.url)
        let loaded = CatalogSettings.load(from: directory.url)
        #expect(loaded == settings)
        #expect(loaded.previewCacheLimitBytes == 2_500_000_000)
        #expect(loaded.standardPreviewFormat(autoPixelSize: 5120) == StandardPreviewFormat(pixelSize: 1440, quality: 0.6))

        // A size or quality a later version added reads as the default, keeping the other settings.
        let plist: [String: Any] = ["standardPreviewSize": 9999, "previewQuality": "ultra", "previewCacheLimitGB": 3.0]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: CatalogPackage.settingsURL(in: directory.url))
        let later = CatalogSettings.load(from: directory.url)
        #expect(later.standardPreviewSize == .auto)
        #expect(later.previewQuality == .medium)
        #expect(later.previewCacheLimitGB == 3)
    }

    @Test func aLimitOfZeroIsNoLimit() {
        var settings = CatalogSettings()
        settings.previewCacheLimitGB = 0
        #expect(settings.previewCacheLimitBytes == nil)
    }

    @Test func previewFormatTagsRoundTrip() {
        for format in [StandardPreviewFormat.original, .init(pixelSize: 5120, quality: 0.9), .init(pixelSize: 1024, quality: 0.6)] {
            #expect(StandardPreviewFormat(tag: format.tag) == format)
        }
        #expect(StandardPreviewFormat.original.tag == "PixelLoupe Standard Preview 2560 q0.80")
        #expect(StandardPreviewFormat(tag: nil) == nil)
        #expect(StandardPreviewFormat(tag: "Adobe Photoshop") == nil)
    }

    @Test func autoSizeIsTheOriginalWithNoDisplays() {
        #expect(CatalogStore.autoPreviewPixelSize(screens: []) == 2560)
    }

    /// Limit Preview Cache Size removes the least recently viewed previews first, just enough to fit.
    @Test func cacheLimitRemovesTheLeastRecentlyViewed() async throws {
        let directory = try TemporaryDirectory()
        let ids = (0..<4).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            var url = StandardPreviewStore.url(for: id, in: directory.url)
            try Data(count: 1000).write(to: url)
            var values = URLResourceValues()
            // Viewed in the order 2, 0, 3, 1 (oldest first).
            values.contentModificationDate = Date(timeIntervalSince1970: TimeInterval([2, 4, 1, 3][index]) * 1000)
            try url.setResourceValues(values)
        }
        try Data(count: 1000).write(to: directory.url.appending(path: ".being-written.jpg"))

        #expect(await StandardPreviewStore.leastRecentlyViewed(in: directory.url, over: 4000).isEmpty)
        #expect(await StandardPreviewStore.leastRecentlyViewed(in: directory.url, over: 2500) == [ids[2], ids[0]])
        #expect(await StandardPreviewStore.leastRecentlyViewed(in: directory.url, over: 0) == [ids[2], ids[0], ids[3], ids[1]])
    }

    @Test func previewsPaneSizesCountPreviewsAndThumbnailsApartFromSmartPreviews() async throws {
        let directory = try TemporaryDirectory()
        let package = directory.url
        for (bytes, folder) in [(100, CatalogPackage.standardPreviewsURL(in: package)), (20, CatalogPackage.thumbnailsURL(in: package)),
                                (3000, CatalogPackage.smartPreviewsURL(in: package))] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(count: bytes).write(to: folder.appending(path: "\(UUID().uuidString).jpg"))
        }
        let sizes = await CatalogPreviewSettingsView.sizes(of: package)
        #expect(sizes == CatalogPreviewSettingsView.Sizes(previewCache: 120, smartPreviews: 3000))
    }
}
