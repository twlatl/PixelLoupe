import CoreGraphics
import Foundation
import simd

/// How Photo Merge ▸ Panorama lays the photos out flat, as Lightroom's projections do.
nonisolated enum PanoramaProjection: String, Codable, CaseIterable, Sendable {
    /// As if mapped to the inside of a sphere: for very wide or multi-row panoramas.
    case spherical
    /// As if mapped to the inside of a cylinder: for wide panoramas, keeping verticals straight.
    case cylindrical
    /// As if mapped to a flat surface: keeps straight lines straight, for architecture.
    case perspective

    var title: String {
        switch self {
        case .spherical: "Spherical"
        case .cylindrical: "Cylindrical"
        case .perspective: "Perspective"
        }
    }

    /// Perspective can't show photos spanning more than this (degrees, across or up and down):
    /// the edges stretch toward infinity.
    static let perspectiveLimit = 150.0

    /// Where a direction (world space: x right, y down, z forward) lands on the flat panorama, in
    /// units of the focal length (radians for the angular axes), or nil when this projection can't
    /// show it.
    func point(for ray: SIMD3<Double>) -> SIMD2<Double>? {
        switch self {
        case .spherical:
            return SIMD2(atan2(ray.x, ray.z), atan2(ray.y, hypot(ray.x, ray.z)))
        case .cylindrical:
            let radius = hypot(ray.x, ray.z)
            guard radius > 1e-9 else { return nil }
            return SIMD2(atan2(ray.x, ray.z), ray.y / radius)
        case .perspective:
            guard ray.z > 1e-6 else { return nil }
            return SIMD2(ray.x / ray.z, ray.y / ray.z)
        }
    }

    /// The direction a point on the flat panorama shows (unit length).
    func ray(for point: SIMD2<Double>) -> SIMD3<Double> {
        switch self {
        case .spherical:
            return SIMD3(cos(point.y) * sin(point.x), sin(point.y), cos(point.y) * cos(point.x))
        case .cylindrical:
            return simd_normalize(SIMD3(sin(point.x), point.y, cos(point.x)))
        case .perspective:
            return simd_normalize(SIMD3(point.x, point.y, 1))
        }
    }

    /// The projection's number for the Core Image kernels.
    var kernelIndex: Float {
        switch self {
        case .spherical: 0
        case .cylindrical: 1
        case .perspective: 2
        }
    }
}

/// Where everything goes in a panorama at full resolution: each photo's camera (centered so the
/// panorama is in the middle), and the flat panorama's size and mapping, for one projection.
nonisolated struct PanoramaLayout: Sendable {
    /// Lightroom's limits for a merged panorama: bigger ones are scaled down to fit.
    static let maximumSide = 65_000.0
    static let maximumPixels = 512_000_000.0

    let projection: PanoramaProjection
    /// Each photo's camera at full resolution, nil for photos left out.
    let cameras: [PanoramaCamera?]
    /// Each photo's full-resolution size.
    let photoSizes: [CGSize]
    /// Pixels per unit of the projection's flat coordinates (the focal length, so the middle of the
    /// panorama is at the photos' own resolution, unless that's over the limits).
    let scale: Double
    /// The flat coordinates of the panorama's top-left corner.
    let origin: SIMD2<Double>
    /// The panorama's size in pixels at full resolution.
    let size: CGSize

    /// How far the photos reach, in degrees: across (around the vertical axis) and up and down.
    let span: (horizontal: Double, vertical: Double)

    /// - Parameters:
    ///   - alignment: the cameras, at `alignedSizes`.
    ///   - photoSizes: the photos' full-resolution sizes.
    init?(alignment: PanoramaAlignment, alignedSizes: [CGSize], photoSizes: [CGSize], projection: PanoramaProjection) {
        var cameras = zip(alignment.cameras, zip(alignedSizes, photoSizes)).map { camera, sizes in
            camera?.scaled(by: Double(sizes.1.width / max(sizes.0.width, 1)))
        }
        guard cameras.contains(where: { $0 != nil }) else { return nil }
        self.photoSizes = photoSizes

        // Centered across: turned about the vertical so the photos' reach is even on both sides.
        let spherical = Self.extent(cameras: cameras, sizes: photoSizes, projection: .spherical)
        let middle = (spherical.min.x + spherical.max.x) / 2
        let turn = simd_double3x3(rows: [
            SIMD3(cos(middle), 0, -sin(middle)), SIMD3(0, 1, 0), SIMD3(sin(middle), 0, cos(middle)),
        ])
        for index in cameras.indices {
            guard var camera = cameras[index] else { continue }
            // The world turned by `middle`: rays seen before at longitude `middle` are now straight ahead.
            camera.rotation = camera.rotation * turn.transpose
            cameras[index] = camera
        }
        self.cameras = cameras
        let centered = Self.extent(cameras: cameras, sizes: photoSizes, projection: .spherical)
        span = ((centered.max.x - centered.min.x) * 180 / .pi, (centered.max.y - centered.min.y) * 180 / .pi)
        if projection == .perspective, max(span.horizontal, span.vertical) > PanoramaProjection.perspectiveLimit { return nil }
        self.projection = projection

        let extent = Self.extent(cameras: cameras, sizes: photoSizes, projection: projection)
        let focalLengths = cameras.compactMap { $0?.focalLength }.sorted()
        var scale = focalLengths[focalLengths.count / 2]
        let width = (extent.max.x - extent.min.x) * scale, height = (extent.max.y - extent.min.y) * scale
        let fit = min(1, Self.maximumSide / max(width, height, 1), sqrt(Self.maximumPixels / max(width * height, 1)))
        scale *= fit
        self.scale = scale
        origin = extent.min
        size = CGSize(
            width: max(1, ((extent.max.x - extent.min.x) * scale).rounded(.down)),
            height: max(1, ((extent.max.y - extent.min.y) * scale).rounded(.down))
        )
    }

    /// Whether Perspective can show photos placed like these.
    static func allowsPerspective(alignment: PanoramaAlignment, alignedSizes: [CGSize]) -> Bool {
        PanoramaLayout(alignment: alignment, alignedSizes: alignedSizes, photoSizes: alignedSizes, projection: .perspective) != nil
    }

    /// The panorama pixel (from its top left, at full resolution) a direction lands on.
    func pixel(for ray: SIMD3<Double>) -> SIMD2<Double>? {
        projection.point(for: ray).map { ($0 - origin) * scale }
    }

    /// The direction a panorama pixel (from its top left, at full resolution) shows.
    func ray(at pixel: SIMD2<Double>) -> SIMD3<Double> {
        projection.ray(for: pixel / scale + origin)
    }

    /// Points around the edge of a photo of `size`, from its center (y down).
    static func border(of size: CGSize, steps: Int = 32) -> [SIMD2<Double>] {
        let w = Double(size.width) / 2, h = Double(size.height) / 2
        var points: [SIMD2<Double>] = []
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            points += [SIMD2(-w + 2 * w * t, -h), SIMD2(-w + 2 * w * t, h), SIMD2(-w, -h + 2 * h * t), SIMD2(w, -h + 2 * h * t)]
        }
        return points
    }

    /// The bounding box of the photos' edges in a projection's flat coordinates.
    static func extent(cameras: [PanoramaCamera?], sizes: [CGSize], projection: PanoramaProjection) -> (min: SIMD2<Double>, max: SIMD2<Double>) {
        var low = SIMD2<Double>(repeating: .infinity), high = SIMD2<Double>(repeating: -.infinity)
        for (camera, size) in zip(cameras, sizes) {
            guard let camera else { continue }
            for point in border(of: size) {
                guard let flat = projection.point(for: camera.ray(point)) else { continue }
                low = simd_min(low, flat)
                high = simd_max(high, flat)
            }
        }
        if !low.x.isFinite { return (.zero, .zero) }
        return (low, high)
    }

    /// The part of the panorama (pixels from its top left at full resolution) a photo covers.
    func footprint(of index: Int) -> CGRect {
        guard let camera = cameras[index] else { return .null }
        var low = SIMD2<Double>(repeating: .infinity), high = SIMD2<Double>(repeating: -.infinity)
        for point in Self.border(of: photoSizes[index]) {
            guard let p = pixel(for: camera.ray(point)) else { continue }
            low = simd_min(low, p)
            high = simd_max(high, p)
        }
        // A photo reaching past the panorama's seam (behind) would wrap; it can't here, but a
        // photo over a pole covers whole rows.
        guard low.x.isFinite else { return .null }
        return CGRect(x: low.x, y: low.y, width: high.x - low.x, height: high.y - low.y)
            .intersection(CGRect(origin: .zero, size: size))
    }
}
