import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PixelLoupe

/// Smart Preview files (RAW-117): what they hold, and that they open and render like their originals.
@Suite("Smart Preview writer")
struct SmartPreviewWriterTests {
    private let metadata = DNGMetadata(
        make: "Canon", model: "EOS R5", lensModel: "RF24-70mm F2.8 L IS USM",
        captureDate: Date(timeIntervalSince1970: 1_791_000_000), timeZone: nil,
        exposureTime: 1.0 / 125, aperture: 8, iso: 200, focalLength: 35
    )

    /// Ramps below half of white: nearer white the RAW engine rolls highlights off, which would hide the comparison.
    private static func ramps(_ x: Int, _ y: Int, width: Int, height: Int) -> SIMD3<Float> {
        SIMD3(0.05 + 0.4 * Float(x) / Float(width - 1), 0.05 + 0.4 * Float(y) / Float(height - 1), 0.25)
    }

    @Test func aLinearDNGBecomesA2560PixelJPEGXLDNG() throws {
        let directory = try TemporaryDirectory()
        let original = directory.url.appending(path: "merge.dng")
        try LinearDNGWriter.write(
            DNGFixtures.image(width: 3200, height: 1800) { Self.ramps($0, $1, width: 3200, height: 1800) },
            metadata: metadata, to: original
        )
        let proxy = directory.url.appending(path: "proxy.dng")
        #expect(SmartPreviewWriter.recipe(for: original) == .linearDNG, "PixelLoupe's own merges use the Linear DNG recipe")
        let info = try SmartPreviewWriter.write(original: original, to: proxy)

        #expect(info.kind == .linearDNG && info.originalWidth == 3200 && info.originalHeight == 1800)
        #expect(abs(info.scale - 0.8) < 0.001)
        #expect(SmartPreviewInfo.read(from: proxy) == info)
        #expect(info.isCurrent(for: original))

        let file = try #require(TIFFFile(contentsOf: proxy))
        let ifd = file.ifd0
        #expect(ifd[256].map(file.integers) == [2560] && ifd[257].map(file.integers) == [1440])
        #expect(ifd[259].map(file.integers) == [52546], "JPEG XL tiles")
        #expect(ifd[50706].map(file.integers) == [1, 7, 0, 0], "DNG 1.7")
        #expect(ifd[51089].map(file.integers) == [3200, 1800], "OriginalDefaultFinalSize")
        #expect(ifd[271].flatMap(file.string) == "Canon" && ifd[272].flatMap(file.string) == "EOS R5")

        // The proxy decodes as the original does at the same size.
        let expected = try DNGFixtures.decodeLinear(original, scale: 0.8)
        let decoded = try DNGFixtures.decodeLinear(proxy)
        try #require(decoded.width == 2560 && decoded.height == 1440 && expected.width == 2560)
        for (x, y) in [(0, 0), (2559, 0), (0, 1439), (2559, 1439), (1280, 720), (300, 1200), (2000, 100)] {
            let difference = DNGFixtures.pixel(decoded, x: x, y: y) - DNGFixtures.pixel(expected, x: x, y: y)
            #expect(max(abs(difference.x), abs(difference.y), abs(difference.z)) < 0.01, "(\(x), \(y)) off by \(difference)")
        }
        let originalFilter = try #require(CIRAWFilter(imageURL: original))
        let proxyFilter = try #require(CIRAWFilter(imageURL: proxy))
        #expect(abs(proxyFilter.neutralTemperature - originalFilter.neutralTemperature) < 25, "the same As Shot temperature")
        #expect(abs(proxyFilter.neutralTint - originalFilter.neutralTint) < 1, "and tint")
    }

    @Test func aSmallOriginalKeepsItsSizeAndIsPaddedToOpen() throws {
        let directory = try TemporaryDirectory()
        let original = directory.url.appending(path: "small.dng")
        try LinearDNGWriter.write(DNGFixtures.image(width: 300, height: 200) { _, _ in SIMD3(repeating: 0.2) }, metadata: metadata, to: original)
        let proxy = directory.url.appending(path: "proxy.dng")
        let info = try SmartPreviewWriter.write(original: original, to: proxy)

        #expect(info.scale == 1 && info.originalWidth == 300 && info.originalHeight == 200)
        let size = try #require(try proxy.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size >= SmartPreviewWriter.smallestOpenableDNG)
        let decoded = try DNGFixtures.decodeLinear(proxy)
        #expect(decoded.width == 300 && decoded.height == 200)
        let pixel = DNGFixtures.pixel(decoded, x: 150, y: 100)
        #expect(abs(pixel.x - 0.2) < 0.01 && abs(pixel.y - 0.2) < 0.01 && abs(pixel.z - 0.2) < 0.01, "\(pixel)")
    }

    @Test func otherPhotosBecomeAnUprightHEIC() throws {
        let directory = try TemporaryDirectory()
        let original = directory.url.appending(path: "photo.jpg")
        // 3000 × 2000, stored turned (orientation 6), so it's 2000 × 3000 upright.
        let context = try #require(CGContext(
            data: nil, width: 3000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.8, green: 0.4, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        let destination = try #require(CGImageDestinationCreateWithURL(original as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "EOS R5"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 2.8],
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))

        #expect(SmartPreviewWriter.recipe(for: original) == .image && SmartPreviewWriter.fileExtension(for: original) == "heic")
        let proxy = directory.url.appending(path: "proxy.heic")
        let info = try SmartPreviewWriter.write(original: original, to: proxy)
        #expect(info.kind == .image && info.originalWidth == 2000 && info.originalHeight == 3000)
        #expect(SmartPreviewInfo.read(from: proxy) == info)

        let source = try #require(CGImageSourceCreateWithURL(proxy as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.heic.identifier)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0, height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        #expect(height == 2560 && abs(width - 1707) <= 1, "upright, 2560 on the long edge: \(width) × \(height)")
        #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        #expect(abs(info.scale - 2560.0 / 3000) < 0.001)
        // The original's metadata comes along, for the shooting settings and lens profiles.
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any], exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFModel] as? String == "EOS R5" && exif?[kCGImagePropertyExifFNumber] as? Double == 2.8)
        #expect(ShootingInfo.read(from: proxy).aperture == 2.8)
    }

    @Test func videosGetNone() {
        let movie = URL(filePath: "/tmp/clip.mov")
        #expect(SmartPreviewWriter.recipe(for: movie) == nil && SmartPreviewWriter.fileExtension(for: movie) == nil)
    }

    @Test func aChangedOriginalMakesItsProxyStale() throws {
        let directory = try TemporaryDirectory()
        let original = directory.url.appending(path: "small.dng")
        try LinearDNGWriter.write(DNGFixtures.image(width: 300, height: 200) { _, _ in SIMD3(repeating: 0.2) }, metadata: metadata, to: original)
        let info = try SmartPreviewWriter.write(original: original, to: directory.url.appending(path: "proxy.dng"))
        #expect(info.isCurrent(for: original))

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: original.path(percentEncoded: false))
        #expect(!info.isCurrent(for: original), "edited after the proxy was made")
        #expect(info.isCurrent(for: directory.url.appending(path: "offline.dng")), "an offline original keeps its proxy")
        var older = info
        older.version -= 1
        #expect(!older.isCurrent(for: directory.url.appending(path: "offline.dng")), "proxies from an older writer are rebuilt")
    }

    @Test func theAsShotNeutralOfD65IsNeutral() {
        let neutral = SmartPreviewWriter.rec2020Neutral(of: CGPoint(x: 0.3127, y: 0.3290))
        #expect(neutral.allSatisfy { abs($0 - 1) < 0.001 }, "\(neutral)")
    }

    /// The RAW-95 sample ARW (when `PIXELLOUPE_PANORAMA_SAMPLES` is set): the proxy renders like the original at
    /// 2560 px. The RAW-85 spikes measured about ΔE00 2.8 at As Shot.
    @Test(.enabled(if: PanoramaSamples.folder != nil))
    func aSampleRAWFileRendersLikeItsOriginal() throws {
        let directory = try TemporaryDirectory()
        let original = try #require(PanoramaSamples.folder).appending(path: "DSC00245.ARW")
        let proxy = directory.url.appending(path: "proxy.dng")
        let info = try SmartPreviewWriter.write(original: original, to: proxy)

        let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
        func render(_ url: URL, scale: Float, shadowBias: Float?, localToneMap: Float?) throws -> (width: Int, pixels: [Float]) {
            let filter = try #require(CIRAWFilter(imageURL: url))
            filter.scaleFactor = scale
            if filter.isSharpnessSupported { filter.sharpnessAmount = 0 }
            if filter.isDetailSupported { filter.detailAmount = 0 }
            if let shadowBias { filter.shadowBias = shadowBias }
            if let localToneMap { filter.localToneMapAmount = localToneMap }
            let image = try #require(filter.outputImage)
            let extent = image.extent.integral
            var pixels = [Float](repeating: 0, count: Int(extent.width) * Int(extent.height) * 4)
            CIContext().render(image, toBitmap: &pixels, rowBytes: Int(extent.width) * 16, bounds: extent, format: .RGBAf, colorSpace: displayP3)
            return (Int(extent.width), pixels)
        }
        let expected = try render(original, scale: Float(info.scale), shadowBias: nil, localToneMap: nil)
        let actual = try render(proxy, scale: 1, shadowBias: info.shadowBias, localToneMap: info.localToneMapAmount)
        try #require(expected.pixels.count == actual.pixels.count)
        var total = 0.0, count = 0
        for index in stride(from: 0, to: expected.pixels.count, by: 4 * 7) {
            func lab(_ p: [Float]) -> ColorDifference.Lab {
                ColorDifference.lab(displayP3: Double(min(max(p[index], 0), 1)), Double(min(max(p[index + 1], 0), 1)), Double(min(max(p[index + 2], 0), 1)))
            }
            total += ColorDifference.deltaE2000(lab(expected.pixels), lab(actual.pixels))
            count += 1
        }
        let mean = total / Double(count)
        PanoramaSamples.note(String(format: "Smart Preview of DSC00245 at As Shot: mean ΔE00 %.2f", mean))
        #expect(mean < 3.5, "mean ΔE00 \(mean)")
    }
}
