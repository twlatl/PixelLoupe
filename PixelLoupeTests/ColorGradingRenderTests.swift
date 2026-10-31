import Foundation
import Testing
@testable import PixelLoupe

/// Color Grading's maths against Lightroom Classic (RAW-242). The expected values are Lightroom's exports of the
/// step wedge from Scripts/color-grading-sweep.swift, as sRGB; the full comparison is the fidelity suite's
/// `color-grading` family.
@Suite("Color Grading rendering")
struct ColorGradingRenderTests {
    typealias Wheel = PhotoAdjustments.ColorWheel

    private func grading(
        shadows: Wheel = .init(), midtones: Wheel = .init(), highlights: Wheel = .init(), global: Wheel = .init(),
        blending: Double = 0.5, balance: Double = 0
    ) -> PhotoAdjustments.ColorGrading {
        .init(shadows: shadows, midtones: midtones, highlights: highlights, global: global, balance: balance, blending: blending)
    }

    private func wheel(_ hue: Double, _ saturation: Double, luminance: Double = 0) -> Wheel {
        .init(hue: hue / 360, amount: saturation / 100, luminance: luminance / 100)
    }

    /// Within `tolerance` per channel (gamma-encoded): the fit's error is spread over the whole wedge, so single points
    /// can be a few levels off while every case stays within the fidelity target.
    private func expectClose(
        _ color: (Double, Double, Double), _ expected: (Double, Double, Double), within tolerance: Double = 0.03,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let differences = [abs(color.0 - expected.0), abs(color.1 - expected.1), abs(color.2 - expected.2)]
        #expect(differences.allSatisfy { $0 <= tolerance }, "got \(color), Lightroom \(expected)", sourceLocation: sourceLocation)
    }

    @Test("Each wheel matches Lightroom's export on gray", arguments: [
        ("Global cyan 50", 0.4942, (0.2927, 0.5661, 0.5467)),
        ("Shadows cyan 50", 0.3045, (0.1090, 0.3411, 0.3266)),
        ("Midtones yellow 50", 0.4942, (0.5728, 0.5462, 0.4248)),
        ("Highlights blue 50", 0.8103, (0.7511, 0.7875, 0.9105)),
        ("Global luminance +100", 0.4942, (0.5846, 0.5846, 0.5846)),
        ("Shadows luminance +100", 0.1781, (0.2662, 0.2662, 0.2662)),
    ])
    func wheelOnGray(name: String, gray: Double, expected: (Double, Double, Double)) {
        let color = switch name {
        case "Global cyan 50": grading(global: wheel(180, 50))
        case "Shadows cyan 50": grading(shadows: wheel(180, 50))
        case "Midtones yellow 50": grading(midtones: wheel(60, 50))
        case "Highlights blue 50": grading(highlights: wheel(240, 50))
        case "Global luminance +100": grading(global: wheel(0, 0, luminance: 100))
        default: grading(shadows: wheel(0, 0, luminance: 100))
        }
        expectClose(ColorLUT.Transform.grade(gray, gray, gray, color), expected, within: 0.05)
    }

    /// The RAW-242 report: Shadows H170 S79, Midtones H179 S30, Highlights H266 S19, Blending 67.
    private var reported: PhotoAdjustments.ColorGrading {
        grading(shadows: wheel(170, 79), midtones: wheel(179, 30), highlights: wheel(266, 19), blending: 0.67)
    }

    @Test("The reported grade turns midtones and warm shadows teal, as Lightroom does")
    func reportedGrade() {
        expectClose(ColorLUT.Transform.grade(0.5574, 0.5574, 0.5574, reported), (0.3164, 0.6397, 0.6289))
        // A warm, shaded skin tone.
        let skin = ColorLUT.Transform.grade(0.4569, 0.2715, 0.2761, reported)
        expectClose(skin, (0.2300, 0.3895, 0.3345), within: 0.04)
        #expect(skin.1 > skin.0, "green-teal, not warm brown")
    }

    @Test("Blending 100 carries Shadows well into the midtones; Balance +100 gives most tones to Highlights")
    func blendingAndBalance() {
        expectClose(ColorLUT.Transform.grade(0.5574, 0.5574, 0.5574, grading(shadows: wheel(180, 50), blending: 1)), (0.3591, 0.6047, 0.5863))
        let balanced = grading(shadows: wheel(180, 50), highlights: wheel(30, 50), balance: 1)
        expectClose(ColorLUT.Transform.grade(0.3045, 0.3045, 0.3045, balanced), (0.4054, 0.2753, 0.2395))
    }

    @Test("Hues raise the channels on their side of the wheel and lower the others")
    func hueDirections() {
        let red = ColorLUT.Transform.hueDirection(0), yellow = ColorLUT.Transform.hueDirection(1.0 / 6), cyan = ColorLUT.Transform.hueDirection(0.5)
        #expect(red == (1, -1, -1) && yellow == (1, 1, -1) && cyan == (-1, 1, 1))
        let orange = ColorLUT.Transform.hueDirection(1.0 / 12)
        #expect(orange.r == 1 && abs(orange.g) < 1e-9 && orange.b == -1)
    }

    @Test("Black and white stay put under any grade")
    func endsStayPut() {
        let strong = grading(shadows: wheel(240, 100), midtones: wheel(60, 100), highlights: wheel(0, 100), global: wheel(120, 100))
        let white = ColorLUT.Transform.grade(1, 1, 1, strong), black = ColorLUT.Transform.grade(0, 0, 0, strong)
        #expect([white.0, white.1, white.2].allSatisfy { abs($0 - 1) < 0.001 })
        #expect([black.0, black.1, black.2].allSatisfy { abs($0) < 0.001 })
    }

    @Test("Tonal weights: Shadows below, Highlights above, Midtones between; Blending and Balance move them")
    func toneWeights() {
        let plain = grading()
        let dark = ColorLUT.Transform.toneWeights(tone: 0.1, plain), middle = ColorLUT.Transform.toneWeights(tone: 0.54, plain)
        let light = ColorLUT.Transform.toneWeights(tone: 0.95, plain)
        #expect(dark.shadows > 0.95 && dark.highlights < 0.05)
        #expect(light.highlights > 0.9 && light.shadows < 0.05)
        #expect(middle.midtones > 0.99 && middle.midtones > middle.shadows && middle.midtones > middle.highlights)
        // Lightroom's Shadows reach into the midtones much further at Blending 100 than at 0.
        let hard = ColorLUT.Transform.toneWeights(tone: 0.6, grading(blending: 0)), soft = ColorLUT.Transform.toneWeights(tone: 0.6, grading(blending: 1))
        #expect(hard.shadows < 0.02 && soft.shadows > 0.4)
        let towardHighlights = ColorLUT.Transform.toneWeights(tone: 0.3, grading(balance: 1))
        #expect(towardHighlights.highlights > towardHighlights.shadows)
    }
}
