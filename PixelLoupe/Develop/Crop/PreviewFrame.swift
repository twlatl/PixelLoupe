import AppKit

/// Where the photo's whole frame sits in the Develop preview, for the overlays that place things on
/// it: masks and spots, which are stored in unit coordinates of the whole uncropped frame. A cropped
/// photo is shown cropped in every tool but Crop (RAW-202), so the frame can reach past the photo
/// shown, and it's turned by the straightening angle about its center, as the pipeline turns the
/// photo before cropping it (``CropRenderer``).
nonisolated struct PreviewFrame: Equatable {
    /// The whole frame, before straightening, in view points.
    var rect: CGRect
    /// The straightening angle in degrees (counterclockwise), about `rect`'s center.
    var angle: Double
    /// The photo as shown, in view points: the crop, or the whole frame when it isn't cropped.
    var visible: CGRect

    init(rect: CGRect, angle: Double = 0, visible: CGRect? = nil) {
        self.rect = rect
        self.angle = angle
        self.visible = visible ?? rect
    }

    static let zero = PreviewFrame(rect: .zero)

    /// The frame for a photo shown cropped by `crop` in `shown` (view points), from its frame's
    /// full-resolution size.
    static func cropped(shown: CGRect, crop: PhotoAdjustments.Crop, frameSize: CGSize) -> PreviewFrame {
        guard crop.isActive, crop.rect.width > 0, crop.rect.height > 0, frameSize.width > 0, frameSize.height > 0 else {
            return PreviewFrame(rect: shown)
        }
        // View points per frame pixel.
        let scale = shown.width / (crop.rect.width * frameSize.width)
        let rect = CGRect(
            x: shown.minX - crop.rect.minX * frameSize.width * scale, y: shown.minY - crop.rect.minY * frameSize.height * scale,
            width: frameSize.width * scale, height: frameSize.height * scale
        )
        return PreviewFrame(rect: rect, angle: crop.angle, visible: shown)
    }

    /// Turns the frame from its unrotated place in `rect` to where it's shown.
    var rotation: CGAffineTransform {
        guard angle != 0 else { return .identity }
        return CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .rotated(by: angle * .pi / 180)
            .translatedBy(x: -rect.midX, y: -rect.midY)
    }

    /// A view point from a point in the frame's pixels (from `rect`'s origin, at its size).
    func viewPoint(_ framePoint: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + framePoint.x, y: rect.minY + framePoint.y).applying(rotation)
    }

    /// A point in the frame's pixels from a view point.
    func framePoint(_ viewPoint: CGPoint) -> CGPoint {
        let unrotated = viewPoint.applying(rotation.inverted())
        return CGPoint(x: unrotated.x - rect.minX, y: unrotated.y - rect.minY)
    }

    /// The whole frame's outline in view points.
    var outline: NSBezierPath {
        let path = NSBezierPath(rect: rect)
        path.transform(using: AffineTransform(rotation))
        return path
    }

    /// How far a view-point drag moves in the frame's pixels (turned back by the angle).
    func frameVector(_ vector: CGVector) -> CGVector {
        let turned = CGPoint(x: vector.dx, y: vector.dy).applying(CGAffineTransform(rotationAngle: -angle * .pi / 180))
        return CGVector(dx: turned.x, dy: turned.y)
    }
}

private nonisolated extension AffineTransform {
    init(_ transform: CGAffineTransform) {
        self.init(m11: transform.a, m12: transform.b, m21: transform.c, m22: transform.d, tX: transform.tx, tY: transform.ty)
    }
}
