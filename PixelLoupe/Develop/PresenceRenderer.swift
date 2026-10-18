import CoreImage
import CoreImage.CIFilterBuiltins

/// Texture, Clarity and Dehaze: the Presence sliders that look at neighboring pixels.
///
/// All three use Core Image's built-in filters, so they run on the GPU with the rest of the
/// pipeline. Radii are fractions of the image's long edge, so a preview matches the full-size render.
/// Dehaze works from a small copy of the photo: the haze estimate is smooth anyway.
nonisolated enum PresenceRenderer {
    static func apply(_ presence: PhotoAdjustments.Presence, to image: CIImage, longEdge: CGFloat) -> CIImage {
        guard presence.hasSpatialEffect else { return image }
        var result = image
        if presence.dehaze != 0 { result = dehaze(result, amount: presence.dehaze) }
        if presence.clarity != 0 { result = localContrast(result, amount: presence.clarity, radius: longEdge * 0.015, strength: 0.9) }
        if presence.texture != 0 { result = localContrast(result, amount: presence.texture, radius: max(1.5, longEdge * 0.003), strength: 1.2) }
        return result.cropped(to: image.extent)
    }

    /// Positive amounts sharpen at `radius`; negative blend toward the blurred photo.
    static func localContrast(_ image: CIImage, amount: Double, radius: CGFloat, strength: Double) -> CIImage {
        if amount > 0 {
            let filter = CIFilter.unsharpMask()
            filter.inputImage = image
            filter.radius = Float(radius)
            filter.intensity = Float(amount * strength)
            return filter.outputImage ?? image
        }
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image.clampedToExtent()
        blur.radius = Float(radius * 0.5)
        guard let blurred = blur.outputImage?.cropped(to: image.extent) else { return image }
        return mix(image, blurred, amount: min(1, -amount * 0.9))
    }

    /// `a` at 0, `b` at 1.
    private static func mix(_ a: CIImage, _ b: CIImage, amount: Double) -> CIImage {
        let filter = CIFilter.dissolveTransition()
        filter.inputImage = a
        filter.targetImage = b
        filter.time = Float(amount)
        return filter.outputImage ?? a
    }

    /// Positive removes haze: estimates the veil from the darkest channel of each neighborhood (haze
    /// lifts the dark channel) and divides it out, `(I − V) / (1 − V)`. Negative lays a flat gray veil over the photo.
    static func dehaze(_ image: CIImage, amount: Double) -> CIImage {
        if amount < 0 {
            let veil = CIImage(color: CIColor(red: 0.78, green: 0.8, blue: 0.82)).cropped(to: image.extent)
            return mix(image, veil, amount: min(1, -amount * 0.5))
        }
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        let scale = min(1, 400 / longEdge)
        // Dark channel on a small copy: per-pixel minimum of R, G and B, then a local minimum.
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let minimum = CIFilter.minimumComponent()
        minimum.inputImage = small
        guard let gray = minimum.outputImage else { return image }
        let erode = CIFilter.morphologyMinimum()
        erode.inputImage = gray.clampedToExtent()
        erode.radius = Float(max(2, 400 * 0.012))
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = erode.outputImage
        blur.radius = Float(max(2, 400 * 0.02))
        guard let dark = blur.outputImage?.cropped(to: small.extent) else { return image }
        // Back to full size and scaled by the amount: V in 0…0.85.
        let veil = dark
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .clampedToExtent()
            .cropped(to: extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.85 * amount, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0.85 * amount, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0.85 * amount, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        let numerator = veil.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        // Subtract blend computes background − source: I − V.
        let denominator = veil.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
        ])
        // Divide blend computes background / source: (I − V) / (1 − V).
        return denominator.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: numerator])
            .cropped(to: extent)
    }
}
