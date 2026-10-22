import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

/// Assisted Culling's measures (RAW-71).
@Suite("Culling analyzer")
struct CullingAnalyzerTests {
    /// A `width`×`height` image whose brightness at each pixel is `value(x, y)`.
    private func pixels(width: Int = 128, height: Int = 128, _ value: (Int, Int) -> Float) -> GrayPixels {
        var values: [Float] = []
        for y in 0..<height {
            for x in 0..<width { values.append(value(x, y)) }
        }
        return GrayPixels(width: width, height: height, values: values)
    }

    private func checkerboard(cell: Int) -> GrayPixels {
        pixels { x, y in (x / cell + y / cell).isMultiple(of: 2) ? 0.8 : 0.2 }
    }

    /// A vertical edge from 0.2 to 0.2 + `contrast` in the middle of a 16 px tile, blurred over about `softness`
    /// pixels.
    private func edge(contrast: Float, softness: Float) -> GrayPixels {
        pixels { x, _ in 0.2 + contrast * (0.5 + 0.5 * tanh((Float(x) - 56.5) / softness)) }
    }

    @Test func crispEdgesAreSharperThanSoftOnes() throws {
        let crisp = try #require(CullingAnalyzer.sharpness(edge(contrast: 0.6, softness: 0.3), tile: 16))
        let soft = try #require(CullingAnalyzer.sharpness(edge(contrast: 0.6, softness: 4), tile: 16))
        #expect(crisp > soft * 2)
        #expect(CullingAnalyzer.sharpness(pixels { _, _ in 0.5 }, tile: 16) == nil, "nothing to judge")
    }

    @Test func sharpnessDoesntDependOnContrast() throws {
        let strong = try #require(CullingAnalyzer.sharpness(edge(contrast: 0.6, softness: 0.3), tile: 16))
        let faint = try #require(CullingAnalyzer.sharpness(edge(contrast: 0.3, softness: 0.3), tile: 16))
        #expect(abs(strong - faint) < strong * 0.1)
    }

    @Test func theCrispestPartOfARegionDecidesItsSharpness() throws {
        // A soft gradient across the left of the region, and one crisp edge on the right: shallow depth of field.
        let image = pixels { x, _ in x < 96 ? 0.2 + 0.5 * Float(x) / 96 : (x < 112 ? 0.2 : 0.8) }
        let crisp = try #require(CullingAnalyzer.sharpness(edge(contrast: 0.6, softness: 0.3), tile: 16))
        #expect(try #require(CullingAnalyzer.sharpness(image, tile: 16)) > crisp * 0.9)
        #expect(try #require(CullingAnalyzer.sharpness(edge(contrast: 0.6, softness: 8), tile: 16)) < crisp / 2)
    }

    @Test func focusScoresRunFromZeroToOne() {
        #expect(CullingAnalyzer.focusScore(sharpness: CullingAnalyzer.softSharpness) == 0)
        #expect(CullingAnalyzer.focusScore(sharpness: CullingAnalyzer.crispSharpness) == 1)
        #expect(CullingAnalyzer.focusScore(sharpness: 100) == 1)
        let middle = (CullingAnalyzer.softSharpness + CullingAnalyzer.crispSharpness) / 2
        #expect(abs(CullingAnalyzer.focusScore(sharpness: middle) - 0.5) < 1e-9)
    }

    @Test func eyeOpennessFollowsTheEyesShape() {
        func eye(height: CGFloat) -> [CGPoint] {
            [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: height / 2), CGPoint(x: 100, y: 0), CGPoint(x: 50, y: -height / 2)]
        }
        let open = CullingAnalyzer.eyeAspectRatio(eye(height: 20)).map(CullingAnalyzer.openness)
        let closed = CullingAnalyzer.eyeAspectRatio(eye(height: 5)).map(CullingAnalyzer.openness)
        #expect(open == 1)
        #expect(closed == 0)
        #expect(CullingAnalyzer.eyeAspectRatio([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]) == nil)
    }

    @Test func clippedOrDarkFramesHaveExposureIssues() {
        let midGrey = pixels { x, y in 0.3 + 0.4 * Float(x + y) / 254 }.statistics()
        let blownOut = pixels { x, _ in x < 40 ? 1 : 0.6 }.statistics()
        let dark = pixels { _, y in 0.02 + 0.1 * Float(y) / 127 }.statistics()
        #expect(!CullingAnalyzer.isExposureIssue(midGrey))
        #expect(CullingAnalyzer.isExposureIssue(blownOut))
        #expect(CullingAnalyzer.isExposureIssue(dark))
    }

    @Test func blankBlackOrBlurredFramesAreMisfires() {
        func isMisfire(_ image: GrayPixels) -> Bool {
            CullingAnalyzer.isMisfire(image.statistics(), subjectSharpness: CullingAnalyzer.sharpness(image, tile: 32))
        }
        // A product on a plain background: little detail, but crisp.
        let minimal = pixels { x, y in (40..<88).contains(x) && (40..<88).contains(y) ? 0.15 : 0.85 }
        #expect(!isMisfire(checkerboard(cell: 4)))
        #expect(!isMisfire(minimal))
        #expect(isMisfire(pixels { _, _ in 0.45 }))
        #expect(isMisfire(pixels { x, y in (x + y).isMultiple(of: 2) ? 0.03 : 0 }))
        #expect(isMisfire(edge(contrast: 0.6, softness: 8)), "nothing sharp")
    }

    @Test func blurringAPhotoLowersItsFocusScore() throws {
        let sharp = CIImage(cgImage: try #require(Self.texture(width: 600, height: 400)))
        let blurred = sharp.clampedToExtent().applyingGaussianBlur(sigma: 4).cropped(to: sharp.extent)
        let region = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let sharpScore = CullingAnalyzer.focusScore(of: sharp, in: region, tile: 32)
        let blurredScore = CullingAnalyzer.focusScore(of: blurred, in: region, tile: 32)
        #expect(blurredScore < sharpScore / 2)
    }

    /// Random noise at a few scales: detail like a real photo's.
    private static func texture(width: Int, height: Int) -> CGImage? {
        var generator = SystemRandomNumberGenerator()
        var bytes = (0..<(width * height)).map { _ in UInt8.random(in: 40...215, using: &generator) }
        return bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )?.makeImage()
        }
    }

    /// Prints the scores of the photos in `PIXELLOUPE_CULLING_SAMPLES` (folders separated by colons), for tuning the
    /// thresholds.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PIXELLOUPE_CULLING_SAMPLES"] != nil))
    func printSampleScores() async throws {
        let folders = try #require(ProcessInfo.processInfo.environment["PIXELLOUPE_CULLING_SAMPLES"]).split(separator: ":")
        let files = try folders.flatMap { try FileManager.default.contentsOfDirectory(at: URL(filePath: String($0)), includingPropertiesForKeys: nil) }
            .filter { SupportedImageTypes.isRaw($0) || ["jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var lines = ["file\tsubject\teyes\topenMin\topenMax\tfaces\texposure\tmisfire\tdocument\tquality\tseconds"]
        for file in files {
            let start = ContinuousClock.now
            let scores = await CullingAnalyzer.analyze(PhotoSourceLocation(original: file), thumbnail: file)
            let seconds = (ContinuousClock.now - start) / .seconds(1)
            guard let s = scores else { continue }
            lines.append([
                file.lastPathComponent, String(format: "%.3f", s.subjectFocus), String(format: "%.3f", s.eyeFocus),
                String(format: "%.2f", s.eyesOpenMin), String(format: "%.2f", s.eyesOpenMax), "\(s.faceCount)",
                "\(s.exposureIssue)", "\(s.misfire)", "\(s.document)", String(format: "%.2f", s.quality),
                String(format: "%.2f", seconds),
            ].joined(separator: "\t"))
        }
        let report = lines.joined(separator: "\n")
        if let path = ProcessInfo.processInfo.environment["PIXELLOUPE_CULLING_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
        print(report)
    }
}


