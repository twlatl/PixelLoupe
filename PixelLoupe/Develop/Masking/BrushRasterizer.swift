import Accelerate
import CoreImage
import os

/// Paints a brush mask's strokes into a gray matte the size of what is being rendered, so a brush is as
/// sharp in an export as on screen. Each stroke is a row of soft dabs along its points: within a stroke
/// the dabs build up by its flow, up to its density; the stroke then paints into (or erases from) the
/// strokes before it.
///
/// While painting, only the last stroke changes, so the matte of the strokes before it is cached and the
/// new stroke is drawn on a copy. The finished image is cached too, so a render that doesn't change the
/// brush (a slider edit) doesn't paint or convert anything.
nonisolated enum BrushRasterizer {
    /// The matte over `extent`, white where painted.
    static func image(for brush: PhotoAdjustments.BrushMask, extent: CGRect) -> CIImage? {
        let width = Int(extent.width.rounded(.up)), height = Int(extent.height.rounded(.up))
        guard width > 0, height > 0 else { return nil }
        let key = Key(strokes: brush.strokes, width: width, height: height)
        let image: CIImage
        if let cached = cachedImage(key) {
            image = cached
        } else {
            // Coverage is 0…1 by construction.
            var bytes = [UInt8](repeating: 0, count: width * height)
            vDSP.convertElements(of: vDSP.multiply(255, matte(for: brush, width: width, height: height)), to: &bytes, rounding: .towardNearestInteger)
            // The matte's row 0 is the bottom (unit coordinates) and a bitmap's is the top, so turn it over.
            image = CIImage(bitmapData: Data(bytes), bytesPerRow: width, size: CGSize(width: width, height: height), format: .L8, colorSpace: nil)
                .transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height)))
            store(image, for: key)
        }
        return image
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    /// Coverage 0…1 for each pixel of a `width` × `height` frame, rows from the bottom.
    static func matte(for brush: PhotoAdjustments.BrushMask, width: Int, height: Int) -> [Float] {
        let key = Key(strokes: brush.strokes, width: width, height: height)
        if let cached = cached(key) { return cached }
        var matte: [Float]
        let before = Key(strokes: brush.strokes.dropLast(), width: width, height: height)
        if let last = brush.strokes.last, let base = cached(before) {
            matte = base
            paint(last, into: &matte, width: width, height: height)
        } else {
            matte = [Float](repeating: 0, count: width * height)
            for (index, stroke) in brush.strokes.enumerated() {
                if index == brush.strokes.count - 1 { store(matte, for: before) }
                paint(stroke, into: &matte, width: width, height: height)
            }
        }
        store(matte, for: key)
        return matte
    }

    // MARK: - Painting

    static func paint(_ stroke: PhotoAdjustments.BrushStroke, into matte: inout [Float], width: Int, height: Int) {
        guard !stroke.points.isEmpty else { return }
        let radius = max(stroke.size * Double(max(width, height)), 0.5)
        let hard = radius * (1 - stroke.feather.clamped(to: 0...1))
        let flow = Float(stroke.flow.clamped(to: 0...1)), density = Float(stroke.density.clamped(to: 0...1))
        let dabs = dabCenters(stroke.points.map { CGPoint(x: $0.x * Double(width), y: $0.y * Double(height)) }, spacing: max(radius * 0.15, 0.5))

        // The pixels the stroke can touch.
        let minX = max(0, Int((dabs.map(\.x).min()! - radius).rounded(.down)))
        let maxX = min(width - 1, Int((dabs.map(\.x).max()! + radius).rounded(.up)))
        let minY = max(0, Int((dabs.map(\.y).min()! - radius).rounded(.down)))
        let maxY = min(height - 1, Int((dabs.map(\.y).max()! + radius).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return }
        let boxWidth = maxX - minX + 1
        var coverage = [Float](repeating: 0, count: boxWidth * (maxY - minY + 1))

        coverage.withUnsafeMutableBufferPointer { coverage in
            for dab in dabs {
                let x0 = max(minX, Int((dab.x - radius).rounded(.down))), x1 = min(maxX, Int((dab.x + radius).rounded(.up)))
                let y0 = max(minY, Int((dab.y - radius).rounded(.down))), y1 = min(maxY, Int((dab.y + radius).rounded(.up)))
                guard x0 <= x1, y0 <= y1 else { continue }
                for y in y0...y1 {
                    let dy = Double(y) + 0.5 - dab.y
                    let row = (y - minY) * boxWidth - minX
                    for x in x0...x1 {
                        let distance = (pow(Double(x) + 0.5 - dab.x, 2) + dy * dy).squareRoot()
                        guard distance < radius else { continue }
                        let falloff = distance <= hard ? 1 : smoothstep(1 - (distance - hard) / (radius - hard))
                        let added = flow * Float(falloff)
                        coverage[row + x] += added * (1 - coverage[row + x])
                    }
                }
            }
        }

        matte.withUnsafeMutableBufferPointer { matte in
            for y in minY...maxY {
                let row = (y - minY) * boxWidth - minX
                for x in minX...maxX {
                    let amount = min(coverage[row + x], density)
                    guard amount > 0 else { continue }
                    let index = y * width + x
                    if stroke.isErasing {
                        matte[index] *= 1 - amount
                    } else {
                        // Builds on what is there, but a stroke never takes a spot past its own density.
                        matte[index] = max(matte[index], min(matte[index] + amount * (1 - matte[index]), density))
                    }
                }
            }
        }
    }

    /// Dab centers every `spacing` along the polyline, starting at its first point.
    static func dabCenters(_ points: [CGPoint], spacing: Double) -> [CGPoint] {
        guard var previous = points.first else { return [] }
        var centers = [previous]
        var sinceLast = 0.0
        for point in points.dropFirst() {
            let length = hypot(point.x - previous.x, point.y - previous.y)
            var along = spacing - sinceLast
            while along <= length {
                let t = along / length
                centers.append(CGPoint(x: previous.x + (point.x - previous.x) * t, y: previous.y + (point.y - previous.y) * t))
                along += spacing
            }
            sinceLast = length - (along - spacing)
            previous = point
        }
        return centers
    }

    private static func smoothstep(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    // MARK: - Cache

    private struct Key: Hashable {
        var strokes: [PhotoAdjustments.BrushStroke]
        var width: Int
        var height: Int

        init(strokes: some Collection<PhotoAdjustments.BrushStroke>, width: Int, height: Int) {
            self.strokes = Array(strokes)
            self.width = width
            self.height = height
        }
    }

    private struct Entry {
        var key: Key
        var matte: [Float]
        var image: CIImage?
    }

    /// A few mattes (and their images), most recently used last: the strokes before the one being painted
    /// and all of them, at the size being rendered. Up to about a 36 MP photo at 1:1, so painting zoomed in
    /// stays quick; an export of a larger photo paints from scratch, once.
    private static let cache = OSAllocatedUnfairLock<[Entry]>(initialState: [])
    private static let cacheLimit = 3
    private static let cachedPixelLimit = 36_000_000

    private static func cached(_ key: Key) -> [Float]? {
        cache.withLock { entries in
            guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.matte
        }
    }

    private static func cachedImage(_ key: Key) -> CIImage? {
        cache.withLock { entries in entries.last { $0.key == key }?.image }
    }

    private static func store(_ matte: [Float], for key: Key) {
        guard key.width * key.height <= cachedPixelLimit else { return }
        cache.withLock { entries in
            entries.removeAll { $0.key == key }
            entries.append(Entry(key: key, matte: matte))
            if entries.count > cacheLimit { entries.removeFirst(entries.count - cacheLimit) }
        }
    }

    private static func store(_ image: CIImage, for key: Key) {
        cache.withLock { entries in
            if let index = entries.lastIndex(where: { $0.key == key }) { entries[index].image = image }
        }
    }
}
