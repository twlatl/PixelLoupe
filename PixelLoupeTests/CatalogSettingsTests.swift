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
}
