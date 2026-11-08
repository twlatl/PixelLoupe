import CoreGraphics
import CoreImage
import Foundation

/// A Remove spot's area as coverage over part of the frame: the object Detect Objects found, then the brush
/// strokes in order (painting adds, erasing takes away), each drawn by ``BrushRasterizer`` so the area is the
/// same as a brush mask over the same strokes.
nonisolated enum RemoveAreaRaster {
    /// Coverage 0…1 over `box` (unit coordinates of a frame `frameSize` pixels) at `width` × `height`,
    /// rows from the bottom.
    static func coverage(of area: PhotoAdjustments.RemoveArea, box: CGRect, frameSize: CGSize, width: Int, height: Int) -> [Float] {
        var matte = [Float](repeating: 0, count: max(0, width * height))
        guard width > 0, height > 0, box.width > 0, box.height > 0 else { return matte }
        if let object = area.object, let bytes = object.coverage {
            paint(object, bytes: bytes, into: &matte, box: box, width: width, height: height)
        }
        // Strokes in the box's own unit coordinates; a brush's size is a fraction of the long edge, so it's
        // rescaled from the frame's long edge to the box's.
        let frameLong = Double(max(frameSize.width, frameSize.height))
        let boxLong = max(Double(box.width * frameSize.width), Double(box.height * frameSize.height))
        guard frameLong > 0, boxLong > 0 else { return matte }
        for stroke in area.brush.strokes {
            var local = stroke
            local.points = stroke.points.map {
                PhotoAdjustments.UnitPoint(x: ($0.x - Double(box.minX)) / Double(box.width), y: ($0.y - Double(box.minY)) / Double(box.height))
            }
            local.size = stroke.size * frameLong / boxLong
            BrushRasterizer.paint(local, into: &matte, width: width, height: height)
        }
        return matte
    }

    /// The object's matte resampled (bilinear) onto the box, taking the larger of it and what's there.
    private static func paint(_ object: PhotoAdjustments.ObjectMatte, bytes: [UInt8], into matte: inout [Float], box: CGRect, width: Int, height: Int) {
        guard object.width > 1, object.height > 1, object.box.width > 0, object.box.height > 0 else { return }
        let ow = object.width, oh = object.height
        for row in 0..<height {
            let y = Double(box.minY) + (Double(row) + 0.5) / Double(height) * Double(box.height)
            let fy = (y - Double(object.box.minY)) / Double(object.box.height) * Double(oh) - 0.5
            guard fy > -1, fy < Double(oh) else { continue }
            let y0 = Int(fy.rounded(.down)), ty = Float(fy - Double(y0))
            for column in 0..<width {
                let x = Double(box.minX) + (Double(column) + 0.5) / Double(width) * Double(box.width)
                let fx = (x - Double(object.box.minX)) / Double(object.box.width) * Double(ow) - 0.5
                guard fx > -1, fx < Double(ow) else { continue }
                let x0 = Int(fx.rounded(.down)), tx = Float(fx - Double(x0))
                func at(_ x: Int, _ y: Int) -> Float {
                    guard x >= 0, x < ow, y >= 0, y < oh else { return 0 }
                    return Float(bytes[y * ow + x]) / 255
                }
                let value = (at(x0, y0) * (1 - tx) + at(x0 + 1, y0) * tx) * (1 - ty) + (at(x0, y0 + 1) * (1 - tx) + at(x0 + 1, y0 + 1) * tx) * ty
                let index = row * width + column
                matte[index] = max(matte[index], value)
            }
        }
    }

    /// The coverage as an image filling `extent` (rows from the bottom become CI's bottom-up rows).
    static func image(_ coverage: [Float], width: Int, height: Int, extent: CGRect) -> CIImage {
        let bytes = coverage.map { UInt8(min(255, max(0, $0 * 255 + 0.5))) }
        // Bitmap row 0 is the top; the coverage's row 0 is the bottom.
        var flipped = [UInt8](repeating: 0, count: bytes.count)
        for row in 0..<height {
            let source = (height - 1 - row) * width
            flipped.replaceSubrange(row * width..<(row + 1) * width, with: bytes[source..<source + width])
        }
        return CIImage(bitmapData: Data(flipped), bytesPerRow: width, size: CGSize(width: width, height: height), format: .L8, colorSpace: nil)
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }
}
