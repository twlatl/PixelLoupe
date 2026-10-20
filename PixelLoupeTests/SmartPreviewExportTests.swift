import AppKit
import Foundation
import ImageIO
import Testing
@testable import PixelLoupe

/// Exporting photos whose original is missing from their Smart Preview, at its size (RAW-122).
@Suite("Exporting from Smart Previews")
struct SmartPreviewExportTests {
    /// A 3200 × 2400 JPEG with a camera in its metadata, and its Smart Preview, in `directory`.
    private func makeItem(in directory: TemporaryDirectory) throws -> ExportItem {
        let original = directory.url.appending(path: "IMG_0001.jpg")
        try Fixtures.writeJPEG(to: original, width: 3200, height: 2400)
        let proxy = directory.url.appending(path: "proxy.heic")
        try SmartPreviewWriter.write(original: original, to: proxy)
        return ExportItem(source: original, adjustments: PhotoAdjustments(), metadata: PhotoMetadata(), keywords: [], rating: 0,
                          captureDate: Date(), smartPreview: proxy)
    }

    private func settings(exportingTo folder: URL) -> ExportSettings {
        var settings = ExportSettings()
        settings.folderPath = folder.path(percentEncoded: false)
        settings.existingFiles = .overwrite
        return settings
    }

    private func pixelSize(_ url: URL) throws -> (width: Int, height: Int, model: String?) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0,
                tiff?[kCGImagePropertyTIFFModel] as? String)
    }

    @Test func aMissingOriginalIsExportedFromItsSmartPreviewAtItsSize() async throws {
        let directory = try TemporaryDirectory()
        let item = try makeItem(in: directory)
        let folder = try directory.subdirectory("Export")
        var settings = settings(exportingTo: folder)

        // With the original there, it's used, at full size.
        let plan = ExportPlan(items: [item], settings: settings, folder: folder)
        var result = await PhotoExporter.run(plan, settings: settings, watermark: nil) { _, _ in }
        #expect(result.failures.isEmpty && result.fromSmartPreviews.isEmpty)
        var exported = try pixelSize(plan.entries[0].url)
        #expect(exported.width == 3200 && exported.height == 2400)

        try FileManager.default.removeItem(at: item.source)
        result = await PhotoExporter.run(plan, settings: settings, watermark: nil) { _, _ in }
        #expect(result.failures.isEmpty && result.fromSmartPreviews == [plan.entries[0].url])
        exported = try pixelSize(plan.entries[0].url)
        #expect(exported.width == 2560 && exported.height == 1920, "the Smart Preview's size: \(exported)")
        #expect(exported.model == "EOS R5", "the original's metadata, from the Smart Preview")

        // Asked for more, it stays at the Smart Preview's size; asked for less, it's smaller.
        settings.resizes = true
        settings.resizeMode = .longEdge
        settings.edge = 4000
        settings.doesNotEnlarge = false
        _ = await PhotoExporter.run(plan, settings: settings, watermark: nil) { _, _ in }
        #expect(try pixelSize(plan.entries[0].url).width == 2560)
        settings.edge = 1000
        _ = await PhotoExporter.run(plan, settings: settings, watermark: nil) { _, _ in }
        #expect(try pixelSize(plan.entries[0].url).width == 1000)
    }

    @Test func nothingIsExportedIntoAnOfflineOriginalsFolder() async throws {
        let directory = try TemporaryDirectory()
        let offline = directory.url.appending(path: "Offline Drive/Photos", directoryHint: .isDirectory)
        var item = try makeItem(in: directory)
        item = ExportItem(source: offline.appending(path: "IMG_0001.jpg"), adjustments: item.adjustments, metadata: item.metadata,
                          keywords: [], rating: 0, captureDate: item.captureDate, smartPreview: item.smartPreview)
        var settings = settings(exportingTo: directory.url)
        settings.destination = .sameFolderAsOriginal
        settings.usesSubfolder = true
        let plan = ExportPlan(items: [item], settings: settings, folder: nil)
        let result = await PhotoExporter.run(plan, settings: settings, watermark: nil) { _, _ in }
        #expect(result.exported.isEmpty && result.failures == ["IMG_0001.jpg: The folder of “IMG_0001.jpg” isn’t available."])
        #expect(!FileManager.default.fileExists(atPath: offline.path(percentEncoded: false)), "the folder isn't made anew")
    }

    @Test @MainActor func theSummarySaysWhichPhotosCameFromSmartPreviews() throws {
        let folder = URL(filePath: "/Exports", directoryHint: .isDirectory)
        #expect(CatalogWindowController.exportSummary(PhotoExporter.Result(exported: [folder.appending(path: "A.jpg")])) == nil)

        let one = try #require(CatalogWindowController.exportSummary(PhotoExporter.Result(
            exported: [folder.appending(path: "A.jpg")], fromSmartPreviews: [folder.appending(path: "A.jpg")]
        )))
        #expect(one.messageText == "A photo was exported from its Smart Preview.")
        #expect(one.informativeText == "“A.jpg” was exported from its Smart Preview, at up to 2,560 pixels, because its original is missing.")

        let urls = ["A.jpg", "B.jpg"].map { folder.appending(path: $0) }
        let both = try #require(CatalogWindowController.exportSummary(PhotoExporter.Result(
            exported: urls, failures: ["C.jpg: “C.jpg” could not be read."], fromSmartPreviews: urls
        )))
        #expect(both.messageText == "1 photo could not be exported.")
        #expect(both.informativeText.hasPrefix("C.jpg: “C.jpg” could not be read.\n\n2 photos were exported from their Smart Previews"))
        #expect(both.informativeText.hasSuffix(":\nA.jpg\nB.jpg"))
    }
}
