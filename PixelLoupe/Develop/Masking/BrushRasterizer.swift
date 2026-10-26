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
        let density = Float(stroke.density.clamped(to: 0...1))
        let dabs = dabCenters(stroke.points.map { CGPoint(x: $0.x * Double(width), y: $0.y * Double(height)) }, spacing: max(radius * 0.15, 0.5))

        // The pixels the stroke can touch.
        let minX = max(0, Int((dabs.map(\.x).min()! - radius).rounded(.down)))
        let maxX = min(width - 1, Int((dabs.map(\.x).max()! + radius).rounded(.up)))
        let minY = max(0, Int((dabs.map(\.y).min()! - radius).rounded(.down)))
        let maxY = min(height - 1, Int((dabs.map(\.y).max()! + radius).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return }
        let boxWidth = maxX - minX + 1, boxHeight = maxY - minY + 1
        var coverage = [Float](repeating: 0, count: boxWidth * boxHeight)

        // The dabs, drawn by Core Graphics (optimized even in a debug build) into a linear float gray
        // bitmap: drawing white at the flow's opacity over what is there is `c + flow × (1 − c)`, so dabs
        // build up as they overlap.
        let space = CGColorSpace(name: CGColorSpace.linearGray)!
        guard let gradient = dabGradient(feather: stroke.feather, flow: stroke.flow, space: space) else { return }
        coverage.withUnsafeMutableBytes { bytes in
            let info = CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            guard let context = CGContext(data: bytes.baseAddress, width: boxWidth, height: boxHeight, bitsPerComponent: 32,
                                          bytesPerRow: boxWidth * 4, space: space, bitmapInfo: info) else { return }
            for dab in dabs {
                let center = CGPoint(x: dab.x - Double(minX), y: dab.y - Double(minY))
                context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
            }
        }

        // Onto the matte, a row at a time with vDSP. The bitmap's row 0 is its top.
        var amount = [Float](repeating: 0, count: boxWidth), scratch = [Float](repeating: 0, count: boxWidth)
        var zero: Float = 0, ceiling = density
        let n = vDSP_Length(boxWidth)
        matte.withUnsafeMutableBufferPointer { matte in
            coverage.withUnsafeBufferPointer { coverage in
                amount.withUnsafeMutableBufferPointer { amount in
                    scratch.withUnsafeMutableBufferPointer { scratch in
                        let v = amount.baseAddress!, t = scratch.baseAddress!
                        for row in 0..<boxHeight {
                            let c = coverage.baseAddress! + row * boxWidth
                            let m = matte.baseAddress! + (maxY - row) * width + minX
                            // What the stroke puts here: its coverage, up to its density.
                            vDSP_vclip(c, 1, &zero, &ceiling, v, 1, n)
                            if stroke.isErasing {
                                // m − m·v
                                vDSP_vmul(m, 1, v, 1, t, 1, n)
                                vDSP_vsub(t, 1, m, 1, m, 1, n)
                            } else {
                                // Builds on what is there, but a stroke never takes a spot past its own
                                // density: max(m, min(m + v − m·v, density)).
                                vDSP_vmul(v, 1, m, 1, t, 1, n)
                                vDSP_vsub(t, 1, v, 1, t, 1, n)
                                vDSP_vadd(m, 1, t, 1, t, 1, n)
                                vDSP_vclip(t, 1, &zero, &ceiling, t, 1, n)
                                vDSP_vmax(m, 1, t, 1, m, 1, n)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A dab: white at the flow's opacity out to where the feather starts, then easing (smoothstep) to
    /// nothing at the edge.
    private static func dabGradient(feather: Double, flow: Double, space: CGColorSpace) -> CGGradient? {
        let flow = flow.clamped(to: 0...1), core = 1 - feather.clamped(to: 0...1)
        var locations: [CGFloat] = [0, core]
        var components: [CGFloat] = [1, flow, 1, flow]
        if core < 1 {
            let steps = 16
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                locations.append(core + (1 - core) * t)
                components += [1, flow * smoothstep(1 - t)]
            }
        }
        return CGGradient(colorSpace: space, colorComponents: components, locations: locations, count: locations.count)
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

    /// Mattes (and their images), most recently used last. One edit renders the brush at several sizes (the
    /// preview, the Navigator, the thumbnail), and painting needs the strokes before the one in progress as
    /// well as all of them, so the cache holds a few of each, within a pixel budget (about 190 MB of mattes).
    /// One matte can be up to a 36 MP photo at 1:1, so painting zoomed in stays quick; a larger export paints
    /// from scratch, once.
    private static let cache = OSAllocatedUnfairLock<[Entry]>(initialState: [])
    private static let cachedPixelBudget = 48_000_000
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
        cache.withLock { entries in
            guard let index = entries.firstIndex(where: { $0.key == key }), entries[index].image != nil else { return nil }
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.image
        }
    }

    private static func store(_ matte: [Float], for key: Key) {
        guard key.width * key.height <= cachedPixelLimit else { return }
        cache.withLock { entries in
            entries.removeAll { $0.key == key }
            entries.append(Entry(key: key, matte: matte))
            var pixels = entries.reduce(0) { $0 + $1.key.width * $1.key.height }
            while pixels > cachedPixelBudget, entries.count > 1 {
                let evicted = entries.removeFirst()
                pixels -= evicted.key.width * evicted.key.height
            }
        }
    }

    /// Whether these strokes' image at this size is cached (for tests).
    static func hasCachedImage(for brush: PhotoAdjustments.BrushMask, width: Int, height: Int) -> Bool {
        let key = Key(strokes: brush.strokes, width: width, height: height)
        return cache.withLock { entries in entries.contains { $0.key == key && $0.image != nil } }
    }

    private static func store(_ image: CIImage, for key: Key) {
        cache.withLock { entries in
            if let index = entries.lastIndex(where: { $0.key == key }) { entries[index].image = image }
        }
    }
}
