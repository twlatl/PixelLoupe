import CoreGraphics
import Foundation

/// What the Metadata panel shows for a photo: catalog edits first, then the file's metadata, plus
/// fields PixelLoupe knows itself (file name, folder, rating, dimensions…).
nonisolated struct MetadataValues: Sendable {
    /// What's needed of a photo, copied on the main thread.
    struct PhotoInfo: Sendable, Equatable {
        var fileName: String
        var filePath: String
        var originalPath: String?
        var folderName: String?
        var fileSize: Int64
        var fileType: String
        var rating: Int
        var colorLabel: ColorLabel
        var captureDate: Date
        var pixelWidth: Int
        var pixelHeight: Int
        var currentSize: CGSize
        var edits: PhotoMetadata
        var sidecars: [String]
        /// Image files that go with the photo (`JPG`), recorded when it was imported.
        var imageSidecars: [String]
        var isVideo: Bool

        init(photo: Photo) {
            fileName = photo.fileName
            filePath = photo.filePath
            originalPath = photo.originalPath
            folderName = photo.folder?.name
            fileSize = photo.fileSize
            fileType = photo.fileType
            rating = Int(photo.rating)
            colorLabel = photo.label
            captureDate = photo.captureDate
            pixelWidth = Int(photo.pixelWidth)
            pixelHeight = Int(photo.pixelHeight)
            let adjustments = photo.adjustments
            let frame = adjustments.orientation.swapsDimensions
                ? CGSize(width: Int(photo.pixelHeight), height: Int(photo.pixelWidth))
                : CGSize(width: Int(photo.pixelWidth), height: Int(photo.pixelHeight))
            currentSize = CGSize(width: (frame.width * adjustments.crop.rect.width).rounded(),
                                 height: (frame.height * adjustments.crop.rect.height).rounded())
            edits = photo.metadata
            sidecars = Self.sidecars(of: URL(filePath: photo.filePath))
            imageSidecars = photo.imageSidecars
            isVideo = photo.isVideo
        }

        /// XMP sidecars next to the file ("IMG_1.xmp" or "IMG_1.CR3.xmp").
        static func sidecars(of file: URL) -> [String] {
            let base = file.deletingPathExtension()
            return [base.appendingPathExtension("xmp"), file.appendingPathExtension("xmp")]
                .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
                .map(\.lastPathComponent)
        }
    }

    let info: PhotoInfo
    let file: FileMetadata

    func value(_ field: MetadataField.ID) -> String {
        if let edited = info.edits[field] { return edited }
        if let own = own(field) { return own }
        return file[field] ?? ""
    }

    /// Whether PixelLoupe's catalog has metadata that differs from the file's.
    var isChanged: Bool {
        info.edits.values.contains { key, value in
            MetadataField.ID(rawValue: key).map { (file[$0] ?? "") != value } ?? false
        }
    }

    private func own(_ field: MetadataField.ID) -> String? {
        switch field {
        case .fileName: return info.fileName
        case .originalFilename:
            return info.originalPath.map { URL(filePath: $0).lastPathComponent } ?? info.fileName
        case .folder: return info.folderName ?? URL(filePath: info.filePath).deletingLastPathComponent().lastPathComponent
        case .filePath: return URL(filePath: info.filePath).deletingLastPathComponent().path(percentEncoded: false)
        case .sidecarFiles: return info.sidecars.joined(separator: ", ")
        case .fileSize: return info.fileSize > 0 ? ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file) : nil
        case .fileType: return Self.fileTypeName(info.fileType, imageSidecars: info.imageSidecars, isVideo: info.isVideo)
        case .metadataStatus: return isChanged ? "Has been changed" : "Up to date"
        case .rating: return info.rating > 0 ? String(repeating: "★", count: info.rating) : ""
        // The label is the photo's color label (edited with 6–9 or here), not free text.
        case .label: return info.colorLabel.title
        case .fileDimensions: return info.pixelWidth > 0 ? "\(info.pixelWidth) x \(info.pixelHeight)" : nil
        case .currentDimensions:
            return info.pixelWidth > 0 ? "\(Int(info.currentSize.width)) x \(Int(info.currentSize.height))" : nil
        case .captureDate: return info.captureDate.formatted(date: .abbreviated, time: .omitted)
        case .captureTime: return info.captureDate.formatted(date: .numeric, time: .standard)
        default: return nil
        }
    }

    /// "Raw (CR3)", or "Raw + JPEG" for a raw file with its JPEG sidecar; "Video (MOV)" for a movie.
    static func fileTypeName(_ type: String, imageSidecars: [String] = [], isVideo: Bool = false) -> String {
        if isVideo { return "Video (\(type.uppercased()))" }
        let name = fileTypeName(type)
        guard !imageSidecars.isEmpty else { return name }
        let sidecars = imageSidecars.map { fileTypeName($0) }.joined(separator: " + ")
        return name.hasPrefix("Raw") ? "Raw + \(sidecars)" : "\(name) + \(sidecars)"
    }

    static func fileTypeName(_ type: String) -> String {
        switch type.uppercased() {
        case "JPG", "JPEG": "JPEG"
        case "HEIC", "HEIF": "HEIF"
        case "TIF", "TIFF": "TIFF"
        case "PNG": "PNG"
        case "DNG": "Digital Negative (DNG)"
        case "": ""
        default: "Raw (\(type.uppercased()))"
        }
    }

    /// One value for several photos: the shared value, or nil when they differ ("mixed").
    static func common(_ field: MetadataField.ID, of photos: [MetadataValues]) -> String? {
        guard let first = photos.first?.value(field) else { return "" }
        return photos.dropFirst().allSatisfy { $0.value(field) == first } ? first : nil
    }
}
