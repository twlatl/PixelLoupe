import CoreImage
import Foundation
import ImageIO
import Testing
@testable import PixelLoupe

/// Helpers for tests that need RAW files: Linear DNGs written by ``LinearDNGWriter``.
enum DNGFixtures {
    static let linearRec2020 = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!

    /// An image whose pixels are `value(x, y)` (RGB, linear Rec. 2020).
    static func image(width: Int, height: Int, _ value: (Int, Int) -> SIMD3<Float>) -> LinearDNGImage {
        var pixels = [Float16](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let rgb = value(x, y)
                let i = (y * width + x) * 3
                pixels[i] = Float16(rgb.x)
                pixels[i + 1] = Float16(rgb.y)
                pixels[i + 2] = Float16(rgb.z)
            }
        }
        return LinearDNGImage(width: width, height: height, pixels: pixels)
    }

    /// Decodes a DNG without the RAW engine's tone boost and shadow bias, as linear Rec. 2020 RGBA,
    /// top row first.
    static func decodeLinear(_ url: URL) throws -> (width: Int, height: Int, pixels: [Float]) {
        let filter = try #require(CIRAWFilter(imageURL: url))
        filter.boostAmount = 0
        filter.isGamutMappingEnabled = false
        filter.shadowBias = 0
        let output = try #require(filter.outputImage)
        let width = Int(output.extent.width), height = Int(output.extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        CIContext(options: [.workingColorSpace: linearRec2020]).render(
            output, toBitmap: &pixels, rowBytes: width * 16, bounds: output.extent, format: .RGBAf, colorSpace: linearRec2020
        )
        return (width, height, pixels)
    }

    static func pixel(_ decoded: (width: Int, height: Int, pixels: [Float]), x: Int, y: Int) -> SIMD3<Float> {
        let i = (y * decoded.width + x) * 4
        return SIMD3(decoded.pixels[i], decoded.pixels[i + 1], decoded.pixels[i + 2])
    }
}

@Suite("Linear DNG writer")
struct LinearDNGWriterTests {
    private let metadata = DNGMetadata(
        make: "Canon", model: "EOS R5", lensModel: "RF24-70mm F2.8 L IS USM",
        // ImageIO doesn't read a RAW file's EXIF time zone offset, so the date is written in local time.
        captureDate: Date(timeIntervalSince1970: 1_791_000_000), timeZone: nil,
        exposureTime: 1.0 / 125, aperture: 8, iso: 200, focalLength: 35
    )

    @Test func rawEngineDecodesItWithHighlightsAboveWhite() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "ramp.dng")
        // A ramp from 0 to 4 (two stops over white), warm in the top half.
        let image = DNGFixtures.image(width: 400, height: 200) { x, y in
            let v = Float(x) / 399 * 4
            return y < 100 ? SIMD3(v, v * 0.5, v * 0.25) : SIMD3(repeating: v)
        }
        try LinearDNGWriter.write(image, metadata: metadata, to: url)

        let decoded = try DNGFixtures.decodeLinear(url)
        #expect(decoded.width == 400 && decoded.height == 200)
        for x in [50, 100, 200, 300, 399] {
            let expected = Float(x) / 399 * 4
            let gray = DNGFixtures.pixel(decoded, x: x, y: 150)
            #expect(abs(gray.x - expected) < expected * 0.03 + 0.01, "gray at \(x): \(gray) vs \(expected)")
            #expect(abs(gray.x - gray.z) < expected * 0.02 + 0.01, "stays neutral")
            let warm = DNGFixtures.pixel(decoded, x: x, y: 50)
            #expect(abs(warm.y / warm.x - 0.5) < 0.03 && abs(warm.z / warm.x - 0.25) < 0.03, "keeps its color at \(x)")
        }
    }

    @Test func pixelsAreStoredInTiles() throws {
        // Apple's RAW engine can drop parts of a large strip-based DNG when Develop decodes it at a new
        // scale while an earlier frame is still rendering; tiled DNGs (as cameras write) don't.
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "tiles.dng")
        // Not a multiple of the tile size, so the edge tiles are partly padding.
        let value: (Int, Int) -> SIMD3<Float> = { x, y in SIMD3(0.1 + 0.6 * Float(x) / 599, 0.1 + 0.6 * Float(y) / 299, 0.4) }
        let image = DNGFixtures.image(width: 600, height: 300, value)
        try LinearDNGWriter.write(image, metadata: metadata, to: url)

        // ImageIO doesn't report a DNG's layout, so read IFD0's tags from the file.
        let data = try Data(contentsOf: url)
        func uint<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> Int {
            Int(data[offset..<(offset + MemoryLayout<T>.size)].reversed().reduce(0) { $0 << 8 | UInt64($1) })
        }
        let ifd = uint(4, UInt32.self)
        var tags: [Int: Int] = [:]
        for entry in 0..<uint(ifd, UInt16.self) {
            let at = ifd + 2 + entry * 12
            tags[uint(at, UInt16.self)] = uint(at + 4, UInt32.self) == 1 ? uint(at + 8, UInt32.self) : -1
        }
        #expect(tags[322] == LinearDNGWriter.tileSize && tags[323] == LinearDNGWriter.tileSize, "tile width and length")
        #expect(tags[324] != nil && tags[273] == nil, "tile offsets, no strips")

        let decoded = try DNGFixtures.decodeLinear(url)
        #expect(decoded.width == 600 && decoded.height == 300)
        for (x, y) in [(0, 0), (599, 0), (0, 299), (599, 299), (255, 255), (256, 256), (520, 280)] {
            let pixel = DNGFixtures.pixel(decoded, x: x, y: y)
            let expected = value(x, y)
            #expect(abs(pixel.x - expected.x) < 0.02 && abs(pixel.y - expected.y) < 0.02 && abs(pixel.z - expected.z) < 0.02,
                    "(\(x), \(y)): \(pixel) vs \(expected)")
        }
    }

    @Test func baselineExposureCarriesTheHeadroom() {
        #expect(LinearDNGWriter.headroom(peak: 4) == 2)
        #expect(LinearDNGWriter.headroom(peak: 0.5) == 0)
    }

    @Test func catalogReadsItsMetadata() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "meta.dng")
        try LinearDNGWriter.write(DNGFixtures.image(width: 300, height: 200) { _, _ in SIMD3(repeating: 0.2) }, metadata: metadata, to: url)

        #expect(SupportedImageTypes.isRaw(url))
        let read = try #require(ImageMetadata.read(from: url))
        #expect(read.pixelWidth == 300 && read.pixelHeight == 200)
        #expect(read.cameraMake == "Canon" && read.cameraModel == "EOS R5")
        #expect(read.lensModel == "RF24-70mm F2.8 L IS USM")
        #expect(read.captureDate == metadata.captureDate)
        #expect(read.iso == 200 && read.aperture == 8 && read.focalLength == 35)
        #expect(abs(read.shutterSpeed - 1.0 / 125) < 0.00001)
        #expect(DevelopSource(url: url)?.isRaw == true)
    }
}
