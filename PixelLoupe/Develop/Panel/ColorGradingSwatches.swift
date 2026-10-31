import CoreImage

/// The colors a Color Grading well offers: the photo's own main colors, found by k-means in Lab on a small copy
/// rendered with Color Grading off, and how a picked color sets a wheel.
nonisolated enum ColorGradingSwatches {
    /// An sRGB color, 0…1 per channel.
    typealias RGB = SIMD3<Double>

    /// How many swatches a well shows.
    static let count = 5
    /// How long the small copy's long side is, in pixels.
    static let sampleSide = 96.0
    /// Colors with less Lab chroma than this read as gray and aren't offered (or picked).
    static let grayChroma = 8.0
    /// Swatches closer than this (Lab distance) to a busier one are left out as repeats.
    static let repeatDistance = 12.0

    /// The wheel setting a color asks for: its hue, and its Lab chroma as the strength (100 is full). `nil` for a
    /// gray, which has no hue to give. Luminance is left to the wheel's own slider.
    static func wheel(for color: RGB) -> (hue: Double, amount: Double)? {
        let chroma = Self.chroma(lab(color))
        guard chroma >= grayChroma else { return nil }
        let hue = ColorLUT.Transform.rgbToHSV(color.x, color.y, color.z).h.rounded()
        return ((hue == 360 ? 0 : hue) / 360, (min(chroma, 100)).rounded() / 100)
    }

    /// Up to `count` of the photo's main colors in a tab's tonal range (each pixel weighted as the renderer weighs
    /// that wheel), busiest first, without grays or near-repeats. Global and All use the whole photo.
    static func swatches(from pixels: [RGB], for tab: ColorGradingTab, in grading: PhotoAdjustments.ColorGrading) -> [RGB] {
        var samples: [(lab: SIMD3<Double>, rgb: RGB, weight: Double)] = []
        samples.reserveCapacity(pixels.count)
        for pixel in pixels {
            let weight = toneWeight(of: pixel, for: tab, in: grading)
            guard weight > 0.05 else { continue }
            samples.append((lab(pixel), pixel, weight))
        }
        guard let heaviest = samples.indices.max(by: { samples[$0].weight < samples[$1].weight }) else { return [] }

        // Seeds spread out from the heaviest sample (farthest first), so the result doesn't depend on chance.
        let clusterCount = min(8, samples.count)
        var centers = [samples[heaviest].lab]
        var nearest = samples.map { distanceSquared($0.lab, centers[0]) }
        while centers.count < clusterCount {
            guard let next = samples.indices.max(by: { nearest[$0] * samples[$0].weight < nearest[$1] * samples[$1].weight }),
                  nearest[next] > 0 else { break }
            centers.append(samples[next].lab)
            for index in samples.indices { nearest[index] = min(nearest[index], distanceSquared(samples[index].lab, samples[next].lab)) }
        }

        var assignment = [Int](repeating: -1, count: samples.count)
        for _ in 0..<12 {
            var moved = false
            for (index, sample) in samples.enumerated() {
                let closest = centers.indices.min { distanceSquared(sample.lab, centers[$0]) < distanceSquared(sample.lab, centers[$1]) }!
                if assignment[index] != closest { assignment[index] = closest; moved = true }
            }
            guard moved else { break }
            var sums = [SIMD3<Double>](repeating: .zero, count: centers.count), weights = [Double](repeating: 0, count: centers.count)
            for (index, sample) in samples.enumerated() {
                sums[assignment[index]] += sample.lab * sample.weight
                weights[assignment[index]] += sample.weight
            }
            for index in centers.indices where weights[index] > 0 { centers[index] = sums[index] / weights[index] }
        }

        // Each cluster's color is its members' average, so it's a color the photo really has.
        var clusters = centers.map { (lab: $0, rgb: RGB.zero, weight: 0.0) }
        for (index, sample) in samples.enumerated() {
            clusters[assignment[index]].rgb += sample.rgb * sample.weight
            clusters[assignment[index]].weight += sample.weight
        }
        let total = clusters.reduce(0) { $0 + $1.weight }
        var kept: [(lab: SIMD3<Double>, rgb: RGB)] = []
        for cluster in clusters.sorted(by: { $0.weight > $1.weight }) where cluster.weight > total * 0.01 {
            let color = cluster.rgb / cluster.weight, lab = lab(color)
            guard chroma(lab) >= grayChroma, !kept.contains(where: { distanceSquared($0.lab, lab) < repeatDistance * repeatDistance })
            else { continue }
            kept.append((lab, color))
            if kept.count == count { break }
        }
        return kept.map(\.rgb)
    }

    /// How much a tab's wheel acts on `pixel`.
    static func toneWeight(of pixel: RGB, for tab: ColorGradingTab, in grading: PhotoAdjustments.ColorGrading) -> Double {
        let weights = ColorLUT.Transform.toneWeights(pixel.x, pixel.y, pixel.z, grading)
        return switch tab {
        case .shadows: weights.shadows
        case .midtones: weights.midtones
        case .highlights: weights.highlights
        case .all, .global: 1
        }
    }

    /// An image's pixels as sRGB colors (fully transparent ones left out).
    static func pixels(of image: CIImage, context: CIContext) -> [RGB] {
        let extent = image.extent.integral
        guard !extent.isEmpty, !extent.isInfinite, extent.width * extent.height <= 1_000_000 else { return [] }
        let width = Int(extent.width), height = Int(extent.height)
        var bitmap = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &bitmap, rowBytes: width * 16, bounds: extent, format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return stride(from: 0, to: bitmap.count, by: 4).compactMap { index in
            bitmap[index + 3] > 0.5
                ? RGB(Double(bitmap[index]), Double(bitmap[index + 1]), Double(bitmap[index + 2])).clamped(lowerBound: .zero, upperBound: .one)
                : nil
        }
    }

    // MARK: Lab

    /// CIE Lab (D65) of an sRGB color.
    static func lab(_ color: RGB) -> SIMD3<Double> {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = linear(color.x), g = linear(color.y), b = linear(color.z)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        return SIMD3(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    static func chroma(_ lab: SIMD3<Double>) -> Double { (lab.y * lab.y + lab.z * lab.z).squareRoot() }

    private static func distanceSquared(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = a - b
        return (d * d).sum()
    }
}
