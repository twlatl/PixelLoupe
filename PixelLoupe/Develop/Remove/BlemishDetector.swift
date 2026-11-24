import CoreGraphics
import Foundation

/// Finds marks on skin that may be blemishes (RAW-306), in one picture of skin: a face, or a whole frame when no
/// face was found.
///
/// No model: it finds the skin by its color (around the face's own skin tone when there's a face), compares every
/// skin pixel with the skin around it, and keeps the small, compact patches that are darker or redder than their
/// surroundings. Each mark is scored as a blemish (red, soft) and as a natural mark (brown, round, even) so the
/// sliders can choose between them. Pure, so it can be tested on made-up skin.
nonisolated enum BlemishDetector {
    /// Bump when what's found or how it's scored changes: photos are then looked at again.
    static let version = 1

    /// Gamma-encoded RGB, 0…1, rows from the bottom.
    struct Image: Sendable {
        var width: Int
        var height: Int
        var pixels: [Float]
    }

    /// A mark, in the image's pixels.
    struct Mark: Equatable, Sendable {
        var center: CGPoint
        var radius: Double
        /// Where its coverage lies, pixels (origin bottom-left).
        var box: CGRect
        /// 8-bit coverage over `box`, rows from the bottom.
        var coverage: [UInt8]
        var coverageWidth: Int
        var coverageHeight: Int
        /// How much darker (relative) and redder than the skin around it, on average.
        var darkness: Double
        var redness: Double
        var roundness: Double
        var blemish: Double
        var natural: Double
    }

    /// The sizes a blemish can be, as radii in pixels.
    struct Sizes: Sendable {
        var minimum: Double
        var maximum: Double
    }

    /// Marks in `image`. `allowed` (one per pixel) leaves out what isn't skin however it looks: eyes, brows, lips,
    /// nostrils. `reference` is where the skin's own tone is measured (a face's cheeks and forehead); without it the
    /// tone comes from everything that looks like skin.
    static func find(in image: Image, allowed: [Bool]? = nil, reference: CGRect? = nil, sizes: Sizes) -> [Mark] {
        let w = image.width, h = image.height, n = w * h
        guard w >= 16, h >= 16, image.pixels.count >= n * 3 else { return [] }
        var luma = [Float](repeating: 0, count: n), cb = luma, cr = luma
        for i in 0..<n {
            let r = image.pixels[i * 3], g = image.pixels[i * 3 + 1], b = image.pixels[i * 3 + 2]
            let y = 0.299 * r + 0.587 * g + 0.114 * b
            luma[i] = y
            cb[i] = (b - y) * 0.564
            cr[i] = (r - y) * 0.713
        }

        // The skin's tone: the median chroma of what looks like skin (in the reference area, when there is one).
        func looksLikeSkin(_ i: Int) -> Bool {
            luma[i] > 0.12 && luma[i] < 0.97 && cr[i] > 0.01 && cr[i] < 0.2 && cb[i] > -0.2 && cb[i] < 0.03
        }
        var sampleCb: [Float] = [], sampleCr: [Float] = [], sampleLuma: [Float] = []
        let area = reference.map { $0.intersection(CGRect(x: 0, y: 0, width: w, height: h)) } ?? CGRect(x: 0, y: 0, width: w, height: h)
        let step = max(1, Int(sqrt(Double(area.width * area.height) / 20000)))
        for y in stride(from: Int(area.minY), to: Int(area.maxY), by: step) {
            for x in stride(from: Int(area.minX), to: Int(area.maxX), by: step) {
                let i = y * w + x
                guard allowed?[i] ?? true, looksLikeSkin(i) else { continue }
                sampleCb.append(cb[i])
                sampleCr.append(cr[i])
                sampleLuma.append(luma[i])
            }
        }
        guard sampleCb.count >= 50 else { return [] }
        let toneCb = median(sampleCb), toneCr = median(sampleCr), toneLuma = median(sampleLuma)

        // Skin: near that tone, and not much darker than it (dark hair shares skin's hue). Blemishes are redder and darker than it, so the mask is closed over holes as big as a
        // blemish, then kept away from the skin's edges (hairline, jaw), where everything differs from its surroundings.
        var skin = [Float](repeating: 0, count: n)
        for i in 0..<n where (allowed?[i] ?? true) && luma[i] > max(0.1, toneLuma * 0.5) && abs(cb[i] - toneCb) < 0.05 && abs(cr[i] - toneCr) < 0.06 {
            skin[i] = 1
        }
        let close = max(2, Int(sizes.maximum.rounded(.up)))
        skin = grow(skin, width: w, height: h, by: close)
        skin = shrink(skin, width: w, height: h, by: close + max(2, close / 2))
        if let allowed { for i in 0..<n where !allowed[i] { skin[i] = 0 } }
        guard skin.contains(1) else { return [] }

        // The surroundings: skin's average luma and redness nearby, from skin only.
        let reach = max(6, Int((sizes.maximum * 2).rounded()))
        var weight = skin, lumaSum = [Float](repeating: 0, count: n), redSum = lumaSum
        for i in 0..<n where skin[i] > 0 {
            lumaSum[i] = luma[i]
            redSum[i] = cr[i]
        }
        for _ in 0..<2 {
            boxBlur(&weight, width: w, height: h, radius: reach)
            boxBlur(&lumaSum, width: w, height: h, radius: reach)
            boxBlur(&redSum, width: w, height: h, radius: reach)
        }

        // How much darker (relative) and redder than its surroundings each skin pixel is, lightly smoothed.
        var dark = [Float](repeating: 0, count: n), red = dark, signal = dark
        for i in 0..<n where skin[i] > 0 && weight[i] > 0.05 {
            let aroundLuma = lumaSum[i] / weight[i], aroundRed = redSum[i] / weight[i]
            dark[i] = max(0, (aroundLuma - luma[i]) / max(aroundLuma, 0.05))
            red[i] = max(0, cr[i] - aroundRed)
            signal[i] = dark[i] + red[i] * 2
        }
        boxBlur(&signal, width: w, height: h, radius: 1)

        // Marks: grown from each peak (strongest first) down to a share of it, so a mark stops where it meets
        // shading rather than spreading into it; of a blemish's size and compact. What spreads too far is shading.
        let low: Float = 0.05, high: Float = 0.09
        var seeds: [Int] = []
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x, value = signal[i]
                guard value >= high, skin[i] > 0 else { continue }
                if value >= signal[i - 1], value >= signal[i + 1], value >= signal[i - w], value >= signal[i + w] { seeds.append(i) }
            }
        }
        seeds.sort { signal[$0] > signal[$1] }
        var claimed = [Bool](repeating: false, count: n)
        var marks: [Mark] = []
        let minArea = Double.pi * sizes.minimum * sizes.minimum * 0.5
        let maxArea = Double.pi * sizes.maximum * sizes.maximum
        var stack: [Int] = []
        let reachSquared = sizes.maximum * sizes.maximum
        for start in seeds where !claimed[start] {
            let bar = max(low, signal[start] * 0.5)
            let sx = start % w, sy = start / w
            // Grown no farther than the largest blemish; one that fills that whole disc is part of something bigger.
            var edge = 0, falls = 0
            var pixels: [Int] = []
            stack.append(start)
            claimed[start] = true
            var tooBig = false
            while let i = stack.popLast() {
                pixels.append(i)
                if Double(pixels.count) > maxArea * 1.5 {
                    tooBig = true
                    break
                }
                let x = i % w, y = i / w
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    let j = ny * w + nx
                    guard !claimed[j] else { continue }
                    guard signal[j] >= bar, skin[j] > 0 else {
                        falls += 1
                        continue
                    }
                    let ddx = Double(nx - sx), ddy = Double(ny - sy)
                    if ddx * ddx + ddy * ddy > reachSquared {
                        edge += 1
                        continue
                    }
                    claimed[j] = true
                    stack.append(j)
                }
            }
            // Reaching the limit all round means it carries on: shading, a shadow's edge.
            if Double(edge) > Double(edge + falls) * 0.15 { tooBig = true }
            if tooBig {
                // Let a mark beside it (a spot at a shadow's edge) have its pixels; only the peak is spent.
                for i in pixels + stack where i != start { claimed[i] = false }
                stack.removeAll(keepingCapacity: true)
                continue
            }
            stack.removeAll(keepingCapacity: true)
            guard Double(pixels.count) >= minArea, Double(pixels.count) <= maxArea else { continue }
            if let mark = mark(pixels, width: w, height: h, dark: dark, red: red, signal: signal) { marks.append(mark) }
        }
        return marks
    }

    /// A mark from its pixels, or nil when it's too thin or straggly to be one (a wrinkle, a hair).
    private static func mark(_ pixels: [Int], width w: Int, height h: Int, dark: [Float], red: [Float], signal: [Float]) -> Mark? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        var sx = 0.0, sy = 0.0, sumDark = 0.0, sumRed = 0.0, peak: Float = 0
        for i in pixels {
            let x = i % w, y = i / w
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            sx += Double(x); sy += Double(y)
            sumDark += Double(dark[i]); sumRed += Double(red[i])
            peak = max(peak, signal[i])
        }
        let count = Double(pixels.count)
        let cx = sx / count, cy = sy / count
        let boxW = maxX - minX + 1, boxH = maxY - minY + 1
        let elongation = Double(max(boxW, boxH)) / Double(max(1, min(boxW, boxH)))
        let fill = count / Double(boxW * boxH)
        guard elongation <= 3, fill >= 0.35 else { return nil }
        // Roundness: its area over the circle reaching its farthest pixel.
        var farthest = 0.0
        for i in pixels {
            let dx = Double(i % w) - cx, dy = Double(i / w) - cy
            farthest = max(farthest, dx * dx + dy * dy)
        }
        let roundness = min(1, count / (Double.pi * max(farthest, 0.25) + count * 0.1))
        guard roundness >= 0.25 else { return nil }
        let meanDark = sumDark / count, meanRed = sumRed / count
        // A blemish is mostly red (inflamed), helped by being darker; less so the less round it is. A natural mark is
        // dark without the red (brown), round and distinct. Shading is neither: dark, not red, and not round.
        func ramp(_ value: Double, _ from: Double, _ to: Double) -> Double { min(1, max(0, (value - from) / (to - from))) }
        let redShare = meanRed * 2 / max(meanDark + meanRed * 2, 1e-6)
        let shape = ramp(roundness, 0.25, 0.5)
        let blemish = (0.7 * ramp(meanRed, 0.01, 0.045) + 0.3 * ramp(meanDark, 0.05, 0.25)) * (0.4 + 0.6 * shape)
        let natural = ramp(0.3 - redShare, 0, 0.2) * ramp(roundness, 0.3, 0.55) * ramp(meanDark, 0.04, 0.1)

        // Coverage: the mark grown a little, so the fill takes its soft edge too.
        let pad = max(2, Int((sqrt(count / Double.pi) * 0.4).rounded()))
        let bx = max(0, minX - pad - 1), by = max(0, minY - pad - 1)
        let bw = min(w, maxX + pad + 2) - bx, bh = min(h, maxY + pad + 2) - by
        var inside = [Float](repeating: 0, count: bw * bh)
        for i in pixels { inside[(i / w - by) * bw + (i % w - bx)] = 1 }
        inside = grow(inside, width: bw, height: bh, by: pad)
        return Mark(
            center: CGPoint(x: cx + 0.5, y: cy + 0.5), radius: max(sqrt(count / Double.pi), sqrt(farthest)) + Double(pad),
            box: CGRect(x: bx, y: by, width: bw, height: bh),
            coverage: inside.map { $0 > 0 ? 255 : 0 }, coverageWidth: bw, coverageHeight: bh,
            darkness: meanDark, redness: meanRed, roundness: roundness, blemish: blemish, natural: natural
        )
    }

    // MARK: - Helpers

    static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// 1 wherever a 1 is within `radius` (a square), on a 0/1 mask.
    static func grow(_ mask: [Float], width: Int, height: Int, by radius: Int) -> [Float] {
        var blurred = mask
        boxBlur(&blurred, width: width, height: height, radius: radius)
        return blurred.map { $0 > 1e-4 ? 1 : 0 }
    }

    /// 1 only where everything within `radius` (a square) is 1, on a 0/1 mask.
    static func shrink(_ mask: [Float], width: Int, height: Int, by radius: Int) -> [Float] {
        var blurred = mask
        boxBlur(&blurred, width: width, height: height, radius: radius)
        return blurred.map { $0 > 1 - 1e-4 ? 1 : 0 }
    }

    /// A box blur of `radius` across and then up, with the edges repeated: running sums, so any radius costs the same.
    static func boxBlur(_ values: inout [Float], width: Int, height: Int, radius: Int) {
        guard radius > 0, width > 0, height > 0 else { return }
        let size = Float(radius * 2 + 1)
        var line = [Float](repeating: 0, count: max(width, height))
        values.withUnsafeMutableBufferPointer { v in
            line.withUnsafeMutableBufferPointer { line in
                for y in 0..<height {
                    let row = y * width
                    var sum: Float = 0
                    for k in -radius...radius { sum += v[row + min(max(k, 0), width - 1)] }
                    for x in 0..<width {
                        line[x] = sum / size
                        sum += v[row + min(x + radius + 1, width - 1)] - v[row + max(x - radius, 0)]
                    }
                    for x in 0..<width { v[row + x] = line[x] }
                }
                for x in 0..<width {
                    var sum: Float = 0
                    for k in -radius...radius { sum += v[min(max(k, 0), height - 1) * width + x] }
                    for y in 0..<height {
                        line[y] = sum / size
                        sum += v[min(y + radius + 1, height - 1) * width + x] - v[max(y - radius, 0) * width + x]
                    }
                    for y in 0..<height { v[y * width + x] = line[y] }
                }
            }
        }
    }
}
