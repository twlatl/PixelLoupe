import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Crop aspect choices, in Lightroom's order.
nonisolated enum CropAspect: Codable, Equatable, Hashable, Sendable {
    /// The camera's recorded crop. PixelLoupe doesn't read in-camera crops yet, so this matches Original.
    case asShot
    case original
    /// Free-form; the aspect isn't constrained.
    case custom
    /// A fixed ratio, stored landscape (width ≥ height); applied in the crop's current orientation.
    case ratio(width: Double, height: Double)

    struct MenuItem {
        var aspect: CropAspect?
        var title: String
        var detail: String?
    }

    /// The Aspect menu; `nil` aspects are separators or "Enter Custom…".
    static let menu: [MenuItem?] = [
        MenuItem(aspect: .asShot, title: "As Shot"),
        MenuItem(aspect: .original, title: "Original"),
        MenuItem(aspect: .custom, title: "Custom"),
        nil,
        MenuItem(aspect: .ratio(width: 1, height: 1), title: "1 x 1"),
        MenuItem(aspect: .ratio(width: 5, height: 4), title: "4 x 5  /  8 x 10"),
        MenuItem(aspect: .ratio(width: 11, height: 8.5), title: "8.5 x 11"),
        MenuItem(aspect: .ratio(width: 7, height: 5), title: "5 x 7"),
        MenuItem(aspect: .ratio(width: 3, height: 2), title: "2 x 3  /  4 x 6"),
        nil,
        MenuItem(aspect: .ratio(width: 4, height: 3), title: "4 x 3", detail: "1024 x 768"),
        MenuItem(aspect: .ratio(width: 16, height: 9), title: "16 x 9", detail: "1920 x 1080"),
        MenuItem(aspect: .ratio(width: 16, height: 10), title: "16 x 10", detail: "1280 x 800"),
        nil,
    ]

    var title: String {
        switch self {
        case .asShot: "As Shot"
        case .original: "Original"
        case .custom: "Custom"
        case .ratio(let width, let height):
            Self.menu.compactMap { $0 }.first { $0.aspect == self }?.title ?? "\(Self.format(height)) x \(Self.format(width))"
        }
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%g", value)
    }

    /// Width ÷ height in pixels for a photo of `imageSize`, landscape; `nil` when unconstrained.
    func landscapeRatio(imageSize: CGSize) -> Double? {
        switch self {
        case .asShot, .original:
            guard imageSize.width > 0, imageSize.height > 0 else { return nil }
            let ratio = Double(imageSize.width / imageSize.height)
            return max(ratio, 1 / ratio)
        case .custom:
            return nil
        case .ratio(let width, let height):
            guard width > 0, height > 0 else { return nil }
            return max(width / height, height / width)
        }
    }
}

/// Crop & Straighten math. The *frame* is the photo's full size, centered on the photo; the photo is
/// rotated by the straightening angle inside it, and the crop rectangle is in unit coordinates of
/// the frame (origin bottom-left).
nonisolated enum CropGeometry {
    static let angleRange: ClosedRange<Double> = -45...45
    static let fullRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    static let minimumSize: CGFloat = 0.02

    /// Whether a unit-frame point shows photo (rather than an empty corner) after rotating by `angle`.
    static func isInsidePhoto(_ point: CGPoint, angle: Double, imageSize: CGSize) -> Bool {
        let radians = -angle * .pi / 180
        let x = (point.x - 0.5) * imageSize.width, y = (point.y - 0.5) * imageSize.height
        let rx = x * cos(radians) - y * sin(radians), ry = x * sin(radians) + y * cos(radians)
        return abs(rx) <= imageSize.width / 2 + 0.01 && abs(ry) <= imageSize.height / 2 + 0.01
    }

    static func isInsidePhoto(_ rect: CGRect, angle: Double, imageSize: CGSize) -> Bool {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
            .allSatisfy { isInsidePhoto($0, angle: angle, imageSize: imageSize) }
    }

    /// Shrinks `rect` about its center (keeping its aspect) until it fits inside the rotated photo,
    /// then pulls it inside the frame.
    static func fit(_ rect: CGRect, angle: Double, imageSize: CGSize) -> CGRect {
        var rect = clampToFrame(rect)
        guard !isInsidePhoto(rect, angle: angle, imageSize: imageSize) else { return rect }
        // Try moving it toward the center first, then shrink.
        var low: CGFloat = 0, high: CGFloat = 1
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for _ in 0..<30 {
            let scale = (low + high) / 2
            let candidate = CGRect(
                x: center.x - rect.width * scale / 2, y: center.y - rect.height * scale / 2,
                width: rect.width * scale, height: rect.height * scale
            )
            if isInsidePhoto(candidate, angle: angle, imageSize: imageSize) { low = scale } else { high = scale }
        }
        if low > 0.001 {
            rect = CGRect(
                x: center.x - rect.width * low / 2, y: center.y - rect.height * low / 2,
                width: rect.width * low, height: rect.height * low
            )
            return rect
        }
        // The center itself is outside the photo: recenter and fit again.
        return fit(rect.offsetBy(dx: 0.5 - rect.midX, dy: 0.5 - rect.midY), angle: angle, imageSize: imageSize)
    }

    static func clampToFrame(_ rect: CGRect) -> CGRect {
        let width = min(max(rect.width, minimumSize), 1), height = min(max(rect.height, minimumSize), 1)
        return CGRect(
            x: rect.minX.clamped(to: 0...(1 - width)), y: rect.minY.clamped(to: 0...(1 - height)),
            width: width, height: height
        )
    }

    /// The largest centered crop with `ratio` (width ÷ height in pixels) that fits the rotated photo.
    static func largestRect(ratio: Double?, portrait: Bool, angle: Double, imageSize: CGSize) -> CGRect {
        var rect = fullRect
        if let ratio, imageSize.width > 0, imageSize.height > 0 {
            let pixelRatio = portrait ? 1 / ratio : ratio
            let frameRatio = Double(imageSize.width / imageSize.height)
            if pixelRatio > frameRatio {
                rect.size.height = CGFloat(frameRatio / pixelRatio)
            } else {
                rect.size.width = CGFloat(pixelRatio / frameRatio)
            }
            rect.origin = CGPoint(x: (1 - rect.width) / 2, y: (1 - rect.height) / 2)
        }
        return fit(rect, angle: angle, imageSize: imageSize)
    }

    /// Whether `rect` is taller than wide in pixels.
    static func isPortrait(_ rect: CGRect, imageSize: CGSize) -> Bool {
        rect.height * imageSize.height > rect.width * imageSize.width
    }

    /// Resizes `rect` so its pixel aspect is `pixelRatio` (width ÷ height), anchored at `anchor`.
    static func constrain(_ rect: CGRect, toPixelRatio pixelRatio: Double, imageSize: CGSize, anchor: CGPoint) -> CGRect {
        let frameRatio = Double(imageSize.width / imageSize.height)
        let unitRatio = CGFloat(pixelRatio / frameRatio)   // width ÷ height in unit coordinates
        var width = rect.width, height = rect.height
        if width / height > unitRatio { width = height * unitRatio } else { height = width / unitRatio }
        let x = anchor.x == rect.maxX ? rect.maxX - width : (anchor.x == rect.midX ? rect.midX - width / 2 : rect.minX)
        let y = anchor.y == rect.maxY ? rect.maxY - height : (anchor.y == rect.midY ? rect.midY - height / 2 : rect.minY)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Angle (degrees) that levels a line drawn from `start` to `end` in the photo's pixel space:
    /// near-horizontal lines become horizontal, near-vertical lines vertical.
    static func straighteningAngle(from start: CGPoint, to end: CGPoint) -> Double? {
        let dx = Double(end.x - start.x), dy = Double(end.y - start.y)
        guard hypot(dx, dy) > 1 else { return nil }
        var degrees = atan2(dy, dx) * 180 / .pi
        // Fold to the nearest horizontal or vertical axis.
        while degrees > 45 { degrees -= 90 }
        while degrees < -45 { degrees += 90 }
        return (-degrees).clamped(to: angleRange)
    }
}

/// How the pipeline applies Crop & Straighten.
nonisolated enum CropRendering: Sendable {
    /// Straightened and cropped: the finished photo.
    case cropped
    /// Straightened only, uncropped, so the crop tool can show the whole photo around the crop.
    case straightenedOnly
}

nonisolated enum CropRenderer {
    /// Rotates `image` about the center of `frame` by the crop's angle, then (for `.cropped`)
    /// crops to the crop rectangle and moves the result to the origin.
    static func apply(_ crop: PhotoAdjustments.Crop, to image: CIImage, frame: CGRect, rendering: CropRendering) -> CIImage {
        guard crop.isActive else { return image }
        var result = image
        if crop.angle != 0 {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let rotation = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: crop.angle * .pi / 180)
                .translatedBy(x: -center.x, y: -center.y)
            result = result.transformed(by: rotation)
        }
        guard rendering == .cropped else { return result }
        let cropRect = CGRect(
            x: frame.minX + crop.rect.minX * frame.width, y: frame.minY + crop.rect.minY * frame.height,
            width: crop.rect.width * frame.width, height: crop.rect.height * frame.height
        ).integral
        return result
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
    }
}

/// Finds the angle that levels a photo, for Crop & Straighten's Auto.
nonisolated enum HorizonDetector {
    /// An image handed to the detector off the main thread (CIImage is an immutable recipe).
    struct Input: @unchecked Sendable {
        let image: CIImage
    }

    /// The straightening angle (degrees, counterclockwise positive) that levels the photo, or nil
    /// if it has nothing to level by. Prefers the photo's dominant straight edges (buildings,
    /// interiors, horizons), which measure tilt directly; falls back to Vision's horizon detection,
    /// but only for small corrections, since on photos without a real horizon it often guesses
    /// several degrees off.
    @concurrent
    static func straighteningAngle(for input: Input) async -> Double? {
        if let angle = edgeAngle(input.image) { return angle }
        guard let angle = visionHorizonAngle(input.image), abs(angle) <= maximumVisionAngle else { return nil }
        return angle
    }

    /// The largest Vision horizon correction trusted without straight edges to back it up.
    static let maximumVisionAngle = 5.0

    /// Vision reports the correcting rotation directly.
    static func visionHorizonAngle(_ image: CIImage) -> Double? {
        let request = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(ciImage: image)
        guard (try? handler.perform([request])) != nil, let horizon = request.results?.first else { return nil }
        return Double(horizon.angle) * 180 / .pi
    }

    /// Levels the photo by its long straight lines: building edges, rooflines, door frames,
    /// horizons. Returns nil when the photo has none, or they don't agree on a tilt.
    static func edgeAngle(_ image: CIImage, maxTilt: Double = 20) -> Double? {
        guard let estimate = edgeEstimate(image, maxTilt: maxTilt),
              estimate.share >= minimumShare, estimate.support >= minimumSupport else { return nil }
        return estimate.angle
    }

    /// The fraction of all straight-line length that must agree on the tilt. Tuned on real photos:
    /// buildings, interiors and street scenes clear it, while trees and rock don't.
    static let minimumShare = 0.3
    /// How much agreeing line length, as a fraction of the longer image side, makes a reliable
    /// answer (one short line isn't enough).
    static let minimumSupport = 0.2

    /// The dominant tilt's correction, from the photo's long straight lines. `share` is the
    /// fraction of all line length that agrees with it; `support` is that agreeing length as a
    /// fraction of the image's longer side.
    ///
    /// Edge pixels within `maxTilt` of level or plumb vote, Hough-style, for the lines through them
    /// (only at angles near their own gradient direction). Lines are the accumulator's peaks, so
    /// only edges that line up over a distance count: texture such as paving, foliage or crowds
    /// contributes thousands of short edges at every angle, but few lines. The answer is the tilt
    /// the most line length agrees on; lines that converge with perspective spread out and don't
    /// outvote a set of parallel ones.
    static func edgeEstimate(_ image: CIImage, maxTilt: Double = 20) -> (angle: Double, share: Double, support: Double)? {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return nil }
        // Work on a small grayscale copy: plenty for line directions, and fast.
        let scale = min(1, 512 / max(extent.width, extent.height))
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // A light blur before measuring gradients: pixel staircases along hard edges otherwise pull
        // the measured directions toward horizontal and vertical.
        let small = scaled.clampedToExtent()
            .applyingGaussianBlur(sigma: 1.5)
            .cropped(to: scaled.extent)
        // Only whole pixels: a partly covered last row or column (scaling rarely lands on whole
        // pixels) would read as a strong, perfectly level edge along the image border.
        let width = Int((extent.width * scale).rounded(.down)), height = Int((extent.height * scale).rounded(.down))
        guard width > 8, height > 8 else { return nil }
        var gray = [Float](repeating: 0, count: width * height)
        PhotoRenderer.context.render(
            small, toBitmap: &gray, rowBytes: width * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .Rf, colorSpace: nil
        )

        // Accumulators over (tilt in 0.1° bins, distance from the center in 1-pixel bins), one for
        // near-horizontal lines and one for near-vertical lines.
        let binsPerDegree = 10.0
        let tiltBins = Int(maxTilt * 2 * binsPerDegree) + 1
        let maxRho = Int((hypot(Double(width), Double(height)) / 2).rounded(.up)) + 1
        let rhoBins = maxRho * 2 + 1
        var accumulators = [[Int32]](repeating: [Int32](repeating: 0, count: tiltBins * rhoBins), count: 2)
        // Line direction for each bin and family: tilt (horizontal) or 90° + tilt (vertical).
        // A point (x, y) lies on the line at signed distance -x·sin + y·cos from the center.
        let trig: [[(sin: Double, cos: Double)]] = (0..<2).map { family in
            (0..<tiltBins).map { bin in
                let radians = (Double(bin) / binsPerDegree - maxTilt + (family == 1 ? 90 : 0)) * .pi / 180
                return (sin(radians), cos(radians))
            }
        }
        // Scharr gradients (more direction-accurate than Sobel). Rows from CIContext bitmaps run
        // top to bottom, so gy is flipped to keep counterclockwise positive.
        var gxs = [Float](repeating: 0, count: width * height), gys = gxs, magnitudes = gxs
        for row in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                func p(_ dx: Int, _ dy: Int) -> Float { gray[(row + dy) * width + (x + dx)] }
                let gx = 3 * (p(1, -1) + p(1, 1)) + 10 * p(1, 0) - 3 * (p(-1, -1) + p(-1, 1)) - 10 * p(-1, 0)
                let gy = 3 * (p(-1, -1) + p(1, -1)) + 10 * p(0, -1) - 3 * (p(-1, 1) + p(1, 1)) - 10 * p(0, 1)
                let i = row * width + x
                gxs[i] = gx
                gys[i] = gy
                magnitudes[i] = gx * gx + gy * gy
            }
        }

        // Each edge pixel votes within this many bins of its own measured tilt.
        let spread = Int(1.5 * binsPerDegree)
        let border = 2
        let centerX = Double(width) / 2, centerY = Double(height) / 2
        for row in border..<(height - border) {
            for x in border..<(width - border) {
                let i = row * width + x
                let magnitude = magnitudes[i]
                guard magnitude > 0.2 else { continue }
                let gx = gxs[i], gy = gys[i]
                // Thin edges to their sharpest pixel (non-maximum suppression across the edge):
                // a blurred edge is several pixels thick, and a slightly tilted line through that
                // band would collect as many votes as the true one.
                let stepX = abs(gx) * 2.414 < abs(gy) ? 0 : (gx > 0 ? 1 : -1)
                let stepY = abs(gy) * 2.414 < abs(gx) ? 0 : (gy > 0 ? -1 : 1)
                let ahead = magnitudes[i + stepY * width + stepX], behind = magnitudes[i - stepY * width - stepX]
                guard magnitude >= ahead, magnitude > behind else { continue }
                // An edge runs perpendicular to its gradient; fold its direction to ±45° from level.
                var direction = atan2(Double(gy), Double(gx)) * 180 / .pi + 90
                direction = direction.truncatingRemainder(dividingBy: 180)
                if direction > 90 { direction -= 180 } else if direction <= -90 { direction += 180 }
                let family = abs(direction) <= 45 ? 0 : 1
                let tilt = family == 0 ? direction : (direction > 0 ? direction - 90 : direction + 90)
                guard abs(tilt) <= maxTilt + 1.5 else { continue }
                let center = Int(((tilt + maxTilt) * binsPerDegree).rounded())
                let px = Double(x) - centerX, py = centerY - Double(row)
                for bin in max(0, center - spread)...min(tiltBins - 1, center + spread) {
                    let (s, c) = trig[family][bin]
                    let rho = Int((-px * s + py * c).rounded()) + maxRho
                    accumulators[family][bin * rhoBins + rho] += 1
                }
            }
        }

        // Lines: accumulator peaks at least `minimumLength` pixels long that are the strongest
        // within ±1° and ±3 pixels.
        let minimumLength = Int32(Double(max(width, height)) * 0.08)
        let tiltWindow = Int(binsPerDegree), rhoWindow = 3
        var lines: [(tilt: Double, length: Double)] = []
        for accumulator in accumulators {
            for bin in 0..<tiltBins {
                for rho in 0..<rhoBins {
                    let votes = accumulator[bin * rhoBins + rho]
                    guard votes >= minimumLength else { continue }
                    var isPeak = true
                    search: for b in max(0, bin - tiltWindow)...min(tiltBins - 1, bin + tiltWindow) {
                        for r in max(0, rho - rhoWindow)...min(rhoBins - 1, rho + rhoWindow) {
                            let other = accumulator[b * rhoBins + r]
                            // Ties go to the first cell, so a flat-topped peak counts once.
                            if other > votes || (other == votes && (b, r) < (bin, rho)) {
                                isPeak = false
                                break search
                            }
                        }
                    }
                    if isPeak { lines.append((Double(bin) / binsPerDegree - maxTilt, Double(votes))) }
                }
            }
        }
        let total = lines.reduce(0) { $0 + $1.length }
        guard total > 0 else { return nil }

        // The tilt the most line length agrees on, within ±0.5°, refined to their weighted mean.
        func agreeing(with tilt: Double) -> [(tilt: Double, length: Double)] {
            lines.filter { abs($0.tilt - tilt) <= 0.5 }
        }
        guard let best = lines.max(by: {
            agreeing(with: $0.tilt).reduce(0) { $0 + $1.length } < agreeing(with: $1.tilt).reduce(0) { $0 + $1.length }
        }) else { return nil }
        let support = agreeing(with: best.tilt)
        let length = support.reduce(0) { $0 + $1.length }
        let tilt = support.reduce(0) { $0 + $1.tilt * $1.length } / length
        let correction = -tilt
        return (abs(correction) < 0.05 ? 0 : correction, length / total, length / Double(max(width, height)))
    }
}
