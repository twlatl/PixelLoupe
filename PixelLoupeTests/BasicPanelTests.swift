import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Basic panel: tone and presence")
struct BasicPanelTests {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// Pixels (RGBA floats) of `image` over `rect`.
    private func pixels(_ image: CIImage, _ rect: CGRect? = nil) -> [Float] {
        let bounds = rect ?? image.extent
        var data = [Float](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
        context.render(image, toBitmap: &data, rowBytes: Int(bounds.width) * 16, bounds: bounds, format: .RGBAf, colorSpace: nil)
        return data
    }

    /// A soft checkerboard with detail at several scales, mid-gray on average.
    private func detailImage(size: Int = 128) -> CIImage {
        var data = [Float](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let coarse = ((x / 32) + (y / 32)) % 2 == 0 ? 0.42 : 0.58
                let fine = ((x / 3) + (y / 3)) % 2 == 0 ? 0.03 : -0.03
                let value = Float(coarse + fine)
                let i = (y * size + x) * 4
                data[i] = value; data[i + 1] = value; data[i + 2] = value; data[i + 3] = 1
            }
        }
        let bytes = data.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: bytes, bytesPerRow: size * 16, size: CGSize(width: size, height: size), format: .RGBAf, colorSpace: nil)
    }

    /// Standard deviation of the red channel around its local 9×9 mean: detail contrast.
    private func detail(_ image: CIImage) -> Double {
        let values = pixels(image).enumerated().filter { $0.offset % 4 == 0 }.map { Double($0.element) }
        let side = Int(image.extent.width)
        var total = 0.0, count = 0.0
        for y in 8..<(side - 8) {
            for x in 8..<(side - 8) {
                var mean = 0.0
                for dy in -4...4 { for dx in -4...4 { mean += values[(y + dy) * side + x + dx] } }
                mean /= 81
                total += pow(values[y * side + x] - mean, 2)
                count += 1
            }
        }
        return (total / count).squareRoot()
    }

    // MARK: Model

    @Test("Light decodes from settings saved before Whites existed")
    func oldLightDecodes() throws {
        let json = Data(#"{"light":{"isEnabled":true,"exposure":0.5,"brilliance":0,"highlights":0.2,"shadows":0,"brightness":0,"contrast":0.1,"blackPoint":0}}"#.utf8)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: json)
        #expect(decoded.light.exposure == 0.5 && decoded.light.highlights == 0.2 && decoded.light.whites == 0)
        #expect(decoded.presence == .init())
        // And a Light with only some fields.
        let partial = try JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{"light":{"contrast":0.3}}"#.utf8))
        #expect(partial.light.contrast == 0.3 && partial.light.isEnabled)
    }

    @Test("Presence round trips and is active only when enabled and changed")
    func presenceActivity() throws {
        var adjustments = PhotoAdjustments()
        #expect(!adjustments.presence.isActive)
        adjustments.presence.clarity = 0.4
        adjustments.light.whites = -0.3
        #expect(adjustments.presence.isActive && adjustments.presence.hasSpatialEffect && !adjustments.presence.hasColorEffect)
        let data = try #require(adjustments.encoded)
        #expect(PhotoAdjustments(data: data) == adjustments)
        adjustments.presence.isEnabled = false
        #expect(!adjustments.presence.isActive)
    }

    // MARK: Color table

    private func transform(_ configure: (inout PhotoAdjustments) -> Void) throws -> ColorLUT.Transform {
        var adjustments = PhotoAdjustments()
        configure(&adjustments)
        return ColorLUT.Transform(key: try #require(ColorLUT.key(for: adjustments)))
    }

    @Test("Whites move the top of the range; blacks leave the middle alone")
    func whitesAndBlacks() throws {
        let brighter = try transform { $0.light.whites = 1 }
        #expect(brighter.apply(0.8, 0.8, 0.8).r > 0.8 && brighter.apply(1, 1, 1).r == 1)
        #expect(abs(brighter.apply(0.1, 0.1, 0.1).r - 0.1) < 0.1 * 0.2)
        let darker = try transform { $0.light.whites = -1 }
        #expect(darker.apply(0.9, 0.9, 0.9).r < 0.9 && darker.apply(1, 1, 1).r < 1)
    }

    @Test("Saturation scales distance from gray; -1 is monochrome; luminance stays")
    func saturation() throws {
        let gray = try transform { $0.presence.saturation = -1 }
        let result = gray.apply(0.8, 0.4, 0.2)
        #expect(abs(result.r - result.g) < 0.001 && abs(result.g - result.b) < 0.001)
        let luma = 0.2126 * 0.8 + 0.7152 * 0.4 + 0.0722 * 0.2
        #expect(abs(result.r - luma) < 0.001)
        let more = try transform { $0.presence.saturation = 0.5 }
        let boosted = more.apply(0.6, 0.5, 0.4)
        #expect(boosted.r - boosted.b > 0.2 - 0.0001 + 0.0001)
        // Gray stays gray.
        let same = more.apply(0.5, 0.5, 0.5)
        #expect(abs(same.r - 0.5) < 1e-9 && abs(same.b - 0.5) < 1e-9)
    }

    @Test("Vibrance lifts muted colors more than saturated ones and spares skin tones")
    func vibrance() throws {
        let t = try transform { $0.presence.vibrance = 1 }
        func chroma(_ c: (r: Double, g: Double, b: Double)) -> Double { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }
        // A muted blue gains a larger share of its chroma than a vivid blue.
        let muted = (r: 0.45, g: 0.5, b: 0.6), vivid = (r: 0.1, g: 0.3, b: 0.9)
        let mutedGain = chroma(t.apply(muted.r, muted.g, muted.b)) / chroma(muted)
        let vividGain = chroma(t.apply(vivid.r, vivid.g, vivid.b)) / chroma(vivid)
        #expect(mutedGain > vividGain && mutedGain > 1.2)
        // A muted orange (skin) gains less than a muted blue of the same chroma.
        let skin = (r: 0.62, g: 0.5, b: 0.42), blue = (r: 0.42, g: 0.5, b: 0.62)
        let skinGain = chroma(t.apply(skin.r, skin.g, skin.b)) / chroma(skin)
        let blueGain = chroma(t.apply(blue.r, blue.g, blue.b)) / chroma(blue)
        #expect(skinGain < blueGain)
        // Negative vibrance mutes.
        let negative = try transform { $0.presence.vibrance = -1 }
        #expect(chroma(negative.apply(muted.r, muted.g, muted.b)) < chroma(muted))
    }

    @Test("The table is rebuilt for color sliders but not for the spatial ones")
    func tableKeys() {
        var adjustments = PhotoAdjustments()
        adjustments.presence.clarity = 0.5
        adjustments.presence.texture = 0.5
        adjustments.presence.dehaze = 0.5
        #expect(ColorLUT.key(for: adjustments) == nil, "texture, clarity and dehaze don't use the table")
        adjustments.presence.vibrance = 0.2
        let a = ColorLUT.key(for: adjustments)
        adjustments.presence.clarity = -0.5
        #expect(a != nil && a == ColorLUT.key(for: adjustments))
    }

    // MARK: Spatial renders

    @Test("Texture and Clarity add local contrast when positive and remove it when negative")
    func localContrast() {
        let base = detailImage()
        let before = detail(base)
        for name in ["texture", "clarity"] {
            var more = PhotoAdjustments.Presence(), less = PhotoAdjustments.Presence()
            if name == "texture" { more.texture = 1; less.texture = -1 } else { more.clarity = 1; less.clarity = -1 }
            let sharper = detail(PresenceRenderer.apply(more, to: base, longEdge: 128))
            let softer = detail(PresenceRenderer.apply(less, to: base, longEdge: 128))
            #expect(sharper > before * 1.05, "\(name) +: \(sharper) vs \(before)")
            #expect(softer < before * 0.95, "\(name) −: \(softer) vs \(before)")
        }
        #expect(PresenceRenderer.apply(.init(), to: base, longEdge: 128) == base, "nothing changes at zero")
    }

    @Test("Dehaze raises contrast of a hazy photo; negative haze flattens it")
    func dehaze() {
        // A checkerboard of dark and mid-gray patches seen through haze: I = J·(1 − t) + A·t.
        let size = 128
        var data = [Float](repeating: 0, count: size * size * 4)
        for y in 0..<size { for x in 0..<size {
            let scene: Float = ((x / 32) + (y / 32)) % 2 == 0 ? 0.05 : 0.5
            let v = scene * 0.5 + 0.9 * 0.5
            let i = (y * size + x) * 4
            data[i] = v * 0.98; data[i + 1] = v; data[i + 2] = v * 1.02; data[i + 3] = 1
        } }
        let hazy = CIImage(bitmapData: data.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: size * 16,
                           size: CGSize(width: size, height: size), format: .RGBAf, colorSpace: nil)
        func range(_ image: CIImage) -> Float {
            let values = pixels(image).enumerated().filter { $0.offset % 4 == 1 }.map(\.element)
            return (values.max() ?? 0) - (values.min() ?? 0)
        }
        let before = range(hazy)
        var clear = PhotoAdjustments.Presence(), haze = PhotoAdjustments.Presence()
        clear.dehaze = 1; haze.dehaze = -1
        #expect(range(PresenceRenderer.apply(clear, to: hazy, longEdge: 128)) > before * 1.15)
        #expect(range(PresenceRenderer.apply(haze, to: hazy, longEdge: 128)) < before * 0.9)
    }

    @Test("A photo renders through the whole pipeline with every new slider")
    func pipelineRenders() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "a.jpg")
        try Fixtures.writeJPEG(to: url, width: 200, height: 150)
        let source = try #require(DevelopSource(url: url))
        var adjustments = PhotoAdjustments()
        adjustments.light.whites = 0.4
        adjustments.presence = .init(texture: 0.3, clarity: 0.3, dehaze: 0.3, vibrance: 0.4, saturation: 0.2)
        let image = source.image(with: adjustments, scale: 1)
        #expect(image.extent.size == CGSize(width: 200, height: 150))
        #expect(context.createCGImage(image, from: image.extent) != nil)
    }

    // MARK: Lightroom mapping

    @Test("Lightroom's basic sliders map to Light and Presence")
    func lightroomMapping() throws {
        let text = """
            { Exposure2012 = 0.5, Contrast2012 = 25, Highlights2012 = -60, Shadows2012 = 40, Whites2012 = 15, Blacks2012 = -20,
              Texture = 10, Clarity2012 = -30, Dehaze = 12, Vibrance = 35, Saturation = -5 }
            """
        var adjustments = PhotoAdjustments()
        let differences = LightroomDevelopMapper.apply(
            .init(settings: try #require(try LuaTableParser.parse(text).table), processVersion: "11.0", whiteBalance: nil, isRaw: true), to: &adjustments)
        #expect(differences.isEmpty)
        #expect(adjustments.light == .init(exposure: 0.5, highlights: -0.6, shadows: 0.4, whites: 0.15, contrast: 0.25, blackPoint: 0.2))
        #expect(adjustments.presence == .init(texture: 0.1, clarity: -0.3, dehaze: 0.12, vibrance: 0.35, saturation: -0.05))
        #expect(LightroomScales.percent(250) == 1 && LightroomScales.blackPoint(fromBlacks: 100) == -1)
    }
}
