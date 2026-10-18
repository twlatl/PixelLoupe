import CoreImage
import CoreImage.CIFilterBuiltins

/// Sharpening with Radius, Detail and Masking, for RAW and other files alike.
nonisolated enum SharpenRenderer {
    /// `scale` is the render scale (1 = full resolution), so radii look the same at any zoom.
    static func apply(_ sharpen: PhotoAdjustments.Sharpen, to image: CIImage, scale: CGFloat) -> CIImage {
        guard sharpen.isActive else { return image }
        let radius = Float(sharpen.radius.clamped(to: PhotoAdjustments.Sharpen.radiusRange) * Double(max(scale, 0.25)))
        let total = sharpen.intensity * 1.5
        // Detail moves some of the strength from the broad radius to a fine one.
        let fine = total * sharpen.detail * 0.6
        let coarse = total - fine

        var sharpened = image
        let broad = CIFilter.unsharpMask()
        broad.inputImage = image
        broad.radius = radius
        broad.intensity = Float(coarse)
        sharpened = broad.outputImage ?? sharpened
        if fine > 0.01 {
            let small = CIFilter.unsharpMask()
            small.inputImage = sharpened
            small.radius = max(0.5, radius * 0.35)
            small.intensity = Float(fine)
            sharpened = small.outputImage ?? sharpened
        }
        guard sharpen.masking > 0, let mask = edgeMask(for: image, masking: sharpen.masking, scale: scale) else { return sharpened }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = sharpened
        blend.backgroundImage = image
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: image.extent) ?? sharpened
    }

    /// White where the photo has edges strong enough to sharpen, black elsewhere. `masking` raises the
    /// bar for what counts as an edge.
    static func edgeMask(for image: CIImage, masking: Double, scale: CGFloat) -> CIImage? {
        let edges = CIFilter.edges()
        edges.inputImage = image
        edges.intensity = 6
        guard let edgeImage = edges.outputImage else { return nil }
        // To one channel (the strongest), then soften so the mask follows edges rather than pixels.
        let gray = edgeImage.applyingFilter("CIMaximumComponent")
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = gray.clampedToExtent()
        blur.radius = Float(max(1, 1.5 * scale))
        guard let soft = blur.outputImage?.cropped(to: image.extent) else { return nil }
        // The blurred line of a strong edge peaks near 0.3, so scale it to about 1, then threshold:
        // nothing below `masking`'s bar, full strength a little above it.
        let gain: CGFloat = 3.2, width: CGFloat = 0.25
        let bar = CGFloat(masking) * 0.8
        let scale = gain / width
        return soft.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: scale, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: scale, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: -bar / width, y: -bar / width, z: -bar / width, w: 0),
        ]).applyingFilter("CIColorClamp").cropped(to: image.extent)
    }

    /// What Option-dragging the Masking slider shows: the mask on its own.
    static func maskPreview(for image: CIImage, masking: Double, scale: CGFloat) -> CIImage {
        edgeMask(for: image, masking: masking, scale: scale) ?? image
    }
}

/// The post-crop vignette: darkens or lightens the edges of the cropped photo.
///
/// Built from Core Image's gradient and blend filters, so it runs with the rest of the pipeline on
/// the GPU. A radial gradient in a unit circle is stretched to the photo's shape; roundness blends
/// that ellipse toward a circle (positive) or squeezes it toward the corners (negative).
nonisolated enum VignetteRenderer {
    /// Mask value 0 at the center and 1 at the edge, with the vignette's shape. Exposed for tests.
    static func mask(_ vignette: PhotoAdjustments.Vignette, extent: CGRect) -> CIImage {
        let width = extent.width, height = extent.height
        // Ellipse radii: the photo's own proportions at roundness 0, a circle at 1, and a longer
        // reach along the shorter side at -1 (the edges stay dark further in).
        let round = vignette.roundness.clamped(to: -1...1)
        let longer = max(width, height) / 2, shorter = min(width, height) / 2
        var rx = width / 2, ry = height / 2
        if round > 0 {
            rx += (longer - rx) * round
            ry += (longer - ry) * round
        } else if round < 0 {
            rx *= 1 + round * 0.25
            ry *= 1 + round * 0.25
            _ = shorter
        }
        let inner = 0.2 + 1.3 * vignette.radius.clamped(to: 0...1)
        let outer = inner + 0.05 + vignette.softness.clamped(to: 0...1) * 1.2
        let gradient = CIFilter.radialGradient()
        gradient.center = .zero
        gradient.radius0 = Float(inner)
        gradient.radius1 = Float(outer)
        gradient.color0 = CIColor(red: 0, green: 0, blue: 0)
        gradient.color1 = CIColor(red: 1, green: 1, blue: 1)
        guard let unit = gradient.outputImage else { return CIImage(color: .black).cropped(to: extent) }
        return unit
            .transformed(by: CGAffineTransform(scaleX: rx, y: ry))
            .transformed(by: CGAffineTransform(translationX: extent.midX, y: extent.midY))
            .cropped(to: extent)
    }

    static func apply(_ vignette: PhotoAdjustments.Vignette, to image: CIImage) -> CIImage {
        guard vignette.isActive else { return image }
        let extent = image.extent
        var edge = mask(vignette, extent: extent)
        let amount = abs(vignette.strength.clamped(to: -1...1)) * 0.9
        let darkens = vignette.strength > 0

        if vignette.style == .highlightPriority, vignette.highlightContrast > 0 {
            // Bright areas keep their brightness: the effect fades with the pixel's luminance.
            let protection = image
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: -0.2126 * vignette.highlightContrast, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: -0.7152 * vignette.highlightContrast, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: -0.0722 * vignette.highlightContrast, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
                ])
            // The gradient and protection are gray images; their product is the effective mask.
            edge = edge.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: protection])
        }
        // Scale the mask by the amount, as the strength of the black or white laid over the photo.
        let strength = edge.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: amount, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: amount, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let overlay = CIImage(color: darkens ? .black : .white).cropped(to: extent)
        switch vignette.style {
        case .paintOverlay, .highlightPriority:
            // Laid over the photo with the mask as opacity (highlight priority has already faded the mask).
            let blend = CIFilter.blendWithMask()
            blend.inputImage = overlay
            blend.backgroundImage = image
            blend.maskImage = strength
            return blend.outputImage?.cropped(to: extent) ?? image
        case .colorPriority:
            // Every tone is scaled (darkening) or lifted toward white (lightening) by the same fraction.
            if darkens {
                let gain = strength.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: -1, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: -1, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
                ])
                return image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: gain]).cropped(to: extent)
            }
            let blend = CIFilter.blendWithMask()
            blend.inputImage = overlay
            blend.backgroundImage = image
            blend.maskImage = strength
            return blend.outputImage?.cropped(to: extent) ?? image
        }
    }
}
