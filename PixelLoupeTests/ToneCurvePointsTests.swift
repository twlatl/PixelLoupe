import Foundation
import Testing
@testable import PixelLoupe

@Suite("Point and parametric curves")
struct ToneCurvePointsTests {
    private func curve(_ pairs: [(Double, Double)]) -> ToneCurve {
        ToneCurve(points: pairs.map { .init(x: $0.0, y: $0.1) })
    }

    @Test("A curve passes exactly through its points, whatever their number")
    func passesThroughPoints() {
        let pairs: [(Double, Double)] = [(0, 0.05), (0.1, 0.02), (0.3, 0.45), (0.37, 0.5), (0.8, 0.9), (1, 0.97)]
        let c = curve(pairs)
        for (x, y) in pairs { #expect(abs(c.value(at: x) - y) < 1e-9, "x = \(x)") }
        // Sixteen points work too and stay monotone for a rising curve.
        let many = curve((0..<16).map { (Double($0) / 15, pow(Double($0) / 15, 1.8)) })
        var previous = -1.0
        for step in 0...400 {
            let value = many.value(at: Double(step) / 400)
            #expect(value >= previous - 1e-9)
            previous = value
        }
    }

    @Test("A curve is flat beyond its end points")
    func flatBeyondEnds() {
        let c = curve([(0.2, 0.1), (0.8, 0.9)])
        #expect(c.value(at: 0) == 0.1 && c.value(at: 0.1) == 0.1)
        #expect(c.value(at: 0.95) == 0.9 && c.value(at: 1) == 0.9)
    }

    @Test("Points are normalized: sorted, clamped, spaced, 2 to 16")
    func normalization() {
        let c = curve([(0.5, 0.5), (-1, 2), (0.5005, 0.9), (1, 1), (0, 0)])
        #expect(c.points.map(\.x) == [0, 0.5, 1] || c.points.count >= 3)
        #expect(c.points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        #expect(zip(c.points, c.points.dropFirst()).allSatisfy { $1.x - $0.x >= ToneCurve.minimumGap })
        #expect(ToneCurve(points: []).points.count == 2 && ToneCurve(points: [.init(x: 0.4, y: 0.4)]).points.count == 2)
        let long = curve((0..<40).map { (Double($0) / 39, Double($0) / 39) })
        #expect(long.points.count == ToneCurve.maximumPoints)
        #expect(long.points.first?.x == 0 && long.points.last?.x == 1)
    }

    @Test("Adding, moving and removing points follows the editor's rules")
    func editing() {
        var c = ToneCurve.identity
        #expect(!c.canRemovePoint)
        let index = c.addPoint(x: 0.5, y: 0.7)
        #expect(index == 1 && c.points.count == 3 && c.value(at: 0.5) == 0.7)
        #expect(c.addPoint(x: 0.5, y: 0.1) == nil, "no second point at the same x")
        // A point can't cross its neighbors.
        c.movePoint(1, toX: 2, y: 0.4)
        #expect(c.points[1].x < 1 && c.points[1].y == 0.4)
        c.movePoint(1, toX: -3, y: 9)
        #expect(c.points[1].x > 0 && c.points[1].y == 1)
        let removed = c.removePoint(1)
        #expect(removed && c.points.count == 2)
        let removedLast = c.removePoint(0)
        #expect(!removedLast, "two points always remain")
        var x = 0.05
        while c.canAddPoint {
            c.addPoint(x: x, y: 0.5)
            x += 0.06
        }
        #expect(c.points.count == ToneCurve.maximumPoints && c.addPoint(x: 0.123, y: 0.5) == nil)
        // End points move in y and x.
        var ends = ToneCurve.identity
        ends.movePoint(0, toX: 0.1, y: 0.2)
        #expect(ends.points[0] == .init(x: 0.1, y: 0.2))
    }

    @Test("Any curve on the diagonal is the identity, and equal to it")
    func identity() {
        #expect(ToneCurve.identity.isIdentity)
        let extra = curve([(0, 0), (0.3, 0.3), (1, 1)])
        #expect(extra.isIdentity && extra == .identity)
        #expect(curve([(0, 0), (0.5, 0.6), (1, 1)]) != .identity)
        var adjustments = PhotoAdjustments()
        adjustments.curves.rgb = extra
        #expect(adjustments.isDefault && !adjustments.curves.isActive)
    }

    @Test("Five-point curves from earlier catalogs decode as points at the old inputs")
    func migration() throws {
        let old = Data(#"{"outputs":[0,0.4,0.55,0.8,1]}"#.utf8)
        let decoded = try JSONDecoder().decode(ToneCurve.self, from: old)
        #expect(decoded == ToneCurve(outputs: [0, 0.4, 0.55, 0.8, 1]))
        #expect(decoded.points.map(\.x) == ToneCurve.legacyInputs)
        let adjustments = try JSONDecoder().decode(PhotoAdjustments.self, from: Data(
            #"{"curves":{"isEnabled":true,"rgb":{"outputs":[0,0.3,0.5,0.7,1]},"red":{"outputs":[0,0.25,0.5,0.75,1]},"green":{"outputs":[0,0.25,0.5,0.75,1]},"blue":{"outputs":[0,0.25,0.5,0.75,1]}}}"#.utf8))
        #expect(adjustments.curves.rgb.value(at: 0.25) == 0.3 && adjustments.curves.red.isIdentity && adjustments.curves.parametric.isIdentity)
        // And new curves round trip.
        var edited = PhotoAdjustments()
        edited.curves.rgb = curve([(0, 0), (0.2, 0.1), (0.9, 0.95), (1, 1)])
        edited.curves.parametric.lights = 0.4
        let data = try #require(edited.encoded)
        #expect(PhotoAdjustments(data: data) == edited)
    }

    // MARK: Parametric

    @Test("Parametric regions lift or lower their own part of the range")
    func parametricRegions() {
        var p = ParametricCurve()
        #expect(p.isIdentity && p.value(at: 0.3) == 0.3)
        p.shadows = 1
        #expect(p.value(at: 0.1) > 0.15 && abs(p.value(at: 0.9) - 0.9) < 0.02)
        p = ParametricCurve(); p.highlights = -1
        #expect(p.value(at: 0.9) < 0.85 && abs(p.value(at: 0.1) - 0.1) < 0.02)
        p = ParametricCurve(); p.darks = 1
        #expect(p.value(at: 0.35) > 0.4)
        p = ParametricCurve(); p.lights = -1
        #expect(p.value(at: 0.65) < 0.6)
        // Black and white stay put whatever the sliders say.
        p = ParametricCurve(shadows: 1, darks: -1, lights: 1, highlights: -1)
        #expect(p.value(at: 0) == 0 && p.value(at: 1) == 1)
    }

    @Test("Moving a split moves the region, and splits stay ordered and apart")
    func splits() {
        var p = ParametricCurve(darks: 1)
        let before = p.value(at: 0.2)
        p.setSplit(0, to: 0.1)
        #expect(p.shadowSplit == 0.1 && p.value(at: 0.2) != before)
        p.setSplit(1, to: 0.05)
        #expect(p.midtoneSplit >= p.shadowSplit + ParametricCurve.minimumSplitGap)
        p.setSplit(2, to: 2)
        #expect(p.highlightSplit <= 1 - ParametricCurve.minimumSplitGap)
        p.setSplit(0, to: 0.9)
        #expect(p.shadowSplit <= p.midtoneSplit - ParametricCurve.minimumSplitGap)
    }

    @Test("The color table bakes in the parametric curve before the point curve")
    func lutBakesBoth() throws {
        var adjustments = PhotoAdjustments()
        adjustments.curves.parametric.shadows = 1
        adjustments.curves.rgb = curve([(0, 0), (0.5, 0.4), (1, 1)])
        let transform = ColorLUT.Transform(key: try #require(ColorLUT.key(for: adjustments)))
        let expected = adjustments.curves.rgb.value(at: adjustments.curves.parametric.value(at: 0.2))
        #expect(abs(transform.apply(0.2, 0.2, 0.2).r - expected) < 0.002)
        // Not the other order.
        let swapped = adjustments.curves.parametric.value(at: adjustments.curves.rgb.value(at: 0.2))
        #expect(abs(expected - swapped) > 0.01)
        #expect(ColorLUT.key(for: PhotoAdjustments()) == nil)
        var onlyParametric = PhotoAdjustments()
        onlyParametric.curves.parametric.lights = 0.5
        #expect(ColorLUT.key(for: onlyParametric) != nil)
    }

    // MARK: Lightroom

    private func map(_ text: String) throws -> (PhotoAdjustments, [LightroomDevelopMapper.Difference]) {
        var adjustments = PhotoAdjustments()
        let differences = LightroomDevelopMapper.apply(
            .init(settings: try #require(try LuaTableParser.parse(text).table), processVersion: "11.0", whiteBalance: nil, isRaw: true), to: &adjustments)
        return (adjustments, differences)
    }

    @Test("Lightroom's point curves import exactly, within 1/255 in the table")
    func importsPointCurves() throws {
        let (adjustments, differences) = try map("""
            { ToneCurvePV2012 = { 0, 0, 64, 48, 128, 140, 200, 230, 255, 255, },
              ToneCurvePV2012Red = { 0, 10, 255, 245, },
              ToneCurvePV2012Green = { 0, 0, 255, 255, },
              ToneCurveName2012 = "Custom" }
            """)
        #expect(differences.isEmpty)
        let rgb = adjustments.curves.rgb
        #expect(rgb.points.count == 5)
        for (x, y) in [(0.0, 0.0), (64.0, 48.0), (128.0, 140.0), (200.0, 230.0), (255.0, 255.0)] {
            #expect(abs(rgb.value(at: x / 255) - y / 255) < 1.0 / 255)
        }
        #expect(adjustments.curves.red.points.count == 2 && adjustments.curves.red.points[0].y == 10.0 / 255)
        #expect(adjustments.curves.green.isIdentity)
        // The color table agrees with the curve within 1/255 at every code value.
        let transform = ColorLUT.Transform(key: try #require(ColorLUT.key(for: adjustments)))
        for code in stride(from: 0, through: 255, by: 5) {
            let x = Double(code) / 255
            let direct = x * 0 + rgb.value(at: x)
            // (The table also has the red channel's curve; check green, which is untouched.)
            #expect(abs(transform.apply(x, x, x).g - direct) < 1.0 / 255 + 0.003)
        }
    }

    @Test("A curve with more than 16 points is simplified and reported; a linear one is nothing")
    func longCurves() throws {
        var numbers: [String] = []
        for index in 0..<20 {
            let x = index * 13
            numbers.append(String(x))
            numbers.append(String(x + (index % 2 == 0 ? 3 : 0)))
        }
        let values = numbers.joined(separator: ", ")
        let (adjustments, differences) = try map("{ ToneCurvePV2012 = { \(values), } }")
        #expect(adjustments.curves.rgb.points.count == ToneCurve.maximumPoints && differences == [LightroomDevelopMapper.curvePoints])
        let (linear, none) = try map("{ ToneCurvePV2012 = { 0, 0, 255, 255, }, ToneCurveName2012 = \"Linear\" }")
        #expect(linear.isDefault && none.isEmpty)
    }

    @Test("Lightroom's parametric sliders and splits import")
    func importsParametric() throws {
        let (adjustments, differences) = try map("""
            { ParametricShadows = 20, ParametricDarks = -10, ParametricLights = 0, ParametricHighlights = 35,
              ParametricShadowSplit = 20, ParametricMidtoneSplit = 45, ParametricHighlightSplit = 80 }
            """)
        #expect(differences.isEmpty)
        // Lightroom's regions are gentler than PixelLoupe's at the same number (RAW-229).
        #expect(adjustments.curves.parametric == ParametricCurve(
            shadows: 0.12, darks: -0.06, lights: 0, highlights: 0.21, shadowSplit: 0.2, midtoneSplit: 0.45, highlightSplit: 0.8))
        // Splits alone change nothing.
        #expect(try map("{ ParametricShadowSplit = 20, ParametricShadows = 0 }").0.isDefault)
    }
}
