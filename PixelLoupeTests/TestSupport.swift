import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import PixelLoupe

/// A window that keeps the size a test gives it. macOS shrinks a window to fit its screen, and CI machines have small
/// virtual displays (GitHub's macOS runners are 1024 × 768), so layout tests that need a big window use this.
final class TestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// A temporary directory removed when the value is deallocated.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "PixelLoupeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func subdirectory(_ path: String) throws -> URL {
        let directory = url.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

enum Fixtures {
    /// Writes a small JPEG with EXIF, TIFF and IPTC metadata.
    @discardableResult
    static func writeJPEG(
        to url: URL,
        width: Int = 64,
        height: Int = 48,
        captureDate: String? = "2026:10:12 09:30:00",
        offset: String? = nil,
        make: String? = "Canon",
        model: String? = "EOS R5",
        lens: String? = "RF24-70mm F2.8 L IS USM",
        keywords: [String] = [],
        gps: (latitude: Double, longitude: Double, altitude: Double?)? = nil
    ) throws -> URL {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!

        var exif: [CFString: Any] = [:]
        if let captureDate { exif[kCGImagePropertyExifDateTimeOriginal] = captureDate }
        if let offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = offset }
        if let lens { exif[kCGImagePropertyExifLensModel] = lens }
        var tiff: [CFString: Any] = [:]
        if let make { tiff[kCGImagePropertyTIFFMake] = make }
        if let model { tiff[kCGImagePropertyTIFFModel] = model }
        var properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
        ]
        if !keywords.isEmpty {
            properties[kCGImagePropertyIPTCDictionary] = [kCGImagePropertyIPTCKeywords: keywords]
        }
        if let gps {
            var dictionary: [CFString: Any] = [
                kCGImagePropertyGPSLatitude: abs(gps.latitude), kCGImagePropertyGPSLatitudeRef: gps.latitude < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude: abs(gps.longitude), kCGImagePropertyGPSLongitudeRef: gps.longitude < 0 ? "W" : "E",
            ]
            if let altitude = gps.altitude {
                dictionary[kCGImagePropertyGPSAltitude] = abs(altitude)
                dictionary[kCGImagePropertyGPSAltitudeRef] = altitude < 0 ? 1 : 0
            }
            properties[kCGImagePropertyGPSDictionary] = dictionary
        }

        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    static func managedInfo(storage: URL) -> CatalogInfo {
        CatalogInfo(name: "Test", storageMode: .managed, storagePath: storage.path(percentEncoded: false))
    }

    static let referencedInfo = CatalogInfo(name: "Test", storageMode: .referenced)
}
