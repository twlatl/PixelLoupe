import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Color mixer, color grading and black & white mix")
struct ColorMixerTests {
    private func transform(_ configure: (inout PhotoAdjustments) -> Void) throws -> ColorLUT.Transform {
        var adjustments = PhotoAdjustments()
        configure(&adjustments)
        return ColorLUT.Transform(key: try #require(ColorLUT.key(for: adjustments)))
    }

    private func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

    // MARK: Model and migration

    @Test("Color grading saved before Global and Blending decodes with them at their defaults")
    func colorGradingMigration() throws {
        let json = Data(#"{"color":{"isEnabled":true,"balance":0.2,"shadows":{"hue":0.6,"amount":0.4,"luminance":0},"midtones":{"hue":0,"amount":0,"luminance":0},"highlights":{"hue":0.1,"amount":0.3,"luminance":0.1}}}"#.utf8)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: json)
        #expect(decoded.color.balance == 0.2 && decoded.color.shadows.hue == 0.6 && decoded.color.highlights.amount == 0.3)
        #expect(decoded.color.global == .init() && decoded.color.blending == 0.5)
    }

    @Test("Grain moves from Black & White to Effects with the same value")
    func grainMigration() throws {
        let json = Data(#"{"blackAndWhite":{"isEnabled":true,"intensity":0.8,"neutrals":0.1,"tone":0.2,"grain":0.45}}"#.utf8)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: json)
        #expect(decoded.effects.grain == 0.45 && decoded.blackAndWhite.isEnabled && decoded.blackAndWhite.intensity == 0.8)
        #expect(decoded.blackAndWhite.mix == Array(repeating: 0, count: 8))
        // New settings keep Effects as stored, and old grain doesn't overwrite it.
        let both = Data(#"{"blackAndWhite":{"isEnabled":true,"grain":0.45},"effects":{"isEnabled":true,"grain":0.1}}"#.utf8)
        #expect(try JSONDecoder().decode(PhotoAdjustments.self, from: both).effects.grain == 0.1)
        var edited = PhotoAdjustments()
        edited.effects.grain = 0.3
        edited.blackAndWhite[.blue] = 0.5
        edited.color.global = .init(hue: 0.2, amount: 0.3, luminance: 0)
        let data = try #require(edited.encoded)
        #expect(PhotoAdjustments(data: data) == edited)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"grain\":0.45"))
    }

    @Test("Grain applies to color photos too")
    func grainOnColorPhoto() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "a.jpg")
        try Fixtures.writeJPEG(to: url, width: 200, height: 150)
        let source = try #require(DevelopSource(url: url))
        var plain = PhotoAdjustments()
        plain.light.contrast = 0.01
        var grainy = plain
        grainy.effects.grain = 1
        let context = CIContext()
        func deviation(_ adjustments: PhotoAdjustments) -> Double {
            let image = source.image(with: adjustments, scale: 1)
            var data = [Float](repeating: 0, count: 200 * 150 * 4)
            context.render(image, toBitmap: &data, rowBytes: 200 * 16, bounds: CGRect(x: 0, y: 0, width: 200, height: 150), format: .RGBAf, colorSpace: nil)
            let greens = stride(from: 1, to: data.count, by: 4).map { Double(data[$0]) }
            let mean = greens.reduce(0, +) / Double(greens.count)
            return (greens.map { pow($0 - mean, 2) }.reduce(0, +) / Double(greens.count)).squareRoot()
        }
        #expect(deviation(grainy) > deviation(plain) + 0.01)
    }

    // MARK: Table math

    @Test("A global wheel tints every tone")
    func globalWheel() throws {
        let t = try transform { $0.color.global = .init(hue: 0, amount: 1, luminance: 0) }   // red
        for level in [0.15, 0.5, 0.85] {
            let result = t.apply(level, level, level)
            #expect(result.r > result.g && result.r > result.b, "level \(level)")
        }
    }

    @Test("Blending sets how sharply the shadow and highlight wheels part")
    func blending() throws {
        func tint(_ blending: Double, at level: Double) throws -> Double {
            let t = try transform {
                $0.color.shadows = .init(hue: 0, amount: 1, luminance: 0)
                $0.color.blending = blending
            }
            let result = t.apply(level, level, level)
            return result.r - result.b
        }
        // Just above the pivot, a hard split has left the shadows' red behind; a wide blend hasn't.
        #expect(try tint(0.9, at: 0.55) > tint(0.1, at: 0.55) + 0.01)
        // Deep shadows get the tint either way.
        #expect(try tint(0.1, at: 0.05) > 0.1)
        // At the default the original look is kept: shadows full at black, gone by the highlights.
        let original = try transform { $0.color.shadows = .init(hue: 0, amount: 1, luminance: 0) }
        #expect(original.apply(0.02, 0.02, 0.02).r - original.apply(0.02, 0.02, 0.02).b > 0.2)
        #expect(abs(original.apply(0.9, 0.9, 0.9).r - 0.9) < 0.01)
    }

    @Test("The B&W mix brightens or darkens colors near its hue only")
    func blackAndWhiteMix() throws {
        let plain = try transform { $0.blackAndWhite.isEnabled = true }
        let brightBlue = try transform { $0.blackAndWhite.isEnabled = true; $0.blackAndWhite[.blue] = 1 }
        let darkBlue = try transform { $0.blackAndWhite.isEnabled = true; $0.blackAndWhite[.blue] = -1 }
        let blue = (r: 0.15, g: 0.3, b: 0.8), green = (r: 0.2, g: 0.7, b: 0.25)
        func gray(_ t: ColorLUT.Transform, _ c: (r: Double, g: Double, b: Double)) -> Double { t.apply(c.r, c.g, c.b).g }
        #expect(gray(brightBlue, blue) > gray(plain, blue) + 0.1 && gray(darkBlue, blue) < gray(plain, blue) - 0.1)
        #expect(abs(gray(brightBlue, green) - gray(plain, green)) < 0.01, "green is untouched by the blue slider")
        // Grays don't move.
        #expect(abs(gray(brightBlue, (0.5, 0.5, 0.5)) - gray(plain, (0.5, 0.5, 0.5))) < 0.001)
    }

    @Test("While black and white is on, the color mixer is replaced by the mix")
    func mixerReplacedByMix() throws {
        var adjustments = PhotoAdjustments()
        adjustments.selectiveColor[.red].luminance = 1
        let color = try #require(ColorLUT.key(for: adjustments))
        #expect(color.selectiveColor != nil)
        adjustments.blackAndWhite.isEnabled = true
        let mono = try #require(ColorLUT.key(for: adjustments))
        #expect(mono.selectiveColor == nil && mono.blackAndWhite != nil)
        // The result is the same as with no mixer at all.
        var without = PhotoAdjustments()
        without.blackAndWhite.isEnabled = true
        let a = ColorLUT.Transform(key: mono), b = ColorLUT.Transform(key: try #require(ColorLUT.key(for: without)))
        let sample = (r: 0.8, g: 0.3, b: 0.2)
        #expect(a.apply(sample.r, sample.g, sample.b) == b.apply(sample.r, sample.g, sample.b))
        _ = luminance(sample)
    }

    // MARK: Lightroom

    private func map(_ text: String) throws -> (PhotoAdjustments, [LightroomDevelopMapper.Difference]) {
        var adjustments = PhotoAdjustments()
        let differences = LightroomDevelopMapper.apply(
            .init(settings: try #require(try LuaTableParser.parse(text).table), processVersion: "11.0", whiteBalance: nil, isRaw: true), to: &adjustments)
        return (adjustments, differences)
    }

    @Test("Lightroom's HSL values map to the color mixer")
    func importsHSL() throws {
        let (adjustments, differences) = try map("""
            { HueAdjustmentRed = -20, SaturationAdjustmentOrange = 35, LuminanceAdjustmentBlue = -50,
              HueAdjustmentMagenta = 100, SaturationAdjustmentGreen = 0 }
            """)
        #expect(differences.isEmpty)
        #expect(adjustments.selectiveColor[.red] == .init(hue: -0.2, saturation: 0, luminance: 0))
        #expect(adjustments.selectiveColor[.orange].saturation == 0.35 && adjustments.selectiveColor[.blue].luminance == -0.5)
        #expect(adjustments.selectiveColor[.magenta].hue == 1 && adjustments.selectiveColor[.green].isIdentity)
    }

    @Test("Lightroom's color grading maps to the wheels, blending and balance")
    func importsColorGrading() throws {
        let (adjustments, differences) = try map("""
            { ColorGradeShadowHue = 216, ColorGradeShadowSat = 30, ColorGradeShadowLum = -10,
              ColorGradeHighlightHue = 40, ColorGradeHighlightSat = 25, ColorGradeHighlightLum = 0,
              ColorGradeMidtoneHue = 0, ColorGradeMidtoneSat = 0, ColorGradeMidtoneLum = 5,
              ColorGradeGlobalHue = 90, ColorGradeGlobalSat = 10, ColorGradeGlobalLum = 0,
              ColorGradeBlending = 70, SplitToningBalance = -25 }
            """)
        #expect(differences.isEmpty)
        #expect(adjustments.color.shadows == .init(hue: 0.6, amount: 0.3, luminance: -0.1))
        #expect(adjustments.color.highlights.hue == 0.111 && adjustments.color.highlights.amount == 0.25)
        #expect(adjustments.color.midtones == .init(hue: 0, amount: 0, luminance: 0.05))
        #expect(adjustments.color.global == .init(hue: 0.25, amount: 0.1, luminance: 0))
        #expect(adjustments.color.blending == 0.7 && adjustments.color.balance == -0.25)
        // Defaults stay the defaults.
        #expect(try map("{ ColorGradeBlending = 50, ColorGradeShadowHue = 0, ColorGradeShadowSat = 0 }").0.isDefault)
    }

    @Test("Old split toning becomes the shadow and highlight wheels, unless color grading is set")
    func importsSplitToning() throws {
        let legacy = try map("""
            { SplitToningShadowHue = 200, SplitToningShadowSaturation = 40, SplitToningHighlightHue = 45, SplitToningHighlightSaturation = 20,
              SplitToningBalance = 10 }
            """).0
        #expect(legacy.color.shadows == .init(hue: 0.556, amount: 0.4, luminance: 0))
        #expect(legacy.color.highlights == .init(hue: 0.125, amount: 0.2, luminance: 0) && legacy.color.balance == 0.1)
        let modern = try map("{ ColorGradeShadowHue = 10, ColorGradeShadowSat = 50, SplitToningShadowHue = 200, SplitToningShadowSaturation = 40 }").0
        #expect(modern.color.shadows.amount == 0.5)
    }

    @Test("Lightroom's black & white and gray mixer import")
    func importsBlackAndWhite() throws {
        let (adjustments, differences) = try map("""
            { ConvertToGrayscale = true, AutoGrayscaleMix = true, GrayMixerRed = 12, GrayMixerBlue = -30, GrayMixerGreen = 0 }
            """)
        #expect(differences.isEmpty)
        #expect(adjustments.blackAndWhite.isEnabled && adjustments.blackAndWhite.intensity == 1)
        #expect(adjustments.blackAndWhite[.red] == 0.12 && adjustments.blackAndWhite[.blue] == -0.3 && adjustments.blackAndWhite[.green] == 0)
        #expect(try map("{ ConvertToGrayscale = false }").0.isDefault)
    }
}
