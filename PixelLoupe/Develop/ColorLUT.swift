import Foundation
import os

/// Folds every per-pixel tone and color adjustment (Light tone curve and Shadows, Levels, Curves, color grading
/// wheels, Selective Color and Black & White) into one 3D lookup table, applied on the GPU with
/// `CIColorCubeWithColorSpace`. One table lookup per pixel keeps slider drags fluid no matter how
/// many of these sections are in use.
nonisolated enum ColorLUT {
    static let dimension = 33
    private static let tableSize = 1024

    /// The adjustments that feed the table. Equal keys produce identical tables.
    struct Key: Equatable, Sendable {
        var light: PhotoAdjustments.Light?
        var levels: PhotoAdjustments.Levels?
        var curves: PhotoAdjustments.Curves?
        var color: PhotoAdjustments.ColorGrading?
        var selectiveColor: PhotoAdjustments.SelectiveColor?
        var blackAndWhite: PhotoAdjustments.BlackAndWhite?
        /// Vibrance and saturation (the Presence sliders that are per-pixel).
        var boost: Boost?
        /// The base look and the camera calibration, which run first.
        var profile: PhotoAdjustments.Profile?
        var calibration: PhotoAdjustments.Calibration?
        /// The photo's bright end, which per-pixel Shadows measures against: set only while it's in use.
        var shadowsReference: Double?
    }

    struct Boost: Equatable, Sendable {
        var vibrance = 0.0
        var saturation = 0.0
    }

    /// `nil` when no table-based adjustment is active. `shadowsReference` is the photo's
    /// (``DevelopSource/shadowsReference(exposure:)``), rounded so nearby measurements share a table.
    static func key(for adjustments: PhotoAdjustments, shadowsReference: Double = Transform.defaultShadowsReference) -> Key? {
        let light = adjustments.light
        let gainShadows = light.isEnabled && Transform.hasGainShadows(light)
        let lightUsesTable = light.isEnabled && (Transform.hasToneCurve(light) || gainShadows)
        let key = Key(
            light: lightUsesTable ? light : nil,
            levels: adjustments.levels.isActive ? adjustments.levels : nil,
            curves: adjustments.curves.isActive ? adjustments.curves : nil,
            color: adjustments.color.isActive ? adjustments.color : nil,
            // The B&W mix replaces the color mixer while black and white is on, as in Lightroom.
            selectiveColor: adjustments.selectiveColor.isActive && !adjustments.blackAndWhite.isActive ? adjustments.selectiveColor : nil,
            blackAndWhite: adjustments.blackAndWhite.isActive ? adjustments.blackAndWhite : nil,
            boost: adjustments.presence.hasColorEffect
                ? Boost(vibrance: adjustments.presence.vibrance, saturation: adjustments.presence.saturation) : nil,
            profile: adjustments.profile.isActive ? adjustments.profile : nil,
            calibration: adjustments.calibration.isActive ? adjustments.calibration : nil,
            shadowsReference: gainShadows ? (shadowsReference * 100).rounded() / 100 : nil
        )
        return key == Key() ? nil : key
    }

    /// The most recent tables, most recently used last: the photo's and each of its masks' (RAW-193), so a render
    /// doesn't build them again for each other.
    private static let cache = OSAllocatedUnfairLock<[(key: Key, data: Data)]>(initialState: [])
    private static let cacheLimit = 6

    /// RGBA float cube data for `CIColorCubeWithColorSpace`, cached for the most recent keys.
    static func cubeData(for key: Key) -> Data {
        let cached = cache.withLock { entries -> Data? in
            guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.data
        }
        if let cached { return cached }
        let data = makeCubeData(for: key)
        cache.withLock { entries in
            entries.removeAll { $0.key == key }
            entries.append((key, data))
            if entries.count > cacheLimit { entries.removeFirst(entries.count - cacheLimit) }
        }
        return data
    }

    private static func makeCubeData(for key: Key) -> Data {
        let transform = Transform(key: key)
        let n = dimension
        var values = [Float](repeating: 0, count: n * n * n * 4)
        var index = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let rgb = transform.apply(
                        Double(r) / Double(n - 1), Double(g) / Double(n - 1), Double(b) / Double(n - 1)
                    )
                    values[index] = Float(rgb.r)
                    values[index + 1] = Float(rgb.g)
                    values[index + 2] = Float(rgb.b)
                    values[index + 3] = 1
                    index += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The color transform the table samples, exposed for tests.
    struct Transform {
        private let key: Key
        private let tone: [Double]?
        /// Shadows under the per-pixel process, -1…1, and the photo's bright end it's measured against.
        private let shadows: Double?
        private let shadowsReference: Double
        private let red: [Double]?
        private let green: [Double]?
        private let blue: [Double]?
        /// The calibration's primaries, as a row-major 3×3.
        private let primaries: [Double]?

        init(key: Key) {
            self.key = key
            primaries = key.calibration.map(Self.primariesMatrix)
            shadows = key.light.flatMap { Self.hasGainShadows($0) ? $0.shadows : nil }
            shadowsReference = key.shadowsReference ?? Self.defaultShadowsReference
            var base: [Double]?
            if let light = key.light, Self.hasToneCurve(light) {
                base = (0..<ColorLUT.tableSize).map {
                    Self.lightTone(Double($0) / Double(ColorLUT.tableSize - 1), light)
                }
            }
            if let levels = key.levels {
                base = Self.compose(base) { Self.level($0, levels) }
            }
            if let curves = key.curves, !curves.parametric.isIdentity {
                // Lightroom applies the parametric curve before the point curve.
                base = Self.compose(base) { curves.parametric.value(at: $0) }
            }
            if let curves = key.curves, !curves.rgb.isIdentity {
                base = Self.compose(base) { curves.rgb.value(at: $0) }
            }
            tone = base
            func channel(_ curve: ToneCurve?) -> [Double]? {
                guard let curve, !curve.isIdentity else { return nil }
                return curve.table(count: ColorLUT.tableSize)
            }
            red = channel(key.curves?.red)
            green = channel(key.curves?.green)
            blue = channel(key.curves?.blue)
        }

        func apply(_ r: Double, _ g: Double, _ b: Double) -> (r: Double, g: Double, b: Double) {
            var (r, g, b) = (r, g, b)
            if let profile = key.profile { (r, g, b) = Self.look(r, g, b, profile) }
            if let primaries, let calibration = key.calibration { (r, g, b) = Self.calibrate(r, g, b, primaries, calibration) }
            if let shadows { (r, g, b) = Self.shadows(r, g, b, shadows, reference: shadowsReference) }
            if let tone { (r, g, b) = (Self.lookup(tone, r), Self.lookup(tone, g), Self.lookup(tone, b)) }
            if let red { r = Self.lookup(red, r) }
            if let green { g = Self.lookup(green, g) }
            if let blue { b = Self.lookup(blue, b) }
            if let color = key.color { (r, g, b) = Self.grade(r, g, b, color) }
            if let selective = key.selectiveColor { (r, g, b) = Self.selective(r, g, b, selective) }
            if let boost = key.boost { (r, g, b) = Self.boost(r, g, b, boost) }
            if let bw = key.blackAndWhite { (r, g, b) = Self.monochrome(r, g, b, bw) }
            return (r.clamped(to: 0...1), g.clamped(to: 0...1), b.clamped(to: 0...1))
        }

        // MARK: Tone

        private static func compose(_ table: [Double]?, _ f: (Double) -> Double) -> [Double] {
            let size = ColorLUT.tableSize
            return (0..<size).map { i in f(table?[i] ?? Double(i) / Double(size - 1)) }
        }

        private static func lookup(_ table: [Double], _ x: Double) -> Double {
            let position = x.clamped(to: 0...1) * Double(table.count - 1)
            let lower = Int(position)
            let upper = min(lower + 1, table.count - 1)
            let t = position - Double(lower)
            return table[lower] * (1 - t) + table[upper] * t
        }

        /// Whether Light needs ``lightTone``.
        static func hasToneCurve(_ light: PhotoAdjustments.Light) -> Bool {
            light.brightness != 0 || light.contrast != 0 || light.blackPoint != 0 || light.whites != 0 || light.highlights > 0
        }

        /// Whether Light's Shadows renders here (the per-pixel process) rather than with Core Image's filter.
        static func hasGainShadows(_ light: PhotoAdjustments.Light) -> Bool {
            light.shadows != 0 && light.shadowsProcess == .perPixelGain
        }

        /// Lightroom's Shadows adapts to the photo: what counts as a shadow is relative to the photo's
        /// bright end (the 95th percentile of its encoded luminance), and the strength grows with it,
        /// `exp(intercept + slope × reference)` stops at full Shadows, up to `cap`. Fitted to Lightroom's
        /// Shadows sweeps of ten photos (RAW-231).
        struct ShadowsStrength {
            var intercept: Double
            var slope: Double
            var cap: Double

            func stops(reference: Double) -> Double { min(exp(intercept + slope * reference), cap) }
        }

        static let shadowsLift = ShadowsStrength(intercept: -1.682, slope: 3.271, cap: 4)
        static let shadowsDeepen = ShadowsStrength(intercept: -1.888, slope: 3.585, cap: 5)
        static let shadowsFalloff = 1.75
        /// For an image with no photo to measure (and a typical one's).
        static let defaultShadowsReference = 0.8
        static let shadowsReferenceRange = 0.1...1.0

        /// Shadows' per-pixel process on sRGB-encoded color: a gain in stops of
        /// `amount × strength × (1 − min(v / reference, 1))^falloff`, where `v` is the pixel's encoded luminance
        /// and `reference` the photo's bright end. A gain keeps the color's ratios, and the photo's
        /// brightest tones are left alone.
        static func shadows(_ r: Double, _ g: Double, _ b: Double, _ amount: Double, reference: Double = defaultShadowsReference) -> (Double, Double, Double) {
            let (lr, lg, lb) = (decodeSRGB(r), decodeSRGB(g), decodeSRGB(b))
            let reference = reference.clamped(to: shadowsReferenceRange)
            let v = min(encodeSRGB(luminance(lr, lg, lb).clamped(to: 0...1)) / reference, 1)
            let strength = (amount > 0 ? shadowsLift : shadowsDeepen).stops(reference: reference)
            let gain = pow(2, amount * strength * pow(1 - v, shadowsFalloff))
            return (encodeSRGB(lr * gain), encodeSRGB(lg * gain), encodeSRGB(lb * gain))
        }

        static func decodeSRGB(_ x: Double) -> Double {
            x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }

        static func encodeSRGB(_ x: Double) -> Double {
            x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }

        static func lightTone(_ x: Double, _ light: PhotoAdjustments.Light) -> Double {
            var x = x
            let bp = light.blackPoint * 0.15
            if bp > 0 {
                x = max(0, (x - bp) / (1 - bp))
            } else if bp < 0 {
                x = -bp + x * (1 + bp)
            }
            if light.brightness != 0 {
                x = pow(x, pow(2, -0.8 * light.brightness))
            }
            if light.highlights > 0 {
                x += light.highlights * 1.2 * x * x * (1 - x)
            }
            let wp = light.whites * 0.15
            if wp > 0 {
                x = min(1, x / (1 - wp))
            } else if wp < 0 {
                x *= 1 + wp
            }
            if light.contrast != 0 {
                x = contrast(x, light.contrast)
            }
            return x.clamped(to: 0...1)
        }

        /// S-curve around middle gray: positive increases contrast, negative flattens.
        static func contrast(_ x: Double, _ amount: Double) -> Double {
            if amount < 0 { return 0.5 + (x - 0.5) * (1 + 0.6 * amount) }
            let k = 1 + 1.5 * amount
            return x < 0.5 ? 0.5 * pow(2 * x, k) : 1 - 0.5 * pow(2 * (1 - x), k)
        }

        static func level(_ x: Double, _ levels: PhotoAdjustments.Levels) -> Double {
            let range = max(levels.inputWhite - levels.inputBlack, 0.001)
            let normalized = ((x - levels.inputBlack) / range).clamped(to: 0...1)
            let curved = pow(normalized, 1 / max(levels.gamma, 0.01))
            return levels.outputBlack + curved * (levels.outputWhite - levels.outputBlack)
        }

        // MARK: Color

        static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
            0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
            let t = ((x - edge0) / max(edge1 - edge0, 0.0001)).clamped(to: 0...1)
            return t * t * (3 - 2 * t)
        }

        /// Fully saturated color for `hue` (0…1), offset so its components average zero.
        static func tint(hue: Double) -> (r: Double, g: Double, b: Double) {
            let (r, g, b) = hsvToRGB(h: hue * 360, s: 1, v: 1)
            let mean = (r + g + b) / 3
            return (r - mean, g - mean, b - mean)
        }

        /// How much each tonal wheel acts on a color of luminance `y` (0…1), given Balance and Blending.
        static func toneWeights(
            luminance y: Double, _ color: PhotoAdjustments.ColorGrading
        ) -> (shadows: Double, midtones: Double, highlights: Double) {
            let pivot = 0.5 + 0.25 * color.balance
            // Each end's weight falls off over a span around the middle of its half; blending 0.5
            // is the original span (the half itself), 0 a hard split and 1 twice as wide.
            let reach = 2 * color.blending.clamped(to: 0...1)
            let shadowCenter = pivot / 2, highlightCenter = (1 + pivot) / 2
            let shadowWeight = 1 - smoothstep(shadowCenter - reach * pivot / 2, shadowCenter + reach * pivot / 2, y)
            let highlightWeight = smoothstep(highlightCenter - reach * (1 - pivot) / 2, highlightCenter + reach * (1 - pivot) / 2, y)
            return (shadowWeight, max(0, 1 - shadowWeight - highlightWeight), highlightWeight)
        }

        static func grade(_ r: Double, _ g: Double, _ b: Double, _ color: PhotoAdjustments.ColorGrading) -> (Double, Double, Double) {
            let (shadowWeight, midtoneWeight, highlightWeight) = toneWeights(luminance: luminance(r, g, b), color)

            var (r, g, b) = (r, g, b)
            for (wheel, weight) in [(color.global, 1.0), (color.shadows, shadowWeight), (color.midtones, midtoneWeight), (color.highlights, highlightWeight)] {
                guard weight > 0 else { continue }
                let t = tint(hue: wheel.hue)
                let strength = wheel.amount * 0.35 * weight
                let lift = wheel.luminance * 0.25 * weight
                r += t.r * strength + lift
                g += t.g * strength + lift
                b += t.b * strength + lift
            }
            return (r, g, b)
        }

        static func selective(_ r: Double, _ g: Double, _ b: Double, _ selective: PhotoAdjustments.SelectiveColor) -> (Double, Double, Double) {
            var (h, s, v) = rgbToHSV(r, g, b)
            guard s > 0.0001 else { return (r, g, b) }
            var hueShift = 0.0, saturation = 0.0, lift = 0.0
            for range in PhotoAdjustments.SelectiveColorRange.allCases {
                let adjustment = selective[range]
                guard !adjustment.isIdentity else { continue }
                var distance = abs(h - range.hue).truncatingRemainder(dividingBy: 360)
                if distance > 180 { distance = 360 - distance }
                var weight = max(0, 1 - distance / 40)
                weight = weight * weight * (3 - 2 * weight) * min(1, s * 2)
                hueShift += weight * adjustment.hue * 30
                saturation += weight * adjustment.saturation
                lift += weight * adjustment.luminance * 0.3
            }
            h = (h + hueShift + 360).truncatingRemainder(dividingBy: 360)
            s = (s * (1 + saturation)).clamped(to: 0...1)
            v = v * (1 + lift)
            return hsvToRGB(h: h, s: s, v: v)
        }

        // MARK: Profile and calibration

        /// A profile's look, blended in by its amount (past 1 it exaggerates the look).
        static func look(_ r: Double, _ g: Double, _ b: Double, _ profile: PhotoAdjustments.Profile) -> (Double, Double, Double) {
            func saturate(_ c: (Double, Double, Double), _ k: Double) -> (Double, Double, Double) {
                let y = luminance(c.0, c.1, c.2)
                return (y + (c.0 - y) * k, y + (c.1 - y) * k, y + (c.2 - y) * k)
            }
            func curve(_ c: (Double, Double, Double), _ amount: Double) -> (Double, Double, Double) {
                (contrast(c.0.clamped(to: 0...1), amount), contrast(c.1.clamped(to: 0...1), amount), contrast(c.2.clamped(to: 0...1), amount))
            }
            var out: (Double, Double, Double)
            let input = (r, g, b)
            switch profile.kind {
            case .standard:
                out = input
            case .neutral:
                out = saturate(curve(input, -0.18), 0.88)
            case .vivid:
                out = saturate(curve(input, 0.25), 1.3)
            case .landscape:
                // Punchier, with extra color in greens and blues and deeper skies.
                let (h, s, _) = rgbToHSV(r, g, b)
                func near(_ center: Double, _ width: Double) -> Double {
                    var d = abs(h - center).truncatingRemainder(dividingBy: 360)
                    if d > 180 { d = 360 - d }
                    return (1 - smoothstep(0, width, d)) * min(1, s * 2)
                }
                let green = near(120, 55), blue = near(225, 50)
                var c = saturate(curve(input, 0.18), 1.12 + 0.2 * max(green, blue))
                let darker = 1 - 0.07 * blue
                c = (c.0 * darker, c.1 * darker, c.2 * darker)
                out = c
            case .portrait:
                // Softer, a little warm, with skin tones calmed.
                let (h, s, _) = rgbToHSV(r, g, b)
                var d = abs(h - 28).truncatingRemainder(dividingBy: 360)
                if d > 180 { d = 360 - d }
                let skin = (1 - smoothstep(0, 32, d)) * min(1, s * 3)
                var c = saturate(curve(input, -0.08), 0.94 - 0.1 * skin)
                c = (c.0 + 0.008, c.1, c.2 - 0.006)
                out = c
            case .monochrome:
                let gray = contrast((0.30 * r + 0.59 * g + 0.11 * b).clamped(to: 0...1), 0.2)
                out = (gray, gray, gray)
            }
            let k = profile.amount.clamped(to: 0...2)
            return (r + (out.0 - r) * k, g + (out.1 - g) * k, b + (out.2 - b) * k)
        }

        /// The calibration's primaries: each of red, green and blue turned about the gray axis by its hue
        /// (±30° at ±1) and its distance from gray scaled by its saturation, as the columns of a matrix
        /// (normalized so white is kept).
        static func primariesMatrix(_ calibration: PhotoAdjustments.Calibration) -> [Double] {
            func primary(_ index: Int, hue: Double, saturation: Double) -> [Double] {
                var v = [0.0, 0.0, 0.0]
                v[index] = 1
                let angle = hue * 30 * .pi / 180
                let mean = 1.0 / 3
                // Rodrigues' rotation of (v − mean) about (1, 1, 1)/√3.
                let d = v.map { $0 - mean }
                let k = 1 / 3.0.squareRoot()
                let axis = [k, k, k]
                let cross = [axis[1] * d[2] - axis[2] * d[1], axis[2] * d[0] - axis[0] * d[2], axis[0] * d[1] - axis[1] * d[0]]
                let rotated = (0..<3).map { d[$0] * cos(angle) + cross[$0] * sin(angle) }
                let scale = 1 + saturation
                return rotated.map { mean + $0 * scale }
            }
            let red = primary(0, hue: calibration.redHue, saturation: calibration.redSaturation)
            let green = primary(1, hue: calibration.greenHue, saturation: calibration.greenSaturation)
            let blue = primary(2, hue: calibration.blueHue, saturation: calibration.blueSaturation)
            // Rows sum to 1, so gray stays gray whatever the primaries do.
            var matrix = [red[0], green[0], blue[0], red[1], green[1], blue[1], red[2], green[2], blue[2]]
            for row in 0..<3 {
                let sum = matrix[row * 3] + matrix[row * 3 + 1] + matrix[row * 3 + 2]
                if abs(sum) > 1e-6 { for column in 0..<3 { matrix[row * 3 + column] /= sum } }
            }
            return matrix
        }

        static func calibrate(_ r: Double, _ g: Double, _ b: Double, _ m: [Double], _ calibration: PhotoAdjustments.Calibration) -> (Double, Double, Double) {
            var out = (
                m[0] * r + m[1] * g + m[2] * b,
                m[3] * r + m[4] * g + m[5] * b,
                m[6] * r + m[7] * g + m[8] * b)
            if calibration.shadowTint != 0 {
                // Green (positive) or magenta (negative) in the darkest tones.
                let dark = pow(1 - luminance(r, g, b).clamped(to: 0...1), 3)
                let tint = calibration.shadowTint * 0.06 * dark
                out = (out.0 - tint / 2, out.1 + tint, out.2 - tint / 2)
            }
            return out
        }

        /// Vibrance lifts muted colors more than saturated ones and leaves skin hues (orange) mostly
        /// alone; saturation scales every color's distance from gray. Both work on the luminance
        /// axis, so brightness doesn't shift.
        static func boost(_ r: Double, _ g: Double, _ b: Double, _ boost: Boost) -> (Double, Double, Double) {
            var scale = 1 + boost.saturation
            if boost.vibrance != 0 {
                let (hue, saturation, _) = rgbToHSV(r, g, b)
                var distance = abs(hue - 30)
                if distance > 180 { distance = 360 - distance }
                // Skin tones sit around 15–45°: protect them by up to 70% while the slider is positive.
                let skin = boost.vibrance > 0 ? 0.7 * max(0, 1 - distance / 30) : 0
                scale *= 1 + boost.vibrance * (1 - saturation) * (1 - skin)
            }
            let y = luminance(r, g, b)
            return (y + (r - y) * scale, y + (g - y) * scale, y + (b - y) * scale)
        }

        static func monochrome(_ r: Double, _ g: Double, _ b: Double, _ bw: PhotoAdjustments.BlackAndWhite) -> (Double, Double, Double) {
            var gray = (0.30 * r + 0.59 * g + 0.11 * b).clamped(to: 0...1)
            if bw.mix.contains(where: { $0 != 0 }) { gray = (gray + mixShift(r, g, b, bw.mix)).clamped(to: 0...1) }
            if bw.tone != 0 { gray = contrast(gray, bw.tone) }
            var tinted = (r: gray, g: gray, b: gray)
            if bw.neutrals != 0 {
                let target = bw.neutrals > 0 ? (r: 1.06, g: 1.0, b: 0.85) : (r: 0.88, g: 0.98, b: 1.08)
                let amount = abs(bw.neutrals)
                tinted = (
                    gray * (1 + (target.r - 1) * amount),
                    gray * (1 + (target.g - 1) * amount),
                    gray * (1 + (target.b - 1) * amount)
                )
            }
            let i = bw.intensity
            return (r + (tinted.r - r) * i, g + (tinted.g - g) * i, b + (tinted.b - b) * i)
        }

        /// How much brighter (or darker) a color's gray comes out with the B&W mix: each range's slider
        /// moves the colors near its hue, in proportion to how colorful they are.
        static func mixShift(_ r: Double, _ g: Double, _ b: Double, _ mix: [Double]) -> Double {
            let (h, s, _) = rgbToHSV(r, g, b)
            guard s > 0.0001 else { return 0 }
            var shift = 0.0
            for range in PhotoAdjustments.SelectiveColorRange.allCases where mix[range.rawValue] != 0 {
                var distance = abs(h - range.hue).truncatingRemainder(dividingBy: 360)
                if distance > 180 { distance = 360 - distance }
                var weight = max(0, 1 - distance / 40)
                weight = weight * weight * (3 - 2 * weight) * min(1, s * 2)
                shift += weight * mix[range.rawValue] * 0.4
            }
            return shift
        }

        static func rgbToHSV(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
            let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
            var h = 0.0
            if delta > 0 {
                if maxC == r {
                    h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
                } else if maxC == g {
                    h = 60 * ((b - r) / delta + 2)
                } else {
                    h = 60 * ((r - g) / delta + 4)
                }
            }
            if h < 0 { h += 360 }
            return (h, maxC > 0 ? delta / maxC : 0, maxC)
        }

        static func hsvToRGB(h: Double, s: Double, v: Double) -> (Double, Double, Double) {
            let c = v * s
            let hp = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
            let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
            let (r1, g1, b1): (Double, Double, Double) = switch hp {
            case ..<1: (c, x, 0)
            case ..<2: (x, c, 0)
            case ..<3: (0, c, x)
            case ..<4: (0, x, c)
            case ..<5: (x, 0, c)
            default: (c, 0, x)
            }
            let m = v - c
            return (r1 + m, g1 + m, b1 + m)
        }
    }
}
