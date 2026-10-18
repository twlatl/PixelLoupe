import Foundation

/// Color science for the fidelity suite: Display P3 to CIELAB, ΔE2000 and the luminance SSIM.
enum ColorDifference {
    struct Lab: Equatable {
        var l: Double, a: Double, b: Double
    }

    /// Display P3 → XYZ (D65) for linear values.
    private static let p3ToXYZ: [Double] = [
        0.4865709, 0.2656677, 0.1982173,
        0.2289746, 0.6917385, 0.0792869,
        0.0000000, 0.0451134, 1.0439444,
    ]
    private static let white = (x: 0.95047, y: 1.0, z: 1.08883)

    /// sRGB and Display P3 share a transfer function.
    static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// CIELAB (D65 white, which is the display's) from gamma-encoded Display P3.
    static func lab(displayP3 r: Double, _ g: Double, _ b: Double) -> Lab {
        let (lr, lg, lb) = (linear(r), linear(g), linear(b))
        let m = p3ToXYZ
        let x = m[0] * lr + m[1] * lg + m[2] * lb, y = m[3] * lr + m[4] * lg + m[5] * lb, z = m[6] * lr + m[7] * lg + m[8] * lb
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let (fx, fy, fz) = (f(x / white.x), f(y / white.y), f(z / white.z))
        return Lab(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    /// CIEDE2000 (Sharma, Wu and Dalal's formulation).
    static func deltaE2000(_ one: Lab, _ two: Lab) -> Double {
        let kL = 1.0, kC = 1.0, kH = 1.0
        func radians(_ d: Double) -> Double { d * .pi / 180 }
        func degrees(_ r: Double) -> Double { r * 180 / .pi }
        let c1 = hypot(one.a, one.b), c2 = hypot(two.a, two.b)
        let cMean = (c1 + c2) / 2
        let g = 0.5 * (1 - sqrt(pow(cMean, 7) / (pow(cMean, 7) + pow(25, 7))))
        let a1 = (1 + g) * one.a, a2 = (1 + g) * two.a
        let cp1 = hypot(a1, one.b), cp2 = hypot(a2, two.b)
        func hue(_ b: Double, _ a: Double) -> Double {
            guard b != 0 || a != 0 else { return 0 }
            let h = degrees(atan2(b, a))
            return h >= 0 ? h : h + 360
        }
        let hp1 = hue(one.b, a1), hp2 = hue(two.b, a2)
        let dL = two.l - one.l
        let dC = cp2 - cp1
        var dh = 0.0
        if cp1 * cp2 != 0 {
            dh = hp2 - hp1
            if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        }
        let dH = 2 * sqrt(cp1 * cp2) * sin(radians(dh / 2))
        let lMean = (one.l + two.l) / 2
        let cpMean = (cp1 + cp2) / 2
        var hpMean = hp1 + hp2
        if cp1 * cp2 != 0 {
            hpMean = abs(hp1 - hp2) <= 180 ? (hp1 + hp2) / 2 : (hp1 + hp2 < 360 ? (hp1 + hp2 + 360) / 2 : (hp1 + hp2 - 360) / 2)
        }
        let t = 1 - 0.17 * cos(radians(hpMean - 30)) + 0.24 * cos(radians(2 * hpMean)) + 0.32 * cos(radians(3 * hpMean + 6)) - 0.20 * cos(radians(4 * hpMean - 63))
        let dTheta = 30 * exp(-pow((hpMean - 275) / 25, 2))
        let rC = 2 * sqrt(pow(cpMean, 7) / (pow(cpMean, 7) + pow(25, 7)))
        let sL = 1 + 0.015 * pow(lMean - 50, 2) / sqrt(20 + pow(lMean - 50, 2))
        let sC = 1 + 0.045 * cpMean
        let sH = 1 + 0.015 * cpMean * t
        let rT = -sin(radians(2 * dTheta)) * rC
        let l = dL / (kL * sL), c = dC / (kC * sC), h = dH / (kH * sH)
        return sqrt(l * l + c * c + h * h + rT * c * h)
    }

    /// Mean structural similarity of two luminance planes (values 0…1, row-major), over 8×8 windows
    /// moved 4 pixels at a time.
    static func ssim(_ x: [Double], _ y: [Double], width: Int, height: Int) -> Double {
        precondition(x.count == width * height && y.count == x.count)
        let c1 = 0.01 * 0.01, c2 = 0.03 * 0.03
        let window = 8, step = 4
        guard width >= window, height >= window else { return x == y ? 1 : 0 }
        var total = 0.0, count = 0.0
        var row = 0
        while row + window <= height {
            var column = 0
            while column + window <= width {
                var sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumYY = 0.0, sumXY = 0.0
                for dy in 0..<window {
                    let base = (row + dy) * width + column
                    for dx in 0..<window {
                        let a = x[base + dx], b = y[base + dx]
                        sumX += a; sumY += b; sumXX += a * a; sumYY += b * b; sumXY += a * b
                    }
                }
                let n = Double(window * window)
                let (meanX, meanY) = (sumX / n, sumY / n)
                let varX = sumXX / n - meanX * meanX, varY = sumYY / n - meanY * meanY, covariance = sumXY / n - meanX * meanY
                total += ((2 * meanX * meanY + c1) * (2 * covariance + c2)) / ((meanX * meanX + meanY * meanY + c1) * (varX + varY + c2))
                count += 1
                column += step
            }
            row += step
        }
        return total / count
    }
}

/// Fits a monotone mapping from sweep measurements (the value Lightroom's slider had, and the value
/// of PixelLoupe's slider that matched its render best), to replace a linear conversion in
/// `LightroomScales`.
enum SliderSweepFit {
    struct Point: Equatable {
        var lightroom: Double
        var pixelLoupe: Double
    }

    /// Pool-adjacent-violators: the closest non-decreasing fit to the measurements, one point per
    /// distinct Lightroom value, in order.
    static func fit(_ measurements: [Point]) -> [Point] {
        let sorted = measurements.sorted { $0.lightroom < $1.lightroom }
        var blocks: [(sum: Double, weight: Double, inputs: [Double])] = sorted.map { ($0.pixelLoupe, 1, [$0.lightroom]) }
        var index = 0
        while index < blocks.count - 1 {
            if blocks[index].sum / blocks[index].weight > blocks[index + 1].sum / blocks[index + 1].weight {
                blocks[index].sum += blocks[index + 1].sum
                blocks[index].weight += blocks[index + 1].weight
                blocks[index].inputs += blocks[index + 1].inputs
                blocks.remove(at: index + 1)
                if index > 0 { index -= 1 }
            } else {
                index += 1
            }
        }
        return blocks.flatMap { block in block.inputs.map { Point(lightroom: $0, pixelLoupe: block.sum / block.weight) } }
    }

    /// The fitted PixelLoupe value for a Lightroom value, interpolating between the fitted points.
    static func evaluate(_ fitted: [Point], at value: Double) -> Double {
        guard let first = fitted.first, let last = fitted.last else { return value }
        if value <= first.lightroom { return first.pixelLoupe }
        if value >= last.lightroom { return last.pixelLoupe }
        for (a, b) in zip(fitted, fitted.dropFirst()) where value >= a.lightroom && value <= b.lightroom {
            guard b.lightroom > a.lightroom else { return b.pixelLoupe }
            let t = (value - a.lightroom) / (b.lightroom - a.lightroom)
            return a.pixelLoupe + (b.pixelLoupe - a.pixelLoupe) * t
        }
        return last.pixelLoupe
    }

    /// Swift for a table to paste into `LightroomScales`.
    static func swiftTable(named name: String, _ fitted: [Point]) -> String {
        let rows = fitted.map { String(format: "(%.3f, %.4f)", $0.lightroom, $0.pixelLoupe) }.joined(separator: ", ")
        return "static let \(name): [(lightroom: Double, pixelLoupe: Double)] = [\(rows)]"
    }
}
