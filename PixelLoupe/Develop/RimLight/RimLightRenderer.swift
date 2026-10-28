import CoreImage
import Foundation

/// Rim Light (RAW-203), from Pixegen's Filter ▸ Rim Light, worked out the way games light flat sprites: the subject's
/// outline (its matte pulled onto the photo's edges, ``SubjectMatteStore/refinedMatte(for:adjustments:waiting:)``) is
/// rounded into a surface that faces sideways at the edge and turns to face the camera a light's Width in, the photo's
/// fine detail is pressed into it as bumps, and each light, from a little behind the subject, brightens what faces it.
/// So the rim starts right at the subject's edge and fades inwards, as a light from behind reaches only what turns away
/// from the camera; strands and edges brighter than their surroundings catch more.
///
/// Pixegen's tuning is for sRGB-encoded values, so the photo is lit in those and turned back to the pipeline's linear
/// light afterwards. Sizes are shares of the photo's long edge, so every render size looks the same.
nonisolated enum RimLightRenderer {
    /// The rim's width as a share of the image's longer side, from Width 0 to 1.
    static func widthShare(_ width: Double) -> Double { 0.002 + width * 0.03 }
    /// How bright a light at Strength 1 is, over the surface's own color.
    static let fullStrength: Double = 10
    /// How much of the rims' light glows around the subject at Glow 1.
    static let fullGlow: Double = 4

    /// `linear` (the pipeline's photo, on the whole frame) with its rim lights added, or as it is without a subject.
    /// `subject` is the refined matte, found on the same frame and stretched over it.
    static func apply(_ settings: PhotoAdjustments.RimLight, to linear: CIImage, subject: CIImage?) -> CIImage {
        let extent = linear.extent
        guard settings.isActive, let subject, !extent.isEmpty, !extent.isInfinite else { return linear }
        let image = linear.applyingFilter("CILinearToSRGBToneCurve")
        let side = max(extent.width, extent.height)
        // Where the light lands: the matte as refined, its soft grays kept, so thin strands of hair catch their share.
        let coverage = placed(subject, in: extent)
        // The outline the form is rounded from: those grays pushed apart, so its edge is where the subject's is.
        let outline = coverage.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.6, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1.6, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1.6, w: 0), "inputBiasVector": CIVector(x: -0.3, y: -0.3, z: -0.3, w: 0)])
            .applyingFilter("CIColorClamp")
        let gray = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0), "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        func blurred(_ image: CIImage, _ sigma: CGFloat) -> CIImage {
            image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        }
        let fine = blurred(gray, 1), coarse = blurred(gray, max(2, side / 400))
        func scaled(_ image: CIImage, _ gain: Double, bias: Double = 0) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0), "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)])
        }
        // The backdrop behind the subject, worked out from around it: the photo outside the outline spread in under it,
        // each place an average of the backdrop near it. How far a pixel differs from that picks out loose strands.
        let open = scaled(outline, -1, bias: 1)
        let spread = side * 0.01
        let weighted = blurred(image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: open]), spread)
        let behind = scaled(blurred(open, spread), 1, bias: 0.001)
            .applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: weighted])
        let backdrop = image.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: behind])
        // How busy that backdrop is there, its colors' spread around their average: on rocks or a crowd everything
        // differs from the average, so a strand has to stand out further than that to count.
        let squares = image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: image])
        let meanSquares = scaled(blurred(open, spread), 1, bias: 0.001).applyingFilter("CIDivideBlendMode", parameters: [
            kCIInputBackgroundImageKey: blurred(squares.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: open]), spread)])
        let busy = meanSquares.applyingFilter("CIDifferenceBlendMode", parameters: [
            kCIInputBackgroundImageKey: behind.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: behind])])
        let near = blurred(outline, side * 0.015)
        // Each light on its own, reaching in as far as its Width, and added up.
        var rims: CIImage?
        for light in settings.lights.prefix(PhotoAdjustments.RimLight.maximumLights) where light.strength > 0 {
            let width = side * widthShare(light.width)
            // The outline blurred far enough to tell, at each pixel, how far in from the edge it is, to twice Width.
            let reach = max(1, width / 1.5)
            guard let rim = RimLightKernel.light(image, coverage: coverage, outline: blurred(outline, reach), fine: fine, coarse: coarse,
                                                 backdrop: backdrop, busy: busy, near: near, width: width, reach: reach, side: side,
                                                 light: light) else { return linear }
            rims = rims.map { rim.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? rim
        }
        guard var light = rims else { return linear }
        if settings.glow > 0 {
            // Glow: the rims' light in the air behind the subject, each light's on its own side in its own color, a
            // halo and a wider haze. It wraps a little way in across the subject's edge, as light from behind does,
            // so the subject sits in it rather than being cut out against it; further in, the subject keeps its rims.
            let amount = settings.glow * fullGlow
            let haze = scaled(blurred(light, side * 0.012), amount * 0.6)
                .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: scaled(blurred(light, side * 0.035), amount)])
            let around = scaled(blurred(outline, side * 0.008), -2, bias: 2).applyingFilter("CIColorClamp")
            let glow = haze.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty().cropped(to: extent), kCIInputMaskImageKey: around])
            light = light.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: glow])
        }
        guard let lit = RimLightKernel.combined(image, light: light.cropped(to: extent)) else { return linear }
        return lit.applyingFilter("CISRGBToneCurveToLinear").cropped(to: extent)
    }

    /// The subject matte stretched over the frame (it was found on the same frame, smaller).
    static func placed(_ matte: CIImage, in extent: CGRect) -> CIImage {
        let size = matte.extent
        guard size.width > 0, size.height > 0 else { return CIImage(color: .black).cropped(to: extent) }
        return matte
            .transformed(by: CGAffineTransform(translationX: -size.minX, y: -size.minY))
            .transformed(by: CGAffineTransform(scaleX: extent.width / size.width, y: extent.height / size.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }
}
