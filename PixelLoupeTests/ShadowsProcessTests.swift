import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing
@testable import PixelLoupe

/// RAW-230: Shadows as a per-pixel gain like Lightroom's, with edits from before it keeping their look.
@Suite("Shadows process")
struct ShadowsProcessTests {
    private typealias Light = PhotoAdjustments.Light
    private let context = CIContext()
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private func light(_ json: String) throws -> Light {
        try JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{"light":\#(json)}"#.utf8)).light
    }

    // MARK: Model

    @Test("Shadows saved before RAW-230 keep the original process; new and unset ones get the current one")
    func decoding() throws {
        #expect(try light(#"{"shadows":0.4}"#).shadowsProcess == .highlightShadowFilter)
        #expect(try light(#"{"shadows":0.4,"shadowsProcess":2}"#).shadowsProcess == .perPixelGain)
        #expect(try light(#"{"shadows":0.4,"shadowsProcess":1}"#).shadowsProcess == .highlightShadowFilter)
        #expect(try light(#"{"shadows":0,"shadowsProcess":1}"#).shadowsProcess == .current, "no Shadows, no process to keep")
        #expect(try light(#"{"exposure":0.5}"#) == Light(exposure: 0.5))
        #expect(try light(#"{"shadows":0.4,"shadowsProcess":9}"#).shadowsProcess == .current, "a later version's process")
        #expect(Light().shadowsProcess == .perPixelGain)

        var old = try light(#"{"shadows":0.4}"#)
        let again = try JSONDecoder().decode(Light.self, from: try JSONEncoder().encode(old))
        #expect(again == old, "the process is saved")
        old.shadows = 0.2
        #expect(old.shadowsProcess == .highlightShadowFilter, "dragging keeps it")
        old.shadows = 0
        #expect(old.shadowsProcess == .current && old == Light(), "back at 0 it's like a new photo")
    }

    @Test("A mask's Shadows keeps its process, saved before or after RAW-193")
    func masks() throws {
        let flat = try JSONDecoder().decode(PhotoAdjustments.LocalSettings.self, from: Data(#"{"shadows":0.3}"#.utf8))
        #expect(flat.light.shadows == 0.3 && flat.light.shadowsProcess == .highlightShadowFilter)
        let sectioned = try JSONDecoder().decode(PhotoAdjustments.LocalSettings.self, from: Data(#"{"light":{"shadows":0.3}}"#.utf8))
        #expect(sectioned.light.shadowsProcess == .highlightShadowFilter)
        var new = PhotoAdjustments.LocalSettings()
        new.shadows = 0.3
        let again = try JSONDecoder().decode(PhotoAdjustments.LocalSettings.self, from: try JSONEncoder().encode(new))
        #expect(again.light.shadowsProcess == .perPixelGain)
    }

    @Test("Amounts convert between processes through the Lightroom value each matches")
    func conversion() {
        #expect(Light.shadows(0.395, from: .highlightShadowFilter, to: .perPixelGain) == 0.5)
        #expect(Light.shadows(0.5, from: .perPixelGain, to: .highlightShadowFilter) == 0.395)
        #expect(Light.shadows(-0.5, from: .highlightShadowFilter, to: .perPixelGain) == -0.5)
        #expect(Light.shadows(0.3, from: .perPixelGain, to: .perPixelGain) == 0.3)
    }

    @Test("Copying Shadows, or applying a preset's, brings its process along")
    func copying() throws {
        var old = PhotoAdjustments()
        old.light.shadows = 0.4
        old.light.shadowsProcess = .highlightShadowFilter
        var new = PhotoAdjustments()
        new.light.shadows = 0.3

        let copied = DevelopSetting.apply([.shadows], from: new, to: old)
        #expect(copied.light.shadows == 0.3 && copied.light.shadowsProcess == .perPixelGain)
        let back = DevelopSetting.apply([.shadows], from: old, to: new)
        #expect(back.light.shadows == 0.4 && back.light.shadowsProcess == .highlightShadowFilter)

        let data = PresetFixtures.xmp(name: "Lift", group: "G", attributes: ["Shadows2012": "+50"])
        let preset = try #require(DevelopPreset.parse(data, url: URL(filePath: "/p/lift.xmp"), defaultGroup: "x"))
        let applied = preset.applied(to: old, isRaw: true)
        #expect(applied.light.shadows == 0.5 && applied.light.shadowsProcess == .perPixelGain)
    }

    @Test("A preset written from either process gives Lightroom the value it matches")
    func writing() {
        func written(_ amount: Double, _ process: Light.ShadowsProcess) -> PresetWriter.Value? {
            var a = PhotoAdjustments()
            a.light.shadows = amount
            a.light.shadowsProcess = process
            return PresetWriter.settings(for: a, sections: [.basicTone])["Shadows2012"]
        }
        #expect(written(0.5, .perPixelGain) == .number(50))
        #expect(written(0.395, .highlightShadowFilter) == .number(50))
    }

    // MARK: Rendering

    /// A gray patch at `value` (sRGB-encoded) after `light`, sRGB-encoded.
    private func render(gray value: Double, red: Double? = nil, _ light: Light) -> (r: Double, g: Double, b: Double) {
        var adjustments = PhotoAdjustments()
        adjustments.light = light
        let color = CIColor(red: red ?? value, green: value, blue: value, alpha: 1, colorSpace: sRGB)!
        let input = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let output = AdjustmentPipeline.applyTone(adjustments, to: input, longEdge: 8, reducesNoise: false)
        var pixel = [Float](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 4, y: 4, width: 1, height: 1), format: .RGBAf, colorSpace: sRGB)
        return (Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
    }

    @Test("The original process renders exactly as it did: Core Image's filter, no color table")
    func originalProcessUnchanged() {
        var light = Light()
        light.shadows = 0.6
        light.shadowsProcess = .highlightShadowFilter
        #expect(ColorLUT.key(for: PhotoAdjustments(light: light)) == nil)

        let input = CIImage(color: CIColor(red: 0.2, green: 0.25, blue: 0.3, alpha: 1, colorSpace: sRGB)!).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let filter = CIFilter.highlightShadowAdjust()
        filter.inputImage = input
        filter.shadowAmount = 0.6
        filter.highlightAmount = 1
        let expected = filter.outputImage!
        var adjustments = PhotoAdjustments()
        adjustments.light = light
        let output = AdjustmentPipeline.applyTone(adjustments, to: input, longEdge: 8, reducesNoise: false)
        func pixel(_ image: CIImage) -> [Float] {
            var p = [Float](repeating: 0, count: 4)
            context.render(image, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 4, y: 4, width: 1, height: 1), format: .RGBAf, colorSpace: sRGB)
            return p
        }
        #expect(pixel(output) == pixel(expected))
    }

    @Test("The per-pixel process lifts dark tones in stops, fades out toward white, and keeps color")
    func perPixelResponse() {
        typealias T = ColorLUT.Transform
        // The curve itself: +100 lifts a dark gray by 2^(3 × (1 − v)^1.75) in linear light.
        let dark = 0.15
        let lifted = T.shadows(dark, dark, dark, 1).0
        let v = dark  // a gray's encoded luminance is its own value
        #expect(abs(T.decodeSRGB(lifted) / T.decodeSRGB(dark) - pow(2, 3 * pow(1 - v, 1.75))) < 1e-9)
        #expect(abs(T.shadows(1, 1, 1, 1).0 - 1) < 1e-9 && abs(T.shadows(1, 1, 1, -1).0 - 1) < 1e-9, "white is left alone")
        #expect(T.shadows(0.4, 0.4, 0.4, -1).0 < 0.4 && T.shadows(0.4, 0.4, 0.4, 0.5).0 < T.shadows(0.4, 0.4, 0.4, 1).0)

        // Through the pipeline, within the color table's interpolation.
        var light = Light()
        light.shadows = 1
        #expect(light.shadowsProcess == .perPixelGain && ColorLUT.key(for: PhotoAdjustments(light: light)) != nil)
        for gray in [0.1, 0.3, 0.6, 0.9] {
            let out = render(gray: gray, light)
            #expect(abs(out.g - T.shadows(gray, gray, gray, 1).1) < 0.01, "gray \(gray): \(out.g)")
        }
        let deepened = render(gray: 0.3, { var l = Light(); l.shadows = -1; return l }())
        #expect(deepened.g < 0.25)
        #expect(abs(render(gray: 0.98, light).g - 0.98) < 0.01)
        // A color keeps its channel ratios in linear light.
        let color = render(gray: 0.2, red: 0.3, light)
        let ratio = T.decodeSRGB(color.r) / T.decodeSRGB(color.g)
        #expect(abs(ratio - T.decodeSRGB(0.3) / T.decodeSRGB(0.2)) < 0.05, "\(ratio)")
    }

    @Test("Brilliance still uses Core Image's filter alongside the per-pixel Shadows")
    func brillianceUnchanged() {
        var brilliance = Light()
        brilliance.brilliance = 0.5
        var both = brilliance
        both.shadows = 0.4
        // Shadows adds the color table's lift on top of what Brilliance did alone.
        let alone = render(gray: 0.2, brilliance), together = render(gray: 0.2, both)
        #expect(together.g > alone.g + 0.02)
        var original = both
        original.shadowsProcess = .highlightShadowFilter
        #expect(render(gray: 0.2, original).g != together.g)
    }
}

private extension PhotoAdjustments {
    init(light: Light) {
        self.init()
        self.light = light
    }
}
