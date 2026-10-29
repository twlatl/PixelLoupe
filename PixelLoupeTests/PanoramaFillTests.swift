import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

/// Fill Edges' content-aware fill (RAW-216) on synthetic images with a hole where the "photos" don't reach.
struct PanoramaFillTests {
    static let width = 320, height = 200
    let context = CIContext(options: [.workingColorSpace: PanoramaMerger.colorSpace, .cacheIntermediates: false])

    /// An RGB image from `color(x, y)`, top row first.
    static func image(width: Int = width, height: Int = height, _ color: (Int, Int) -> SIMD3<Float>) -> CIImage {
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = color(x, y)
                let index = (y * width + x) * 4
                pixels[index] = c.x
                pixels[index + 1] = c.y
                pixels[index + 2] = c.z
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
    }

    /// Coverage (red) 1 except where `hole(x, y)`.
    static func coverage(width: Int = width, height: Int = height, _ hole: (Int, Int) -> Bool) -> CIImage {
        image(width: width, height: height) { x, y in SIMD3(repeating: hole(x, y) ? 0 : 1) }
    }

    /// A small, fixed noise in -1…1.
    static func noise(_ x: Int, _ y: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663)
        h ^= h >> 13
        h = h &* 0x5bd1_e995
        h ^= h >> 15
        return Float(h % 2001) / 1000 - 1
    }

    func pixels(_ image: CIImage) -> [SIMD3<Float>] {
        let extent = image.extent
        let width = Int(extent.width), height = Int(extent.height)
        var raw = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &raw, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: nil)
        return (0..<(width * height)).map { SIMD3(raw[$0 * 4], raw[$0 * 4 + 1], raw[$0 * 4 + 2]) }
    }

    func filled(_ color: CIImage, _ coverage: CIImage, maxPixels: Int = 4_000_000) throws -> [SIMD3<Float>] {
        let solution = try PanoramaFill.solve(color: color, coverage: coverage, context: context, maxPixels: maxPixels)
        return pixels(PanoramaFill.composite(color, coverage: coverage, fill: solution.fill))
    }

    /// A wedge along the right edge, wider at the top, like a panorama's corner.
    static func wedge(_ x: Int, _ y: Int) -> Bool {
        Double(x) > Double(width) * 0.78 + Double(y) * 0.25
    }

    @Test func flatColorFillsWithItsColor() throws {
        let base = SIMD3<Float>(0.3, 0.5, 0.2)
        let color = Self.image { x, y in base * (1 + 0.03 * Self.noise(x, y)) }
        let result = try filled(color, Self.coverage(Self.wedge))
        var worst: Float = 0
        for y in 0..<Self.height {
            for x in 0..<Self.width where Self.wedge(x, y) {
                let c = result[y * Self.width + x]
                worst = max(worst, ((c - base) / base).max(), ((base - c) / base).max())
            }
        }
        #expect(worst < 0.06, "worst relative difference \(worst)")
    }

    @Test func rowsCarryTheirColorIntoTheHole() throws {
        // A gradient down the image (like sky to ground); the hole is the left side, so each row has its own color.
        func shade(_ y: Int) -> Float { 0.05 + 0.9 * Float(y) / Float(Self.height - 1) }
        let color = Self.image { _, y in SIMD3(repeating: shade(y)) }
        let hole: (Int, Int) -> Bool = { x, y in Double(x) < Double(Self.width) * 0.18 - Double(y) * 0.1 }
        let result = try filled(color, Self.coverage(hole))
        var total: Float = 0, count: Float = 0, worst: Float = 0
        for y in 0..<Self.height {
            for x in 0..<Self.width where hole(x, y) {
                let error = abs(result[y * Self.width + x].x - shade(y))
                total += error
                count += 1
                worst = max(worst, error)
            }
        }
        #expect(total / count < 0.02, "mean error \(total / count)")
        #expect(worst < 0.08, "worst error \(worst)")
    }

    @Test func stripesKeepTheirPeriod() throws {
        // Vertical stripes 8 pixels wide; the hole is the bottom of the image, so the stripes should run on down.
        func stripe(_ x: Int) -> Float { (x / 8) % 2 == 0 ? 0.2 : 0.8 }
        let color = Self.image { x, _ in SIMD3(repeating: stripe(x)) }
        let hole: (Int, Int) -> Bool = { x, y in y > Self.height - 40 + (x % 64) / 8 }
        let result = try filled(color, Self.coverage(hole))
        var right: Float = 0, count: Float = 0
        for y in 0..<Self.height {
            for x in 0..<Self.width where hole(x, y) {
                if abs(result[y * Self.width + x].x - stripe(x)) < 0.15 { right += 1 }
                count += 1
            }
        }
        #expect(right / count > 0.85, "\(right / count) of the hole follows the stripes")
    }

    @Test func coveredPixelsStayAsTheyWere() throws {
        let color = Self.image { x, y in SIMD3(Float(x) / Float(Self.width), Float(y) / Float(Self.height), 0.5 + 0.2 * Self.noise(x, y)) }
        let original = pixels(color)
        let result = try filled(color, Self.coverage(Self.wedge))
        for y in 0..<Self.height {
            for x in 0..<Self.width where !Self.wedge(x, y) {
                #expect(result[y * Self.width + x] == original[y * Self.width + x])
            }
        }
    }

    @Test func theSameInputFillsTheSame() throws {
        let color = Self.image { x, y in SIMD3(repeating: 0.4 + 0.3 * Self.noise(x, y)) }
        let coverage = Self.coverage(Self.wedge)
        let first = try PanoramaFill.solve(color: color, coverage: coverage, context: context)
        let second = try PanoramaFill.solve(color: color, coverage: coverage, context: context)
        #expect(pixels(first.fill) == pixels(second.fill))
        #expect(first.field.entries == second.field.entries)
    }

    @Test func cancellingStopsTheSolve() {
        let color = Self.image { _, _ in SIMD3(repeating: 0.5) }
        #expect(throws: CancellationError.self) {
            try PanoramaFill.solve(color: color, coverage: Self.coverage(Self.wedge), context: context, isCancelled: { true })
        }
    }

    @Test func theFieldFillsAFinerImage() throws {
        // Solved at half resolution, then filled at full resolution from the full-resolution image.
        func shade(_ y: Int) -> Float { 0.05 + 0.9 * Float(y) / Float(Self.height - 1) }
        let color = Self.image { _, y in SIMD3(repeating: shade(y)) }
        let hole: (Int, Int) -> Bool = { x, y in Double(x) < Double(Self.width) * 0.18 - Double(y) * 0.1 }
        let coverage = Self.coverage(hole)
        let solution = try PanoramaFill.solve(color: color, coverage: coverage, context: context,
                                              maxPixels: Self.width * Self.height / 4)
        #expect(solution.field.width == Self.width / 2)
        let result = pixels(PanoramaFill.composite(color, coverage: coverage, fill: solution.field.fill(from: color)))
        var total: Float = 0, count: Float = 0
        for y in 0..<Self.height {
            for x in 0..<Self.width where hole(x, y) {
                total += abs(result[y * Self.width + x].x - shade(y))
                count += 1
            }
        }
        #expect(total / count < 0.03, "mean error \(total / count)")
    }
}
