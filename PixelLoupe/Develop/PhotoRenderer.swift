import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders a photo with its Develop settings to a bitmap, off the main thread.
nonisolated enum PhotoRenderer {
    /// A rendered image handed back to the main actor. `CGImage` is immutable.
    struct Rendered: @unchecked Sendable {
        let image: CGImage
    }

    static let context = CIContext(options: [.cacheIntermediates: false])

    /// Renders `url` so its long edge is at most `maxPixels` (never upscaled).
    @concurrent
    static func render(_ url: URL, adjustments: PhotoAdjustments, maxPixels: CGFloat) async -> Rendered? {
        guard let source = DevelopSource(url: url) else { return nil }
        let image = source.image(with: adjustments, scale: source.scale(toFit: maxPixels, adjustments: adjustments))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let cgImage = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace)
        else { return nil }
        return Rendered(image: cgImage)
    }

    enum JPEGError: Error {
        case unreadable, unwritable
    }

    /// Writes the photo as it looks in PixelLoupe (edits applied) to a full-size sRGB JPEG at `url`,
    /// keeping the original's metadata (EXIF, IPTC, GPS) except its orientation, which is applied.
    @concurrent
    static func writeJPEG(of source: URL, adjustments: PhotoAdjustments, to url: URL, quality: CGFloat = 0.9) async throws {
        guard let develop = DevelopSource(url: source) else { throw JPEGError.unreadable }
        let image = develop.image(with: adjustments, scale: 1)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace)
        else { throw JPEGError.unreadable }

        var properties: [CFString: Any] = [:]
        if let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
           let original = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary,
                        kCGImagePropertyGPSDictionary, kCGImagePropertyExifAuxDictionary] {
                if let value = original[key] { properties[key] = value }
            }
            // The pixels are already upright and sized as rendered.
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
            if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = cgImage.width
                exif[kCGImagePropertyExifPixelYDimension] = cgImage.height
                properties[kCGImagePropertyExifDictionary] = exif
            }
        }
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImageDestinationLossyCompressionQuality] = quality

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw JPEGError.unwritable }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw JPEGError.unwritable }
    }
}
