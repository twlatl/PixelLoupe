import Foundation

/// Guided filtering (He, Sun & Tang): a mask pulled onto the edges of the image it came from, which is what recovers
/// hair and fur that a segmentation model cuts straight through. Core Image's own `CIGuidedFilter` does nothing on
/// this system, so this does the arithmetic directly. From Pixegen, for Rim Light's subject (RAW-203).
nonisolated enum GuidedMatte {
    /// Mean over a (2r+1)² square, as two running-sum passes — the cost doesn't grow with the radius.
    static func box(_ source: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        let span = Float(radius * 2 + 1)
        var pass = [Float](repeating: 0, count: width * height)
        source.withUnsafeBufferPointer { src in
            pass.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    let row = y * width
                    var sum: Float = 0
                    for x in -radius...radius { sum += src[row + min(width - 1, max(0, x))] }
                    for x in 0..<width {
                        out[row + x] = sum / span
                        sum -= src[row + min(width - 1, max(0, x - radius))]
                        sum += src[row + min(width - 1, max(0, x + radius + 1))]
                    }
                }
            }
        }
        var result = [Float](repeating: 0, count: width * height)
        pass.withUnsafeBufferPointer { src in
            result.withUnsafeMutableBufferPointer { out in
                for x in 0..<width {
                    var sum: Float = 0
                    for y in -radius...radius { sum += src[min(height - 1, max(0, y)) * width + x] }
                    for y in 0..<height {
                        out[y * width + x] = sum / span
                        sum -= src[min(height - 1, max(0, y - radius)) * width + x]
                        sum += src[min(height - 1, max(0, y + radius + 1)) * width + x]
                    }
                }
            }
        }
        return result
    }

    /// `mask` refined by `guide` (both 0–1, the same size). A bigger radius reaches further for detail; `epsilon`
    /// decides how much of an edge in the guide counts, so a small one follows fine strands.
    static func filter(mask: [Float], guide: [Float], width: Int, height: Int, radius: Int, epsilon: Float) -> [Float] {
        let count = width * height
        let meanGuide = box(guide, width: width, height: height, radius: radius)
        let meanMask = box(mask, width: width, height: height, radius: radius)
        var squares = [Float](repeating: 0, count: count), products = [Float](repeating: 0, count: count)
        for i in 0..<count { squares[i] = guide[i] * guide[i]; products[i] = guide[i] * mask[i] }
        let meanSquares = box(squares, width: width, height: height, radius: radius)
        let meanProducts = box(products, width: width, height: height, radius: radius)
        var slope = [Float](repeating: 0, count: count), offset = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let variance = meanSquares[i] - meanGuide[i] * meanGuide[i]
            let covariance = meanProducts[i] - meanGuide[i] * meanMask[i]
            slope[i] = covariance / (variance + epsilon)
            offset[i] = meanMask[i] - slope[i] * meanGuide[i]
        }
        let meanSlope = box(slope, width: width, height: height, radius: radius)
        let meanOffset = box(offset, width: width, height: height, radius: radius)
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count { result[i] = min(1, max(0, meanSlope[i] * guide[i] + meanOffset[i])) }
        return result
    }
}
