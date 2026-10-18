import Foundation
import UniformTypeIdentifiers

/// File types PixelLoupe can import: every camera RAW format Core Image supports plus common image formats.
nonisolated enum SupportedImageTypes {
    static let standardTypes: [UTType] = [.jpeg, .heic, .heif, .tiff, .png]

    /// Photoshop documents: ImageIO reads their flattened composite, so they view and edit like TIFFs.
    static let photoshop = UTType("com.adobe.photoshop-image")

    /// Extensions of image files that can be a raw file's JPEG (or similar) sidecar.
    static let sidecarImageExtensions: Set<String> = ["JPG", "JPEG", "TIF", "TIFF", "PNG", "HEIC", "HEIF"]

    static func isSupported(_ url: URL) -> Bool {
        if isVideo(url) { return true }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        if let photoshop, type.conforms(to: photoshop) { return true }
        return type.conforms(to: .rawImage) || standardTypes.contains { type.conforms(to: $0) }
    }

    /// Movies, which PixelLoupe shows and plays but doesn't develop.
    static func isVideo(_ url: URL) -> Bool {
        let ext = url.pathExtension.uppercased()
        if SmartCollectionRules.videoExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .movie)
    }

    /// Whether an import panel should offer `url`: any folder, or a supported image file.
    static func isImportable(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true { return values?.isPackage != true }
        return isSupported(url)
    }

    static func isRaw(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .rawImage) ?? false
    }
}
