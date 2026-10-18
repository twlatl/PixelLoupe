import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Detail and effects: sharpening, noise reduction, vignette, grain")
struct DetailEffectsTests {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func pixels(_ image: CIImage, _ rect: CGRect? = nil) -> [Float] {
        let bounds = rect ?? image.extent
        var data = [Float](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
        context.render(image, toBitmap: &data, rowBytes: Int(bounds.width) * 16, bounds: bounds, format: .RGBAf, colorSpace: nil)
        return data
    }

    private func value(_ image: CIImage, _ x: Int, _ y: Int, channel: Int = 0) -> Double {
        Double(pixels(image, CGRect(x: x, y: y, width: 1, height: 1))[channel])
    }

    /// A flat gray field with one soft vertical edge (left dark, right light) down the middle.
    private func edgeImage(size: Int = 96) -> CIImage {
        var data = [Float](repeating: 0, count: size * size * 4)
        for y in 0..<size { for x in 0..<size {
            let v: Float = x < size / 2 ? 0.35 : 0.65
            let i = (y * size + x) * 4
            data[i] = v; data[i + 1] = v; data[i + 2] = v; data[i + 3] = 1
        } }
        return CIImage(bitmapData: data.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: size * 16,
                       size: CGSize(width: size, height: size), format: .RGBAf, colorSpace: nil)
    }

    private func flat(_ level: Double, size: Int = 96) -> CIImage {
        CIImage(color: CIColor(red: level, green: level, blue: level)).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    // MARK: Model

    @Test("Sharpening saved with `edges` becomes a radius; new fields default")
    func sharpenMigration() throws {
        let old = try JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{"sharpen":{"isEnabled":true,"intensity":0.6,"edges":0.5}}"#.utf8))
        #expect(old.sharpen.intensity == 0.6 && old.sharpen.radius == 1.75)
        #expect(old.sharpen.detail == 0.25 && old.sharpen.masking == 0)
        let fresh = PhotoAdjustments.Sharpen()
        #expect(fresh.radius == 1 && !fresh.isActive)
        var edited = PhotoAdjustments()
        edited.sharpen = .init(intensity: 0.4, radius: 2.2, detail: 0.6, masking: 0.3)
        edited.vignette = .init(strength: 0.5, radius: 0.4, softness: 0.6, roundness: -0.3, style: .paintOverlay, highlightContrast: 0.4)
        edited.effects = .init(grain: 0.5, grainSize: 0.7, grainRoughness: 0.2, grainSeed: 123)
        edited.noiseReduction.detail = 0.8
        let data = try #require(edited.encoded)
        #expect(PhotoAdjustments(data: data) == edited)
        // Older noise reduction, vignette and effects decode with the new fields at their defaults.
        let older = try JSONDecoder().decode(PhotoAdjustments.self, from: Data(
            #"{"noiseReduction":{"amount":0.3,"color":0.2},"vignette":{"strength":0.5,"radius":0.4,"softness":0.6},"effects":{"grain":0.3}}"#.utf8))
        #expect(older.noiseReduction.detail == 0.5 && older.vignette.style == .highlightPriority && older.vignette.roundness == 0)
        #expect(older.effects.grainSize == 0.25 && older.effects.grainRoughness == 0.5 && older.effects.grainSeed == 0)
    }

    // MARK: Sharpening

    @Test("Sharpening steepens an edge; masking leaves flat areas and weak edges alone")
    func sharpening() {
        let base = edgeImage()
        let sharp = PhotoAdjustments.Sharpen(intensity: 1, radius: 1.5, detail: 0.25, masking: 0)
        let result = SharpenRenderer.apply(sharp, to: base, scale: 1)
        // The light side of the edge overshoots; the dark side undershoots.
        #expect(value(result, 49, 48) > 0.67 && value(result, 46, 48) < 0.3)
        // Flat area far from the edge is unchanged.
        #expect(abs(value(result, 10, 10) - 0.35) < 0.002 && abs(value(result, 85, 10) - 0.65) < 0.002)
        // Off at zero.
        #expect(SharpenRenderer.apply(.init(), to: base, scale: 1) == base)
    }

    @Test("Masking confines sharpening to strong edges")
    func sharpenMasking() {
        // A strong edge and a faint one side by side.
        let size = 96
        var data = [Float](repeating: 0, count: size * size * 4)
        for y in 0..<size { for x in 0..<size {
            let v: Float = x < 24 ? 0.2 : (x < 48 ? 0.8 : (x < 72 ? 0.8 : 0.82))
            let i = (y * size + x) * 4
            data[i] = v; data[i + 1] = v; data[i + 2] = v; data[i + 3] = 1
        } }
        let base = CIImage(bitmapData: data.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: size * 16,
                           size: CGSize(width: size, height: size), format: .RGBAf, colorSpace: nil)
        let unmasked = SharpenRenderer.apply(.init(intensity: 1, masking: 0), to: base, scale: 1)
        let masked = SharpenRenderer.apply(.init(intensity: 1, masking: 0.9), to: base, scale: 1)
        // The faint edge at x = 72 (0.80 → 0.82) overshoots without masking and not with it.
        let faintUnmasked = abs(value(unmasked, 73, 48) - 0.82)
        let faintMasked = abs(value(masked, 73, 48) - 0.82)
        #expect(faintMasked < faintUnmasked, "masked \(faintMasked) vs \(faintUnmasked)")
        // The strong edge at x = 24 is still sharpened with masking (it overshoots both ways).
        #expect(value(masked, 25, 48) > 0.82 || value(masked, 22, 48) < 0.18)
    }

    @Test("The mask preview is white on edges and black elsewhere")
    func maskPreview() {
        let mask = SharpenRenderer.maskPreview(for: edgeImage(), masking: 0.5, scale: 1)
        #expect(max(value(mask, 47, 48), value(mask, 48, 48)) > 0.5, "on the edge")
        #expect(value(mask, 8, 48) < 0.05 && value(mask, 88, 48) < 0.05, "in flat areas")
        // A higher bar admits fewer edges.
        let strict = SharpenRenderer.maskPreview(for: edgeImage(), masking: 1, scale: 1)
        #expect(value(strict, 47, 48) <= value(mask, 47, 48) + 0.001)
    }

    // MARK: Vignette

    @Test("Each vignette style darkens the corners and leaves the center", arguments: PhotoAdjustments.Vignette.Style.allCases)
    func vignetteStyles(style: PhotoAdjustments.Vignette.Style) {
        let base = flat(0.6, size: 120)
        var vignette = PhotoAdjustments.Vignette()
        vignette.strength = 1
        vignette.style = style
        let result = VignetteRenderer.apply(vignette, to: base)
        #expect(abs(value(result, 60, 60) - 0.6) < 0.01, "center")
        #expect(value(result, 1, 1) < 0.35, "corner is much darker: \(value(result, 1, 1))")
        // Lightening goes the other way.
        vignette.strength = -1
        let lighter = VignetteRenderer.apply(vignette, to: base)
        #expect(value(lighter, 1, 1) > 0.8 && abs(value(lighter, 60, 60) - 0.6) < 0.01)
    }

    @Test("Highlight priority keeps bright areas bright")
    func vignetteHighlights() {
        var vignette = PhotoAdjustments.Vignette()
        vignette.strength = 1
        vignette.style = .highlightPriority
        let bright = VignetteRenderer.apply(vignette, to: flat(0.95, size: 120))
        vignette.highlightContrast = 1
        let protected = VignetteRenderer.apply(vignette, to: flat(0.95, size: 120))
        #expect(value(protected, 1, 1) > value(bright, 1, 1) + 0.1)
        // Dark areas are barely protected.
        let darkPlain = value(VignetteRenderer.apply(.init(strength: 1), to: flat(0.2, size: 120)), 1, 1)
        let darkProtected = value(VignetteRenderer.apply(vignette, to: flat(0.2, size: 120)), 1, 1)
        #expect(abs(darkProtected - darkPlain) < 0.1)
    }

    @Test("Midpoint, feather and roundness shape the vignette")
    func vignetteShape() {
        let wide = CGRect(x: 0, y: 0, width: 200, height: 100)
        func mask(_ configure: (inout PhotoAdjustments.Vignette) -> Void) -> CIImage {
            var vignette = PhotoAdjustments.Vignette()
            configure(&vignette)
            return VignetteRenderer.mask(vignette, extent: wide)
        }
        // A lower midpoint brings the effect further in.
        #expect(value(mask { $0.radius = 0.1 }, 140, 50) > value(mask { $0.radius = 0.9 }, 140, 50))
        // A bigger feather spreads it (more at a point just inside the start).
        let near = value(mask { $0.radius = 0.5; $0.softness = 0.1 }, 100, 5)
        let wideFeather = value(mask { $0.radius = 0.5; $0.softness = 0.9 }, 100, 5)
        #expect(near != wideFeather)
        // At roundness 0 the vignette follows the photo's shape: the same distance (as a fraction of the
        // half-size) along the long and the short axis; a circle reaches further along the short axis.
        let ellipse = mask { $0.radius = 0.3; $0.softness = 0.3 }
        #expect(abs(value(ellipse, 190, 50) - value(ellipse, 100, 95)) < 0.1)
        let circle = mask { $0.radius = 0.3; $0.softness = 0.3; $0.roundness = 1 }
        #expect(value(circle, 100, 95) < value(ellipse, 100, 95), "a circle reaches the short edge later")
    }

    @Test("The vignette follows the cropped frame")
    func vignetteInPipeline() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "a.jpg")
        try Fixtures.writeJPEG(to: url, width: 200, height: 150)
        let source = try #require(DevelopSource(url: url))
        var plain = PhotoAdjustments()
        plain.crop.rect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        var vignetted = plain
        vignetted.vignette.strength = 1
        let a = source.image(with: plain, scale: 1), b = source.image(with: vignetted, scale: 1)
        #expect(a.extent == b.extent)
        let corner = CGRect(x: a.extent.minX, y: a.extent.minY, width: 3, height: 3)
        let darker = zip(pixels(a, corner), pixels(b, corner)).allSatisfy { $0 >= $1 }
        #expect(darker && pixels(b, corner)[0] < pixels(a, corner)[0])
    }

    // MARK: Grain

    private func extent() -> CGRect { CGRect(x: 0, y: 0, width: 128, height: 128) }

    /// Mean absolute difference between horizontally adjacent pixels: high for fine grain.
    private func roughness(_ image: CIImage) -> Double {
        let data = pixels(image)
        let width = Int(image.extent.width)
        var total = 0.0, count = 0.0
        for y in 0..<Int(image.extent.height) { for x in 1..<width {
            total += abs(Double(data[(y * width + x) * 4]) - Double(data[(y * width + x - 1) * 4]))
            count += 1
        } }
        return total / count
    }

    @Test("Grain is stable per seed, different between seeds, and neutral on average")
    func grainSeeds() throws {
        var effects = PhotoAdjustments.Effects(grain: 1)
        effects.grainSeed = 7
        let a = try #require(AdjustmentPipeline.grainLayer(effects, extent: extent(), scale: 1))
        let again = try #require(AdjustmentPipeline.grainLayer(effects, extent: extent(), scale: 1))
        #expect(pixels(a) == pixels(again))
        effects.grainSeed = 8
        let other = try #require(AdjustmentPipeline.grainLayer(effects, extent: extent(), scale: 1))
        #expect(pixels(a) != pixels(other))
        let mean = pixels(a).enumerated().filter { $0.offset % 4 == 0 }.map { Double($0.element) }.reduce(0, +) / (128 * 128)
        #expect(abs(mean - 0.5) < 0.02)
    }

    @Test("Grain size and roughness change its character")
    func grainCharacter() throws {
        func layer(size: Double, roughness: Double, amount: Double = 1) throws -> CIImage {
            try #require(AdjustmentPipeline.grainLayer(
                .init(grain: amount, grainSize: size, grainRoughness: roughness, grainSeed: 3), extent: extent(), scale: 1))
        }
        // Bigger grain is smoother pixel to pixel.
        #expect(try roughness(layer(size: 1, roughness: 0.5)) < roughness(layer(size: 0, roughness: 0.5)))
        // Higher roughness is crisper.
        #expect(try roughness(layer(size: 0.25, roughness: 1)) > roughness(layer(size: 0.25, roughness: 0)))
        // Amount scales the strength.
        #expect(try roughness(layer(size: 0.25, roughness: 0.5, amount: 1)) > roughness(layer(size: 0.25, roughness: 0.5, amount: 0.3)) * 2)
    }

    @Test("Grain looks the same at a reduced scale")
    func grainScale() throws {
        let effects = PhotoAdjustments.Effects(grain: 1, grainSize: 0.5, grainRoughness: 0.5, grainSeed: 5)
        let full = try #require(AdjustmentPipeline.grainLayer(effects, extent: CGRect(x: 0, y: 0, width: 256, height: 256), scale: 1))
        let half = try #require(AdjustmentPipeline.grainLayer(effects, extent: CGRect(x: 0, y: 0, width: 128, height: 128), scale: 0.5))
        // Per full-size pixel the grain is as coarse: roughness measured over equal spans of the photo
        // (two preview pixels per full-size pixel pair) is comparable.
        func swing(_ image: CIImage) -> Double {
            let data = pixels(image)
            let values = stride(from: 0, to: data.count, by: 4).map { Double(data[$0]) }
            let mean = values.reduce(0, +) / Double(values.count)
            return (values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count)).squareRoot()
        }
        #expect(abs(swing(full) - swing(half)) / swing(full) < 0.35)
    }

    // MARK: Noise reduction

    @Test("Noise reduction detail changes how a noisy non-RAW photo renders")
    func noiseReductionRenders() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "noisy.jpg")
        // A gradient with speckle and a hard edge.
        let size = 128
        var data = [Float](repeating: 0, count: size * size * 4)
        var seed: UInt32 = 12345
        for y in 0..<size { for x in 0..<size {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Float(seed >> 16) / 65535 - 0.5
            let v = (x < size / 2 ? 0.3 : 0.7) + noise * 0.15
            let i = (y * size + x) * 4
            data[i] = v; data[i + 1] = v; data[i + 2] = v; data[i + 3] = 1
        } }
        let image = CIImage(bitmapData: data.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: size * 16,
                            size: CGSize(width: size, height: size), format: .RGBAf, colorSpace: nil)
        try context.writeJPEGRepresentation(of: image, to: url, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let source = try #require(DevelopSource(url: url))
        var soft = PhotoAdjustments()
        soft.noiseReduction.amount = 1
        soft.noiseReduction.detail = 0
        var crisp = soft
        crisp.noiseReduction.detail = 1
        let a = pixels(source.image(with: soft, scale: 1)), b = pixels(source.image(with: crisp, scale: 1))
        #expect(a != b)
    }

    // MARK: Lightroom

    private func map(_ text: String, raw: Bool = true, seed: Int = 0) throws -> (PhotoAdjustments, [LightroomDevelopMapper.Difference]) {
        var adjustments = PhotoAdjustments()
        let differences = LightroomDevelopMapper.apply(
            .init(settings: try #require(try LuaTableParser.parse(text).table), processVersion: "11.0", whiteBalance: nil, isRaw: raw, seed: seed),
            to: &adjustments)
        return (adjustments, differences)
    }

    @Test("Lightroom's default RAW sharpening and color noise reduction are not edits")
    func rawDefaults() throws {
        let (defaults, differences) = try map("{ Sharpness = 40, SharpenRadius = 1, SharpenDetail = 25, SharpenEdgeMasking = 0, ColorNoiseReduction = 25, LuminanceSmoothing = 0 }")
        #expect(defaults.isDefault && differences.isEmpty)
        // For a JPEG the same values are real.
        let jpeg = try map("{ Sharpness = 40, ColorNoiseReduction = 25 }", raw: false).0
        #expect(jpeg.sharpen.intensity == 0.267 && jpeg.noiseReduction.color == 0.25)
    }

    @Test("Lightroom's sharpening and noise reduction import")
    func importsSharpenAndNoise() throws {
        let (adjustments, differences) = try map("""
            { Sharpness = 75, SharpenRadius = 1.8, SharpenDetail = 60, SharpenEdgeMasking = 35,
              LuminanceSmoothing = 40, ColorNoiseReduction = 50, LuminanceNoiseReductionDetail = 70 }
            """)
        #expect(differences.isEmpty)
        #expect(adjustments.sharpen == .init(intensity: 0.5, radius: 1.8, detail: 0.6, masking: 0.35))
        #expect(adjustments.noiseReduction == .init(amount: 0.4, color: 0.5, detail: 0.7))
        // Turning RAW sharpening off isn't representable: reported.
        let off = try map("{ Sharpness = 0, SharpenRadius = 1 }")
        #expect(off.0.sharpen == .init() && off.1 == [LightroomDevelopMapper.sharpeningOff])
        // Values with no counterpart are reported, not lost silently.
        let unsupported = try map("{ LuminanceNoiseReductionContrast = 30, ColorNoiseReductionSmoothness = 80 }")
        #expect(unsupported.1.map(\.key) == ["noise-reduction-detail"])
    }

    @Test("Lightroom's post-crop vignette imports with its sign, style and shape")
    func importsVignette() throws {
        let (adjustments, differences) = try map("""
            { PostCropVignetteAmount = -40, PostCropVignetteMidpoint = 30, PostCropVignetteFeather = 70,
              PostCropVignetteRoundness = -20, PostCropVignetteStyle = 3, PostCropVignetteHighlightContrast = 25 }
            """)
        #expect(differences.isEmpty)
        #expect(adjustments.vignette == .init(strength: 0.4, radius: 0.3, softness: 0.7, roundness: -0.2, style: .paintOverlay, highlightContrast: 0.25))
        let lighter = try map("{ PostCropVignetteAmount = 25, PostCropVignetteStyle = 2 }").0.vignette
        #expect(lighter.strength == -0.25 && lighter.style == .colorPriority && lighter.radius == 0.5)
        #expect(try map("{ PostCropVignetteAmount = 0, PostCropVignetteStyle = 3 }").0.isDefault)
    }

    @Test("Lightroom's grain imports with a seed of its own")
    func importsGrain() throws {
        let (adjustments, differences) = try map("{ GrainAmount = 35, GrainSize = 40, GrainFrequency = 80 }", seed: 4242)
        #expect(differences.isEmpty)
        #expect(adjustments.effects == .init(grain: 0.35, grainSize: 0.4, grainRoughness: 0.8, grainSeed: 4242))
        #expect(try map("{ GrainAmount = 0, GrainSize = 40 }").0.isDefault)
        let a = LightroomDevelopPhase.seed(for: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        #expect(a == LightroomDevelopPhase.seed(for: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!) && a > 0)
    }
}
