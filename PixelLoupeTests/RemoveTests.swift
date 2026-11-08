import AppKit
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PixelLoupe

@Suite("Remove (RAW-260)")
struct RemoveTests {
    typealias Spot = PhotoAdjustments.Spot
    typealias UnitPoint = PhotoAdjustments.UnitPoint

    // MARK: Saved settings

    @Test("Spots saved before Remove decode with its defaults, and a Remove spot round-trips")
    func coding() throws {
        let legacy = #"{"id":"6D3F9A1C-2B4E-4F7A-9C1D-0E8B7A6F5D4C","kind":"clone","center":{"x":0.3,"y":0.4},"source":{"x":0.5,"y":0.4},"radius":0.02,"feather":0.5,"opacity":1}"#
        let old = try JSONDecoder().decode(Spot.self, from: Data(legacy.utf8))
        #expect(old.kind == .clone && old.area == nil && old.seed == 0 && !old.usesGenerativeAI && !old.hasCustomSource)

        var spot = Spot()
        spot.kind = .remove
        spot.seed = 42
        spot.usesGenerativeAI = true
        spot.area = PhotoAdjustments.RemoveArea(
            object: PhotoAdjustments.ObjectMatte(box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), width: 4, height: 4,
                                                 coverage: [UInt8](repeating: 255, count: 16)),
            brush: PhotoAdjustments.BrushMask(strokes: [stroke([(0.5, 0.5)], size: 0.01)])
        )
        let decoded = try JSONDecoder().decode(Spot.self, from: JSONEncoder().encode(spot))
        #expect(decoded == spot)
        #expect(decoded.area?.object?.coverage == [UInt8](repeating: 255, count: 16))
        #expect(decoded.isFilled)
        var sourced = decoded
        sourced.hasCustomSource = true
        #expect(!sourced.isFilled, "a ⌘-dragged source copies instead of filling")
    }

    @Test("Moving a painted spot moves what was painted, and its circle fits the area")
    func moving() {
        var spot = Spot()
        spot.kind = .remove
        spot.area = PhotoAdjustments.RemoveArea(brush: PhotoAdjustments.BrushMask(strokes: [stroke([(0.4, 0.5), (0.6, 0.5)], size: 0.05)]))
        spot.fitCircleToArea(aspect: 1)
        #expect(abs(spot.center.x - 0.5) < 1e-9 && abs(spot.center.y - 0.5) < 1e-9)
        #expect(abs(spot.radius - 0.15) < 1e-9, "half of 0.2 + 2 × 0.05")
        spot.move(by: 0.1, -0.1)
        #expect(abs(spot.area!.brush.strokes[0].points[0].x - 0.5) < 1e-9 && abs(spot.area!.brush.strokes[0].points[0].y - 0.4) < 1e-9)
        #expect(abs(spot.center.x - 0.6) < 1e-9)
    }

    // MARK: Area

    @Test("An area is its object, then strokes painting more and erasing some, over any box")
    func coverage() {
        let painted = stroke([(0.5, 0.5)], size: 0.1)
        var erased = stroke([(0.55, 0.5)], size: 0.03)
        erased.isErasing = true
        let area = PhotoAdjustments.RemoveArea(
            object: PhotoAdjustments.ObjectMatte(box: CGRect(x: 0, y: 0, width: 0.2, height: 0.2), width: 2, height: 2, coverage: [255, 255, 255, 255]),
            brush: PhotoAdjustments.BrushMask(strokes: [painted, erased])
        )
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        let matte = RemoveAreaRaster.coverage(of: area, box: whole, frameSize: CGSize(width: 100, height: 100), width: 100, height: 100)
        func at(_ x: Int, _ y: Int) -> Float { matte[y * 100 + x] }
        #expect(at(5, 5) > 0.9, "the object")
        #expect(at(45, 50) > 0.9, "the stroke")
        #expect(at(55, 50) < 0.1, "erased")
        #expect(at(90, 90) == 0)
        // The same area over half the frame at the same density matches.
        let half = RemoveAreaRaster.coverage(of: area, box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                                             frameSize: CGSize(width: 100, height: 100), width: 20, height: 20)
        #expect(abs(half[10 * 20 + 5] - at(45, 50)) < 0.05)
        #expect(abs(half[10 * 20 + 15] - at(55, 50)) < 0.05)
    }

    // MARK: Patch fill

    @Test("Patch fill carries the texture around a hole into it, the same way for the same seed")
    func patchFill() {
        // Vertical stripes 4 pixels wide, with a 14 × 14 hole of black in the middle.
        let width = 64, height = 64
        var truth = [Float](repeating: 0, count: width * height * 3)
        for y in 0..<height { for x in 0..<width { for c in 0..<3 { truth[(y * width + x) * 3 + c] = (x / 4) % 2 == 0 ? 0.8 : 0.2 } } }
        var damaged = truth
        var hole = [Bool](repeating: false, count: width * height)
        for y in 25..<39 { for x in 25..<39 {
            hole[y * width + x] = true
            for c in 0..<3 { damaged[(y * width + x) * 3 + c] = 0 }
        } }
        let input = PatchInpainter.Image(width: width, height: height, pixels: damaged)
        let filled = PatchInpainter.fill(input, hole: hole, seed: 7)
        var error: Float = 0, before: Float = 0, count: Float = 0
        for i in hole.indices where hole[i] {
            for c in 0..<3 {
                error += abs(filled.pixels[i * 3 + c] - truth[i * 3 + c])
                before += abs(damaged[i * 3 + c] - truth[i * 3 + c])
            }
            count += 3
        }
        #expect(error / count < 0.12, "close to the stripes: \(error / count) (unfilled \(before / count))")
        for i in hole.indices where !hole[i] { #expect(filled.pixels[i * 3] == damaged[i * 3]); break }
        #expect(PatchInpainter.fill(input, hole: hole, seed: 7).pixels == filled.pixels, "deterministic")
    }

    @Test("Patch fill keeps a busy texture busy, rather than smoothing the hole into an average")
    func patchFillKeepsTexture() {
        // Seeded noise blobs (like rocks), with a smooth sky band on top to tempt it.
        let width = 96, height = 96
        var rng = SeededGenerator(seed: 11)
        var pixels = [Float](repeating: 0, count: width * height * 3)
        for y in 0..<height { for x in 0..<width {
            let v: Float = y >= 80 ? 0.6 : Float(rng.next() % 1000) / 1000 * 0.8 + 0.1
            for c in 0..<3 { pixels[(y * width + x) * 3 + c] = v }
        } }
        var hole = [Bool](repeating: false, count: width * height)
        for y in 30..<60 { for x in 35..<55 { hole[y * width + x] = true; for c in 0..<3 { pixels[(y * width + x) * 3 + c] = 0 } } }
        let filled = PatchInpainter.fill(PatchInpainter.Image(width: width, height: height, pixels: pixels), hole: hole, seed: 5)
        func spread(_ indices: [Int]) -> Float {
            let values = indices.map { filled.pixels[$0 * 3] }
            let mean = values.reduce(0, +) / Float(values.count)
            return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)).squareRoot()
        }
        let inside = hole.indices.filter { hole[$0] }
        let around = (0..<(width * 70)).filter { !hole[$0] }
        #expect(spread(inside) > spread(around) * 0.5, "textured: \(spread(inside)) vs \(spread(around)) around it")
    }

    // MARK: Fills

    @Test("A Remove spot is filled from around it, kept on disk, and refilled for another seed")
    func fillStore() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "blob.png")
        try writePhoto(to: url)
        let store = RemoveFillStore(directory: directory.url.appending(path: "Fills"))
        store.generative = nil
        let adjustments = removing(seed: 1)
        let rendered = try await Task.detached {
            let source = try #require(DevelopSource(url: url))
            source.removeFills = store
            let before = source.image(with: PhotoAdjustments(), scale: 1)
            let after = source.image(with: adjustments, scale: 1)
            return (Self.pixel(before, 60, 40), Self.pixel(after, 60, 40), Self.pixel(after, 10, 10), Self.pixel(before, 10, 10))
        }.value
        #expect(rendered.0[0] < 0.2, "the blob is dark: \(rendered.0)")
        #expect(rendered.1[0] > 0.5, "filled with the gray around it: \(rendered.1)")
        #expect(abs(rendered.2[0] - rendered.3[0]) < 0.01, "away from the spot nothing changes")

        // A new store reads it back from disk; another seed is another fill.
        let files = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let source = try #require(DevelopSource(url: url))
        let reread = RemoveFillStore(directory: store.directory)
        reread.generative = nil
        #expect(!reread.isReady(for: source, adjustments: adjustments, spotIndex: 0))
        let fill = try #require(reread.fill(for: source, adjustments: adjustments, spotIndex: 0, waiting: true))
        #expect(reread.isReady(for: source, adjustments: adjustments, spotIndex: 0))
        #expect(fill.width > 0 && fill.ringFraction > 0)
        #expect(try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil).count == 1, "nothing new made")
        #expect(!reread.isReady(for: source, adjustments: removing(seed: 2), spotIndex: 0), "another seed is another fill")
        // Changing only the spot's opacity uses the same fill.
        var faded = adjustments
        faded.spots[0].opacity = 0.5
        #expect(reread.isReady(for: source, adjustments: faded, spotIndex: 0))
    }

    @Test("A fill takes on the colors of what it's drawn over, so a brighter render needn't fill again")
    func colorMatching() {
        // A fill made on mid-gray, drawn over the same scene twice as bright.
        let width = 32, height = 32
        var patch = [Float16](repeating: 0.4, count: width * height * 4)
        for i in 0..<(width * height) { patch[i * 4 + 3] = 1 }
        var ring = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width where x < 4 || x >= 28 || y < 4 || y >= 28 { ring[y * width + x] = 255 } }
        let fill = RemoveFillStore.Fill(
            box: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), width: width, height: height,
            patch: patch.withUnsafeBytes { Data($0) }, mask: Data(repeating: 255, count: width * height), ring: Data(ring),
            ringMean: SIMD3(0.4, 0.4, 0.4), ringFraction: Float(ring.filter { $0 > 0 }.count) / Float(width * height)
        )
        let bright = CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let drawn = RetouchRenderer.apply(fill, opacity: 1, to: bright)
        let value = Self.pixel(drawn, 32, 32)[0]
        #expect(abs(value - 0.8) < 0.03, "scaled up to match: \(value)")
    }

    @Test("A downloaded model that isn't the one expected isn't installed")
    func checksum() async throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appending(path: "Inpainting.zip")
        try Data("not a model".utf8).write(to: file)
        let store = InpaintingModelStore(downloadURL: file, checksum: String(repeating: "0", count: 64), directory: directory.url.appending(path: "Models"))
        #expect(store.state == .notDownloaded && !store.isAvailable)
        store.download()
        let start = Date()
        while Date().timeIntervalSince(start) < 20 {
            if case .failed = store.state { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .failed = store.state else { Issue.record("refused: \(store.state)"); return }
        #expect(!FileManager.default.fileExists(atPath: store.compiledURL.path))
        // Nowhere to download from and nothing installed: not offered.
        #expect(InpaintingModelStore(downloadURL: nil, checksum: nil, directory: directory.url.appending(path: "None")).state == .unavailable)
    }

    // MARK: Helpers

    private func stroke(_ points: [(Double, Double)], size: Double) -> PhotoAdjustments.BrushStroke {
        PhotoAdjustments.BrushStroke(points: points.map { UnitPoint(x: $0.0, y: $0.1) }, size: size, feather: 0, flow: 1, density: 1)
    }

    /// A Remove spot over the blob in ``writePhoto(to:)``.
    private func removing(seed: UInt64) -> PhotoAdjustments {
        var spot = Spot()
        spot.kind = .remove
        spot.seed = seed
        spot.area = PhotoAdjustments.RemoveArea(brush: PhotoAdjustments.BrushMask(strokes: [stroke([(0.5, 0.5)], size: 0.08)]))
        spot.fitCircleToArea(aspect: 1.5)
        var adjustments = PhotoAdjustments()
        adjustments.spots = [spot]
        return adjustments
    }

    /// 120 × 80 mid-gray with a dark blob at the center (radius 6).
    private func writePhoto(to url: URL) throws {
        let width = 120, height = 80
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
        context.fillEllipse(in: CGRect(x: 54, y: 34, width: 12, height: 12))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    nonisolated private static func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> [Float] {
        var data = [Float](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let extent = image.extent
        context.render(image, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: extent.minX + CGFloat(x), y: extent.minY + CGFloat(y), width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
        return data
    }
}
