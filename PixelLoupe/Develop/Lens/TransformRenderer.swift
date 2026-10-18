import CoreImage
import Foundation

/// Perspective correction: Lightroom's Transform sliders as a projective warp of the oriented photo,
/// applied before the crop.
///
/// Model: a virtual camera looks at the photo from `focal` pixels away. Vertical and Horizontal tilt
/// it about the x and y axes, Rotate turns it about the lens axis; Aspect, Scale and the offsets
/// reshape the picture on the way. The warp is a 3×3 homography, found for each *output* pixel
/// (where in the source it comes from), so the resampling happens once on the GPU.
nonisolated enum TransformRenderer {
    /// Degrees of tilt at the end of the Vertical and Horizontal sliders.
    static let maximumTilt = 25.0
    /// Distance of the virtual camera from the photo, as a multiple of the photo's long edge.
    static let focalFactor = 1.2

    /// Where each output point (offset from the photo's center, pixels, y up) comes from in the source.
    struct Geometry: Equatable, Sendable {
        /// Row-major 3×3, applied to (x, y, 1).
        var matrix: [Double]
        /// The photo's size, the unit for offsets.
        var size: CGSize
        var isIdentity: Bool { matrix == [1, 0, 0, 0, 1, 0, 0, 0, 1] }

        init(_ transform: PhotoAdjustments.Transform, size: CGSize) {
            self.size = size
            guard transform.isActive, size.width > 0, size.height > 0 else {
                matrix = [1, 0, 0, 0, 1, 0, 0, 0, 1]
                return
            }
            let width = Double(size.width), height = Double(size.height)
            let focal = max(width, height) * focalFactor
            let tiltX = transform.vertical * Self.radians(maximumTilt)
            let tiltY = transform.horizontal * Self.radians(maximumTilt)
            let roll = Self.radians(transform.rotate)

            // Camera rotation R = Rz · Rx · Ry.
            let (cx, sx) = (cos(tiltX), sin(tiltX)), (cy, sy) = (cos(tiltY), sin(tiltY)), (cz, sz) = (cos(roll), sin(roll))
            let rx = [1, 0, 0, 0, cx, -sx, 0, sx, cx]
            let ry = [cy, 0, sy, 0, 1, 0, -sy, 0, cy]
            let rz = [cz, -sz, 0, sz, cz, 0, 0, 0, 1]
            let r = Self.multiply(rz, Self.multiply(rx, ry))
            // Pixels to rays and back: M = K R K⁻¹ with K = diag(f, f, 1).
            let homography = [
                r[0], r[1], focal * r[2],
                r[3], r[4], focal * r[5],
                r[6] / focal, r[7] / focal, r[8],
            ]
            // Before it: undo the aspect stretch, the scale and the offset (output side).
            let stretch = 1 + transform.aspect * 0.3
            let zoom = max(transform.scale, 0.01)
            let pre = [
                1 / (zoom * stretch), 0, -transform.offsetX * 0.25 * width / (zoom * stretch),
                0, stretch / zoom, -transform.offsetY * 0.25 * height * stretch / zoom,
                0, 0, 1,
            ]
            matrix = Self.multiply(homography, pre)
        }

        /// The source point (offset from the center) for an output point.
        func source(for point: CGPoint) -> CGPoint? {
            let m = matrix
            let w = m[6] * point.x + m[7] * point.y + m[8]
            guard w > 1e-4 else { return nil }
            return CGPoint(x: (m[0] * point.x + m[1] * point.y + m[2]) / w, y: (m[3] * point.x + m[4] * point.y + m[5]) / w)
        }

        /// The source region an output region needs: lines map to lines, so the corners and edges' ends bound it.
        func sourceRect(for rect: CGRect, center: CGPoint, within source: CGRect) -> CGRect {
            var bounds = CGRect.null
            let steps = 8
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                for point in [
                    CGPoint(x: rect.minX + rect.width * t, y: rect.minY), CGPoint(x: rect.minX + rect.width * t, y: rect.maxY),
                    CGPoint(x: rect.minX, y: rect.minY + rect.height * t), CGPoint(x: rect.maxX, y: rect.minY + rect.height * t),
                ] {
                    guard let origin = self.source(for: CGPoint(x: point.x - center.x, y: point.y - center.y)) else { return source }
                    bounds = bounds.union(CGRect(x: center.x + origin.x, y: center.y + origin.y, width: 0, height: 0))
                }
            }
            let needed = bounds.insetBy(dx: -4, dy: -4).intersection(source.insetBy(dx: -4, dy: -4))
            // A region that comes from entirely outside the photo still needs an input to be drawn from
            // (the kernel then finds nothing there and leaves it transparent); with an empty one the
            // processor would skip the region and leave whatever was in memory.
            return needed.isNull || needed.isEmpty ? CGRect(x: source.minX, y: source.minY, width: 1, height: 1) : needed
        }

        /// The zoom (≥ 1) at which every edge pixel of the result comes from inside the photo.
        func constrainingZoom() -> Double {
            let halfWidth = Double(size.width) / 2 - 0.5, halfHeight = Double(size.height) / 2 - 0.5
            func covered(_ zoom: Double) -> Bool {
                let steps = 32
                for i in 0...steps {
                    let t = Double(i) / Double(steps) * 2 - 1
                    for edge in [
                        CGPoint(x: t * halfWidth, y: halfHeight), CGPoint(x: t * halfWidth, y: -halfHeight),
                        CGPoint(x: halfWidth, y: t * halfHeight), CGPoint(x: -halfWidth, y: t * halfHeight),
                    ] {
                        guard let origin = source(for: CGPoint(x: edge.x / zoom, y: edge.y / zoom)) else { return false }
                        if abs(origin.x) > halfWidth + 0.1 || abs(origin.y) > halfHeight + 0.1 { return false }
                    }
                }
                return true
            }
            if covered(1) { return 1 }
            var low = 1.0, high = 4.0
            if !covered(high) { return high }
            for _ in 0..<24 {
                let middle = (low + high) / 2
                if covered(middle) { high = middle } else { low = middle }
            }
            return high
        }

        private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }

        static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
            (0..<9).map { index in
                let (row, column) = (index / 3, index % 3)
                return a[row * 3] * b[column] + a[row * 3 + 1] * b[3 + column] + a[row * 3 + 2] * b[6 + column]
            }
        }
    }

    static func apply(_ transform: PhotoAdjustments.Transform, to image: CIImage) -> CIImage {
        guard transform.isActive else { return image }
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return image }
        var geometry = Geometry(transform, size: extent.size)
        if transform.constrainCrop {
            // Zoom in about the center until no empty corner is left.
            var zoomed = transform
            zoomed.scale *= geometry.constrainingZoom()
            geometry = Geometry(zoomed, size: extent.size)
        }
        guard !geometry.isIdentity else { return image }
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let final = geometry
        let roi = LensKernel.RegionOfInterest { rect in final.sourceRect(for: rect, center: center, within: extent) }
        let m = final.matrix.map(Float.init)
        return LensKernel.apply(.transform, to: image, parameters: [Float(center.x), Float(center.y)] + m, roi: roi) ?? image
    }
}
