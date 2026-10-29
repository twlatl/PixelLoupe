import CoreImage
import Foundation

/// Portrait Lighting (RAW-211) on the pipeline's photo, after masks and before Rim Light, on the whole frame. Stage puts
/// the people (``SubjectMatteStore``'s refined person matte) on black, Intensity taking the background from the photo
/// to black; Stage Mono does the same with the people in black and white whatever the Intensity. Studio and Contour
/// light the faces (RAW-215).
///
/// Worked in sRGB-encoded values, as Rim Light is, and turned back to the pipeline's linear light afterwards.
nonisolated enum PortraitLightingRenderer {
    /// `linear` with the effect, or as it is without people. `people` is the refined person matte, found on the same
    /// frame and stretched over it.
    static func apply(_ settings: PhotoAdjustments.PortraitLighting, to linear: CIImage, people: CIImage?) -> CIImage {
        let extent = linear.extent
        guard settings.isActive, let people, !extent.isEmpty, !extent.isInfinite else { return linear }
        switch settings.effect {
        case .stage, .stageMono:
            return stage(linear, people: RimLightRenderer.placed(people, in: extent), intensity: settings.intensity,
                         mono: settings.effect == .stageMono)
        case .studio, .contour:
            return linear
        }
    }

    private static func stage(_ linear: CIImage, people: CIImage, intensity: Double, mono: Bool) -> CIImage {
        let extent = linear.extent
        let image = linear.applyingFilter("CILinearToSRGBToneCurve")
        let keep = 1 - min(max(intensity, 0), 1)
        let background = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: keep, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: keep, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: keep, w: 0)])
        let subject = mono ? image.applyingFilter("CIPhotoEffectNoir") : image
        return subject
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: people])
            .applyingFilter("CISRGBToneCurveToLinear")
            .cropped(to: extent)
    }
}
