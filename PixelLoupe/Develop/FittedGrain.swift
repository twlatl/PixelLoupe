import CoreImage

/// Film grain fitted to Lightroom Classic (RAW-284), from LrC's exports of the RAW-283 sweep (`effects-grain`: a
/// 6016 × 4016 gray chart at Amount, Size and Roughness steps, measured as each export minus its grain-free base).
///
/// What the exports showed, and how this grain follows them:
/// - Lightroom's grain is Gaussian, monochrome, and the same strength in every tone (in gamma-encoded levels; it
///   fades, linearly, within 5% of black or white, so it hardly clips there). So it's added to luminance in
///   gamma-encoded Display P3, not blended with Overlay (which peaks at mid-gray and tints colored pixels).
/// - Its spectrum is white noise filtered by `K̂(f) = e^(−u) · (gaussian + laplacian · u)`, u = 2π²σ²|f|², which fits
///   every case within 5%. Size sets σ (0.32 px at Size 0 to 2.3 px at 100). Roughness trades the Gaussian part (low
///   frequencies: mottle) for the Laplacian part (a band-pass ring): Roughness 0 is almost all band-pass, 75 and
///   above all Gaussian. Amount scales it linearly.
/// - Grain belongs to the photo's pixels: a 2048 px export shows the full-size grain box-averaged by the downscale.
///   At render scale s the kernel is the full-size one widened by that average (σ'² = σ²s² + (1 − s²)/12) and
///   weakened by it, which predicts LrC's 2048 px exports within 3%. Lightroom shrinks in linear light, so averaging
///   strong grain also lifts the encoded mean, by about 0.114 · (variance averaged away) / tone; that's added too.
nonisolated enum FittedGrainRenderer {
    /// The grain filter at one resolution: σ in pixels, and each part's strength in 8-bit levels per unit noise.
    struct Filter: Equatable {
        var sigma: Double
        var gaussian: Double
        var laplacian: Double
    }

    // The fits at Amount 50, one slider at a time around Size 25 and Roughness 50.
    static let sizes: [Double] = [0, 0.10, 0.25, 0.50, 0.75, 1]
    static let sigmaBySize: [Double] = [0.322, 0.499, 0.901, 1.399, 1.858, 2.295]
    static let gaussianBySize: [Double] = [12.42, 14.57, 17.97, 25.19, 33.34, 41.83]
    static let laplacianBySize: [Double] = [62.35, 23.24, 15.78, 13.28, 11.86, 10.32]
    static let roughnesses: [Double] = [0, 0.25, 0.50, 0.75, 1]
    static let sigmaByRoughness: [Double] = [1.012, 0.964, 0.901, 0.850, 0.911]
    static let gaussianByRoughness: [Double] = [1.00, 8.10, 17.97, 27.86, 37.49]
    static let laplacianByRoughness: [Double] = [61.37, 37.85, 15.78, 0, 0]

    /// The full-resolution filter for these settings. Size and Roughness were swept one at a time, so their
    /// effects combine as ratios to the shared case (Size 25, Roughness 50).
    static func filter(amount: Double, size: Double, roughness: Double) -> Filter {
        let size = size.clamped(to: 0...1), roughness = roughness.clamped(to: 0...1)
        func at(_ x: Double, _ xs: [Double], _ ys: [Double]) -> Double {
            guard let upper = xs.firstIndex(where: { $0 >= x }), upper > 0 else { return ys[0] }
            let t = (x - xs[upper - 1]) / (xs[upper] - xs[upper - 1])
            return ys[upper - 1] + t * (ys[upper] - ys[upper - 1])
        }
        let gain = amount.clamped(to: 0...1) / 0.5
        return Filter(
            sigma: at(size, sizes, sigmaBySize) * at(roughness, roughnesses, sigmaByRoughness) / sigmaByRoughness[2],
            gaussian: gain * at(size, sizes, gaussianBySize) * at(roughness, roughnesses, gaussianByRoughness) / gaussianByRoughness[2],
            laplacian: gain * at(size, sizes, laplacianBySize) * at(roughness, roughnesses, laplacianByRoughness) / laplacianByRoughness[2])
    }

    /// `filter` (full resolution) as it looks in a render at `scale` of full size: box-averaged by the downscale.
    static func filter(_ filter: Filter, atScale scale: Double) -> Filter {
        let s = scale.clamped(to: 1e-3...1)
        let sigma = ((filter.sigma * s) * (filter.sigma * s) + (1 - s * s) / 12).squareRoot()
        let narrowing = (filter.sigma * s / sigma) * (filter.sigma * s / sigma)
        return Filter(sigma: sigma, gaussian: filter.gaussian * s, laplacian: filter.laplacian * s * narrowing)
    }

    static let maximumRadius = 11

    /// How much the encoded mean rises per unit of grain variance a linear-light downscale averages away, over the
    /// tone (fitted to LrC's 2048 px export of Size 0, the strongest grain).
    static let downscaleLift = 0.114

    /// The grain's variance per pixel (8-bit levels²) for `filter`: the sum of its squared 2D taps.
    static func variance(_ filter: Filter) -> Double {
        let (h, d) = taps(sigma: filter.sigma)
        func tap(_ t: [Float], _ i: Int) -> Double { Double(t[abs(i)]) }
        var total = 0.0
        for y in -maximumRadius...maximumRadius {
            for x in -maximumRadius...maximumRadius {
                let k = filter.gaussian * tap(h, x) * tap(h, y) + filter.laplacian * (tap(h, x) * tap(d, y) + tap(d, x) * tap(h, y))
                total += k * k
            }
        }
        return total
    }

    /// The 1D taps (0…11) whose responses on the pixel grid are `e^(−2π²σ²f²)` (h) and `2π²σ²f² e^(−2π²σ²f²)` (d),
    /// so the separable filter is the fitted spectrum exactly up to the Nyquist frequency.
    static func taps(sigma: Double) -> (h: [Float], d: [Float]) {
        let steps = 512
        var h = [Float](repeating: 0, count: maximumRadius + 1), d = h
        for step in 0..<steps {
            let f = (Double(step) + 0.5) / Double(steps) - 0.5
            let u = 2 * Double.pi * Double.pi * sigma * sigma * f * f
            let response = exp(-u)
            for i in 0...maximumRadius {
                let wave = cos(2 * Double.pi * f * Double(i)) / Double(steps)
                h[i] += Float(response * wave)
                d[i] += Float(u * response * wave)
            }
        }
        return (h, d)
    }

    /// The grain alone at render `scale` over `extent`, with the photo's seed choosing its pattern: in red, as an
    /// offset to gamma-encoded values (1 = full scale); in green, the downscale's mean lift times the tone.
    static func grain(_ effects: PhotoAdjustments.Effects, extent: CGRect, scale: CGFloat) -> CIImage? {
        guard let random = CIFilter.randomGenerator().outputImage else { return nil }
        let full = filter(amount: effects.grain, size: effects.grainSize, roughness: effects.grainRoughness)
        let render = filter(full, atScale: Double(scale))
        let (h, d) = taps(sigma: render.sigma)
        // The mean lift (in the green channel) from the variance a downscale averages away, in encoded units × tone.
        let lift = scale < 1 ? downscaleLift * max(variance(full) - variance(render), 0) / (255 * 255) : 0
        func vectors(_ t: [Float]) -> [Any] {
            var result: [Any] = []
            for i in 0..<3 {
                let values: [CGFloat] = t[(i * 4)..<(i * 4 + 4)].map { CGFloat($0) }
                result.append(CIVector(values: values, count: 4))
            }
            return result
        }
        // Each seed reads a different part of the (endless) random field, anchored to the extent's corner.
        let seed = effects.grainSeed
        let dx: CGFloat = CGFloat((seed &* 7919) % 4096) + extent.minX
        let dy: CGFloat = CGFloat((seed &* 104_729) % 4096) + extent.minY
        let shifted: CIImage = random.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        guard let noise = GrainKernels.noise.apply(extent: .infinite, arguments: [shifted]) else { return nil }
        let r = CGFloat(maximumRadius)
        let padded = extent.insetBy(dx: 0, dy: -r)
        let taps: [Any] = vectors(h) + vectors(d)
        let horizontalArguments: [Any] = [noise] + taps
        guard let horizontal = GrainKernels.blurH.apply(
            extent: padded, roiCallback: { _, rect in rect.insetBy(dx: -r, dy: 0) }, arguments: horizontalArguments) else { return nil }
        let strengths: [Any] = [render.gaussian / 255, render.laplacian / 255, lift]
        let verticalArguments: [Any] = [horizontal] + taps + strengths
        return GrainKernels.blurV.apply(
            extent: extent, roiCallback: { _, rect in rect.insetBy(dx: 0, dy: -r) }, arguments: verticalArguments)
    }

    /// `image` with grain added to its luminance in gamma-encoded Display P3 (whatever the context's working space).
    static func apply(_ effects: PhotoAdjustments.Effects, to image: CIImage, extent: CGRect, scale: CGFloat) -> CIImage {
        guard effects.isActive, effects.grain > 0, !extent.isInfinite, let grain = grain(effects, extent: extent, scale: scale),
              let space = CGColorSpace(name: CGColorSpace.extendedDisplayP3),
              let encoded = image.matchedFromWorkingSpace(to: space),
              let added = GrainKernels.add.apply(extent: extent, arguments: [encoded, grain])
        else { return image }
        return added.matchedToWorkingSpace(from: space)?.cropped(to: extent) ?? image
    }
}

nonisolated enum GrainKernels {
    static let noise = color("grainNoise")
    static let blurH = load(name: "grainBlurH") { try CIKernel(functionName: $0, fromMetalLibraryData: $1) }
    static let blurV = load(name: "grainBlurV") { try CIKernel(functionName: $0, fromMetalLibraryData: $1) }
    static let add = color("grainAdd")

    private static let library: Data? = Bundle.main.url(forResource: "default", withExtension: "metallib")
        .flatMap { try? Data(contentsOf: $0) }

    private static func color(_ name: String) -> CIColorKernel {
        load(name: name) { try CIColorKernel(functionName: $0, fromMetalLibraryData: $1) }
    }

    private static func load<Kernel>(name: String, _ make: (String, Data) throws -> Kernel) -> Kernel {
        guard let library, let kernel = try? make(name, library) else {
            fatalError("The Core Image kernel \(name) is missing from the app's Metal library.")
        }
        return kernel
    }
}
