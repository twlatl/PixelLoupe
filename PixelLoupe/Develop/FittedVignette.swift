import CoreImage
import Foundation

/// The post-crop vignette's fitted process (RAW-275): Lightroom Classic's look, measured from its exports.
///
/// Scripts/vignette-sweep.swift writes the cases (the acceptance set, and with --calibration the ones these numbers
/// came from); the PixelLoupe Fidelity plug-in exports Lightroom's renders of them. What they showed:
///
/// - One falloff v (0 inside … 1 at the edges) drives everything. It depends on the distance from the center in the
///   crop's own proportions (an ellipse; Roundness turns it into a circle or toward a rectangle). Midpoint moves where
///   v reaches 0.5 (1.0, the edge's midpoint, at 50; ×1.17 for every 25), and Feather widens it around there. Its
///   shape isn't a standard curve, so `radii` holds where it reaches each level over a Midpoint × Feather grid.
/// - Darkening is a mask m = 1 − (1 − v)^2.2 scaling linear light toward (1 − amount)^2.2; lightening blends toward
///   white by (amount · v)^2.2. Paint Overlay is exactly that.
/// - Highlight and Color Priority darken per channel of linear ProPhoto RGB, multiplying exp(φ) of the channel by
///   the same factor; φ (in the kernel) darkens the midtones more than linear light and holds the highlights.
///   Highlights holds bright channels back; Color Priority holds all three by the brightest's amount.
nonisolated enum FittedVignetteRenderer {
    static func apply(_ vignette: PhotoAdjustments.Vignette, to image: CIImage) -> CIImage {
        guard vignette.isActive else { return image }
        let extent = image.extent
        let halfWidth = extent.width / 2, halfHeight = extent.height / 2
        guard halfWidth > 0, halfHeight > 0 else { return image }
        let (axes, exponent, scale) = metric(roundness: vignette.roundness.clamped(to: -1...1), halfWidth: halfWidth, halfHeight: halfHeight)
        let radii = falloffRadii(midpoint: vignette.radius.clamped(to: 0...1), feather: vignette.softness.clamped(to: 0...1)).map(CGFloat.init)
        let quarters = stride(from: 0, to: 20, by: 4).map { i in
            CIVector(x: radii[min(i, 16)], y: radii[min(i + 1, 16)], z: radii[min(i + 2, 16)], w: radii[min(i + 3, 16)])
        }
        let style: CGFloat = switch vignette.style {
        case .highlightPriority: 0
        case .colorPriority: 1
        case .paintOverlay: 2
        }
        // PixelLoupe's positive strength darkens (Lightroom's negative amounts).
        let amount = abs(vignette.strength.clamped(to: -1...1))
        let arguments: [Any] = [
            linear(image),
            CIVector(x: extent.midX, y: extent.midY, z: axes.width, w: axes.height),
            CIVector(x: exponent, y: scale, z: 0, w: 0),
        ] + quarters + [
            CIVector(x: amount, y: vignette.strength > 0 ? 1 : 0, z: style, w: vignette.highlightContrast.clamped(to: 0...1)),
        ]
        guard let output = kernel.apply(extent: extent, arguments: arguments) else { return image }
        return output.matchedToWorkingSpace(from: linearP3) ?? output
    }

    // MARK: The falloff

    /// The falloff's levels (the kernel has the same list).
    static let levels: [Float] = [0.01, 0.03, 0.06, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 0.94, 0.97, 0.99]

    /// Radius at each level, by Midpoint (0, 25 … 100) then Feather (0, 25 … 100), in the crop's proportions
    /// (1 at the middle of an edge, √2 at a corner). From Paint Overlay at −100 (levels to 0.5) and +100 (above),
    /// on flat gray; levels past the corner are extrapolated.
    static let radii: [[Float]] = [
        [0.6866, 0.7003, 0.7025, 0.7054, 0.7091, 0.7128, 0.7201, 0.7234, 0.7267, 0.7297, 0.7329, 0.7361, 0.7377, 0.7393, 0.7450, 0.7534, 0.7589],
        [0.4618, 0.5192, 0.5607, 0.5940, 0.6229, 0.6442, 0.6774, 0.7025, 0.7239, 0.7463, 0.7723, 0.8066, 0.8302, 0.8615, 0.8992, 0.9471, 1.0142],
        [0.2666, 0.3434, 0.4054, 0.4600, 0.5108, 0.5521, 0.6189, 0.6738, 0.7228, 0.7761, 0.8346, 0.9087, 0.9559, 1.0161, 1.0815, 1.1560, 1.2444],
        [0.1487, 0.2225, 0.2888, 0.3523, 0.4148, 0.4678, 0.5603, 0.6426, 0.7216, 0.8082, 0.8997, 1.0071, 1.0709, 1.1459, 1.2192, 1.2905, 1.3557],
        [0.0832, 0.1449, 0.2072, 0.2712, 0.3382, 0.3982, 0.5078, 0.6136, 0.7203, 0.8404, 0.9595, 1.0903, 1.1623, 1.2397, 1.3056, 1.3587, 1.3950],
        [0.8148, 0.8226, 0.8272, 0.8333, 0.8402, 0.8417, 0.8446, 0.8476, 0.8505, 0.8531, 0.8561, 0.8591, 0.8625, 0.8690, 0.8742, 0.8781, 0.8875],
        [0.5657, 0.6305, 0.6768, 0.7134, 0.7445, 0.7675, 0.8022, 0.8282, 0.8499, 0.8731, 0.8987, 0.9328, 0.9551, 0.9848, 1.0194, 1.0624, 1.1208],
        [0.3333, 0.4266, 0.5000, 0.5638, 0.6220, 0.6678, 0.7403, 0.7984, 0.8489, 0.9025, 0.9591, 1.0281, 1.0706, 1.1228, 1.1769, 1.2354, 1.2999],
        [0.1878, 0.2792, 0.3610, 0.4370, 0.5105, 0.5725, 0.6765, 0.7658, 0.8477, 0.9345, 1.0199, 1.1150, 1.1678, 1.2271, 1.2823, 1.3326, 1.3765],
        [0.1046, 0.1828, 0.2601, 0.3385, 0.4205, 0.4916, 0.6186, 0.7346, 0.8465, 0.9646, 1.0736, 1.1840, 1.2402, 1.2967, 1.3426, 1.3782, 1.4019],
        [0.9639, 0.9748, 0.9809, 0.9827, 0.9849, 0.9871, 0.9915, 0.9959, 1.0003, 1.0048, 1.0090, 1.0132, 1.0153, 1.0174, 1.0191, 1.0243, 1.0355],
        [0.7092, 0.7813, 0.8289, 0.8670, 0.8988, 0.9211, 0.9547, 0.9794, 0.9994, 1.0201, 1.0428, 1.0732, 1.0923, 1.1178, 1.1459, 1.1793, 1.2233],
        [0.4344, 0.5478, 0.6343, 0.7071, 0.7708, 0.8194, 0.8941, 0.9511, 0.9985, 1.0464, 1.0956, 1.1526, 1.1860, 1.2246, 1.2639, 1.3043, 1.3463],
        [0.2478, 0.3658, 0.4669, 0.5602, 0.6469, 0.7170, 0.8288, 0.9192, 0.9974, 1.0744, 1.1458, 1.2186, 1.2575, 1.2987, 1.3346, 1.3668, 1.3929],
        [0.1392, 0.2414, 0.3407, 0.4407, 0.5404, 0.6248, 0.7668, 0.8884, 0.9962, 1.1003, 1.1884, 1.2686, 1.3071, 1.3434, 1.3725, 1.3933, 1.4071],
        [1.1428, 1.1496, 1.1599, 1.1610, 1.1623, 1.1636, 1.1661, 1.1686, 1.1712, 1.1732, 1.1758, 1.1784, 1.1797, 1.1856, 1.1916, 1.1960, 1.1990],
        [0.9218, 0.9900, 1.0338, 1.0670, 1.0926, 1.1119, 1.1383, 1.1568, 1.1717, 1.1876, 1.2037, 1.2237, 1.2372, 1.2537, 1.2715, 1.2924, 1.3178],
        [0.6104, 0.7475, 0.8443, 0.9192, 0.9812, 1.0257, 1.0892, 1.1354, 1.1711, 1.2057, 1.2395, 1.2750, 1.2953, 1.3180, 1.3390, 1.3612, 1.3823],
        [0.3609, 0.5211, 0.6513, 0.7612, 0.8575, 0.9292, 1.0338, 1.1107, 1.1703, 1.2244, 1.2707, 1.3146, 1.3356, 1.3583, 1.3764, 1.3921, 1.4026],
        [0.2047, 0.3510, 0.4887, 0.6184, 0.7390, 0.8334, 0.9775, 1.0846, 1.1695, 1.2424, 1.2966, 1.3416, 1.3625, 1.3806, 1.3943, 1.4047, 1.4116],
        [1.3602, 1.3607, 1.3612, 1.3620, 1.3630, 1.3640, 1.3660, 1.3680, 1.3700, 1.3718, 1.3739, 1.3759, 1.3769, 1.3780, 1.3788, 1.3794, 1.3799],
        [1.2858, 1.3122, 1.3262, 1.3380, 1.3443, 1.3493, 1.3592, 1.3637, 1.3677, 1.3715, 1.3754, 1.3793, 1.3837, 1.3893, 1.3938, 1.3972, 1.3994],
        [1.0952, 1.1985, 1.2517, 1.2858, 1.3098, 1.3251, 1.3445, 1.3583, 1.3668, 1.3749, 1.3826, 1.3904, 1.3943, 1.3982, 1.4013, 1.4037, 1.4053],
        [0.7915, 1.0076, 1.1301, 1.2066, 1.2587, 1.2901, 1.3278, 1.3507, 1.3665, 1.3793, 1.3882, 1.3970, 1.4013, 1.4057, 1.4092, 1.4118, 1.4136],
        [0.4967, 0.7763, 0.9701, 1.1024, 1.1927, 1.2469, 1.3090, 1.3436, 1.3662, 1.3824, 1.3927, 1.4030, 1.4082, 1.4134, 1.4175, 1.4206, 1.4226],
    ]

    /// The radii for any Midpoint and Feather, 0…1: interpolated between the grid's, level by level.
    static func falloffRadii(midpoint: Double, feather: Double) -> [Float] {
        let m = midpoint * 4, f = feather * 4
        let m0 = min(Int(m), 3), f0 = min(Int(f), 3)
        let mt = Float(m - Double(m0)), ft = Float(f - Double(f0))
        func row(_ mi: Int, _ fi: Int) -> [Float] { radii[mi * 5 + fi] }
        return (0..<levels.count).map { i in
            let low = row(m0, f0)[i] * (1 - ft) + row(m0, f0 + 1)[i] * ft
            let high = row(m0 + 1, f0)[i] * (1 - ft) + row(m0 + 1, f0 + 1)[i] * ft
            return low * (1 - mt) + high * mt
        }
    }

    // MARK: The shape

    /// The distance the falloff is measured in: the crop's proportions at Roundness 0; positive Roundness turns the
    /// ellipse into a circle through the same diagonal point; negative squares it toward the edges (a superellipse,
    /// approximate: fitted on three cases).
    static func metric(roundness: Double, halfWidth: CGFloat, halfHeight: CGFloat) -> (axes: CGSize, exponent: CGFloat, scale: CGFloat) {
        if roundness >= 0 {
            let circle = ((halfWidth * halfWidth + halfHeight * halfHeight) / 2).squareRoot()
            var a = pow(halfWidth, 1 - roundness) * pow(circle, roundness)
            var b = pow(halfHeight, 1 - roundness) * pow(circle, roundness)
            // Keep the corner at √2.
            let s = ((halfWidth * halfWidth / (a * a) + halfHeight * halfHeight / (b * b)) / 2).squareRoot()
            a /= s; b /= s
            return (CGSize(width: a, height: b), 2, 1)
        }
        let squareness = -roundness
        return (CGSize(width: halfWidth, height: halfHeight), 2 + 26 * pow(squareness, 4.25), 1 - 0.24 * pow(squareness, 2.45))
    }

    // MARK: Core Image

    private static let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    /// The image as linear Display P3, which the kernel works in (a no-op in the app's linear working space).
    private static func linear(_ image: CIImage) -> CIImage {
        image.matchedFromWorkingSpace(to: linearP3) ?? image
    }

    private static let library: Data? = Bundle.main.url(forResource: "default", withExtension: "metallib")
        .flatMap { try? Data(contentsOf: $0) }

    private static let kernel: CIColorKernel = {
        guard let library, let kernel = try? CIColorKernel(functionName: "vignetteFitted", fromMetalLibraryData: library) else {
            fatalError("The Core Image kernel vignetteFitted is missing from the app's Metal library.")
        }
        return kernel
    }()
}
