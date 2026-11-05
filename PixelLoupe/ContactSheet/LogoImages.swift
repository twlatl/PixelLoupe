import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The logos chosen for contact sheets and web galleries: each PNG or JPEG is copied into
/// ~/Library/Application Support/PixelLoupe/Logos when it's chosen, so the sheet or gallery keeps
/// it after the original is moved or deleted. Settings refer to a logo by its copy's name.
nonisolated struct LogoImages: Sendable {
    static let shared = LogoImages(directory: URL.applicationSupportDirectory.appending(path: "PixelLoupe/Logos", directoryHint: .isDirectory))

    /// What can be chosen.
    static let contentTypes: [UTType] = [.png, .jpeg]
    /// Logos are read at most this many pixels on their long edge: sharp in a printed header, small
    /// enough to keep in memory.
    static let maxPixels = 2400

    let directory: URL

    /// Copies a PNG or JPEG into the logos folder; returns its name there.
    func importImage(from url: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).\(Self.fileExtension(of: url.lastPathComponent))"
        try FileManager.default.copyItem(at: url, to: directory.appending(path: name))
        return name
    }

    func url(named name: String) -> URL {
        directory.appending(path: name)
    }

    func exists(named name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(named: name).path(percentEncoded: false))
    }

    /// "png" or "jpg": what a logo named `name` is, by its extension.
    static func fileExtension(of name: String) -> String {
        (name as NSString).pathExtension.lowercased() == "png" ? "png" : "jpg"
    }

    /// The logo, upright and at most ``maxPixels`` on its long edge; nil when it can't be read.
    @concurrent
    static func load(_ url: URL) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}
