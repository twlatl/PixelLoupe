import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Vision

/// What Assisted Culling knows about a photo (RAW-71), as stored on `Photo` (model v17).
///
/// Scores run 0–1; -1 means unknown. The eye scores are unknown when no face is big enough to count, and
/// focus is unknown when the photo could only be analyzed from its thumbnail (`focusPending`).
nonisolated struct CullingScores: Equatable, Sendable {
    var subjectFocus = -1.0
    /// The sharpest eyes among the faces counted: the photographer focuses on one of them.
    var eyeFocus = -1.0
    /// The least and most open eyes among the faces counted.
    var eyesOpenMin = -1.0
    var eyesOpenMax = -1.0
    var faceCount = 0
    var exposureIssue = false
    var misfire = false
    var document = false
    var quality = -1.0
    var focusPending = false

    /// Stores the scores on `photo` and its virtual copies, which share its file.
    func write(to photo: Photo) {
        for photo in photo.photosSharingFile {
            photo.cullVersion = CullingAnalyzer.version
            photo.cullSubjectFocus = subjectFocus
            photo.cullEyeFocus = eyeFocus
            photo.cullEyesOpenMin = eyesOpenMin
            photo.cullEyesOpenMax = eyesOpenMax
            photo.cullFaceCount = Int16(clamping: faceCount)
            photo.cullExposureIssue = exposureIssue
            photo.cullMisfire = misfire
            photo.cullDocument = document
            photo.cullQuality = quality
            photo.cullFocusPending = focusPending
        }
    }
}

/// Scores photos for Assisted Culling. Everything is measured on the unedited photo: Vision finds faces, the
/// subject and documents on a small render and reads eyes from a larger one, and the measures here judge exposure,
/// misfires and focus.
///
/// Focus is measured at ``focusLongEdge`` whatever the original's size, so a photo scores the same from its
/// original as from its Smart Preview (which is that size), and "sharp" means sharp on a large display.
nonisolated enum CullingAnalyzer {
    /// Bump when the scoring changes: photos with an older version count as unanalyzed and are scored again.
    static let version: Int16 = 1
    /// The long edge of the render faces, exposure and misfires are judged on.
    static let overviewLongEdge: CGFloat = 1024
    static let focusLongEdge: CGFloat = 2560
    /// Faces narrower than this fraction of the frame (people in the background) aren't counted.
    static let minimumFaceWidth = 0.03

    // MARK: Thresholds (tuned against real RAW files; see docs/design/RAW-71-assisted-culling.md)

    /// Sharpness (``sharpness(_:tile:)``) that scores 0 and 1.
    static let softSharpness = 0.25
    static let crispSharpness = 0.85
    /// Eye aspect ratio (height / width of the eye outline) for fully closed and fully open eyes.
    static let closedEyeRatio = 0.07
    static let openEyeRatio = 0.15
    /// More than this fraction of the frame at black or white is an exposure issue, as is a mean far from mid-grey.
    static let maximumShadowClipping = 0.30
    static let maximumHighlightClipping = 0.15
    static let meanBrightnessRange = 0.12...0.85
    /// A frame with less contrast than this, darker overall, or with nothing sharp in its subject
    /// (``sharpness(_:tile:)`` at ``focusLongEdge``) is a misfire. Shallow depth of field measures 0.55 and up.
    static let misfireContrast = 0.035
    static let misfireBrightness = 0.04
    static let misfireSharpness = 0.3
    /// A utility image (Vision's term: screenshots, receipts, product shots…) is a document when it has this many
    /// lines of text covering this fraction of it.
    static let documentLines = 3
    static let documentTextCoverage = 0.05

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Analyzes the photo at `location`, or only its thumbnail (at `thumbnail`) when neither the original nor a
    /// Smart Preview can be read. Returns nil when there's nothing to analyze.
    @concurrent
    static func analyze(_ location: PhotoSourceLocation, thumbnail: URL) async -> CullingScores? {
        if let source = DevelopSource.open(location) {
            let overview = source.image(with: .default, scale: source.scale(toFit: overviewLongEdge))
            guard let overviewImage = context.createCGImage(overview, from: overview.extent) else { return nil }
            let detail = source.image(with: .default, scale: source.scale(toFit: focusLongEdge))
            return await analyze(overview: overviewImage, detail: detail)
        }
        guard let source = CGImageSourceCreateWithURL(thumbnail as CFURL, nil),
              let thumbnail = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return await analyze(overview: thumbnail, detail: nil)
    }

    /// Scores a photo from `overview`, a small render, and `detail`, the same photo at ``focusLongEdge`` (or as
    /// large as there is), which faces' eyes and focus are measured on. Without `detail` (only a thumbnail to go
    /// on), eyes are read from `overview` and focus is left to be measured.
    static func analyze(overview: CGImage, detail: CIImage?) async -> CullingScores {
        var scores = CullingScores()
        let stats = GrayPixels(overview).statistics()
        scores.exposureIssue = isExposureIssue(stats)

        let faces = await faces(in: overview, detail: detail ?? CIImage(cgImage: overview))
        scores.faceCount = faces.count
        if let least = faces.map(\.openness).min(), let most = faces.map(\.openness).max() {
            scores.eyesOpenMin = least
            scores.eyesOpenMax = most
        }
        if let detail {
            if !faces.isEmpty {
                scores.eyeFocus = faces.map { focusScore(of: detail, in: $0.eyes, tile: 16) }.max() ?? -1
            }
            let subjectSharpness = sharpness(of: detail, in: await subject(in: overview), tile: 32)
            scores.subjectFocus = subjectSharpness.map(focusScore) ?? -1
            // Blur all over shows in the subject; at overview size every frame has a few crisp edges.
            scores.misfire = isMisfire(stats, subjectSharpness: subjectSharpness)
        } else {
            scores.misfire = isMisfire(stats, subjectSharpness: nil)
            scores.focusPending = true
        }

        if let aesthetics = try? await CalculateImageAestheticsScoresRequest().perform(on: overview) {
            if aesthetics.isUtility {
                scores.document = await isDocument(overview)
            }
            // overallScore runs -1…1.
            scores.quality = min(1, max(0, (Double(aesthetics.overallScore) + 1) / 2))
        }
        return scores
    }

    /// Whether `image`, a utility image, has enough text to be a document rather than, say, a product shot.
    static func isDocument(_ image: CGImage) async -> Bool {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .fast
        let lines = (try? await request.perform(on: image)) ?? []
        let coverage = lines.reduce(0) { $0 + Double($1.boundingBox.width * $1.boundingBox.height) }
        return lines.count >= documentLines && coverage >= documentTextCoverage
    }

    // MARK: Faces and eyes

    /// A face counted for culling.
    struct Face {
        /// How open its eyes are, 0 (closed) to 1 (open).
        var openness: Double
        /// Around its eyes, as a fraction of the frame with the origin at the bottom left (Vision's and Core
        /// Image's).
        var eyes: CGRect
    }

    /// The faces in the photo wide enough to count whose eyes can be made out. Faces are found on `overview`;
    /// their eyes are read from `detail`, since at overview size a small face's eye outlines collapse.
    static func faces(in overview: CGImage, detail: CIImage) async -> [Face] {
        let found = (try? await DetectFaceRectanglesRequest().perform(on: overview)) ?? []
        let extent = detail.extent
        var faces: [Face] = []
        for face in found where face.boundingBox.width >= minimumFaceWidth {
            let box = face.boundingBox.cgRect
            let around = box.insetBy(dx: -box.width * 0.3, dy: -box.height * 0.3)
            let crop = CGRect(
                x: extent.minX + around.minX * extent.width, y: extent.minY + around.minY * extent.height,
                width: around.width * extent.width, height: around.height * extent.height
            ).integral.intersection(extent)
            guard !crop.isEmpty, let image = context.createCGImage(detail, from: crop),
                  let landmarks = ((try? await DetectFaceLandmarksRequest().perform(on: image)) ?? [])
                    .max(by: { $0.boundingBox.width < $1.boundingBox.width })?.landmarks
            else { continue }
            let size = CGSize(width: image.width, height: image.height)
            let eyes = [landmarks.leftEye, landmarks.rightEye].map { $0.pointsInImageCoordinates(size) }
            let ratios = eyes.compactMap(eyeAspectRatio)
            guard !ratios.isEmpty else { continue }
            // Back to fractions of the frame.
            let outline = eyes.joined().reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            let inFrame = CGRect(
                x: (crop.minX - extent.minX + outline.minX) / extent.width, y: (crop.minY - extent.minY + outline.minY) / extent.height,
                width: outline.width / extent.width, height: outline.height / extent.height
            )
            // Lashes and lids are what show focus; take in some of the face around the eyes.
            let region = inFrame.insetBy(dx: -inFrame.width * 0.15, dy: -max(inFrame.height, inFrame.width * 0.2))
            faces.append(Face(openness: openness(eyeAspectRatio: ratios.reduce(0, +) / Double(ratios.count)), eyes: region))
        }
        return faces
    }

    /// Height over width of an eye outline in pixels; nil when the outline has collapsed.
    static func eyeAspectRatio(_ points: [CGPoint]) -> Double? {
        guard points.count >= 4 else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let width = xs.max()! - xs.min()!, height = ys.max()! - ys.min()!
        guard width >= 2 else { return nil }
        return Double(height / width)
    }

    static func openness(eyeAspectRatio ratio: Double) -> Double {
        min(1, max(0, (ratio - closedEyeRatio) / (openEyeRatio - closedEyeRatio)))
    }

    // MARK: Focus

    /// The main subject, as a fraction of the frame with the origin at the bottom left; the middle of the frame
    /// when nothing stands out.
    static func subject(in overview: CGImage) async -> CGRect {
        let salient = (try? await GenerateAttentionBasedSaliencyImageRequest().perform(on: overview))?.salientObjects ?? []
        let subject = salient.map { $0.boundingBox.cgRect }.reduce(CGRect.null) { $0.union($1) }
        return subject.isNull ? CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5) : subject
    }

    /// The focus score (0–1) of `region` (a fraction of the frame) of `image`; -1 (unknown) when it can't be judged.
    static func focusScore(of image: CIImage, in region: CGRect, tile: Int) -> Double {
        sharpness(of: image, in: region, tile: tile).map(focusScore) ?? -1
    }

    /// ``sharpness(_:tile:)`` of `region` (a fraction of the frame) of `image`; nil when the region is too small or
    /// has no edges.
    static func sharpness(of image: CIImage, in region: CGRect, tile: Int) -> Double? {
        let extent = image.extent
        var rect = CGRect(
            x: extent.minX + region.minX * extent.width, y: extent.minY + region.minY * extent.height,
            width: region.width * extent.width, height: region.height * extent.height
        ).integral.intersection(extent)
        // A big subject is judged on its middle, which is plenty and keeps the render small.
        let limit: CGFloat = 1024
        if rect.width > limit { rect = rect.insetBy(dx: (rect.width - limit) / 2, dy: 0).integral }
        if rect.height > limit { rect = rect.insetBy(dx: 0, dy: (rect.height - limit) / 2).integral }
        guard rect.width >= 8, rect.height >= 8, let pixels = GrayPixels(image.cropped(to: rect), context: context) else { return nil }
        return sharpness(pixels, tile: tile)
    }

    static func focusScore(sharpness: Double) -> Double {
        min(1, max(0, (sharpness - softSharpness) / (crispSharpness - softSharpness)))
    }

    /// How crisp the edges in `pixels` are, whatever their contrast: the mean absolute Laplacian over the mean
    /// gradient, which falls as edges widen. Measured after a light blur (so sensor noise doesn't pass for
    /// detail) in `tile`-pixel squares, taking the crispest tenth of those with edges: smooth areas have no edges
    /// to judge, and with shallow depth of field only a sliver of the subject is meant to be sharp. Nil when there are
    /// no edges: a cartoon's eyes, a clear sky.
    static func sharpness(_ pixels: GrayPixels, tile: Int) -> Double? {
        let crispness = pixels.blurred().edgeMeasures(tile: tile)
            .filter { $0.gradient >= minimumEdgeGradient }.map { $0.laplacian / $0.gradient }
        let crispest = crispness.sorted(by: >).prefix(max(1, crispness.count / 10))
        guard !crispest.isEmpty else { return nil }
        return crispest.reduce(0, +) / Double(crispest.count)
    }

    /// Below this mean gradient a tile has no edges worth judging (sensor noise stays under it).
    static let minimumEdgeGradient = 0.015


    // MARK: Exposure and misfires

    static func isExposureIssue(_ stats: GrayPixels.Statistics) -> Bool {
        stats.shadowClipping > maximumShadowClipping || stats.highlightClipping > maximumHighlightClipping
            || !meanBrightnessRange.contains(stats.mean)
    }

    /// Whether a frame is a misfire; `subjectSharpness` is nil when it couldn't be measured.
    static func isMisfire(_ stats: GrayPixels.Statistics, subjectSharpness: Double?) -> Bool {
        stats.standardDeviation < misfireContrast || stats.mean < misfireBrightness
            || (subjectSharpness ?? .infinity) < misfireSharpness
    }
}

/// A greyscale image as brightness values 0–1, for the measures above.
nonisolated struct GrayPixels {
    let width: Int
    let height: Int
    var values: [Float]

    init(width: Int, height: Int, values: [Float]) {
        precondition(values.count == width * height)
        self.width = width
        self.height = height
        self.values = values
    }

    init(_ image: CGImage) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        self.init(width: width, height: height, values: bytes.map { Float($0) / 255 })
    }

    init?(_ image: CIImage, context: CIContext) {
        let extent = image.extent
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        context.render(
            image, toBitmap: &bytes, rowBytes: width, bounds: extent, format: .L8,
            colorSpace: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)
        )
        self.init(width: width, height: height, values: bytes.map { Float($0) / 255 })
    }

    struct Statistics {
        var mean: Double
        var standardDeviation: Double
        /// Fractions of the pixels at black and at white.
        var shadowClipping: Double
        var highlightClipping: Double
    }

    func statistics() -> Statistics {
        let count = Double(max(values.count, 1))
        var sum = 0.0, squares = 0.0, shadows = 0, highlights = 0
        for value in values {
            sum += Double(value)
            squares += Double(value * value)
            if value <= 2 / 255 { shadows += 1 } else if value >= 253 / 255 { highlights += 1 }
        }
        let mean = sum / count
        return Statistics(
            mean: mean, standardDeviation: max(0, squares / count - mean * mean).squareRoot(),
            shadowClipping: Double(shadows) / count, highlightClipping: Double(highlights) / count
        )
    }

    /// A 3×3 binomial blur; edge pixels are left as they are.
    func blurred() -> GrayPixels {
        guard width >= 3, height >= 3 else { return self }
        var out = values
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let above = values[i - width - 1] + 2 * values[i - width] + values[i - width + 1]
                let row = 2 * values[i - 1] + 4 * values[i] + 2 * values[i + 1]
                let below = values[i + width - 1] + 2 * values[i + width] + values[i + width + 1]
                out[i] = (above + row + below) / 16
            }
        }
        return GrayPixels(width: width, height: height, values: out)
    }

    /// Mean gradient magnitude and mean absolute Laplacian of each `tile`×`tile` square of the interior.
    func edgeMeasures(tile: Int) -> [(gradient: Double, laplacian: Double)] {
        guard width >= 3, height >= 3, tile > 0 else { return [] }
        let columns = max(1, (width - 2) / tile), rows = max(1, (height - 2) / tile)
        var gradients = [Double](repeating: 0, count: columns * rows), laplacians = gradients, counts = gradients
        for y in 1..<(height - 1) {
            let row = min(rows - 1, (y - 1) / tile)
            for x in 1..<(width - 1) {
                let i = y * width + x
                let gx = (values[i + 1] - values[i - 1]) / 2, gy = (values[i + width] - values[i - width]) / 2
                let laplacian = values[i - 1] + values[i + 1] + values[i - width] + values[i + width] - 4 * values[i]
                let cell = row * columns + min(columns - 1, (x - 1) / tile)
                gradients[cell] += Double((gx * gx + gy * gy).squareRoot())
                laplacians[cell] += Double(abs(laplacian))
                counts[cell] += 1
            }
        }
        return (0..<gradients.count).compactMap { cell in
            counts[cell] > 0 ? (gradients[cell] / counts[cell], laplacians[cell] / counts[cell]) : nil
        }
    }
}
