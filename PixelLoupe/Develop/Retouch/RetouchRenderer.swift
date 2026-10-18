import CoreImage
import CoreImage.CIFilterBuiltins

/// Spot removal and red-eye correction, drawn on the photo as decoded.
///
/// Both work inside a box around each spot, so a photo with a few spots costs a few small renders
/// whatever its size.
nonisolated enum RetouchRenderer {
    static func apply(spots: [PhotoAdjustments.Spot], redEyes: [PhotoAdjustments.RedEyeSpot], to image: CIImage) -> CIImage {
        guard !spots.isEmpty || !redEyes.isEmpty else { return image }
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return image }
        var result = image
        for spot in spots { result = apply(spot, to: result) }
        for eye in redEyes { result = apply(eye, to: result) }
        return result.cropped(to: extent)
    }

    private static func pixelPoint(_ p: PhotoAdjustments.UnitPoint, in extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + CGFloat(p.x) * extent.width, y: extent.minY + CGFloat(p.y) * extent.height)
    }

    /// White inside a circle of `radius` (full to `1 - feather` of it, then fading), black outside.
    static func disc(center: CGPoint, radius: CGFloat, feather: Double, in box: CGRect) -> CIImage {
        let filter = CIFilter.radialGradient()
        filter.center = center
        filter.radius0 = Float(radius * CGFloat(1 - feather.clamped(to: 0...0.98)))
        filter.radius1 = Float(radius)
        filter.color0 = CIColor(red: 1, green: 1, blue: 1)
        filter.color1 = CIColor(red: 0, green: 0, blue: 0)
        return (filter.outputImage ?? CIImage(color: .black)).cropped(to: box)
    }

    // MARK: Spots

    static func apply(_ spot: PhotoAdjustments.Spot, to image: CIImage) -> CIImage {
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        let radius = CGFloat(spot.radius) * longEdge
        guard radius >= 1, spot.opacity > 0 else { return image }
        let center = pixelPoint(spot.center, in: extent), source = pixelPoint(spot.source, in: extent)
        // The box the spot changes, with room for the heal's blur.
        let margin = radius * 1.6
        let box = CGRect(x: center.x - margin, y: center.y - margin, width: margin * 2, height: margin * 2).intersection(extent)
        guard !box.isEmpty else { return image }

        // The source moved onto the spot; beyond the photo's edge it repeats the edge pixels.
        let moved = image.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: center.x - source.x, y: center.y - source.y))
        var patch = moved.cropped(to: box)
        if spot.kind == .heal {
            // Keep the source's texture but take the colors and brightness around the spot: scale it by
            // the ratio of the surroundings' low frequencies to the source's.
            let blurRadius = Float(max(1, radius * 0.7))
            let low = { (input: CIImage) -> CIImage in
                let blur = CIFilter.gaussianBlur()
                blur.inputImage = input.clampedToExtent()
                blur.radius = blurRadius
                return (blur.outputImage ?? input).cropped(to: box)
            }
            let destinationLow = low(image), sourceLow = low(patch)
            let lifted = sourceLow.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0.02, y: 0.02, z: 0.02, w: 0),
            ])
            // Divide blend computes background / source.
            let ratio = lifted.applyingFilter("CIDivideBlendMode", parameters: [
                kCIInputBackgroundImageKey: destinationLow.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: 0.02, y: 0.02, z: 0.02, w: 0),
                ]),
            ]).cropped(to: box)
            patch = patch.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: ratio]).cropped(to: box)
        }

        var mask = disc(center: center, radius: radius, feather: spot.feather, in: box)
        if spot.opacity < 1 {
            let opacity = CGFloat(spot.opacity.clamped(to: 0...1))
            mask = mask.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: opacity, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: opacity, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: opacity, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = patch
        blend.backgroundImage = image.cropped(to: box)
        blend.maskImage = mask
        guard let blended = blend.outputImage else { return image }
        return blended.cropped(to: box).composited(over: image)
    }

    // MARK: Red eye

    static func apply(_ eye: PhotoAdjustments.RedEyeSpot, to image: CIImage) -> CIImage {
        let extent = image.extent
        let radius = CGFloat(eye.radius) * max(extent.width, extent.height)
        guard radius >= 1, eye.strength > 0 else { return image }
        let center = pixelPoint(eye.center, in: extent)
        let box = CGRect(x: center.x - radius * 1.5, y: center.y - radius * 1.5, width: radius * 3, height: radius * 3).intersection(extent)
        guard !box.isEmpty else { return image }
        // Red is pulled down to the other channels' average, and the pupil darkened.
        let dark = CGFloat(1 - 0.7 * eye.darken.clamped(to: 0...1))
        let corrected = image.cropped(to: box).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0.5 * dark, z: 0.5 * dark, w: 0),
            "inputGVector": CIVector(x: 0, y: dark, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: dark, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        var mask = disc(center: center, radius: radius, feather: 0.4, in: box)
        let strength = CGFloat(eye.strength.clamped(to: 0...1))
        if strength < 1 {
            mask = mask.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: strength, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: strength, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = corrected
        blend.backgroundImage = image.cropped(to: box)
        blend.maskImage = mask
        return (blend.outputImage ?? corrected).cropped(to: box).composited(over: image)
    }

    // MARK: Finding an eye

    /// The center and radius (fractions of the long edge, bottom-left origin) of the reddest blob near
    /// `point`, for clicking an eye; `nil` when nothing there is red.
    static func findRedEye(near point: PhotoAdjustments.UnitPoint, in image: CIImage, context: CIContext, searchRadius: Double = 0.04) -> (center: PhotoAdjustments.UnitPoint, radius: Double)? {
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        let reach = CGFloat(searchRadius) * longEdge
        let center = pixelPoint(point, in: extent)
        let box = CGRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2).intersection(extent).integral
        guard box.width >= 3, box.height >= 3, box.width <= 1500, box.height <= 1500 else { return nil }
        var pixels = [Float](repeating: 0, count: Int(box.width * box.height) * 4)
        context.render(image, toBitmap: &pixels, rowBytes: Int(box.width) * 16, bounds: box, format: .RGBAf, colorSpace: nil)
        var weight = 0.0, sumX = 0.0, sumY = 0.0, count = 0.0
        let width = Int(box.width), height = Int(box.height)
        for row in 0..<height {
            for column in 0..<width {
                let i = (row * width + column) * 4
                let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
                // Redness: how far red stands above the others.
                let red = r - max(g, b)
                guard red > 0.15, r > 0.25 else { continue }
                weight += red
                sumX += red * (Double(box.minX) + Double(column) + 0.5)
                // Bitmap rows run top to bottom.
                sumY += red * (Double(box.maxY) - Double(row) - 0.5)
                count += 1
            }
        }
        guard weight > 0, count >= 4 else { return nil }
        let found = CGPoint(x: sumX / weight, y: sumY / weight)
        let radius = max(2, (count / .pi).squareRoot()) / Double(longEdge)
        return (.init(x: (Double(found.x) - Double(extent.minX)) / Double(extent.width), y: (Double(found.y) - Double(extent.minY)) / Double(extent.height)), radius)
    }
}
