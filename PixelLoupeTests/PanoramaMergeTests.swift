import AppKit
import CoreData
import Foundation
import Testing
import simd
@testable import PixelLoupe

/// Photos of a synthetic scene taken by a camera turning about one point, written as Linear DNGs: the
/// scene is a textured sphere around the camera, so where each photo points is known exactly.
struct SyntheticPanorama {
    let directory: TemporaryDirectory
    let width: Int
    let height: Int
    /// Pixels.
    let focal: Double
    /// Each photo's camera-to-world rotation.
    let rotations: [simd_double3x3]
    let stops: [Double]
    var sources: [PhotoMergeSource] = []

    /// Photos turned by `yaws` (degrees, right positive) at `pitch` (degrees, up positive), each
    /// exposed `stops` from the first (recorded in its metadata), in capture order.
    init(yaws: [Double] = [-36, -12, 12, 36], pitch: Double = 4, stops: [Double]? = nil,
         width: Int = 360, height: Int = 240, focal: Double = 300, name: String = "PANO") throws {
        directory = try TemporaryDirectory()
        self.width = width
        self.height = height
        self.focal = focal
        let stops = stops ?? Array(repeating: 0, count: yaws.count)
        self.stops = stops
        rotations = yaws.map { Self.rotation(yaw: $0, pitch: pitch) }
        // A focal length in millimeters that gives `focal` pixels on a full-frame camera.
        let millimeters = focal / hypot(Double(width), Double(height)) * hypot(36, 24)
        for (index, rotation) in rotations.enumerated() {
            let gain = Float(pow(2, stops[index]))
            let image = DNGFixtures.image(width: width, height: height) { x, y in
                // 2 × 2 samples per pixel, so the photos agree where they overlap.
                var total: Float = 0
                for (dx, dy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                    total += Self.scene(rotation * simd_normalize(SIMD3(Double(x) + dx - Double(width) / 2, Double(y) + dy - Double(height) / 2, focal)))
                }
                return SIMD3(repeating: min(total / 4 * gain, 1))
            }
            let url = directory.url.appending(path: "\(name)_\(index).dng")
            var metadata = DNGMetadata(make: "Canon", model: "EOS R5", captureDate: Date(timeIntervalSince1970: 1_791_000_000 + Double(index)))
            metadata.exposureTime = pow(2, stops[index]) / 100
            metadata.aperture = 8
            metadata.iso = 100
            metadata.focalLength = millimeters
            try LinearDNGWriter.write(image, metadata: metadata, to: url)
            sources.append(PhotoMergeSource(
                url: url, exposureTime: metadata.exposureTime, aperture: 8, iso: 100, make: "Canon", model: "EOS R5",
                focalLength: millimeters, captureDate: metadata.captureDate
            ))
        }
    }

    /// Camera to world: turned right by `yaw`, then up by `pitch` (y is down).
    static func rotation(yaw: Double, pitch: Double) -> simd_double3x3 {
        let a = yaw * .pi / 180, b = pitch * .pi / 180
        let turn = simd_double3x3(rows: [SIMD3(cos(a), 0, sin(a)), SIMD3(0, 1, 0), SIMD3(-sin(a), 0, cos(a))])
        let tilt = simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(b), -sin(b)), SIMD3(0, sin(b), cos(b))])
        return turn * tilt
    }

    /// The scene's brightness in a direction (world: x right, y down, z forward): blocks of random
    /// brightness at two sizes, for corners to find, over a gentle gradient. At most 0.24, so photos
    /// two stops brighter don't clip.
    static func scene(_ ray: SIMD3<Double>) -> Float {
        let longitude = atan2(ray.x, ray.z) * 180 / .pi, latitude = asin(max(-1, min(1, ray.y))) * 180 / .pi
        func hash(_ i: Int, _ j: Int) -> Float {
            var h = UInt32(truncatingIfNeeded: i &* 73_856_093 ^ j &* 19_349_663)
            h ^= h >> 13
            h = h &* 0x5BD1_E995
            h ^= h >> 15
            return Float(h % 1000) / 1000
        }
        let fine = hash(Int((longitude / 1.3).rounded(.down)), Int((latitude / 1.3).rounded(.down)))
        let coarse = hash(Int((longitude / 5).rounded(.down)) + 7919, Int((latitude / 5).rounded(.down)) + 104_729)
        return 0.01 + 0.03 * Float((latitude + 90) / 180) + 0.1 * fine + 0.1 * coarse
    }

    /// The angle (degrees) between two rotations.
    static func angle(between a: simd_double3x3, _ b: simd_double3x3) -> Double {
        let r = a * b.transpose
        let trace = r[0, 0] + r[1, 1] + r[2, 2]
        return acos(max(-1, min(1, (trace - 1) / 2))) * 180 / .pi
    }
}

/// One test at a time: each merges on the GPU, and many at once starve the Develop tests that wait
/// on renders.
@Suite("Panorama merge", .serialized)
struct PanoramaMergeTests {
    // MARK: Alignment

    @Test func alignmentFindsHowThePhotosTurned() throws {
        let panorama = try SyntheticPanorama()
        let merger = try PanoramaMerger(sources: panorama.sources)
        #expect(merger.mergedCount == 4)
        let cameras = merger.alignment.cameras.compactMap { $0 }
        try #require(cameras.count == 4)
        // The turn from each photo to the next, whatever way the panorama itself is turned.
        for i in 0..<3 {
            let found = cameras[i + 1].rotation * cameras[i].rotation.transpose
            let truth = panorama.rotations[i + 1].transpose * panorama.rotations[i]
            #expect(SyntheticPanorama.angle(between: found, truth) < 0.25, "photos \(i) and \(i + 1)")
        }
        // The aligner works on the photos as they are (smaller than 1536 pixels).
        for camera in cameras { #expect(abs(camera.focalLength - panorama.focal) / panorama.focal < 0.02, "\(camera.focalLength)") }
        // Levelled: the cameras were held level, so none of them is rolled, and all point 4° up.
        for camera in cameras {
            let right = SIMD3(camera.rotation[0, 0], camera.rotation[1, 0], camera.rotation[2, 0])
            let forward = SIMD3(camera.rotation[0, 2], camera.rotation[1, 2], camera.rotation[2, 2])
            #expect(abs(asin(right.y) * 180 / .pi) < 0.3, "roll")
            #expect(abs(-asin(forward.y) * 180 / .pi - 4) < 0.5, "pitch")
        }
    }

    @Test func photosThatDontOverlapAreLeftOut() throws {
        let panorama = try SyntheticPanorama()
        let elsewhere = try SyntheticPanorama(yaws: [150], name: "AWAY")
        var sources = panorama.sources
        sources.insert(elsewhere.sources[0], at: 2)
        let merger = try PanoramaMerger(sources: sources)
        #expect(merger.mergedCount == 4)
        #expect(merger.alignment.cameras[2] == nil)
        #expect(throws: PanoramaAlignmentError.noOverlap) {
            try PanoramaMerger(sources: [panorama.sources[0], elsewhere.sources[0]])
        }
    }

    @Test func onlyRawPhotosFromOneCameraMerge() throws {
        let panorama = try SyntheticPanorama()
        #expect(throws: PhotoMergeError.tooFewPhotos) { try PanoramaMerger(sources: [panorama.sources[0]]) }
        var other = panorama.sources[1]
        other.model = "EOS R6"
        #expect(throws: PhotoMergeError.differentCameras) { try PanoramaMerger(sources: [panorama.sources[0], other]) }
    }

    // MARK: Projections

    @Test(arguments: PanoramaProjection.allCases)
    func projectionsRoundTrip(_ projection: PanoramaProjection) {
        for point in [SIMD2(0.0, 0.0), SIMD2(0.6, -0.3), SIMD2(-1.1, 0.4), SIMD2(0.2, 0.9)] {
            let back = projection.point(for: projection.ray(for: point))
            #expect(back.map { simd_distance($0, point) < 1e-9 } == true, "\(projection) \(point)")
        }
    }

    @Test func perspectiveIsOnlyForPanoramasItCanShow() throws {
        let narrowPhotos = try SyntheticPanorama(), widePhotos = try SyntheticPanorama(yaws: [-80, -55, -30, -5, 20, 45, 70, 95])
        let narrow = try PanoramaMerger(sources: narrowPhotos.sources)
        #expect(narrow.allowsPerspective)
        let wide = try PanoramaMerger(sources: widePhotos.sources)
        #expect(!wide.allowsPerspective)
        var options = PanoramaMergeOptions()
        options.projection = .perspective
        #expect(throws: PanoramaMergeError.projectionNotPossible(.perspective)) { try wide.merge(options: options, scale: 0.25) }
    }

    @Test func sizesFollowTheProjection() throws {
        let panorama = try SyntheticPanorama()
        let merger = try PanoramaMerger(sources: panorama.sources)
        // Spherical and Cylindrical measure across in angle at the photos' resolution: four photos
        // 24° apart, each about 62° across, make about 134°.
        let spherical = try merger.size(for: .spherical), cylindrical = try merger.size(for: .cylindrical)
        let expected = (72 + 2 * atan(180.0 / 300) * 180 / .pi) * .pi / 180 * 300
        #expect(abs(spherical.width - expected) / expected < 0.03, "\(spherical)")
        #expect(abs(cylindrical.width - spherical.width) < 2)
        // Perspective stretches toward the edges.
        #expect(try merger.size(for: .perspective).width > spherical.width * 1.3)
    }

    // MARK: Merging

    @Test func mergeShowsTheSceneAtTheAverageExposure() throws {
        // Exposures a stop apart: the merge matches the photos' average (+1 stop).
        let panorama = try SyntheticPanorama(stops: [0, 1, 2, 1])
        let merger = try PanoramaMerger(sources: panorama.sources)
        let result = try merger.merge(options: PanoramaMergeOptions(), scale: 1)
        let image = result.image
        let scale = Float(pow(2, image.headroom ?? 0))
        let layout = try #require(PanoramaLayout(
            alignment: merger.alignment, alignedSizes: Array(repeating: CGSize(width: panorama.width, height: panorama.height), count: 4),
            photoSizes: Array(repeating: CGSize(width: panorama.width, height: panorama.height), count: 4), projection: .spherical
        ))
        // Points across the panorama, each found through the first photo that sees it.
        var errors: [Float] = []
        var mergedTotal: Float = 0, truthTotal: Float = 0
        for y in stride(from: 20, to: image.height - 20, by: 7) {
            for x in stride(from: 20, to: image.width - 20, by: 7) {
                let ray = layout.ray(at: SIMD2(Double(x) + 0.5, Double(y) + 0.5))
                guard let (index, point) = layout.cameras.enumerated().lazy.compactMap({ index, camera -> (Int, SIMD2<Double>)? in
                    guard let p = camera?.project(ray), abs(p.x) < Double(panorama.width) / 2 - 8, abs(p.y) < Double(panorama.height) / 2 - 8 else { return nil }
                    return (index, p)
                }).first else { continue }
                let truth = SyntheticPanorama.scene(panorama.rotations[index] * simd_normalize(SIMD3(point.x, point.y, panorama.focal))) * 2
                let i = (y * image.width + x) * 3
                let merged = Float(image.pixels[i + 1]) * scale
                errors.append(abs(merged - truth) / truth)
                mergedTotal += merged
                truthTotal += truth
            }
        }
        errors.sort()
        try #require(errors.count > 500)
        // As bright as the scene at the photos' average exposure…
        #expect(abs(mergedTotal / truthTotal - 1) < 0.03, "brightness \(mergedTotal / truthTotal)")
        // …and in the right place: the scene's blocks are 7 pixels across, so many points are near
        // an edge, where resampling softens it.
        #expect(errors[errors.count / 2] < 0.1, "median error \(errors[errors.count / 2])")
        // The photos' corners don't reach the panorama's: those are white (the brightest value).
        #expect(image.pixels[0] == 1 && image.pixels[1] == 1 && image.pixels[2] == 1)
    }

    @Test func autoCropAndBoundaryWarpRemoveTheEmptyEdges() throws {
        let panorama = try SyntheticPanorama()
        let merger = try PanoramaMerger(sources: panorama.sources)
        var options = PanoramaMergeOptions()
        let plain = try merger.merge(options: options, scale: 0.5)
        let plainCoverage = try #require(plain.coverage)
        #expect(plain.crop == nil)
        let filled = plainCoverage.values.reduce(0, +) / Float(plainCoverage.values.count)
        #expect(filled < 0.97)

        // Auto Crop: the largest rectangle the photos cover, as a Develop crop on the whole panorama.
        options.autoCrop = true
        let cropped = try merger.merge(options: options, scale: 0.5)
        let crop = try #require(cropped.crop)
        #expect(crop.width < 1 && crop.height < 1 && crop.width > 0.5 && crop.height > 0.5)
        #expect(cropped.image.width == plain.image.width, "the DNG keeps the whole panorama")
        for (fx, fy) in [(0.0, 0.0), (1, 0), (0, 1), (1, 1), (0.5, 0.5)] {
            let x = Int((crop.minX + crop.width * fx) * Double(plainCoverage.width - 1))
            let y = Int((1 - crop.minY - crop.height * fy) * Double(plainCoverage.height - 1))
            #expect(plainCoverage.values[y * plainCoverage.width + x] > 0.5, "crop corner \(fx), \(fy) is covered")
        }

        // Boundary Warp at 100 bends the edges out to fill (nearly) the whole rectangle.
        options.autoCrop = false
        options.boundaryWarp = 100
        let warped = try #require(try merger.merge(options: options, scale: 0.5).coverage)
        #expect(warped.values.reduce(0, +) / Float(warped.values.count) > 0.97)
        options.boundaryWarp = 50
        let half = try #require(try merger.merge(options: options, scale: 0.5).coverage)
        let halfFilled = half.values.reduce(0, +) / Float(half.values.count)
        #expect(halfFilled > filled && halfFilled < 0.99)
        // And Auto Crop then keeps more of the panorama.
        options.boundaryWarp = 100
        options.autoCrop = true
        let warpedCrop = try #require(try merger.merge(options: options, scale: 0.5).crop)
        #expect(warpedCrop.width * warpedCrop.height > crop.width * crop.height)
    }

    @Test func previewAndFullMergeMatch() throws {
        let panorama = try SyntheticPanorama(stops: [0, 1, 0, 1])
        let merger = try PanoramaMerger(sources: panorama.sources)
        let options = PanoramaMergeOptions()
        let full = try merger.merge(options: options, scale: 1).image
        let preview = try merger.merge(options: options, scale: 0.5).image
        #expect(full.headroom == preview.headroom)
        // The same place in both, away from the edges: the preview is the full merge, smaller.
        var difference: Float = 0, count: Float = 0
        for y in stride(from: 30, to: preview.height - 30, by: 9) {
            for x in stride(from: 30, to: preview.width - 30, by: 9) {
                var sum: Float = 0
                for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    sum += Float(full.pixels[((y * 2 + dy) * full.width + x * 2 + dx) * 3 + 1])
                }
                difference += abs(sum / 4 - Float(preview.pixels[(y * preview.width + x) * 3 + 1]))
                count += 1
            }
        }
        #expect(difference / count < 0.02, "mean difference \(difference / count)")
    }

    @Test func fillEdgesFillsWhereThePhotosDontReach() throws {
        let panorama = try SyntheticPanorama()
        let merger = try PanoramaMerger(sources: panorama.sources)
        var options = PanoramaMergeOptions()
        let plain = try merger.merge(options: options, scale: 0.5)
        let coverage = try #require(plain.coverage)
        options.fillEdges = true
        options.autoCrop = true
        let filled = try merger.merge(options: options, scale: 0.5)
        // It covers the whole rectangle, so there's nothing to crop or show through.
        #expect(filled.crop == nil && filled.coverage == nil)
        #expect(filled.image.width == plain.image.width && filled.image.height == plain.image.height)
        var holeSum: Float = 0, holeCount: Float = 0, coveredSum: Float = 0, coveredCount: Float = 0, white = 0
        var coveredChange: Float = 0, worstChange: Float = 0
        for (index, value) in coverage.values.enumerated() {
            let green = Float(filled.image.pixels[index * 3 + 1])
            if value >= 1 {
                let change = abs(green - Float(plain.image.pixels[index * 3 + 1]))
                coveredChange += change
                worstChange = max(worstChange, change)
                coveredSum += green
                coveredCount += 1
            } else if value < 0.01 {
                holeSum += green
                holeCount += 1
                if green > 0.98 { white += 1 }
            }
        }
        // The photos' pixels are kept (to a step or so of the half floats Core Image keeps its intermediates in).
        #expect(worstChange < 1e-3, "mean \(coveredChange / coveredCount), worst \(worstChange)")
        #expect(holeCount > 100)
        #expect(Float(white) / holeCount < 0.05, "\(white) of \(holeCount) hole pixels are still white")
        // The fill is made of the scene, so it's about as bright.
        #expect(abs(holeSum / holeCount - coveredSum / coveredCount) < 0.15)
    }

    @Test func fillEdgesPreviewAndFullMergeMatch() throws {
        // The full merge copies the preview-sized solve's matches up (a small solve forces that here).
        let panorama = try SyntheticPanorama()
        let merger = try PanoramaMerger(sources: panorama.sources)
        let coverage = try #require(try merger.merge(options: PanoramaMergeOptions(), scale: 0.5).coverage)
        var options = PanoramaMergeOptions()
        options.fillEdges = true
        let preview = try merger.merge(options: options, scale: 0.5).image
        merger.fillPixels = preview.width * preview.height
        let full = try merger.merge(options: options, scale: 1).image
        func downsampled(_ x: Int, _ y: Int) -> Float {
            var sum: Float = 0
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                sum += Float(full.pixels[((y * 2 + dy) * full.width + x * 2 + dx) * 3 + 1])
            }
            return sum / 4
        }
        var coveredDifference: Float = 0, coveredCount: Float = 0
        var holeFull: Float = 0, holePreview: Float = 0, holeCount: Float = 0, white = 0
        for y in 0..<min(preview.height, full.height / 2) {
            for x in 0..<min(preview.width, full.width / 2) {
                let value = coverage.values[y * coverage.width + x]
                let small = Float(preview.pixels[(y * preview.width + x) * 3 + 1])
                if value >= 1, x > 30, y > 30, x < preview.width - 30, y < preview.height - 30 {
                    coveredDifference += abs(downsampled(x, y) - small)
                    coveredCount += 1
                } else if value < 0.01 {
                    holeFull += downsampled(x, y)
                    holePreview += small
                    holeCount += 1
                    if downsampled(x, y) > 0.98 { white += 1 }
                }
            }
        }
        #expect(coveredDifference / coveredCount < 0.02, "covered: mean difference \(coveredDifference / coveredCount)")
        #expect(holeCount > 100 && Float(white) / holeCount < 0.05)
        #expect(abs(holeFull - holePreview) / holeCount < 0.05, "filled: mean difference \(abs(holeFull - holePreview) / holeCount)")
    }

    @Test func cancellingStopsAFilledMerge() async throws {
        let panorama = try SyntheticPanorama()
        let sources = panorama.sources
        let task = Task.detached {
            let merger = try PanoramaMerger(sources: sources)
            var options = PanoramaMergeOptions()
            options.fillEdges = true
            return try merger.merge(options: options, scale: 1)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        withExtendedLifetime(panorama) {}
    }

    @Test func cancellingStopsTheMerge() async throws {
        let panorama = try SyntheticPanorama()
        let sources = panorama.sources
        let task = Task.detached {
            let merger = try PanoramaMerger(sources: sources)
            return try merger.merge(options: PanoramaMergeOptions(), scale: 1)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        withExtendedLifetime(panorama) {}
    }

    // MARK: Seams, gains, crops and warps

    @Test func theBlendDoesntDependOnWhatsDrawnAfterIt() {
        // Two textured photos overlapping in the middle, on a canvas whose size halves to fractions. Drawn as it is
        // and through a kernel that changes nothing (adding a clear image), the blend must be the same.
        let width = 355, height = 114
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        func image(_ value: (Int, Int) -> SIMD4<Float>) -> CIImage {
            var pixels = [Float](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let v = value(x, y)
                    for c in 0..<4 { pixels[(y * width + x) * 4 + c] = v[c] }
                }
            }
            return CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                           size: canvas.size, format: .RGBAf, colorSpace: nil)
        }
        func texture(_ x: Int, _ y: Int) -> Float { 0.2 + 0.6 * Float((x * 7 + y * 13) % 17) / 17 }
        let photos = [(0, 230), (120, width)].map { range in
            let covers = { (x: Int, y: Int) in x >= range.0 && x < range.1 && y > 6 && y < height - 9 }
            return PanoramaMerger.BlendPhoto(
                image: image { x, y in covers(x, y) ? SIMD4(texture(x, y), texture(y, x), 0.5, 1) : .zero },
                mask: image { x, _ in SIMD4(x >= range.0 && x < range.1 && (range.0 == 0 ? x < 175 : x >= 175) ? 1 : 0, 0, 0, 1) },
                feather: image { x, _ in SIMD4(range.0 == 0 ? Float(230 - x) / 230 : Float(x - 120) / 235, 0, 0, 1) }
            )
        }
        let blended = PanoramaMerger.blend(photos, canvas: canvas, levels: 6)
        let passedOn = PanoramaKernels.add.apply(extent: canvas, arguments: [blended, PanoramaMerger.blank(canvas)])!
        let context = CIContext(options: [.workingColorSpace: PanoramaMerger.colorSpace, .cacheIntermediates: false])
        func render(_ image: CIImage) -> [Float] {
            var pixels = [Float](repeating: 0, count: width * height * 4)
            context.render(image, toBitmap: &pixels, rowBytes: width * 16, bounds: canvas, format: .RGBAf, colorSpace: nil)
            return pixels
        }
        let direct = render(blended), after = render(passedOn)
        let worst = zip(direct, after).map { abs($0 - $1) }.max() ?? 0
        // To a step or so of the half floats Core Image keeps its intermediates in.
        #expect(worst < 1e-3, "worst difference \(worst)")
    }

    @Test func seamsGoAroundWhatMoved() {
        // Two photos overlapping in the middle third; something sits in the overlap in the first only.
        let width = 90, height = 30
        func photo(x: Int, ghost: Bool) -> PanoramaSeams.Photo {
            let w = 60
            var color = [SIMD3<Float>](repeating: .zero, count: w * height)
            for y in 0..<height {
                for px in 0..<w {
                    let gx = x + px
                    var value = 0.2 + 0.4 * Float((gx * 7 + y * 13) % 10) / 10
                    if ghost, (40..<50).contains(gx), (8..<22).contains(y) { value = 0.9 }
                    color[y * w + px] = SIMD3(repeating: value)
                }
            }
            let centrality = (0..<(w * height)).map { i in Float(min(i % w, w - 1 - i % w)) / Float(w) }
            return PanoramaSeams.Photo(x: x, y: 0, width: w, height: height, color: color,
                                       covered: Array(repeating: true, count: w * height), centrality: centrality)
        }
        let photos = [photo(x: 0, ghost: true), photo(x: 30, ghost: false)]
        let labels = PanoramaSeams.labels(photos, gains: [1, 1], width: width, height: height)
        // Every pixel of the thing that moved comes from one photo: the seam doesn't cut through it.
        let ghost = (8..<22).flatMap { y in (40..<50).map { x in labels[y * width + x] } }
        #expect(Set(ghost).count == 1)
        #expect(labels[0] == 0 && labels[width - 1] == 1)
    }

    @Test func gainsEvenOutBrightness() {
        func photo(x: Int, brightness: Float) -> PanoramaSeams.Photo {
            let w = 40, h = 20
            return PanoramaSeams.Photo(x: x, y: 0, width: w, height: h,
                                       color: Array(repeating: SIMD3(repeating: 0.4 * brightness), count: w * h),
                                       covered: Array(repeating: true, count: w * h), centrality: Array(repeating: 0.5, count: w * h))
        }
        let gains = PanoramaSeams.gains([photo(x: 0, brightness: 1), photo(x: 20, brightness: 1.2)])
        // The brighter photo comes down and the darker up, until they nearly match.
        #expect(gains[1] < 1 && gains[0] > 1)
        #expect(abs(gains[0] * 1 - gains[1] * 1.2) < 0.06)
    }

    @Test func largestRectangleIsCoveredEntirely() throws {
        // An L shape: the bigger arm wins.
        let width = 10, height = 8
        var covered = [Bool](repeating: false, count: width * height)
        for y in 0..<height { for x in 0..<3 { covered[y * width + x] = true } }
        for y in 5..<height { for x in 0..<width { covered[y * width + x] = true } }
        let rect = try #require(PanoramaCrop.largestRectangle(covered, width: width, height: height))
        #expect(rect.width == 10 && rect.height == 3 && rect.x == 0 && rect.y == 5)
    }

    @Test func boundaryWarpBendsTheEdgeToTheRectangle() throws {
        // A panorama whose top and bottom edges sag, as a wide one's do.
        let width = 200, height = 80
        var covered = [Bool](repeating: false, count: width * height)
        for x in 0..<width {
            let sag = Int(10 * sin(Double(x) / Double(width) * .pi))
            for y in (2 + sag)..<(height - 12 + sag) { covered[y * width + x] = true }
        }
        let warp = try #require(PanoramaBoundaryWarp(coverage: covered, width: width, height: height))
        let full = warp.map(amount: 1, step: 1)
        // Fully warped, nearly every pixel shows the panorama…
        let shown = full.points.indices.filter { i in
            guard let p = full.points[i] else { return false }
            let x = min(width - 1, Int(p.x * Float(width))), y = min(height - 1, Int(p.y * Float(height)))
            return covered[y * width + x]
        }
        #expect(Double(shown.count) / Double(full.points.count) > 0.97)
        // …and with no warp, each pixel shows itself.
        let none = warp.map(amount: 0, step: 1)
        let center = try #require(none.points[40 * width + 100])
        #expect(abs(center.x * Float(width) - 100.5) < 0.5 && abs(center.y * Float(height) - 40.5) < 0.5)
    }

    // MARK: Options

    @Test func optionsStartAtLightroomsDefaultsAndAreRemembered() throws {
        let defaults = try #require(UserDefaults(suiteName: "PanoramaMergeTests-\(UUID().uuidString)"))
        let options = PanoramaMergeOptions.load(from: defaults)
        #expect(options == PanoramaMergeOptions())
        #expect(options.projection == .spherical && options.boundaryWarp == 0 && !options.autoCrop && options.autoSettings && !options.createsStack)
        var changed = options
        changed.projection = .cylindrical
        changed.boundaryWarp = 40
        changed.autoCrop = true
        changed.save(to: defaults)
        #expect(PanoramaMergeOptions.load(from: defaults) == changed)
    }

    @Test func fillEdgesStartsOffAndOlderSettingsStillLoad() throws {
        #expect(!PanoramaMergeOptions().fillEdges)
        // Saved before Fill Edges existed.
        let old = Data(#"{"projection":"cylindrical","boundaryWarp":40,"autoCrop":true,"autoSettings":false,"createsStack":true}"#.utf8)
        let options = try JSONDecoder().decode(PanoramaMergeOptions.self, from: old)
        #expect(options.projection == .cylindrical && options.boundaryWarp == 40 && options.autoCrop)
        #expect(!options.autoSettings && options.createsStack && !options.fillEdges)
        #expect(options.cropsToCovered)
        var filled = options
        filled.fillEdges = true
        #expect(!filled.cropsToCovered && filled.autoCrop, "Fill Edges turns Auto Crop off but keeps the choice")
        #expect(try JSONDecoder().decode(PanoramaMergeOptions.self, from: JSONEncoder().encode(filled)) == filled)
    }
}

@Suite("Panorama merge in the catalog", .serialized)
@MainActor
struct PanoramaCatalogTests {
    /// A referenced catalog holding a synthetic panorama, the photos in file name order.
    private struct Setup {
        let panorama: SyntheticPanorama
        let store: CatalogStore
        let ids: [NSManagedObjectID]
        var editing: PhotoEditing { PhotoEditing(store: store) }

        init(stops: [Double]? = nil) async throws {
            panorama = try SyntheticPanorama(stops: stops)
            store = try CatalogStore.inMemory(
                info: Fixtures.referencedInfo, packageURL: panorama.directory.url.appending(path: "Test.pixelloupe")
            )
            _ = try await ImportService(store: store).importPhotos(from: panorama.sources.map(\.url))
            let request = Photo.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "fileName", ascending: true)]
            ids = try store.viewContext.fetch(request).map(\.objectID)
        }

        func photo(_ id: NSManagedObjectID) -> Photo { store.viewContext.object(with: id) as! Photo }

        func merge(_ ids: [NSManagedObjectID]? = nil, options: PanoramaMergeOptions = PanoramaMergeOptions()) async throws -> (Photo, PanoramaMergeRunner.Result) {
            let ids = ids ?? self.ids
            let destination = try #require(editing.mergeDestination(for: ids, kind: .panorama))
            let result = try await PanoramaMergeRunner.run(
                sources: editing.photoMergeSources(ids), options: options, destination: destination,
                thumbnailDirectory: store.thumbnails.directory
            )
            let id = try #require(editing.addMergedPhoto(result.output, sources: ids, createsStack: options.createsStack))
            return (photo(id), result)
        }
    }

    @Test func panoramaJoinsTheCatalogBesideItsSources() async throws {
        let setup = try await Setup(stops: [0, 1, 1, 0])
        let first = setup.photo(setup.ids[0])
        first.tags.insert(Tag.findOrCreate(named: "Pool", in: setup.store.viewContext))
        var options = PanoramaMergeOptions()
        options.autoSettings = false
        let (merged, result) = try await setup.merge(options: options)
        #expect(result.mergedCount == 4 && result.photoCount == 4)
        #expect(merged.fileName == "PANO_0-Pano.dng")
        #expect(merged.fileURL.deletingLastPathComponent() == first.fileURL.deletingLastPathComponent())
        #expect(merged.folder == first.folder)
        // The earliest photo's details, as Lightroom's panoramas have.
        #expect(merged.captureDate == first.captureDate && merged.shutterSpeed == first.shutterSpeed)
        #expect(merged.cameraMake == "Canon" && merged.cameraModel == "EOS R5")
        #expect(Set(merged.tagNames) == ["Pool"])
        // Spherical: wider than the photos, a little shorter (it measures up and down in angle).
        #expect(merged.pixelWidth > Int32(setup.panorama.width * 3 / 2) && merged.pixelHeight > Int32(setup.panorama.height * 8 / 10))
        // Without Auto Settings or Auto Crop it starts at the defaults.
        #expect(merged.adjustments == PhotoAdjustments())
        #expect(FileManager.default.fileExists(atPath: setup.store.thumbnails.url(for: merged.id).path(percentEncoded: false)))
        #expect(try await setup.merge(options: options).0.fileName == "PANO_0-Pano-2.dng")
    }

    @Test func autoSettingsAndAutoCropAreDevelopSettings() async throws {
        let setup = try await Setup()
        var options = PanoramaMergeOptions()
        options.autoCrop = true
        let (merged, _) = try await setup.merge(options: options)
        let adjustments = merged.adjustments
        // Auto Settings is Develop's Auto (tone), not baked into the pixels…
        #expect(adjustments.light.isEnabled)
        // …and Auto Crop a crop that can be widened again: the DNG has the whole panorama.
        #expect(adjustments.crop.rect.width < 1 && adjustments.crop.rect.height < 1)
        #expect(adjustments.crop.aspect == .custom && !adjustments.crop.isAspectLocked)
        #expect(merged.isCropped)
    }

    @Test func fillEdgesLeavesTheMergeUncropped() async throws {
        let setup = try await Setup()
        var options = PanoramaMergeOptions()
        options.autoCrop = true
        options.fillEdges = true
        options.autoSettings = false
        let (merged, _) = try await setup.merge(options: options)
        #expect(!merged.isCropped)
        #expect(merged.adjustments.crop.rect == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func createStackPutsThePanoramaOnTopOfThePhotosInOrder() async throws {
        let setup = try await Setup()
        var options = PanoramaMergeOptions()
        options.createsStack = true
        options.autoSettings = false
        // Selected in another order, they still stack in the order they were taken.
        let (merged, _) = try await setup.merge(setup.ids.reversed(), options: options)
        let stack = try #require(merged.stack)
        #expect(stack.isCollapsed)
        #expect(stack.orderedPhotos.map(\.fileName) == ["PANO_0-Pano.dng", "PANO_0.dng", "PANO_1.dng", "PANO_2.dng", "PANO_3.dng"])
    }

    @Test func sheetShowsTheOptionsAndHowManyPhotosMerged() async throws {
        let setup = try await Setup()
        var options = PanoramaMergeOptions()
        options.projection = .cylindrical
        options.boundaryWarp = 30
        let sheet = PanoramaMergeSheetController(sources: setup.editing.photoMergeSources(setup.ids), options: options)
        let window = try #require(sheet.window)
        window.setContentSize(NSSize(width: 1080, height: 680))
        window.contentView?.layoutSubtreeIfNeeded()
        let well = sheet.previewWell.convert(sheet.previewWell.bounds, to: nil)
        let controls = sheet.autoCropCheckbox.convert(sheet.autoCropCheckbox.bounds, to: nil)
        #expect(well.width > 700 && well.height > 400, "\(well)")
        #expect(controls.minX > well.maxX)
        #expect(sheet.cylindricalButton.state == .on && sheet.sphericalButton.state == .off)
        #expect(sheet.boundaryWarpSlider.integerValue == 30 && sheet.boundaryWarpField.integerValue == 30)
        // Nothing to merge with until the photos are aligned.
        #expect(!sheet.mergeButton.isEnabled)
        for _ in 0..<600 where !sheet.mergeButton.isEnabled { try await Task.sleep(for: .milliseconds(100)) }
        #expect(sheet.mergeButton.isEnabled)
        #expect(sheet.statusLabel.stringValue == "All 4 photos merged")
        #expect(sheet.perspectiveButton.isEnabled && sheet.perspectiveNote.isHidden)
        // The synthetic camera has no lens profile: Lightroom's notice shows.
        #expect(!sheet.lensNoticeRow.isHidden)

        var finished: PanoramaMergeOptions?
        sheet.onFinish = { finished = $0 }
        sheet.sphericalButton.performClick(nil)
        sheet.autoCropCheckbox.performClick(nil)
        sheet.merge(nil)
        #expect(finished?.projection == .spherical && finished?.autoCrop == true && finished?.boundaryWarp == 30)
    }
}
