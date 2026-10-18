import CoreImage
import Foundation

/// Applies Lens Corrections to a photo as decoded (before orientation, crop and other edits):
/// vignetting first (on the uncorrected image, where the lens put it), then distortion and lateral
/// chromatic aberration in one resampling pass, then defringe.
nonisolated enum LensCorrector {
    static func apply(_ lens: PhotoAdjustments.LensCorrections, to image: CIImage, builtInApplied: Bool = false) -> CIImage {
        guard !lens.isDefault else { return image }
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return image }
        let center = [Float(extent.midX), Float(extent.midY)]
        let halfDiagonal = hypot(extent.width, extent.height) / 2
        let profile = lens.appliesProfile && !builtInApplied ? lens.profile : nil
        var result = image

        // Vignetting.
        let profileVignetting = profile.flatMap { $0.vignetting.count == 3 && lens.vignettingAmount > 0 ? $0 : nil }
        if profileVignetting != nil || lens.manualVignetting != 0 {
            let k = profileVignetting?.vignetting ?? [0, 0, 0]
            let unit = profileVignetting.map { $0.vignettingUnit * halfDiagonal } ?? 0
            result = LensKernel.apply(.vignette, to: result, parameters: center + [
                Float(unit), Float(k[0]), Float(k[1]), Float(k[2]), Float(lens.vignettingAmount),
                Float(halfDiagonal), Float(lens.manualVignetting * 1.5), Float(0.75 * lens.vignettingMidpoint),
            ]) ?? result
        }

        // Distortion and chromatic aberration.
        let geometry = Geometry(lens: lens, profile: profile, halfDiagonal: halfDiagonal)
        if !geometry.isIdentity {
            let scale = lens.constrainCrop ? geometry.constrainingScale(in: extent) : 1
            let origin = CGPoint(x: extent.midX, y: extent.midY)
            let roi = LensKernel.RegionOfInterest { rect in geometry.sourceRect(for: rect, center: origin, scale: scale, within: extent) }
            let d = geometry.distortion, red = geometry.red, blue = geometry.blue
            result = LensKernel.apply(.geometry, to: result, parameters: center + [
                Float(geometry.unit), Float(halfDiagonal), Float(scale), Float(geometry.manualK),
                Float(d[0]), Float(d[1]), Float(d[2]), Float(d[3]), Float(d[4]),
                Float(red[0]), Float(red[1]), Float(red[2]), Float(blue[0]), Float(blue[1]), Float(blue[2]),
            ], roi: roi) ?? result
        }

        // Defringe.
        if lens.purpleAmount > 0 || lens.greenAmount > 0 {
            // How far to look for the edge a fringe lies along: fringes are a few pixels wide in a
            // full-size photo (about 6000 pixels across), narrower in a reduced render.
            let radius = min(4, max(2, 4 * extent.width / 6000))
            let roi = LensKernel.RegionOfInterest { $0.insetBy(dx: -radius - 1, dy: -radius - 1) }
            result = LensKernel.apply(.defringe, to: result, parameters: [
                Float(radius),
                Float(lens.purpleAmount), Float(lens.purpleHue.lower), Float(lens.purpleHue.upper),
                Float(lens.greenAmount), Float(lens.greenHue.lower), Float(lens.greenHue.upper),
            ], roi: roi) ?? result
        }
        return result
    }

    /// The geometric part of the corrections, mirrored on the CPU (for Constrain Crop and for
    /// telling Core Image which source pixels a region needs).
    struct Geometry: Sendable {
        /// Pixels per unit radius of the profile's distortion model.
        var unit: Double
        var halfDiagonal: Double
        var manualK: Double
        /// (a, b, c, d, e) of rd = ru · (e·ru⁴ + a·ru³ + b·ru² + c·ru + d).
        var distortion: [Double]
        /// (b, c, v) of rd = ru · (b·ru² + c·ru + v).
        var red: [Double]
        var blue: [Double]

        init(lens: PhotoAdjustments.LensCorrections, profile: PhotoAdjustments.LensProfile?, halfDiagonal: Double) {
            self.halfDiagonal = halfDiagonal
            unit = max(1, (profile?.distortionUnit ?? 1) * halfDiagonal)
            // Positive manual distortion corrects barrel distortion: corrected pixels come from
            // closer to the center, so the edges are pulled out (and in at the corners).
            manualK = -0.25 * lens.manualDistortion
            if let profile, profile.distortion.count == 5, lens.distortionAmount != 0 {
                let amount = lens.distortionAmount
                let c = profile.distortion
                distortion = [c[0] * amount, c[1] * amount, c[2] * amount, 1 + (c[3] - 1) * amount, c[4] * amount]
            } else {
                distortion = [0, 0, 0, 1, 0]
            }
            if lens.removeChromaticAberration, let profile, profile.tcaRed.count == 3, profile.tcaBlue.count == 3 {
                red = profile.tcaRed
                blue = profile.tcaBlue
            } else if lens.removeChromaticAberration {
                red = [0, 0, lens.chromaticAberration.red]
                blue = [0, 0, lens.chromaticAberration.blue]
            } else {
                red = [0, 0, 1]
                blue = [0, 0, 1]
            }
        }

        var isIdentity: Bool {
            manualK == 0 && distortion == [0, 0, 0, 1, 0] && red == [0, 0, 1] && blue == [0, 0, 1]
        }

        /// Where the corrected pixel at `offset` from the center (in pixels) comes from, for green,
        /// red and blue, as offsets from the center.
        func sourceOffsets(for offset: CGPoint, scale: Double) -> [CGPoint] {
            var p = (x: Double(offset.x) * scale, y: Double(offset.y) * scale)
            let rn = hypot(p.x, p.y) / halfDiagonal
            let m = 1 + manualK * rn * rn
            p = (p.x * m / unit, p.y * m / unit)
            let r = hypot(p.x, p.y)
            let d = distortion
            let f = (((d[4] * r + d[0]) * r + d[1]) * r + d[2]) * r + d[3]
            let g = (x: p.x * f, y: p.y * f)
            let rg = hypot(g.x, g.y)
            let fr = (red[0] * rg + red[1]) * rg + red[2]
            let fb = (blue[0] * rg + blue[1]) * rg + blue[2]
            return [1, fr, fb].map { CGPoint(x: g.x * $0 * unit, y: g.y * $0 * unit) }
        }

        /// The source region the corrected `rect` needs: the bounds of where its edges come from
        /// (radial corrections map edges to edges), plus a margin for sampling.
        func sourceRect(for rect: CGRect, center: CGPoint, scale: Double, within source: CGRect) -> CGRect {
            // Nothing outside the photo is drawn. (Never a null region: Core Image takes that as
            // "everything", which smeared other images drawn in the same render. And never an empty
            // one: the processor then skips the region and leaves whatever was in memory, so it
            // gets one pixel to draw nothing from.)
            let single = CGRect(x: source.minX, y: source.minY, width: 1, height: 1)
            let rect = rect.intersection(source)
            guard !rect.isNull, !rect.isEmpty else { return single }
            var bounds = CGRect.null
            let steps = 12
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                for point in [
                    CGPoint(x: rect.minX + rect.width * t, y: rect.minY), CGPoint(x: rect.minX + rect.width * t, y: rect.maxY),
                    CGPoint(x: rect.minX, y: rect.minY + rect.height * t), CGPoint(x: rect.maxX, y: rect.minY + rect.height * t),
                ] {
                    for offset in sourceOffsets(for: CGPoint(x: point.x - center.x, y: point.y - center.y), scale: scale) {
                        bounds = bounds.union(CGRect(x: center.x + offset.x, y: center.y + offset.y, width: 0, height: 0))
                    }
                }
            }
            // A rect containing the center maps around it, so its edges bound it too; still, keep
            // the center's neighborhood when it's inside.
            if rect.contains(center) { bounds = bounds.union(CGRect(origin: center, size: .zero)) }
            let needed = bounds.insetBy(dx: -4, dy: -4).intersection(source.insetBy(dx: -4, dy: -4))
            return needed.isNull || needed.isEmpty ? single : needed
        }

        /// The largest zoom-out factor (≤ 1) for which every edge pixel of the corrected photo
        /// comes from inside the original, so no empty space shows.
        func constrainingScale(in extent: CGRect) -> Double {
            // Pixel centers along the edges must come from inside the original's outer pixel centers
            // (with a little room for the GPU's precision).
            let halfWidth = Double(extent.width) / 2 - 0.5, halfHeight = Double(extent.height) / 2 - 0.5
            func covered(_ scale: Double) -> Bool {
                let steps = 32
                for i in 0...steps {
                    let t = Double(i) / Double(steps) * 2 - 1
                    for edge in [
                        CGPoint(x: t * halfWidth, y: halfHeight), CGPoint(x: t * halfWidth, y: -halfHeight),
                        CGPoint(x: halfWidth, y: t * halfHeight), CGPoint(x: -halfWidth, y: t * halfHeight),
                    ] {
                        for source in sourceOffsets(for: edge, scale: scale)
                        where abs(source.x) > halfWidth - 0.1 || abs(source.y) > halfHeight - 0.1 {
                            return false
                        }
                    }
                }
                return true
            }
            if covered(1) { return 1 }
            var low = 0.5, high = 1.0
            for _ in 0..<24 {
                let middle = (low + high) / 2
                if covered(middle) { low = middle } else { high = middle }
            }
            return low
        }
    }
}
