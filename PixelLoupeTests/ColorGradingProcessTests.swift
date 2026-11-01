import Foundation
import Testing
@testable import PixelLoupe

/// RAW-242: Color Grading rendered like Lightroom's, with grades from before it keeping their look.
@Suite("Color Grading process")
struct ColorGradingProcessTests {
    private typealias Grading = PhotoAdjustments.ColorGrading

    private func grading(_ json: String) throws -> Grading {
        try JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{"color":\#(json)}"#.utf8)).color
    }

    private let teal = #"{"hue":0.5,"amount":0.5,"luminance":0}"#

    @Test("Grades saved before RAW-242 keep the original process; new and unset ones get the current one")
    func decoding() throws {
        #expect(try grading(#"{"shadows":\#(teal)}"#).process == .additiveTint)
        #expect(try grading(#"{"global":\#(teal),"process":2}"#).process == .proPhotoGain)
        #expect(try grading(#"{"midtones":\#(teal),"process":1}"#).process == .additiveTint)
        #expect(try grading(#"{"blending":0.8,"process":1}"#).process == .current, "no wheels, no process to keep")
        #expect(try grading(#"{"highlights":\#(teal),"process":9}"#).process == .current, "a later version's process")
        #expect(Grading().process == .proPhotoGain)

        var old = try grading(#"{"shadows":\#(teal)}"#)
        let again = try JSONDecoder().decode(Grading.self, from: try JSONEncoder().encode(old))
        #expect(again == old, "the process is saved")
        old.shadows.hue = 0.6
        #expect(old.process == .additiveTint, "dragging keeps it")
        old.shadows = .init()
        #expect(old.process == .current && old == Grading(), "every wheel back at the center is like a new photo")
    }

    @Test("A mask's grade keeps its process")
    func masks() throws {
        let old = try JSONDecoder().decode(PhotoAdjustments.LocalSettings.self, from: Data(#"{"color":{"shadows":\#(teal)}}"#.utf8))
        #expect(old.color.process == .additiveTint)
        var new = PhotoAdjustments.LocalSettings()
        new.color.shadows = .init(hue: 0.5, amount: 0.5)
        let again = try JSONDecoder().decode(PhotoAdjustments.LocalSettings.self, from: try JSONEncoder().encode(new))
        #expect(again.color.process == .proPhotoGain)
    }

    @Test("Each process renders its own maths, through the color table")
    func rendering() throws {
        var adjustments = PhotoAdjustments()
        adjustments.color.global = .init(hue: 0.5, amount: 0.5)
        let current = ColorLUT.Transform(key: try #require(ColorLUT.key(for: adjustments))).apply(0.4942, 0.4942, 0.4942)
        adjustments.color.process = .additiveTint
        let original = ColorLUT.Transform(key: try #require(ColorLUT.key(for: adjustments))).apply(0.4942, 0.4942, 0.4942)
        // v1.2.0: a zero-mean cyan tint of 0.35 × 0.5 in encoded values.
        #expect(abs(original.r - (0.4942 - 0.175 * 2 / 3)) < 0.001 && abs(original.g - (0.4942 + 0.175 / 3)) < 0.001)
        // Lightroom's export: (0.293, 0.566, 0.547).
        #expect(abs(current.r - 0.293) < 0.03 && abs(current.g - 0.566) < 0.03)
        #expect(ColorLUT.key(for: adjustments) != ColorLUT.key(for: { var a = adjustments; a.color.process = .proPhotoGain; return a }()),
                "the process is part of the table's key")
    }

    @Test("The color well's tonal weights follow the grade's process")
    func swatchWeights() {
        var grade = Grading()
        grade.shadows = .init(hue: 0.5, amount: 0.5)
        let current = ColorLUT.Transform.toneWeights(0.3, 0.3, 0.3, grade)
        grade.process = .additiveTint
        let original = ColorLUT.Transform.toneWeights(0.3, 0.3, 0.3, grade)
        #expect(original == ColorLUT.Transform.additiveToneWeights(luminance: 0.3, grade))
        #expect(current != original)
    }

    @Test("Copying Color Grading, or applying a preset's wheel, brings its process along")
    func copying() throws {
        var old = PhotoAdjustments()
        old.color.midtones = .init(hue: 0.1, amount: 0.3)
        old.color.process = .additiveTint
        var new = PhotoAdjustments()
        new.color.shadows = .init(hue: 0.5, amount: 0.4)

        #expect(DevelopSetting.apply([.colorGrading], from: new, to: old).color.process == .proPhotoGain)
        #expect(DevelopSetting.apply([.colorGrading], from: old, to: new).color.process == .additiveTint)

        let data = PresetFixtures.xmp(name: "Teal", group: "G", attributes: ["SplitToningShadowHue": "180", "SplitToningShadowSaturation": "40"])
        let preset = try #require(DevelopPreset.parse(data, url: URL(filePath: "/p/teal.xmp"), defaultGroup: "x"))
        let applied = preset.applied(to: old, isRaw: true)
        #expect(applied.color.shadows.amount == 0.4 && applied.color.process == .proPhotoGain)
    }
}
