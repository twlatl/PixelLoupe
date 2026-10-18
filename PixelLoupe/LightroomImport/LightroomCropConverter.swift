import CoreGraphics
import Foundation

/// Turns Lightroom's crop (`CropLeft/Top/Right/Bottom`, `CropAngle`) into PixelLoupe's ``PhotoAdjustments/Crop``.
///
/// Lightroom keeps the crop as a rectangle in the oriented, unstraightened photo (normalized, origin
/// top-left) and an angle that is positive clockwise. PixelLoupe turns the photo about the *photo's*
/// center by an angle that is positive counterclockwise, and keeps the crop as an upright rectangle in
/// the straightened frame (origin bottom-left). So the angle's sign flips (``angleSign``), the y axis
/// flips, and the rectangle's center is carried around the photo's center by the straightening
/// angle; its size stays.
///
/// **Unverified:** the sign and the frame the rectangle is in follow the Jira ticket's description of
/// Lightroom; they have not been compared with Lightroom exports (a handful of crops in one real
/// catalog did not settle it). If exports show the opposite direction, change ``angleSign``.
nonisolated enum LightroomCropConverter {
    struct Crop: Equatable, Sendable {
        var left = 0.0, top = 0.0, right = 1.0, bottom = 1.0
        /// Degrees, positive clockwise.
        var angle = 0.0
        var constrainAspectRatio = false

        var isActive: Bool { left != 0 || top != 0 || right != 1 || bottom != 1 || angle != 0 }
    }

    /// Ratios (landscape, width ÷ height) a crop is recognized as, from the Aspect menu.
    private static let standardRatios: [(width: Double, height: Double)] = CropAspect.menu.compactMap { item in
        if case .ratio(let width, let height)? = item?.aspect { return (width, height) }
        return nil
    }

    /// PixelLoupe's straightening angle is Lightroom's times this.
    static let angleSign = -1.0

    /// How close a crop's proportions must be to a ratio to count as it.
    static let ratioTolerance = 0.005

    /// `size` is the photo's size in pixels after orientation (width × height as shown).
    static func convert(_ lightroom: Crop, size: CGSize) -> PhotoAdjustments.Crop? {
        guard lightroom.isActive, size.width > 0, size.height > 0 else { return nil }
        let left = lightroom.left.clamped(to: 0...1), right = lightroom.right.clamped(to: 0...1)
        let top = lightroom.top.clamped(to: 0...1), bottom = lightroom.bottom.clamped(to: 0...1)
        guard right > left, bottom > top else { return nil }

        let width = Double(size.width), height = Double(size.height)
        let cropWidth = (right - left) * width, cropHeight = (bottom - top) * height
        // The crop's center in the photo, y up.
        let center = (x: (left + right) / 2 * width, y: height - (top + bottom) / 2 * height)
        let angle = lightroom.angle.clamped(to: CropGeometry.angleRange)
        let straighten = angleSign * angle * .pi / 180
        let (dx, dy) = (center.x - width / 2, center.y - height / 2)
        let turned = (
            x: width / 2 + dx * cos(straighten) - dy * sin(straighten),
            y: height / 2 + dx * sin(straighten) + dy * cos(straighten))

        var crop = PhotoAdjustments.Crop()
        crop.angle = (angleSign * angle * 1000).rounded() / 1000
        crop.rect = CropGeometry.clampToFrame(CGRect(
            x: (turned.x - cropWidth / 2) / width, y: (turned.y - cropHeight / 2) / height,
            width: cropWidth / width, height: cropHeight / height))
        // Lightroom keeps the crop inside the photo unless Upright or Transform is used.
        crop.constrainToImage = true
        (crop.aspect, crop.isAspectLocked) = aspect(cropWidth: cropWidth, cropHeight: cropHeight, size: size, constrained: lightroom.constrainAspectRatio)
        return crop
    }

    /// The aspect menu choice a crop of these proportions is, and whether it is locked.
    static func aspect(cropWidth: Double, cropHeight: Double, size: CGSize, constrained: Bool) -> (CropAspect, Bool) {
        guard constrained, cropWidth > 0, cropHeight > 0 else { return (.custom, false) }
        let ratio = max(cropWidth, cropHeight) / min(cropWidth, cropHeight)
        func matches(_ other: Double) -> Bool { abs(ratio - other) / other <= ratioTolerance }
        let original = max(Double(size.width), Double(size.height)) / min(Double(size.width), Double(size.height))
        if matches(original) { return (.original, true) }
        for standard in standardRatios {
            let landscape = max(standard.width, standard.height) / min(standard.width, standard.height)
            if matches(landscape) { return (.ratio(width: max(standard.width, standard.height), height: min(standard.width, standard.height)), true) }
        }
        return (.custom, true)
    }
}

nonisolated extension Photo {
    /// The photo's size in pixels as shown: the stored size, turned by the camera's orientation and by
    /// PixelLoupe's own rotation.
    var displayedPixelSize: CGSize {
        var size = CGSize(width: Double(pixelWidth), height: Double(pixelHeight))
        if orientation >= 5 { size = CGSize(width: size.height, height: size.width) }
        if adjustments.orientation.swapsDimensions { size = CGSize(width: size.height, height: size.width) }
        return size
    }
}
