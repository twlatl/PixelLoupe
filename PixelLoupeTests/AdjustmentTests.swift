import CoreData
import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Adjustments model")
struct PhotoAdjustmentsTests {
    @Test func defaultsStoreNothing() {
        #expect(PhotoAdjustments().isDefault)
        #expect(PhotoAdjustments().encoded == nil)
        #expect(PhotoAdjustments(data: nil) == .default)
        #expect(PhotoAdjustments(data: Data("garbage".utf8)) == .default)
    }

    @Test func roundTripsThroughJSON() throws {
        var adjustments = PhotoAdjustments()
        adjustments.light.exposure = 0.7
        adjustments.color.shadows = .init(hue: 0.6, amount: 0.4, luminance: -0.2)
        adjustments.curves.red = ToneCurve(outputs: [0, 0.25, 0.6, 0.75, 1])
        adjustments.selectiveColor[.blue].saturation = -0.5
        adjustments.whiteBalance.temperature = 5200
        adjustments.blackAndWhite.isEnabled = true
        let data = try #require(adjustments.encoded)
        #expect(PhotoAdjustments(data: data) == adjustments)
        #expect(adjustments.encoded == data, "encoding is stable")
    }

    @Test func activeOnlyWhenEnabledAndChanged() {
        var adjustments = PhotoAdjustments()
        #expect(!adjustments.light.isActive)
        #expect(!adjustments.blackAndWhite.isActive, "Black & White is off by default")
        #expect(!adjustments.whiteBalance.isActive, "As Shot white balance is not an adjustment")

        adjustments.light.exposure = 1
        #expect(adjustments.light.isActive)
        adjustments.light.isEnabled = false
        #expect(!adjustments.light.isActive)

        adjustments.blackAndWhite.isEnabled = true
        #expect(adjustments.blackAndWhite.isActive)
        adjustments.whiteBalance.tint = 10
        #expect(adjustments.whiteBalance.isActive)
    }

    @Test func photoClearsDataWhenReset() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url)
        let photo = Photo(context: store.viewContext)
        var adjustments = PhotoAdjustments()
        adjustments.vignette.strength = 0.5
        photo.adjustments = adjustments
        #expect(photo.adjustmentsData != nil)
        #expect(photo.adjustments == adjustments)
        photo.adjustments = .default
        #expect(photo.adjustmentsData == nil)
    }
}

@Suite("Tone curve")
struct ToneCurveTests {
    @Test func identityIsLinear() {
        for x in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect(abs(ToneCurve.identity.value(at: x) - x) < 1e-9)
        }
    }

    @Test func passesThroughControlPoints() {
        let curve = ToneCurve(outputs: [0.1, 0.3, 0.6, 0.85, 0.95])
        for (x, y) in zip(ToneCurve.legacyInputs, [0.1, 0.3, 0.6, 0.85, 0.95]) {
            #expect(abs(curve.value(at: x) - y) < 1e-9)
        }
    }

    @Test func monotoneCurveNeverOvershoots() {
        let curve = ToneCurve(outputs: [0, 0.05, 0.9, 0.95, 1])
        var previous = -1.0
        for step in 0...200 {
            let value = curve.value(at: Double(step) / 200)
            #expect(value >= previous - 1e-9)
            #expect((0...1).contains(value))
            previous = value
        }
    }
}

@Suite("Color lookup table")
struct ColorLUTTests {
    private func transform(_ configure: (inout PhotoAdjustments) -> Void) throws -> ColorLUT.Transform {
        var adjustments = PhotoAdjustments()
        configure(&adjustments)
        return ColorLUT.Transform(key: try #require(ColorLUT.key(for: adjustments)))
    }

    @Test func noTableWhenNothingUsesIt() {
        var adjustments = PhotoAdjustments()
        #expect(ColorLUT.key(for: adjustments) == nil)
        adjustments.light.exposure = 1          // handled by the RAW engine / exposure filter
        adjustments.vignette.strength = 0.5     // handled by its own filter
        #expect(ColorLUT.key(for: adjustments) == nil)
        adjustments.light.contrast = 0.5
        #expect(ColorLUT.key(for: adjustments) != nil)
    }

    @Test func cubeDataHasExpectedSize() throws {
        var adjustments = PhotoAdjustments()
        adjustments.levels.inputBlack = 0.1
        let data = ColorLUT.cubeData(for: try #require(ColorLUT.key(for: adjustments)))
        #expect(data.count == ColorLUT.dimension * ColorLUT.dimension * ColorLUT.dimension * 4 * MemoryLayout<Float>.size)
    }

    @Test func contrastSpreadsTones() throws {
        let t = try transform { $0.light.contrast = 0.8 }
        #expect(t.apply(0.25, 0.25, 0.25).r < 0.25)
        #expect(t.apply(0.75, 0.75, 0.75).r > 0.75)
        #expect(abs(t.apply(0.5, 0.5, 0.5).r - 0.5) < 0.01)
    }

    @Test func levelsRemapInputRange() throws {
        let t = try transform {
            $0.levels.inputBlack = 0.2
            $0.levels.inputWhite = 0.8
        }
        #expect(t.apply(0.2, 0.2, 0.2).r < 0.01)
        #expect(t.apply(0.8, 0.8, 0.8).r > 0.99)
    }

    @Test func channelCurveAffectsOnlyThatChannel() throws {
        let t = try transform { $0.curves.red = ToneCurve(outputs: [0, 0.4, 0.75, 0.9, 1]) }
        let result = t.apply(0.5, 0.5, 0.5)
        #expect(result.r > 0.7)
        #expect(abs(result.g - 0.5) < 0.01)
        #expect(abs(result.b - 0.5) < 0.01)
    }

    @Test func blackAndWhiteRemovesColor() throws {
        let t = try transform { $0.blackAndWhite.isEnabled = true }
        let result = t.apply(0.9, 0.2, 0.1)
        #expect(abs(result.r - result.g) < 0.001)
        #expect(abs(result.g - result.b) < 0.001)
    }

    @Test func shadowWheelTintsShadowsMoreThanHighlights() throws {
        // Hue 2/3 is blue.
        let t = try transform { $0.color.shadows = .init(hue: 2.0 / 3.0, amount: 1) }
        let dark = t.apply(0.15, 0.15, 0.15)
        let light = t.apply(0.9, 0.9, 0.9)
        #expect(dark.b - dark.r > 0.1)
        #expect(light.b - light.r < 0.02)
    }

    @Test func selectiveColorTargetsOneHue() throws {
        let t = try transform { $0.selectiveColor[.red].saturation = -1 }
        let red = t.apply(0.9, 0.1, 0.1)
        let blue = t.apply(0.1, 0.1, 0.9)
        #expect(abs(red.r - red.g) < 0.05, "reds are desaturated")
        #expect(blue.b - blue.r > 0.7, "blues are untouched")
    }
}

@Suite("Render pipeline")
struct RenderPipelineTests {
    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    private func averageColor(_ image: CIImage, in rect: CGRect? = nil) -> (r: Double, g: Double, b: Double) {
        let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: rect ?? image.extent),
        ])!
        var pixel = [Float](repeating: 0, count: 4)
        context.render(filter.outputImage!, toBitmap: &pixel, rowBytes: 16,
                       bounds: filter.outputImage!.extent, format: .RGBAf, colorSpace: nil)
        return (Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
    }

    /// Kept alive for the whole test so the source file isn't deleted while it's being read.
    private let directory: TemporaryDirectory
    private let source: DevelopSource

    init() throws {
        directory = try TemporaryDirectory()
        let url = try Fixtures.writeJPEG(to: directory.url.appending(path: "photo.jpg"), width: 400, height: 300)
        source = try #require(DevelopSource(url: url))
    }

    @Test func defaultAdjustmentsLeaveImageUnchanged() throws {
        let original = averageColor(source.baseImage(with: .default, scale: 1))
        let rendered = averageColor(source.image(with: .default, scale: 1))
        #expect(abs(original.r - rendered.r) < 0.001 && abs(original.b - rendered.b) < 0.001)
    }

    @Test func exposureBrightens() throws {
        var adjustments = PhotoAdjustments()
        adjustments.light.exposure = 1
        let before = averageColor(source.image(with: .default, scale: 1))
        let after = averageColor(source.image(with: adjustments, scale: 1))
        #expect(after.g > before.g * 1.3)
    }

    @Test func blackAndWhiteDesaturates() throws {
        var adjustments = PhotoAdjustments()
        adjustments.blackAndWhite.isEnabled = true
        let color = averageColor(source.image(with: adjustments, scale: 1))
        #expect(abs(color.r - color.b) < 0.02)
    }

    @Test func vignetteDarkensCorners() throws {
        var adjustments = PhotoAdjustments()
        adjustments.vignette.strength = 1
        let image = source.image(with: adjustments, scale: 1)
        let corner = averageColor(image, in: CGRect(x: 0, y: 0, width: 20, height: 20))
        let center = averageColor(image, in: CGRect(x: 190, y: 140, width: 20, height: 20))
        #expect(corner.g < center.g * 0.8)
    }

    private func toneStats(_ image: CIImage) -> (mean: Double, deviation: Double) {
        let extent = image.extent
        let width = Int(extent.width), height = Int(extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &pixels, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: nil)
        let greens = stride(from: 1, to: pixels.count, by: 4).map { Double(pixels[$0]) }
        let mean = greens.reduce(0, +) / Double(greens.count)
        let variance = greens.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(greens.count)
        return (mean, variance.squareRoot())
    }

    /// Grain adds texture without replacing or brightening the photo.
    @Test(arguments: [0.01, 0.5, 1.0])
    func grainKeepsThePhoto(amount: Double) throws {
        var plain = PhotoAdjustments()
        plain.blackAndWhite.isEnabled = true
        var grainy = plain
        grainy.effects.grain = amount
        let scale = source.scale(toFit: 200)
        let before = toneStats(source.image(with: plain, scale: scale))
        let after = toneStats(source.image(with: grainy, scale: scale))
        #expect(abs(after.mean - before.mean) < 0.03, "average brightness is preserved")
        if amount >= 0.5 {
            #expect(after.deviation > before.deviation + 0.01, "grain is visible")
        }
        #expect(after.deviation - before.deviation < amount * 0.25 + 0.01, "grain is texture, not noise replacing the image")
    }

    @Test func everySectionRendersAtReducedScale() throws {
        var adjustments = PhotoAdjustments()
        adjustments.light = .init(exposure: 0.3, brilliance: 0.4, highlights: -0.5, shadows: 0.5, brightness: 0.2, contrast: 0.3, blackPoint: 0.2)
        adjustments.color.midtones = .init(hue: 0.1, amount: 0.5, luminance: 0.1)
        adjustments.blackAndWhite = .init(isEnabled: true, intensity: 0.5, neutrals: 0.3, tone: 0.2)
        adjustments.effects.grain = 0.4
        adjustments.redEye.isEnabled = true
        adjustments.whiteBalance = .init(temperature: 5000, tint: 10)
        adjustments.curves.rgb = ToneCurve(outputs: [0, 0.2, 0.55, 0.8, 1])
        adjustments.levels = .init(inputBlack: 0.05, inputWhite: 0.95, gamma: 1.2)
        adjustments.definition.intensity = 0.5
        adjustments.selectiveColor[.green].hue = 0.5
        adjustments.noiseReduction = .init(amount: 0.3, color: 0.3)
        adjustments.sharpen.intensity = 0.5
        adjustments.vignette.strength = 0.4

        let image = source.image(with: adjustments, scale: source.scale(toFit: 200))
        #expect(image.extent.size == CGSize(width: 200, height: 150))
        let cgImage = context.createCGImage(image, from: image.extent)
        #expect(cgImage?.width == 200)
    }

    @Test func asShotWhiteBalanceForNonRawIsNeutral() throws {
        #expect(!source.isRaw)
        #expect(source.asShotWhiteBalance.temperature == 6500)
        #expect(source.asShotWhiteBalance.tint == 0)
    }
}

@Suite("Edited thumbnails")
struct EditedThumbnailTests {
    @Test func editingRegeneratesThumbnail() async throws {
        let directory = try TemporaryDirectory()
        let source = try directory.subdirectory("Source")
        try Fixtures.writeJPEG(to: source.appending(path: "a.jpg"), width: 300, height: 200)
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "Test.pixelloupe"))
        _ = try await ImportService(store: store).importPhotos(from: [source])
        let photo = try #require(try store.viewContext.fetch(Photo.fetchRequest()).first)
        let thumbnailURL = store.thumbnails.url(for: photo.id)
        let original = try Data(contentsOf: thumbnailURL)

        let updated = NotificationCenter.default.notifications(named: ThumbnailStore.didUpdateNotification)
        var adjustments = PhotoAdjustments()
        adjustments.blackAndWhite.isEnabled = true
        photo.adjustments = adjustments
        store.save()

        for await notification in updated {
            if notification.userInfo?["id"] as? UUID == photo.id { break }
        }
        let regenerated = try Data(contentsOf: thumbnailURL)
        #expect(regenerated != original)

        let image = try #require(await store.thumbnails.image(for: photo.id))
        let provider = try #require(image.dataProvider?.data as Data?)
        let bytesPerPixel = image.bitsPerPixel / 8
        let middle = (image.height / 2) * image.bytesPerRow + (image.width / 2) * bytesPerPixel
        #expect(abs(Int(provider[middle]) - Int(provider[middle + 2])) <= 3, "thumbnail is monochrome")
    }
}

@Suite("Catalog migration")
struct CatalogMigrationTests {
    @Test func opensVersionOneCatalog() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "Old.pixelloupe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(Fixtures.referencedInfo).write(to: CatalogPackage.infoURL(in: packageURL))

        // Create a store with the original model, as RAW-2's first build did.
        let momd = try #require(Bundle(for: Photo.self).url(forResource: "PixelLoupe", withExtension: "momd"))
        let v1 = try #require(NSManagedObjectModel(contentsOf: momd.appending(path: "PixelLoupe.mom")))
        #expect(v1.entitiesByName["Photo"]?.attributesByName["adjustmentsData"] == nil)
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: v1)
            _ = try coordinator.addPersistentStore(type: .sqlite, at: CatalogPackage.databaseURL(in: packageURL))
            let context = NSManagedObjectContext(.mainQueue)
            context.persistentStoreCoordinator = coordinator
            let photo = NSEntityDescription.insertNewObject(forEntityName: "Photo", into: context)
            photo.setValue(UUID(), forKey: "id")
            photo.setValue("old.jpg", forKey: "fileName")
            photo.setValue(Date(), forKey: "captureDate")
            photo.setValue(Date(), forKey: "importDate")
            photo.setValue(Date(), forKey: "editDate")
            photo.setValue(3, forKey: "rating")
            try context.save()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }

        let store = try CatalogStore.open(at: packageURL)
        let photo = try #require(try store.viewContext.fetch(Photo.fetchRequest()).first)
        #expect(photo.fileName == "old.jpg")
        #expect(photo.rating == 3)
        #expect(photo.adjustments == .default)
    }

    @Test func opensVersionTwoCatalog() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "V2.pixelloupe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(Fixtures.referencedInfo).write(to: CatalogPackage.infoURL(in: packageURL))

        // A store from before RAW-12 added catalog metadata.
        let momd = try #require(Bundle(for: Photo.self).url(forResource: "PixelLoupe", withExtension: "momd"))
        let v2 = try #require(NSManagedObjectModel(contentsOf: momd.appending(path: "PixelLoupe 2.mom")))
        #expect(v2.entitiesByName["Photo"]?.attributesByName["metadataData"] == nil)
        var adjustments = PhotoAdjustments()
        adjustments.light.exposure = 0.7
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: v2)
            _ = try coordinator.addPersistentStore(type: .sqlite, at: CatalogPackage.databaseURL(in: packageURL))
            let context = NSManagedObjectContext(.mainQueue)
            context.persistentStoreCoordinator = coordinator
            let photo = NSEntityDescription.insertNewObject(forEntityName: "Photo", into: context)
            photo.setValue(UUID(), forKey: "id")
            photo.setValue("v2.jpg", forKey: "fileName")
            photo.setValue(Date(), forKey: "captureDate")
            photo.setValue(Date(), forKey: "importDate")
            photo.setValue(Date(), forKey: "editDate")
            photo.setValue(adjustments.encoded, forKey: "adjustmentsData")
            try context.save()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }

        let store = try CatalogStore.open(at: packageURL)
        let photo = try #require(try store.viewContext.fetch(Photo.fetchRequest()).first)
        #expect(photo.fileName == "v2.jpg")
        #expect(photo.adjustments.light.exposure == 0.7)
        #expect(photo.metadata.isEmpty)
        photo.metadata[.title] = "Now editable"
        try store.viewContext.save()
        #expect(PhotoMetadata(data: photo.metadataData)[.title] == "Now editable")
    }

    @Test func opensVersionThreeCatalog() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "V3.pixelloupe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(Fixtures.referencedInfo).write(to: CatalogPackage.infoURL(in: packageURL))

        // A store from before RAW-18 added collections.
        let momd = try #require(Bundle(for: Photo.self).url(forResource: "PixelLoupe", withExtension: "momd"))
        let v3 = try #require(NSManagedObjectModel(contentsOf: momd.appending(path: "PixelLoupe 3.mom")))
        #expect(v3.entitiesByName["PhotoCollection"] == nil)
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: v3)
            _ = try coordinator.addPersistentStore(type: .sqlite, at: CatalogPackage.databaseURL(in: packageURL))
            let context = NSManagedObjectContext(.mainQueue)
            context.persistentStoreCoordinator = coordinator
            let photo = NSEntityDescription.insertNewObject(forEntityName: "Photo", into: context)
            photo.setValue(UUID(), forKey: "id")
            photo.setValue("v3.jpg", forKey: "fileName")
            photo.setValue(Date(), forKey: "captureDate")
            photo.setValue(Date(), forKey: "importDate")
            photo.setValue(Date(), forKey: "editDate")
            try context.save()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }

        let store = try CatalogStore.open(at: packageURL)
        let photo = try #require(try store.viewContext.fetch(Photo.fetchRequest()).first)
        #expect(photo.fileName == "v3.jpg" && photo.collections.isEmpty)
        let collection = CollectionEditing(store: store).create(.collection, named: "Now possible", in: nil, photos: [photo.objectID])
        #expect(collection.photos == [photo])
    }
}
