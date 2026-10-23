import CoreGraphics
import Foundation

/// Everything File ▸ Export… decides, laid out like Lightroom's Export dialog. Codable for
/// presets and for Export with Previous; decoding is tolerant, so presets survive new options.
nonisolated struct ExportSettings: Codable, Equatable, Sendable {
    // MARK: Export Location

    enum Destination: String, Codable, Sendable, CaseIterable {
        case specificFolder, sameFolderAsOriginal, chooseLater

        var title: String {
            switch self {
            case .specificFolder: "Specific folder"
            case .sameFolderAsOriginal: "Same folder as original photo"
            case .chooseLater: "Choose folder later (useful for presets)"
            }
        }
    }

    enum ExistingFiles: String, Codable, Sendable, CaseIterable {
        case ask, uniqueName, overwrite, skip

        var title: String {
            switch self {
            case .ask: "Ask what to do"
            case .uniqueName: "Choose a new name for the exported file"
            case .overwrite: "Overwrite WITHOUT WARNING"
            case .skip: "Skip"
            }
        }
    }

    var destination = Destination.specificFolder
    /// The folder for `.specificFolder`.
    var folderPath = URL.picturesDirectory.path(percentEncoded: false)
    var usesSubfolder = false
    var subfolderName = "Untitled Export"
    var existingFiles = ExistingFiles.ask

    // MARK: File Naming

    enum NamingTemplate: String, Codable, Sendable, CaseIterable {
        case filename, filenameSequence, filenameEdit, customName, customNameSequence, customNameOfTotal, dateFilename

        var title: String {
            switch self {
            case .filename: "Filename"
            case .filenameSequence: "Filename - Sequence"
            case .filenameEdit: "Filename-Edit"
            case .customName: "Custom Name"
            case .customNameSequence: "Custom Name - Sequence"
            case .customNameOfTotal: "Custom Name (x of y)"
            case .dateFilename: "Date - Filename"
            }
        }

        var usesCustomText: Bool { [.customName, .customNameSequence, .customNameOfTotal].contains(self) }
        var usesStartNumber: Bool { [.filenameSequence, .customNameSequence].contains(self) }
    }

    enum ExtensionCase: String, Codable, Sendable, CaseIterable {
        case lowercase, uppercase

        var title: String { self == .lowercase ? "Lowercase" : "Uppercase" }
    }

    var renames = false
    var namingTemplate = NamingTemplate.filename
    var customText = "Untitled"
    var startNumber = 1
    var extensionCase = ExtensionCase.lowercase

    // MARK: Video (PixelLoupe has no video yet; kept for Lightroom parity)

    var includesVideo = false

    // MARK: File Settings

    enum Format: String, Codable, Sendable, CaseIterable {
        case jpeg, heic, tiff, png, psd, original

        var title: String {
            switch self {
            case .jpeg: "JPEG"
            case .heic: "HEIC"
            case .tiff: "TIFF"
            case .png: "PNG"
            case .psd: "PSD"
            case .original: "Original"
            }
        }

        var fileExtension: String? {
            switch self {
            case .jpeg: "jpg"
            case .heic: "heic"
            case .tiff: "tif"
            case .png: "png"
            case .psd: "psd"
            case .original: nil   // the original's
            }
        }

        var isLossy: Bool { self == .jpeg || self == .heic }
        var hasBitDepth: Bool { self == .tiff || self == .png || self == .psd }
    }

    enum ColorSpace: String, Codable, Sendable, CaseIterable {
        case sRGB, displayP3, adobeRGB, proPhotoRGB

        var title: String {
            switch self {
            case .sRGB: "sRGB IEC61966-2.1"
            case .displayP3: "Display P3"
            case .adobeRGB: "Adobe RGB (1998)"
            case .proPhotoRGB: "ProPhoto RGB"
            }
        }

        var cgColorSpace: CGColorSpace {
            let name = switch self {
            case .sRGB: CGColorSpace.sRGB
            case .displayP3: CGColorSpace.displayP3
            case .adobeRGB: CGColorSpace.adobeRGB1998
            case .proPhotoRGB: CGColorSpace.rommrgb
            }
            return CGColorSpace(name: name) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        }
    }

    enum TIFFCompression: String, Codable, Sendable, CaseIterable {
        case none, lzw, zip

        var title: String {
            switch self {
            case .none: "None"
            case .lzw: "LZW"
            case .zip: "ZIP"
            }
        }

        /// TIFF tag 259 values.
        var tagValue: Int {
            switch self {
            case .none: 1
            case .lzw: 5
            case .zip: 8
            }
        }
    }

    var format = Format.jpeg
    /// 0…100.
    var quality = 80.0
    var limitsFileSize = false
    /// Kilobytes.
    var fileSizeLimit = 500
    var colorSpace = ColorSpace.sRGB
    /// 8 or 16, for TIFF, PNG and PSD.
    var bitDepth = 8
    var tiffCompression = TIFFCompression.none

    // MARK: Image Sizing

    enum ResizeMode: String, Codable, Sendable, CaseIterable {
        case widthHeight, dimensions, longEdge, shortEdge, megapixels, percentage

        var title: String {
            switch self {
            case .widthHeight: "Width & Height"
            case .dimensions: "Dimensions"
            case .longEdge: "Long Edge"
            case .shortEdge: "Short Edge"
            case .megapixels: "Megapixels"
            case .percentage: "Percentage"
            }
        }
    }

    enum SizeUnit: String, Codable, Sendable, CaseIterable {
        case pixels, inches, centimeters

        var title: String {
            switch self {
            case .pixels: "pixels"
            case .inches: "in"
            case .centimeters: "cm"
            }
        }
    }

    enum ResolutionUnit: String, Codable, Sendable, CaseIterable {
        case pixelsPerInch, pixelsPerCentimeter

        var title: String { self == .pixelsPerInch ? "pixels per inch" : "pixels per cm" }
    }

    var resizes = false
    var resizeMode = ResizeMode.longEdge
    var width = 1000.0
    var height = 1000.0
    /// The long or short edge's size.
    var edge = 1000.0
    var megapixels = 12.0
    var percentage = 100.0
    var sizeUnit = SizeUnit.pixels
    var doesNotEnlarge = true
    var resolution = 240.0
    var resolutionUnit = ResolutionUnit.pixelsPerInch

    // MARK: Output Sharpening

    enum SharpenMedium: String, Codable, Sendable, CaseIterable {
        case screen, mattePaper, glossyPaper

        var title: String {
            switch self {
            case .screen: "Screen"
            case .mattePaper: "Matte Paper"
            case .glossyPaper: "Glossy Paper"
            }
        }
    }

    enum SharpenAmount: String, Codable, Sendable, CaseIterable {
        case low, standard, high

        var title: String {
            switch self {
            case .low: "Low"
            case .standard: "Standard"
            case .high: "High"
            }
        }
    }

    var sharpens = false
    var sharpenMedium = SharpenMedium.screen
    var sharpenAmount = SharpenAmount.standard

    // MARK: Metadata

    enum MetadataInclusion: String, Codable, Sendable, CaseIterable {
        case copyrightOnly, copyrightAndContact, allExceptCameraAndRaw, allExceptRaw, all

        var title: String {
            switch self {
            case .copyrightOnly: "Copyright Only"
            case .copyrightAndContact: "Copyright & Contact Info Only"
            case .allExceptCameraAndRaw: "All Except Camera & Camera Raw Info"
            case .allExceptRaw: "All Except Camera Raw Info"
            case .all: "All Metadata"
            }
        }

        /// Whether the photo's other metadata (and so person and location info) is included.
        var includesDescriptive: Bool { self != .copyrightOnly && self != .copyrightAndContact }
    }

    var metadata = MetadataInclusion.all
    var removesPersonInfo = false
    var removesLocationInfo = false
    /// Also write each keyword's path from the top of the keyword tree ("Places|Ireland|Dublin") as
    /// `lr:hierarchicalSubject`, which Lightroom and other apps read back as a hierarchy (RAW-182).
    var writesKeywordHierarchy = false

    // MARK: Watermarking

    var watermarks = false
    var watermarkName = WatermarkPresets.simpleCopyrightName

    // MARK: Post-Processing

    enum AfterExport: String, Codable, Sendable, CaseIterable {
        case nothing, showInFinder, openInApplication

        var title: String {
            switch self {
            case .nothing: "Do nothing"
            case .showInFinder: "Show in Finder"
            case .openInApplication: "Open in Other Application…"
            }
        }
    }

    var afterExport = AfterExport.nothing
    var applicationPath: String?

    init() {}

    // Tolerant decoding: missing keys keep their defaults.
    init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let decoded = try? container.decodeIfPresent(T.self, forKey: key) { value = decoded }
        }
        read(.destination, &destination); read(.folderPath, &folderPath); read(.usesSubfolder, &usesSubfolder)
        read(.subfolderName, &subfolderName); read(.existingFiles, &existingFiles)
        read(.renames, &renames); read(.namingTemplate, &namingTemplate); read(.customText, &customText)
        read(.startNumber, &startNumber); read(.extensionCase, &extensionCase)
        read(.includesVideo, &includesVideo)
        read(.format, &format); read(.quality, &quality); read(.limitsFileSize, &limitsFileSize)
        read(.fileSizeLimit, &fileSizeLimit); read(.colorSpace, &colorSpace); read(.bitDepth, &bitDepth)
        read(.tiffCompression, &tiffCompression)
        read(.resizes, &resizes); read(.resizeMode, &resizeMode); read(.width, &width); read(.height, &height)
        read(.edge, &edge); read(.megapixels, &megapixels); read(.percentage, &percentage)
        read(.sizeUnit, &sizeUnit); read(.doesNotEnlarge, &doesNotEnlarge); read(.resolution, &resolution)
        read(.resolutionUnit, &resolutionUnit)
        read(.sharpens, &sharpens); read(.sharpenMedium, &sharpenMedium); read(.sharpenAmount, &sharpenAmount)
        read(.metadata, &metadata); read(.removesPersonInfo, &removesPersonInfo); read(.removesLocationInfo, &removesLocationInfo)
        read(.writesKeywordHierarchy, &writesKeywordHierarchy)
        read(.watermarks, &watermarks); read(.watermarkName, &watermarkName)
        read(.afterExport, &afterExport)
        applicationPath = try? container.decodeIfPresent(String.self, forKey: .applicationPath)
    }

    // MARK: - Derived values

    /// Pixels per inch.
    var pixelsPerInch: Double {
        resolutionUnit == .pixelsPerInch ? resolution : resolution * 2.54
    }

    /// A length in the size unit, as pixels at the export resolution.
    func pixels(_ value: Double) -> Double {
        switch sizeUnit {
        case .pixels: value
        case .inches: value * pixelsPerInch
        case .centimeters: value / 2.54 * pixelsPerInch
        }
    }

    /// The scale (of the photo as shown, after cropping) the output is rendered at.
    func scale(for size: CGSize) -> CGFloat {
        guard resizes, format != .original, size.width > 0, size.height > 0 else { return 1 }
        let long = max(size.width, size.height), short = min(size.width, size.height)
        var scale: CGFloat = switch resizeMode {
        case .widthHeight:
            // Fits inside the box, whichever way the photo is turned.
            min(pixels(width) / size.width, pixels(height) / size.height)
        case .dimensions:
            // The larger value applies to the long edge.
            min(pixels(max(width, height)) / long, pixels(min(width, height)) / short)
        case .longEdge:
            pixels(edge) / long
        case .shortEdge:
            pixels(edge) / short
        case .megapixels:
            sqrt(megapixels * 1_000_000 / (size.width * size.height))
        case .percentage:
            percentage / 100
        }
        if doesNotEnlarge { scale = min(scale, 1) }
        return max(scale, 1 / max(long, 1))
    }
}
