import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo to export, captured on the main actor so exporting never touches Core Data.
nonisolated struct ExportItem: Sendable {
    /// The original.
    let source: URL
    let adjustments: PhotoAdjustments
    let metadata: PhotoMetadata
    let keywords: [String]
    /// The keywords' paths in the keyword tree ("Places|Ireland|Dublin"), for Write Keywords as
    /// PixelLoupe Hierarchy.
    var keywordPaths: [String] = []
    let rating: Int
    let captureDate: Date
    /// The photo's Smart Preview, exported from (at its size) when the original can't be read.
    var smartPreview: URL? = nil
    /// The location set in the catalog, which replaces the original's in the exported file.
    var gps: ExportGPS = .file

    var fileName: String { source.lastPathComponent }
    var location: PhotoSourceLocation { PhotoSourceLocation(original: source, smartPreview: smartPreview) }
}

extension ExportItem {
    init(_ photo: Photo, smartPreview: URL? = nil) {
        self.init(
            source: photo.fileURL, adjustments: photo.adjustments, metadata: photo.metadata,
            keywords: Tag.exportNames(for: photo.tags), keywordPaths: Tag.exportPaths(for: photo.tags),
            rating: Int(photo.rating), captureDate: photo.captureDate, smartPreview: smartPreview, gps: ExportGPS(photo)
        )
    }
}

/// An exported photo's location, from the catalog (RAW-164).
nonisolated enum ExportGPS: Sendable, Equatable {
    /// The original's location (or none) is kept.
    case file
    /// The location typed into the catalog replaces the original's.
    case set(GPSCoordinate)
    /// The location was removed in the catalog: the exported file has none.
    case cleared

    init(_ photo: Photo) {
        self = switch photo.locationKind {
        case .file: .file
        case .set: photo.overrideLocation.map(ExportGPS.set) ?? .file
        case .cleared: .cleared
        }
    }
}

/// File names and destinations for an export, before anything is written.
nonisolated struct ExportPlan: Sendable {
    struct Entry: Sendable {
        let item: ExportItem
        var url: URL
    }

    var entries: [Entry]

    /// Entries whose file already exists.
    var conflicts: [Entry] {
        entries.filter { FileManager.default.fileExists(atPath: $0.url.path(percentEncoded: false)) }
    }

    /// Names every item; `folder` is the chosen folder (nil for the same folder as each original).
    /// Two photos that would get the same name in this export are told apart with "-2", "-3"….
    init(items: [ExportItem], settings: ExportSettings, folder: URL?) {
        var used = Set<String>()
        entries = items.enumerated().map { index, item in
            var directory = folder ?? item.source.deletingLastPathComponent()
            if settings.usesSubfolder, !settings.subfolderName.trimmingCharacters(in: .whitespaces).isEmpty {
                directory = directory.appending(path: settings.subfolderName, directoryHint: .isDirectory)
            }
            let name = ExportNaming.fileName(for: item, index: index, total: items.count, settings: settings)
            var url = directory.appending(path: name)
            var copy = 2
            while used.contains(url.path(percentEncoded: false).lowercased()) {
                url = ExportNaming.numbered(directory.appending(path: name), copy)
                copy += 1
            }
            used.insert(url.path(percentEncoded: false).lowercased())
            return Entry(item: item, url: url)
        }
    }

    /// Applies the Existing Files choice to files already on disk (Ask has been answered by now).
    func resolving(_ rule: ExportSettings.ExistingFiles) -> ExportPlan {
        var plan = self
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        switch rule {
        case .overwrite, .ask:
            break
        case .skip:
            plan.entries.removeAll { exists($0.url) }
        case .uniqueName:
            var taken = Set(entries.map { $0.url.path(percentEncoded: false).lowercased() })
            for index in plan.entries.indices where exists(plan.entries[index].url) {
                let original = plan.entries[index].url
                var copy = 2
                var url = ExportNaming.numbered(original, copy)
                while exists(url) || taken.contains(url.path(percentEncoded: false).lowercased()) {
                    copy += 1
                    url = ExportNaming.numbered(original, copy)
                }
                taken.insert(url.path(percentEncoded: false).lowercased())
                plan.entries[index].url = url
            }
        }
        return plan
    }
}

/// File Naming's templates.
nonisolated enum ExportNaming {
    static func fileName(for item: ExportItem, index: Int, total: Int, settings: ExportSettings) -> String {
        let original = item.source.deletingPathExtension().lastPathComponent
        var base = original
        if settings.renames {
            let custom = settings.customText.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : settings.customText
            let number = settings.startNumber + index
            let date = item.captureDate.formatted(.iso8601.year().month().day().dateSeparator(.dash))
            base = switch settings.namingTemplate {
            case .filename: original
            case .filenameSequence: "\(original)-\(number)"
            case .filenameEdit: "\(original)-Edit"
            case .customName: custom
            case .customNameSequence: "\(custom)-\(number)"
            case .customNameOfTotal: "\(custom) (\(index + 1) of \(total))"
            case .dateFilename: "\(date)-\(original)"
            }
        }
        base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let ext = settings.format.fileExtension ?? item.source.pathExtension
        return "\(base).\(settings.extensionCase == .uppercase ? ext.uppercased() : ext.lowercased())"
    }

    /// "Name-2.jpg" for "Name.jpg".
    static func numbered(_ url: URL, _ number: Int) -> URL {
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appending(path: ext.isEmpty ? "\(base)-\(number)" : "\(base)-\(number).\(ext)")
    }
}

/// Renders and writes exported photos (any thread).
nonisolated enum PhotoExporter {
    enum ExportError: LocalizedError {
        case unreadable(String), unwritable(String)
        /// Exporting next to an original whose folder isn't there (its drive is disconnected).
        case folderUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "“\(name)” could not be read."
            case .unwritable(let name): "“\(name)” could not be written."
            case .folderUnavailable(let name): "The folder of “\(name)” isn’t available."
            }
        }
    }

    struct Result: Sendable {
        var exported: [URL] = []
        var failures: [String] = []
        /// The exported files drawn from Smart Previews, at their size, because the originals couldn't be read.
        var fromSmartPreviews: [URL] = []
    }

    /// A watermark to draw, and its graphic's file.
    struct Watermark: Sendable {
        let settings: WatermarkSettings
        let imageURL: URL?

        init(settings: WatermarkSettings, imageURL: URL?) {
            self.settings = settings
            self.imageURL = imageURL
        }

        /// The watermark export settings ask for, nil when they don't (or its preset is gone).
        @MainActor
        init?(_ settings: ExportSettings) {
            guard settings.watermarks, settings.format != .original,
                  let preset = WatermarkPresets.shared.preset(named: settings.watermarkName) else { return nil }
            self.init(settings: preset.settings, imageURL: preset.settings.imageName.map(WatermarkPresets.shared.imageURL(named:)))
        }
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Exports every entry, a few at a time, reporting progress (completed, total) as it goes.
    static func run(_ plan: ExportPlan, settings: ExportSettings, watermark: Watermark?,
                    progress: @escaping @MainActor (Int, Int) -> Void) async -> Result {
        let total = plan.entries.count
        await progress(0, total)
        var result = Result()
        let concurrency = max(1, min(3, ProcessInfo.processInfo.activeProcessorCount / 3))
        await withTaskGroup(of: (URL, Swift.Result<Bool, Error>).self) { group in
            var pending = plan.entries.makeIterator()
            func addNext() -> Bool {
                guard let entry = pending.next() else { return false }
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let fromSmartPreview = try await export(entry.item, to: entry.url, settings: settings, watermark: watermark)
                        return (entry.url, .success(fromSmartPreview))
                    } catch {
                        return (entry.url, .failure(error))
                    }
                }
                return true
            }
            for _ in 0..<concurrency where !addNext() { break }
            var completed = 0
            for await (url, outcome) in group {
                completed += 1
                switch outcome {
                case .failure(let error):
                    if !(error is CancellationError) {
                        result.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                case .success(let fromSmartPreview):
                    result.exported.append(url)
                    if fromSmartPreview { result.fromSmartPreviews.append(url) }
                }
                await progress(completed, total)
                if !Task.isCancelled { _ = addNext() }
            }
        }
        return result
    }

    /// Exports one photo to `url`, creating its folder. Returns whether it was drawn from the photo's Smart Preview.
    @concurrent
    @discardableResult
    static func export(_ item: ExportItem, to url: URL, settings: ExportSettings, watermark: Watermark?) async throws -> Bool {
        // Never make an offline original's folder anew on the startup disk.
        var originalFolder = item.source.deletingLastPathComponent().path(percentEncoded: false)
        if !originalFolder.hasSuffix("/") { originalFolder += "/" }
        if url.path(percentEncoded: false).hasPrefix(originalFolder), !FileManager.default.fileExists(atPath: originalFolder) {
            throw ExportError.folderUnavailable(item.fileName)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if settings.format == .original {
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: item.source, to: url)
            return false
        }
        let rendered = try render(item, settings: settings, watermark: watermark)
        let metadata = metadata(for: item, settings: settings, size: CGSize(width: rendered.image.width, height: rendered.image.height))
        let data = try encode(rendered.image, metadata: metadata, settings: settings, name: url.lastPathComponent)
        try data.write(to: url, options: .atomic)
        return rendered.isFromSmartPreview
    }

    // MARK: - Rendering

    /// The photo with its edits, sized, sharpened and watermarked, in the export's color space and
    /// bit depth (no alpha). From the photo's Smart Preview when the original can't be read, at no
    /// more than the Smart Preview's size (2560 px on the long edge, before cropping).
    static func render(_ item: ExportItem, settings: ExportSettings, watermark: Watermark?) throws -> (image: CGImage, isFromSmartPreview: Bool) {
        guard let develop = DevelopSource.open(item.location) else { throw ExportError.unreadable(item.fileName) }
        let size = develop.croppedSize(item.adjustments)
        let scale = develop.smartPreview.map { min(settings.scale(for: size), $0.scale) } ?? settings.scale(for: size)
        var image = develop.image(with: item.adjustments, scale: min(scale, 1))
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if scale > 1 {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        }
        let target = CGRect(x: 0, y: 0, width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        // Stretch the last fraction of a pixel so the output has whole-pixel edges.
        if image.extent.width > 0, image.extent.height > 0 {
            image = image.transformed(by: CGAffineTransform(scaleX: target.width / image.extent.width, y: target.height / image.extent.height))
        }
        image = image.clampedToExtent().cropped(to: target)

        if settings.sharpens {
            image = sharpen(image, settings: settings)
        }
        if let watermark {
            image = WatermarkRenderer.apply(watermark.settings, imageURL: watermark.imageURL, to: image)
        }

        let colorSpace = settings.colorSpace.cgColorSpace
        let sixteen = settings.format.hasBitDepth && settings.bitDepth == 16
        guard let rendered = context.createCGImage(image, from: target, format: sixteen ? .RGBA16 : .RGBA8, colorSpace: colorSpace),
              let output = CGContext(
                data: nil, width: Int(target.width), height: Int(target.height), bitsPerComponent: sixteen ? 16 : 8,
                bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | (sixteen ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
              )
        else { throw ExportError.unreadable(item.fileName) }
        output.draw(rendered, in: target)
        guard let flattened = output.makeImage() else { throw ExportError.unreadable(item.fileName) }
        return (flattened, develop.isSmartPreview)
    }

    /// Output sharpening for the medium, scaled to the output's resolution.
    static func sharpen(_ image: CIImage, settings: ExportSettings) -> CIImage {
        let radius: Double = switch settings.sharpenMedium {
        case .screen: 0.8
        case .mattePaper: max(0.8, settings.pixelsPerInch / 300 * 1.5)
        case .glossyPaper: max(0.6, settings.pixelsPerInch / 300 * 1.0)
        }
        let intensity: Double = switch settings.sharpenAmount {
        case .low: 0.3
        case .standard: 0.6
        case .high: 1.0
        }
        return image.clampedToExtent()
            .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: radius, kCIInputIntensityKey: intensity])
            .cropped(to: image.extent)
    }

    // MARK: - Encoding

    static func encode(_ image: CGImage, metadata: CGImageMetadata, settings: ExportSettings, name: String) throws -> Data {
        func encode(quality: Double) -> Data? {
            let type: UTType = switch settings.format {
            case .jpeg, .original: .jpeg
            case .heic: .heic
            case .tiff: .tiff
            case .png: .png
            case .psd: UTType("com.adobe.photoshop-image") ?? .tiff
            }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
            var options: [CFString: Any] = [
                kCGImagePropertyDPIWidth: settings.pixelsPerInch,
                kCGImagePropertyDPIHeight: settings.pixelsPerInch,
            ]
            if settings.format.isLossy {
                options[kCGImageDestinationLossyCompressionQuality] = quality / 100
            }
            if settings.format == .tiff {
                options[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: settings.tiffCompression.tagValue]
            }
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, options as CFDictionary)
            return CGImageDestinationFinalize(destination) ? data as Data : nil
        }

        let quality = settings.quality.clamped(to: 0...100)
        guard settings.format == .jpeg, settings.limitsFileSize else {
            guard let data = encode(quality: quality) else { throw ExportError.unwritable(name) }
            return data
        }
        // Limit File Size: the best quality that fits, found by halving the range.
        let limit = settings.fileSizeLimit * 1024
        guard var best = encode(quality: 0) else { throw ExportError.unwritable(name) }
        var low = 0.0, high = 100.0
        for _ in 0..<7 {
            let middle = (low + high) / 2
            guard let data = encode(quality: middle) else { break }
            if data.count <= limit {
                best = data
                low = middle
            } else {
                high = middle
            }
        }
        if let top = encode(quality: 100), top.count <= limit { best = top }
        return best
    }

    // MARK: - Metadata

    private static let copyrightFields: [MetadataField.ID] = [.copyright, .rightsUsageTerms, .copyrightInfoURL]
    private static let contactFields: [MetadataField.ID] = [
        .creator, .creatorJobTitle, .creatorAddress, .creatorCity, .creatorState, .creatorPostalCode,
        .creatorCountry, .creatorPhone, .creatorEmail, .creatorWebsite,
    ]
    /// The XMP the copyright-only choices take from the original.
    private static let copyrightPaths = ["dc:rights", "xmpRights:UsageTerms", "xmpRights:WebStatement", "xmpRights:Marked"]
    private static let contactPaths = ["dc:creator", "photoshop:AuthorsPosition", "Iptc4xmpCore:CreatorContactInfo"]
    private static let cameraPaths = [
        "tiff:Make", "tiff:Model", "exifEX:BodySerialNumber", "exifEX:LensMake", "exifEX:LensModel",
        "exifEX:LensSerialNumber", "exifEX:LensSpecification", "exif:MakerNote",
    ]
    private static let namespaces = [
        "dc": "http://purl.org/dc/elements/1.1/", "xmp": "http://ns.adobe.com/xap/1.0/",
        "xmpRights": "http://ns.adobe.com/xap/1.0/rights/", "xmpMM": "http://ns.adobe.com/xap/1.0/mm/",
        "photoshop": "http://ns.adobe.com/photoshop/1.0/", "Iptc4xmpCore": "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/",
        "Iptc4xmpExt": "http://iptc.org/std/Iptc4xmpExt/2008-02-29/", "tiff": "http://ns.adobe.com/tiff/1.0/",
        "exif": "http://ns.adobe.com/exif/1.0/", "lr": "http://ns.adobe.com/lightroom/1.0/",
    ]

    /// The exported file's metadata: the original's, as much as Include allows, with the
    /// catalog's edits (metadata, keywords, rating), and the size and orientation as exported.
    static func metadata(for item: ExportItem, settings: ExportSettings, size: CGSize) -> CGImageMetadata {
        // A missing original's Smart Preview keeps its metadata.
        let original = ([item.source] + [item.smartPreview].compactMap { $0 }).lazy
            .compactMap { CGImageSourceCreateWithURL($0 as CFURL, nil).flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) } }
            .first
        let result: CGMutableImageMetadata
        var fields: [MetadataField.ID]
        switch settings.metadata {
        case .copyrightOnly, .copyrightAndContact:
            result = CGImageMetadataCreateMutable()
            register(result)
            var paths = copyrightPaths
            fields = copyrightFields
            if settings.metadata == .copyrightAndContact {
                paths += contactPaths
                fields += contactFields
            }
            if let original {
                for path in paths {
                    if let tag = CGImageMetadataCopyTagWithPath(original, nil, path as CFString) {
                        CGImageMetadataSetTagWithPath(result, nil, path as CFString, tag)
                    }
                }
            }
        case .allExceptCameraAndRaw, .allExceptRaw, .all:
            result = original.flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
            register(result)
            fields = Array(FileMetadata.xmpPaths.keys)
            var removed = Set<String>()
            if settings.metadata != .all { removed.insert("crs") }
            if settings.metadata == .allExceptCameraAndRaw {
                removed.insert("aux")
                for path in cameraPaths { CGImageMetadataRemoveTagWithPath(result, nil, path as CFString) }
            }
            // The catalog's location replaces the original's (its altitude and direction go too, since
            // they were measured somewhere else); Remove Location Info removes either.
            if settings.removesLocationInfo || item.gps != .file {
                for path in topLevelPaths(result) where path.hasPrefix("exif:GPS") {
                    CGImageMetadataRemoveTagWithPath(result, nil, path as CFString)
                }
            }
            if !settings.removesLocationInfo, case .set(let coordinate) = item.gps {
                CGImageMetadataSetValueWithPath(result, nil, "exif:GPSVersionID" as CFString, "2.2.0.0" as CFString)
                CGImageMetadataSetValueWithPath(result, nil, "exif:GPSLatitude" as CFString,
                                                xmpCoordinate(coordinate.latitude, positive: "N", negative: "S") as CFString)
                CGImageMetadataSetValueWithPath(result, nil, "exif:GPSLongitude" as CFString,
                                                xmpCoordinate(coordinate.longitude, positive: "E", negative: "W") as CFString)
            }
            if settings.removesPersonInfo {
                for path in ["Iptc4xmpExt:PersonInImage", "Iptc4xmpExt:PersonInImageWDetails", "mwg-rs:Regions"] {
                    CGImageMetadataRemoveTagWithPath(result, nil, path as CFString)
                }
                fields.removeAll { $0 == .personShown }
            }
            for path in topLevelPaths(result) {
                if let prefix = path.split(separator: ":").first, removed.contains(String(prefix)) {
                    CGImageMetadataRemoveTagWithPath(result, nil, path as CFString)
                }
            }
            // Keywords and rating, from the catalog.
            CGImageMetadataRemoveTagWithPath(result, nil, "dc:subject" as CFString)
            if !item.keywords.isEmpty, let tag = CGImageMetadataTagCreate(
                namespaces["dc"]! as CFString, "dc" as CFString, "subject" as CFString, .arrayUnordered, item.keywords as CFArray
            ) {
                CGImageMetadataSetTagWithPath(result, nil, "dc:subject" as CFString, tag)
            }
            // The original's hierarchy is as stale as its keywords: the catalog's replaces it, or none.
            CGImageMetadataRemoveTagWithPath(result, nil, "lr:hierarchicalSubject" as CFString)
            if settings.writesKeywordHierarchy, !item.keywordPaths.isEmpty, let tag = CGImageMetadataTagCreate(
                namespaces["lr"]! as CFString, "lr" as CFString, "hierarchicalSubject" as CFString, .arrayUnordered,
                item.keywordPaths as CFArray
            ) {
                CGImageMetadataSetTagWithPath(result, nil, "lr:hierarchicalSubject" as CFString, tag)
            }
            if item.rating > 0 {
                CGImageMetadataSetValueWithPath(result, nil, "xmp:Rating" as CFString, item.rating as CFNumber)
            } else {
                CGImageMetadataRemoveTagWithPath(result, nil, "xmp:Rating" as CFString)
            }
        }

        // Metadata typed into PixelLoupe overrides the file's (an empty value removes it).
        for field in fields {
            guard let value = item.metadata[field], let path = FileMetadata.xmpPaths[field]?.first else { continue }
            let xmpPath = path.replacingOccurrences(of: "/", with: ".") as CFString
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CGImageMetadataRemoveTagWithPath(result, nil, xmpPath)
            } else {
                CGImageMetadataSetValueWithPath(result, nil, xmpPath, value as CFString)
            }
        }

        // The pixels are upright and sized as exported.
        if settings.metadata.includesDescriptive {
            CGImageMetadataSetValueWithPath(result, nil, "tiff:Orientation" as CFString, 1 as CFNumber)
            CGImageMetadataSetValueWithPath(result, nil, "exif:PixelXDimension" as CFString, Int(size.width) as CFNumber)
            CGImageMetadataSetValueWithPath(result, nil, "exif:PixelYDimension" as CFString, Int(size.height) as CFNumber)
        }
        return result
    }

    /// XMP's form of a GPS coordinate, degrees and decimal minutes with the direction: `37,46.4957N`.
    static func xmpCoordinate(_ value: Double, positive: String, negative: String) -> String {
        let absolute = abs(value), degrees = Int(absolute)
        return String(format: "%d,%.6f%@", degrees, (absolute - Double(degrees)) * 60, value < 0 ? negative : positive)
    }

    private static func register(_ metadata: CGMutableImageMetadata) {
        for (prefix, namespace) in namespaces {
            CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace as CFString, prefix as CFString, nil)
        }
    }

    private static func topLevelPaths(_ metadata: CGImageMetadata) -> [String] {
        var paths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, _ in
            paths.append(path as String)
            return true
        }
        return paths
    }
}
