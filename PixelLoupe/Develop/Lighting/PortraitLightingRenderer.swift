import CoreImage
import Foundation

/// Portrait Lighting (RAW-211) on the pipeline's photo, after masks and before Rim Light, on the whole frame. Stage puts
/// the people (``SubjectMatteStore``'s refined person matte) on black, Intensity taking the background from the photo
/// to black; Stage Mono does the same with the people in black and white whatever the Intensity. Studio and Contour
/// (RAW-215) light each face (``FaceStore``) with soft gradients shaped to it, tilted with it and moved toward the
/// way it's turned, soft-light blended onto the people only:
/// - Studio: one soft key light from above the camera.
/// - Contour: short lighting, a key on the side the face is turned toward (the far side from the camera) and a shadow on
///   the broad side; a face looking at the camera is lit from the camera's left.
///
/// Worked in sRGB-encoded values, as Rim Light is, and turned back to the pipeline's linear light afterwards.
nonisolated enum PortraitLightingRenderer {
    /// How far a face must be turned (``FaceStore/Face/turn``) for Contour to light its far side, about 10°.
    static let contourTurn = 0.08

    /// `linear` with the effect, or as it is without people. `people` is the refined person matte, found on the same
    /// frame and stretched over it; `faces` are on that frame too.
    static func apply(_ settings: PhotoAdjustments.PortraitLighting, to linear: CIImage, people: CIImage?,
                      faces: [FaceStore.Face] = []) -> CIImage {
        let extent = linear.extent
        guard settings.isActive, let people, !extent.isEmpty, !extent.isInfinite else { return linear }
        switch settings.effect {
        case .stage, .stageMono:
            return stage(linear, people: RimLightRenderer.placed(people, in: extent), intensity: settings.intensity,
                         mono: settings.effect == .stageMono)
        case .studio, .contour:
            return light(linear, people: RimLightRenderer.placed(people, in: extent), faces: faces,
                         intensity: settings.intensity, contour: settings.effect == .contour)
        }
    }

    /// One soft light for a face: an ellipse `radii` across (in face widths and heights) at `offset` from its middle
    /// (the same units, x toward the frame's right before the face's tilt), 1 in the middle fading to 0 at its edge.
    private struct Lamp {
        var offset: CGPoint
        var radii: CGSize
        var strength: Double
    }

    private static func lamps(for face: FaceStore.Face, contour: Bool) -> (key: [Lamp], shadow: [Lamp]) {
        guard contour else {
            // Studio: from above the camera, following the face a little as it turns.
            return ([Lamp(offset: CGPoint(x: face.turn * 0.15, y: 0.2), radii: CGSize(width: 1.0, height: 1.25), strength: 0.8)], [])
        }
        let side: CGFloat = abs(face.turn) > contourTurn ? (face.turn > 0 ? 1 : -1) : -1
        return ([Lamp(offset: CGPoint(x: side * 0.35, y: 0.1), radii: CGSize(width: 0.75, height: 1.1), strength: 0.75)],
                [Lamp(offset: CGPoint(x: -side * 0.55, y: -0.05), radii: CGSize(width: 0.65, height: 1.2), strength: 0.7)])
    }

    /// A light's gradient over `extent`: white in the middle of its ellipse, black at and beyond its edge.
    private static func gradient(_ lamp: Lamp, face: FaceStore.Face, in extent: CGRect) -> CIImage {
        let width = face.bounds.width * extent.width, height = face.bounds.height * extent.height
        let center = CGPoint(x: extent.minX + face.center.x * extent.width, y: extent.minY + face.center.y * extent.height)
        let unit = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": 0, "inputRadius1": 1,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0, green: 0, blue: 0)])?.outputImage
        guard let unit else { return CIImage(color: .black).cropped(to: extent) }
        let transform = CGAffineTransform(scaleX: lamp.radii.width * width, y: lamp.radii.height * height)
            .concatenating(CGAffineTransform(translationX: lamp.offset.x * width, y: lamp.offset.y * height))
            .concatenating(CGAffineTransform(rotationAngle: face.roll))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        return unit.cropped(to: CGRect(x: -1, y: -1, width: 2, height: 2)).transformed(by: transform)
            .composited(over: CIImage(color: .black)).cropped(to: extent)
    }

    /// The lamps' gradients over `extent`, each at its strength, the brightest wherever they overlap.
    private static func layer(_ lamps: [(Lamp, FaceStore.Face)], in extent: CGRect, intensity: Double) -> CIImage? {
        lamps.map { lamp, face in
            let amount = lamp.strength * intensity * 0.5
            return gradient(lamp, face: face, in: extent).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: amount, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: amount, w: 0)])
        }.reduce(nil as CIImage?) { sum, next in
            sum.map { next.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? next
        }
    }

    private static func light(_ linear: CIImage, people: CIImage, faces: [FaceStore.Face], intensity: Double, contour: Bool) -> CIImage {
        let extent = linear.extent
        guard !faces.isEmpty, intensity > 0 else { return linear }
        let planned = faces.map { (face: $0, lamps: lamps(for: $0, contour: contour)) }
        let keys = planned.flatMap { plan in plan.lamps.key.map { ($0, plan.face) } }
        let shadows = planned.flatMap { plan in plan.lamps.shadow.map { ($0, plan.face) } }
        // Mid-gray leaves the photo as it is under soft light: the keys lift it toward white, the shadows lower it.
        var map = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        if let key = layer(keys, in: extent, intensity: intensity) {
            map = key.applyingFilter("CILinearDodgeBlendMode", parameters: [kCIInputBackgroundImageKey: map])
        }
        if let shadow = layer(shadows, in: extent, intensity: intensity) {
            map = shadow.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: map])
        }
        let image = linear.applyingFilter("CILinearToSRGBToneCurve")
        let lit = map.cropped(to: extent).applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        return lit
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: people])
            .applyingFilter("CISRGBToneCurveToLinear")
            .cropped(to: extent)
    }

    /// A face to light when someone was found but no face was (turned away, or too small): upright and facing the
    /// camera, as wide as half the person and at the top of them. Nil without a person.
    static func standIn(for people: SubjectMatteStore.Matte) -> FaceStore.Face? {
        guard people.hasSubject else { return nil }
        var minX = people.width, maxX = -1, minRow = people.height, maxRow = -1
        people.bytes.withUnsafeBytes { bytes in
            for row in 0..<people.height {
                for x in 0..<people.width where bytes[row * people.width + x] >= 128 {
                    minX = min(minX, x); maxX = max(maxX, x); minRow = min(minRow, row); maxRow = max(maxRow, row)
                }
            }
        }
        guard maxX >= minX, maxRow >= minRow else { return nil }
        let width = Double(people.width), height = Double(people.height)
        let personWidth = Double(maxX - minX + 1) / width
        let faceWidth = personWidth / 2, faceHeight = min(Double(maxRow - minRow + 1) / height, faceWidth * width / height * 1.3)
        // Rows are from the top; the frame's fractions are from the bottom.
        let top = 1 - Double(minRow) / height
        let bounds = CGRect(x: Double(minX) / width + (personWidth - faceWidth) / 2, y: top - faceHeight, width: faceWidth, height: faceHeight)
        return FaceStore.Face(bounds: bounds, center: CGPoint(x: bounds.midX, y: bounds.midY), turn: 0, roll: 0)
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
