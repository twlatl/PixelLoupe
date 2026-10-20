import CoreData
import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

/// The exposure correction that keeps camera RAW files' Smart Previews as bright as their originals away from As Shot
/// (RAW-121).
@Suite("Smart Preview white balance")
struct SmartPreviewWhiteBalanceTests {
    /// A table whose error is `mired / 100 + tint / 10`, which is linear in what the table interpolates in.
    private let linear = SmartPreviewWhiteBalance(errors: SmartPreviewWhiteBalance.temperatures.map { temperature in
        SmartPreviewWhiteBalance.tints.map { 1e6 / temperature / 100 + $0 / 10 }
    })

    @Test func theTableInterpolatesInMiredAndTint() {
        for (temperature, tint) in [(2500.0, -30.0), (5000, 0), (3200, 12), (7000, -21), (12000, 30)] {
            #expect(abs(linear.error(temperature: temperature, tint: tint) - (1e6 / temperature / 100 + tint / 10)) < 1e-9,
                    "\(temperature) K / \(tint)")
        }
        // Beyond the table it holds its edge.
        #expect(linear.error(temperature: 2000, tint: -50) == linear.error(temperature: 2500, tint: -30))
        #expect(linear.error(temperature: 50000, tint: 80) == linear.error(temperature: 12000, tint: 30))
    }

    @Test func theCorrectionIsZeroAtAsShotAndFadesInOnTheCoolSide() {
        let asShot = (temperature: 5000.0, tint: 8.0)
        #expect(linear.exposureCorrection(temperature: 5000, tint: 8, asShot: asShot) == 0)
        let warm = linear.exposureCorrection(temperature: 3000, tint: 8, asShot: asShot)
        #expect(abs(warm - (1e6 / 3000 - 1e6 / 5000) / 100) < 1e-9, "warmer: all of it")
        // 200 mired at As Shot: 160 is 40 cooler, 110 is 90 cooler.
        #expect(abs(linear.exposureCorrection(temperature: 1e6 / 160, tint: 18, asShot: asShot) - 1) < 1e-9,
                "40 mired cooler, only the tint's part")
        #expect(abs(linear.exposureCorrection(temperature: 1e6 / 135, tint: 8, asShot: asShot) - (-0.65 / 2)) < 1e-9, "half way")
        #expect(abs(linear.exposureCorrection(temperature: 1e6 / 110, tint: 8, asShot: asShot) - (-0.9)) < 1e-9, "90 mired cooler, all of it")
    }

    @Test func tablesAreKeptByCameraModel() throws {
        let directory = try TemporaryDirectory()
        let tables = SmartPreviewWhiteBalance.directory(in: directory.url)
        #expect(SmartPreviewWhiteBalance.load(cameraModel: "Sony ILCE-7RM5", in: tables) == nil)
        try linear.save(cameraModel: "Sony ILCE-7RM5", in: tables)
        try SmartPreviewWhiteBalance(errors: [[0]]).save(cameraModel: "Broken/Camera", in: tables)
        #expect(SmartPreviewWhiteBalance.load(cameraModel: "Sony ILCE-7RM5", in: tables) == linear)
        #expect(SmartPreviewWhiteBalance.load(cameraModel: "Broken/Camera", in: tables) == nil, "a table of the wrong shape")
        #expect(FileManager.default.fileExists(atPath: tables.appending(path: "Broken-Camera.json").path(percentEncoded: false)))
    }

    @Test func onlyCameraRAWFilesGetATable() throws {
        let directory = try TemporaryDirectory()
        let merge = directory.url.appending(path: "merge.dng"), jpeg = directory.url.appending(path: "photo.jpg")
        try LinearDNGWriter.write(
            DNGFixtures.image(width: 300, height: 200) { _, _ in SIMD3(repeating: 0.2) },
            metadata: DNGMetadata(make: "Sony", model: "ILCE-7RM5"), to: merge
        )
        try Fixtures.writeJPEG(to: jpeg)
        #expect(SmartPreviewWhiteBalance.cameraModel(of: merge) == nil, "a linear DNG's Smart Preview matches it without one")
        #expect(SmartPreviewWhiteBalance.cameraModel(of: jpeg) == nil)
    }

    /// With `PIXELLOUPE_WHITE_BALANCE_SAMPLES` naming a folder of camera RAW files: Smart Previews built as the builder
    /// does (one table per camera model, from its first photo) render like their originals away from As Shot, and
    /// better than without the correction where it matters. Prints each photo's ΔE00 means.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PIXELLOUPE_WHITE_BALANCE_SAMPLES"] != nil))
    func samplesRenderLikeTheirOriginalsAwayFromAsShot() async throws {
        let folder = URL(filePath: try #require(ProcessInfo.processInfo.environment["PIXELLOUPE_WHITE_BALANCE_SAMPLES"]))
        let originals = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { SmartPreviewWhiteBalance.cameraModel(of: $0) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(Int(ProcessInfo.processInfo.environment["PIXELLOUPE_WHITE_BALANCE_COUNT"] ?? "3") ?? 3)
        try #require(!originals.isEmpty, "no camera RAW files in \(folder.path(percentEncoded: false))")
        let directory = try TemporaryDirectory()
        var tables: [String: SmartPreviewWhiteBalance] = [:]
        let settings: [(name: String, temperature: Double?, tint: Double?)] = [
            ("As Shot", nil, nil), ("3000 K / 0", 3000, 0), ("3500 K / 0", 3500, 0), ("4500 K / -15", 4500, -15),
            ("7500 K / +20", 7500, 20), ("10000 K / 0", 10000, 0),
        ]
        for original in originals {
            let model = try #require(SmartPreviewWhiteBalance.cameraModel(of: original))
            let plainURL = directory.url.appending(path: "\(original.lastPathComponent)-plain.dng")
            let info = try SmartPreviewWriter.write(original: original, to: plainURL)
            if tables[model] == nil {
                let started = Date()
                tables[model] = try SmartPreviewWhiteBalance.measure(original: original, smartPreview: plainURL, smartPreviewScale: info.scale)
                print("WB table for \(model) from \(original.lastPathComponent) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            }
            let table = try #require(tables[model])
            let correctedURL = directory.url.appending(path: "\(original.lastPathComponent).dng")
            try SmartPreviewWriter.write(original: original, to: correctedURL, whiteBalance: table)

            let source = try #require(DevelopSource(url: original))
            let plain = try #require(DevelopSource(smartPreview: plainURL)), corrected = try #require(DevelopSource(smartPreview: correctedURL))
            #expect(corrected.smartPreview?.whiteBalance == table)
            // Compared at a quarter of the Smart Preview's size: color and brightness, not detail.
            let scale = info.scale / 4
            var floor = 0.0
            for setting in settings {
                var adjustments = PhotoAdjustments()
                adjustments.whiteBalance = .init(isEnabled: setting.temperature != nil, temperature: setting.temperature, tint: setting.tint)
                let expected = render(source.image(with: adjustments, scale: scale))
                let withoutCorrection = meanDeltaE(expected, render(plain.image(with: adjustments, scale: scale)))
                let withCorrection = meanDeltaE(expected, render(corrected.image(with: adjustments, scale: scale)))
                print("WB \(original.lastPathComponent) \(setting.name): plain \(String(format: "%.2f", withoutCorrection)), corrected \(String(format: "%.2f", withCorrection))")
                // Against the photo's As Shot, where the Smart Preview is as close as it gets.
                guard let temperature = setting.temperature else {
                    floor = withCorrection
                    #expect(abs(withCorrection - withoutCorrection) < 0.05, "no correction at As Shot")
                    continue
                }
                let note = "\(original.lastPathComponent) at \(setting.name): \(withCorrection) against \(withoutCorrection) without, \(floor) at As Shot"
                #expect(withCorrection < floor + 1, Comment(rawValue: note))
                if temperature <= 4500 {
                    #expect(withCorrection < withoutCorrection - 1, Comment(rawValue: note))
                } else {
                    #expect(withCorrection < withoutCorrection + 0.25, Comment(rawValue: note))
                }
            }
        }
    }

    /// With `PIXELLOUPE_WHITE_BALANCE_SAMPLES`: the builder measures a camera model's table on its first Smart
    /// Preview, keeps it in the catalog and puts it in the Smart Preview.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PIXELLOUPE_WHITE_BALANCE_SAMPLES"] != nil))
    @MainActor
    func theBuilderKeepsATablePerCameraModel() async throws {
        let folder = URL(filePath: try #require(ProcessInfo.processInfo.environment["PIXELLOUPE_WHITE_BALANCE_SAMPLES"]))
        let original = try #require(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first { SmartPreviewWhiteBalance.cameraModel(of: $0) != nil })
        let model = try #require(SmartPreviewWhiteBalance.cameraModel(of: original))
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.create(
            at: directory.url.appending(path: "C.pixelloupe", directoryHint: .isDirectory), info: Fixtures.referencedInfo
        )
        let photo = Photo(context: store.viewContext)
        photo.id = UUID()
        photo.fileName = original.lastPathComponent
        photo.filePath = original.path(percentEncoded: false)
        photo.fileType = original.pathExtension.uppercased()
        photo.captureDate = Date()
        photo.importDate = Date()
        photo.editDate = Date()
        try store.viewContext.save()

        store.smartPreviewBuilder.start(after: .zero)
        store.smartPreviewBuilder.build([photo])
        await store.smartPreviewBuilder.waitUntilIdle()
        store.smartPreviewBuilder.stop()
        let table = try #require(SmartPreviewWhiteBalance.load(
            cameraModel: model, in: SmartPreviewWhiteBalance.directory(in: store.smartPreviews.directory)
        ))
        let file = try #require(store.smartPreviews.file(for: photo))
        #expect(SmartPreviewInfo.read(from: file)?.whiteBalance == table)
        #expect(store.smartPreviews.files.count == 1, "the tables' folder isn't a Smart Preview")
    }

    private struct Bitmap {
        var width: Int, height: Int, pixels: [Float]
    }

    private func render(_ image: CIImage) -> Bitmap {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        CIContext().render(image, toBitmap: &pixels, rowBytes: width * 16, bounds: extent, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
        return Bitmap(width: width, height: height, pixels: pixels)
    }

    /// Over the size both have (the RAW engine and the Smart Preview can round a scaled size differently, by a pixel).
    private func meanDeltaE(_ one: Bitmap, _ two: Bitmap) -> Double {
        let width = min(one.width, two.width), height = min(one.height, two.height)
        var total = 0.0, count = 0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                func lab(_ bitmap: Bitmap) -> ColorDifference.Lab {
                    let i = (y * bitmap.width + x) * 4
                    func channel(_ c: Int) -> Double { Double(min(max(bitmap.pixels[i + c], 0), 1)) }
                    return ColorDifference.lab(displayP3: channel(0), channel(1), channel(2))
                }
                total += ColorDifference.deltaE2000(lab(one), lab(two))
                count += 1
            }
        }
        return total / Double(max(count, 1))
    }
}
