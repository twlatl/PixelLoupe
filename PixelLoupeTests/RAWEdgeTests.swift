import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Edges of scaled-down RAW photos")
struct RAWEdgeTests {
    private func render(_ image: CGImage) -> (width: Int, height: Int, green: [Int]) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (width, height, stride(from: 1, to: bytes.count, by: 4).map { Int(bytes[$0]) })
    }

    @Test("A plain gray RAW photo exports gray to its edges at any size", arguments: [(1500, 1000), (1000, 1500)], [256.0, 512, 577, 1000])
    func resizedExportsHaveNoDarkEdge(size: (width: Int, height: Int), edge: Double) throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "Gray.dng")
        try LinearDNGWriter.write(
            DNGFixtures.image(width: size.width, height: size.height) { _, _ in SIMD3(repeating: 0.25) },
            metadata: DNGMetadata(make: "Canon", model: "EOS R5", lensModel: nil, captureDate: Date(timeIntervalSince1970: 1_791_000_000),
                                  timeZone: nil, exposureTime: 1.0 / 125, aperture: 8, iso: 200, focalLength: 35),
            to: url
        )
        let item = ExportItem(source: url, adjustments: PhotoAdjustments(), metadata: PhotoMetadata(), keywords: [], rating: 0, captureDate: .now)
        var settings = ExportSettings()
        settings.resizes = true
        settings.edge = edge
        let image = render(try PhotoExporter.render(item, settings: settings, watermark: nil).image)
        #expect(max(image.width, image.height) == Int(edge))
        let middle = image.green[image.height / 2 * image.width + image.width / 2]
        #expect(middle > 40)
        #expect(image.green.allSatisfy { abs($0 - middle) <= 2 }, "darkest \(image.green.min() ?? 0), middle \(middle)")
    }

    @Test func onlyTheOutermostPixelsChange() throws {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        // Each pixel's own value: 16 across, 12 down.
        var source = [Float](repeating: 1, count: 16 * 12 * 4)
        for i in 0..<(16 * 12) { source[i * 4] = Float(i) / 255 }
        let image = source.withUnsafeBytes {
            CIImage(bitmapData: Data($0), bytesPerRow: 16 * 16, size: CGSize(width: 16, height: 12), format: .RGBAf, colorSpace: nil)
        }
        let repaired = DevelopSource.repairingEdges(image)
        #expect(repaired.extent == image.extent)
        var result = [Float](repeating: 0, count: source.count)
        context.render(repaired, toBitmap: &result, rowBytes: 16 * 16, bounds: image.extent, format: .RGBAf, colorSpace: nil)
        for y in 0..<12 {
            for x in 0..<16 {
                let row = min(max(y, 1), 10), column = min(max(x, 1), 14)
                let difference: Float = result[(y * 16 + x) * 4] - source[(row * 16 + column) * 4]
                #expect(abs(difference) < 0.001)
            }
        }
    }
}
