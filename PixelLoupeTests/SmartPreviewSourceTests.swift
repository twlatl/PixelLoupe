import AppKit
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PixelLoupe

/// Photos drawn from their Smart Preview while the original is missing (RAW-120).
@Suite("Drawing from Smart Previews")
@MainActor
struct SmartPreviewSourceTests {
    private let metadata = DNGMetadata(
        make: "Canon", model: "EOS R5", lensModel: nil, captureDate: Date(timeIntervalSince1970: 1_791_000_000),
        timeZone: nil, exposureTime: 1.0 / 125, aperture: 8, iso: 200, focalLength: 35
    )

    private static let context = CIContext(options: [.workingColorSpace: DNGFixtures.linearRec2020, .cacheIntermediates: false])

    /// The pixel at a fraction of the image's width and height, in linear Rec. 2020.
    private func sample(_ image: CIImage, at point: (x: Double, y: Double)) -> SIMD3<Float> {
        let extent = image.extent
        let pixel = CGRect(x: (extent.minX + point.x * (extent.width - 1)).rounded(.down),
                           y: (extent.minY + point.y * (extent.height - 1)).rounded(.down), width: 1, height: 1)
        var rgba = [Float](repeating: 0, count: 4)
        Self.context.render(image, toBitmap: &rgba, rowBytes: 16, bounds: pixel, format: .RGBAf, colorSpace: DNGFixtures.linearRec2020)
        return SIMD3(rgba[0], rgba[1], rgba[2])
    }

    private func isClose(_ a: CGSize, _ b: CGSize) -> Bool { abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1 }

    @Test func aRAWFilesSmartPreviewPassesForItsOriginal() throws {
        let directory = try TemporaryDirectory()
        let original = directory.url.appending(path: "IMG_0001.dng"), proxy = directory.url.appending(path: "proxy.dng")
        try LinearDNGWriter.write(
            DNGFixtures.image(width: 3200, height: 1800) { x, y in
                SIMD3(0.05 + 0.4 * Float(x) / 3199, 0.05 + 0.4 * Float(y) / 1799, 0.25)
            },
            metadata: metadata, to: original
        )
        try SmartPreviewWriter.write(original: original, to: proxy)
        let location = PhotoSourceLocation(original: original, smartPreview: proxy)

        let fromOriginal = try #require(DevelopSource.open(location))
        #expect(!fromOriginal.isSmartPreview, "the original, while it can be read")
        let fromProxy = try #require(DevelopSource(smartPreview: proxy))
        #expect(fromProxy.isSmartPreview && fromProxy.isRaw)
        #expect(fromProxy.nativeSize == CGSize(width: 3200, height: 1800), "the original's size")
        #expect(fromProxy.reducesNoiseInPipeline && !fromOriginal.reducesNoiseInPipeline,
                "the RAW engine can't reduce noise in a Linear DNG")

        // Scales are the original's: below the proxy's own size it decodes smaller, above it enlarges.
        let adjustments = PhotoAdjustments()
        for scale in [0.25, 0.5, 1.0] {
            let expected = fromOriginal.image(with: adjustments, scale: scale), actual = fromProxy.image(with: adjustments, scale: scale)
            #expect(isClose(actual.extent.size, expected.extent.size), "at \(scale): \(actual.extent) against \(expected.extent)")
            for point in [(0.5, 0.5), (0.1, 0.9), (0.9, 0.2)] {
                let difference = sample(actual, at: point) - sample(expected, at: point)
                #expect(max(abs(difference.x), abs(difference.y), abs(difference.z)) < 0.02, "at \(scale), \(point): \(difference)")
            }
        }

        try FileManager.default.removeItem(at: original)
        #expect(try #require(DevelopSource.open(location)).isSmartPreview, "the Smart Preview once the original is gone")
        #expect(DevelopSource.open(PhotoSourceLocation(original: original)) == nil)
    }

    @Test func anImagesSmartPreviewIsSizedLikeItsOriginal() throws {
        let directory = try TemporaryDirectory()
        let original = directory.url.appending(path: "IMG_0002.jpg"), proxy = directory.url.appending(path: "proxy.heic")
        try Fixtures.writeJPEG(to: original, width: 3200, height: 2400)
        try SmartPreviewWriter.write(original: original, to: proxy)
        let source = try #require(DevelopSource(smartPreview: proxy))
        #expect(source.isSmartPreview && !source.isRaw && source.reducesNoiseInPipeline)
        #expect(source.nativeSize == CGSize(width: 3200, height: 2400))
        let image = source.image(with: PhotoAdjustments(), scale: 0.25)
        #expect(isClose(image.extent.size, CGSize(width: 800, height: 600)), "\(image.extent)")
        #expect(isClose(source.image(with: PhotoAdjustments(), scale: 1).extent.size, CGSize(width: 3200, height: 2400)))
    }

    @Test func thumbnailsDrawnFromSmartPreviewsAreRedrawnFromTheOriginal() async throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.create(
            at: directory.url.appending(path: "C.pixelloupe", directoryHint: .isDirectory), info: Fixtures.referencedInfo
        )
        let original = try Fixtures.writeJPEG(to: directory.url.appending(path: "IMG_0003.jpg"), width: 1200, height: 800)
        let photo = Photo(context: store.viewContext)
        photo.id = UUID()
        photo.fileName = original.lastPathComponent
        photo.filePath = original.path(percentEncoded: false)
        photo.fileType = "JPG"
        photo.captureDate = Date()
        photo.importDate = Date()
        photo.editDate = Date()
        var adjustments = PhotoAdjustments()
        adjustments.light.exposure = 1
        photo.adjustments = adjustments
        try store.viewContext.save()
        try FileManager.default.createDirectory(at: store.smartPreviews.directory, withIntermediateDirectories: true)
        let proxy = SmartPreviewStore.url(for: photo.id, fileExtension: "heic", in: store.smartPreviews.directory)
        try SmartPreviewWriter.write(original: original, to: proxy)
        store.smartPreviews.didWrite(proxy, for: photo.id)

        // While the original is missing, the edited thumbnail comes from the Smart Preview, and is listed.
        let moved = directory.url.appending(path: "elsewhere.jpg")
        try FileManager.default.moveItem(at: original, to: moved)
        #expect(await store.thumbnails.render(id: photo.id, source: store.sourceLocation(of: photo), adjustments: photo.adjustments))
        #expect(store.thumbnails.drawnFromSmartPreviews == [photo.id])
        #expect(SeededThumbnails.load(from: store.thumbnails.directory, origin: .smartPreview) == [photo.id])
        #expect(SeededThumbnails.load(from: store.thumbnails.directory).isEmpty, "not mixed up with Lightroom's")

        // Once it's back, the maintenance pass draws it from the original.
        try FileManager.default.moveItem(at: moved, to: original)
        store.thumbnailMaintenance.start(after: .zero)
        await store.thumbnailMaintenance.waitUntilIdle()
        store.thumbnailMaintenance.stop()
        #expect(store.thumbnails.drawnFromSmartPreviews.isEmpty)
        #expect(SeededThumbnails.load(from: store.thumbnails.directory, origin: .smartPreview).isEmpty)
    }

    @Test func theLensPanelSaysWhenTheBuiltInProfileIsOnlyOnTheOriginal() throws {
        let panel = LensPanelViewController()
        _ = panel.view
        panel.isEditingEnabled = true
        func statusLabel(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.accessibilityIdentifier() == "lensStatus" { return field }
            return view.subviews.lazy.compactMap(statusLabel).first
        }
        let label = try #require(statusLabel(in: panel.view))
        var lens = PhotoAdjustments.LensCorrections()
        lens.enableProfileCorrections = true
        panel.display(lens, status: .builtIn, catalog: LensCatalog(), builtInAlwaysOn: false, onSmartPreview: true)
        #expect(label.stringValue == "The Built-in Lens Profile is applied to the original only.")
        panel.display(lens, status: .builtIn, catalog: LensCatalog(), builtInAlwaysOn: true, onSmartPreview: true)
        #expect(label.stringValue == "Built-in Lens Profile applied.", "a camera that always applies it: it's in the Smart Preview")
        panel.display(lens, status: .builtIn, catalog: LensCatalog(), builtInAlwaysOn: false)
        #expect(label.stringValue == "Built-in Lens Profile applied.")
    }
}
