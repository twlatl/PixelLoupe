import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Remove's Detect Objects (RAW-260): turns a rough stroke around (or over) something into the object itself.
///
/// The stroke marks a region: what a loop encloses, or what the brush covered. Vision looks for foreground
/// objects in a crop around it (in a crop, whatever the stroke went round is likely to stand out as the
/// foreground), and the objects mostly inside the region, kept to the region grown a little, are the area. When
/// Vision finds nothing there, the region itself is.
nonisolated enum ObjectDetector {
    /// The long side of the crop Vision looks at, and of the matte kept in the spot.
    static let detectionLongEdge: CGFloat = 1024
    static let matteLongEdge = 256

    /// The object `stroke` marks on `source`'s frame with `geometry`'s Lens Corrections, Rotate/Flip and Transform.
    static func detect(stroke: PhotoAdjustments.BrushStroke, source: DevelopSource, geometry: PhotoAdjustments) -> PhotoAdjustments.ObjectMatte? {
        let frameSize = source.frameSize(geometry)
        let aspect = Double(frameSize.width / max(frameSize.height, 1))
        let marked = PhotoAdjustments.RemoveArea(brush: PhotoAdjustments.BrushMask(strokes: [stroke]))
        guard let painted = marked.bounds(aspect: aspect) else { return nil }
        let box = painted.insetBy(dx: -painted.width * 0.15, dy: -painted.height * 0.15).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isEmpty else { return nil }

        // The region the stroke marks, at the matte's size.
        let longSide = max(box.width * frameSize.width, box.height * frameSize.height)
        let matteScale = CGFloat(matteLongEdge) / max(longSide, 1)
        let width = max(8, Int((box.width * frameSize.width * matteScale).rounded()))
        let height = max(8, Int((box.height * frameSize.height * matteScale).rounded()))
        let region = self.region(stroke, aspect: aspect, box: box, frameSize: frameSize, width: width, height: height)
        guard region.contains(where: { $0 > 0.5 }) else { return nil }

        var coverage = region.map { $0 > 0.5 ? UInt8(255) : 0 }
        if let objects = objects(in: box, source: source, geometry: geometry, width: width, height: height) {
            // Each object mostly inside the region counts, kept to the region grown by 4%.
            let grown = RemoveFillStore.dilate(region.map { $0 > 0.5 }, width: width, height: height, by: max(2, Int(Double(max(width, height)) * 0.04)))
            var found = [Float](repeating: 0, count: width * height)
            for object in objects {
                var inside: Float = 0, total: Float = 0
                for i in object.indices where object[i] > 0.5 {
                    total += 1
                    if region[i] > 0.5 { inside += 1 }
                }
                guard total > 0, inside / total >= 0.5 else { continue }
                for i in object.indices where grown[i] { found[i] = max(found[i], object[i]) }
            }
            if found.contains(where: { $0 > 0.5 }) {
                coverage = found.map { UInt8(min(255, max(0, $0 * 255 + 0.5))) }
            }
        }
        return PhotoAdjustments.ObjectMatte(box: box, width: width, height: height, coverage: coverage)
    }

    /// What a loop encloses (when it ends near where it began), or what the brush covered; rows from the bottom.
    static func region(_ stroke: PhotoAdjustments.BrushStroke, aspect: Double, box: CGRect, frameSize: CGSize, width: Int, height: Int) -> [Float] {
        let brushed = RemoveAreaRaster.coverage(of: PhotoAdjustments.RemoveArea(brush: PhotoAdjustments.BrushMask(strokes: [stroke])),
                                                box: box, frameSize: frameSize, width: width, height: height)
        guard isLoop(stroke, aspect: aspect),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return brushed }
        let path = CGMutablePath()
        let points = stroke.points.map {
            CGPoint(x: ($0.x - Double(box.minX)) / Double(box.width) * Double(width), y: ($0.y - Double(box.minY)) / Double(box.height) * Double(height))
        }
        path.addLines(between: points)
        path.closeSubpath()
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(path)
        context.fillPath()
        // The context's memory starts at its top row (its y is up, so that's the highest y).
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height)
        var result = brushed
        for row in 0..<height {
            for column in 0..<width {
                let value = Float(bytes[(height - 1 - row) * width + column]) / 255
                result[row * width + column] = max(result[row * width + column], value)
            }
        }
        return result
    }

    /// Whether the stroke goes round something: it ends close to where it began, and went some way first.
    static func isLoop(_ stroke: PhotoAdjustments.BrushStroke, aspect: Double) -> Bool {
        guard stroke.points.count >= 8, let first = stroke.points.first, let last = stroke.points.last else { return false }
        func distance(_ a: PhotoAdjustments.UnitPoint, _ b: PhotoAdjustments.UnitPoint) -> Double {
            hypot((a.x - b.x) * aspect, a.y - b.y) / max(aspect, 1)
        }
        let length = zip(stroke.points, stroke.points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
        return length > stroke.size * 8 && distance(first, last) < max(stroke.size * 3, length * 0.15)
    }

    /// Vision's foreground objects in the crop, each as coverage at `width` × `height`, rows from the bottom.
    private static func objects(in box: CGRect, source: DevelopSource, geometry: PhotoAdjustments, width: Int, height: Int) -> [[Float]]? {
        let frameSize = source.frameSize(geometry)
        let scale = min(1, detectionLongEdge / max(box.width * frameSize.width, box.height * frameSize.height, 1))
        let frame = source.frameImage(with: geometry, scale: scale)
        let extent = frame.extent
        let crop = CGRect(x: extent.minX + box.minX * extent.width, y: extent.minY + box.minY * extent.height,
                          width: box.width * extent.width, height: box.height * extent.height).integral.intersection(extent)
        guard crop.width >= 16, crop.height >= 16, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = PhotoRenderer.context.createCGImage(frame, from: crop, format: .RGBA8, colorSpace: space) else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        do { try handler.perform([request]) } catch { return nil }
        guard let observation = request.results?.first else { return [] }
        return observation.allInstances.compactMap { instance -> [Float]? in
            guard let buffer = try? observation.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler),
                  let matte = SubjectMatteStore.matte(from: buffer) else { return nil }
            return resample(matte, width: width, height: height)
        }
    }

    /// A matte (rows from the top) at `width` × `height`, rows from the bottom.
    private static func resample(_ matte: SubjectMatteStore.Matte, width: Int, height: Int) -> [Float] {
        var result = [Float](repeating: 0, count: width * height)
        guard matte.width > 0, matte.height > 0 else { return result }
        for row in 0..<height {
            let sy = min(matte.height - 1, Int((1 - (Double(row) + 0.5) / Double(height)) * Double(matte.height)))
            for column in 0..<width {
                let sx = min(matte.width - 1, Int((Double(column) + 0.5) / Double(width) * Double(matte.width)))
                result[row * width + column] = Float(matte.bytes[sy * matte.width + sx]) / 255
            }
        }
        return result
    }
}
