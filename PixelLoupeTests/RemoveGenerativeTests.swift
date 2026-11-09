import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PixelLoupe

/// Generative Remove with the real model. The model isn't in the repository (it's downloaded the first time it's
/// used), so these run only when `PL_INPAINTING_MODEL_DIRECTORY` names a folder holding `Inpainting.mlmodelc`
/// (set `TEST_RUNNER_PL_INPAINTING_MODEL_DIRECTORY` for xcodebuild).
@Suite("Remove with the generative model (RAW-260)", .enabled(if: ProcessInfo.processInfo.environment["PL_INPAINTING_MODEL_DIRECTORY"] != nil))
struct RemoveGenerativeTests {
    /// The welcome screen's photo, with the smaller Joshua tree (in front of the rocks) painted over.
    nonisolated private static func removingTheSmallTree(seed: UInt64, generative: Bool) -> PhotoAdjustments {
        var spot = PhotoAdjustments.Spot()
        spot.kind = .remove
        spot.seed = seed
        spot.usesGenerativeAI = generative
        let trunk: [(Double, Double)] = [(0.648, 0.18), (0.646, 0.26), (0.643, 0.33), (0.632, 0.39), (0.615, 0.43), (0.6, 0.45)]
        spot.area = PhotoAdjustments.RemoveArea(brush: PhotoAdjustments.BrushMask(strokes: [
            PhotoAdjustments.BrushStroke(points: trunk.map { .init(x: $0.0, y: $0.1) }, size: 0.035, feather: 0.1, flow: 1, density: 1),
            PhotoAdjustments.BrushStroke(points: [.init(x: 0.61, y: 0.44)], size: 0.06, feather: 0.1, flow: 1, density: 1),
        ]))
        spot.fitCircleToArea(aspect: 1)
        var adjustments = PhotoAdjustments()
        adjustments.spots = [spot]
        return adjustments
    }

    private var photoURL: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Design/WelcomeScreen.jpg")
    }

    @Test("The model fills the area, the same way for the same seed, and differently from patch fill")
    func fills() async throws {
        let models = try #require(ProcessInfo.processInfo.environment["PL_INPAINTING_MODEL_DIRECTORY"])
        let model = InpaintingModelStore(downloadURL: nil, checksum: nil, directory: URL(filePath: models))
        #expect(model.isAvailable)
        let directory = try TemporaryDirectory()
        let url = photoURL
        let results = try await Task.detached { () -> [[Float]] in
            let source = try #require(DevelopSource(url: url))
            var crops: [[Float]] = []
            for (generative, seed, folder) in [(true, UInt64(3), "a"), (true, 3, "b"), (false, 3, "c")] {
                let store = RemoveFillStore(directory: directory.url.appending(path: folder))
                store.generative = model
                source.removeFills = store
                let image = source.image(with: Self.removingTheSmallTree(seed: seed, generative: generative), scale: 1)
                crops.append(Self.pixels(image, CGRect(x: 760, y: 200, width: 120, height: 400)))
                if let out = ProcessInfo.processInfo.environment["PL_SNAPSHOT_DIRECTORY"] {
                    Self.write(image, to: URL(filePath: out).appending(path: generative ? "generative.png" : "patch.png"))
                }
            }
            return crops
        }.value
        let before = try await Task.detached { () -> [Float] in
            let source = try #require(DevelopSource(url: url))
            return Self.pixels(source.image(with: PhotoAdjustments(), scale: 1), CGRect(x: 760, y: 200, width: 120, height: 400))
        }.value
        #expect(results[0] == results[1], "deterministic")
        #expect(results[0] != results[2], "not patch fill")
        // The dark trunk is gone: the area is brighter than the tree was.
        func mean(_ values: [Float]) -> Float { values.reduce(0, +) / Float(values.count) }
        #expect(mean(results[0]) > mean(before) + 0.05, "filled: \(mean(results[0])) vs \(mean(before))")
    }

    nonisolated private static func pixels(_ image: CIImage, _ rect: CGRect) -> [Float] {
        var data = [Float](repeating: 0, count: Int(rect.width * rect.height) * 4)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        context.render(image, toBitmap: &data, rowBytes: Int(rect.width) * 16, bounds: rect, format: .RGBAf, colorSpace: nil)
        return data
    }

    nonisolated private static func write(_ image: CIImage, to url: URL) {
        let context = CIContext()
        guard let cgImage = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
    }

    @Test("The released zip downloads, checks out, unzips and compiles into a model that fills",
          .enabled(if: ProcessInfo.processInfo.environment["PL_INPAINTING_MODEL_ZIP"] != nil))
    func installs() async throws {
        let zip = URL(filePath: try #require(ProcessInfo.processInfo.environment["PL_INPAINTING_MODEL_ZIP"]))
        let directory = try TemporaryDirectory()
        let checksum = try InpaintingModelStore.sha256(of: zip)
        let store = InpaintingModelStore(downloadURL: zip, checksum: checksum, directory: directory.url)
        #expect(store.state == .notDownloaded)
        store.download()
        let start = Date()
        while Date().timeIntervalSince(start) < 300 {
            if case .ready = store.state { break }
            if case .failed(let message) = store.state { Issue.record("failed: \(message)"); return }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(store.isAvailable && FileManager.default.fileExists(atPath: store.compiledURL.path))
        // A hole in a flat image comes back filled.
        var pixels = [Float](repeating: 0.5, count: 64 * 64 * 3)
        var hole = [Bool](repeating: false, count: 64 * 64)
        for y in 20..<40 { for x in 20..<40 { hole[y * 64 + x] = true; for c in 0..<3 { pixels[(y * 64 + x) * 3 + c] = 0 } } }
        let filled = try #require(store.fill(PatchInpainter.Image(width: 64, height: 64, pixels: pixels), hole: hole, seed: 1))
        #expect(abs(filled.pixels[(30 * 64 + 30) * 3] - 0.5) < 0.1, "\(filled.pixels[(30 * 64 + 30) * 3])")
    }
}
