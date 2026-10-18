import AppKit
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PixelLoupe

/// A 64 × 48 JPEG with camera, date and GPS metadata, as an export item.
private func makeItem(in directory: TemporaryDirectory, name: String = "IMG_0001.JPG", metadata: PhotoMetadata = PhotoMetadata(),
                      keywords: [String] = [], rating: Int = 0) throws -> ExportItem {
    let url = directory.url.appending(path: name)
    let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Noise, so JPEG quality changes the file's size.
    for x in 0..<64 { for y in 0..<48 {
        context.setFillColor(red: CGFloat((x * 37 + y * 11) % 255) / 255, green: CGFloat((x * 13 + y * 29) % 255) / 255, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: x, y: y, width: 1, height: 1))
    } }
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, [
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "EOS R5"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:12 09:30:00", kCGImagePropertyExifLensModel: "RF24-70mm"],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 40.7, kCGImagePropertyGPSLatitudeRef: "N"],
        kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCopyrightNotice: "© Example Studio"],
    ] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return ExportItem(source: url, adjustments: PhotoAdjustments(), metadata: metadata, keywords: keywords, rating: rating,
                      captureDate: Date(timeIntervalSince1970: 1_791_000_000))
}

private func properties(_ url: URL) throws -> [CFString: Any] {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
}

private func xmp(_ url: URL, _ path: String) -> String? {
    CGImageSourceCreateWithURL(url as CFURL, nil)
        .flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) }
        .flatMap { FileMetadata.xmpString($0, path) }
}

@Suite("Export settings")
struct ExportSettingsTests {
    private let landscape = CGSize(width: 6000, height: 4000)

    @Test func resizeModes() {
        var settings = ExportSettings()
        #expect(settings.scale(for: landscape) == 1, "not resizing")
        settings.resizes = true
        settings.resizeMode = .longEdge
        settings.edge = 1500
        #expect(settings.scale(for: landscape) == 0.25)
        #expect(settings.scale(for: CGSize(width: 4000, height: 6000)) == 0.25, "the long edge whichever way it's turned")
        settings.resizeMode = .shortEdge
        settings.edge = 1000
        #expect(settings.scale(for: landscape) == 0.25)
        settings.resizeMode = .widthHeight
        (settings.width, settings.height) = (3000, 1000)
        #expect(settings.scale(for: landscape) == 0.25, "fits inside the box")
        settings.resizeMode = .dimensions
        (settings.width, settings.height) = (2000, 3000)
        #expect(settings.scale(for: landscape) == 0.5, "the larger value goes to the long edge")
        settings.resizeMode = .megapixels
        settings.megapixels = 6
        #expect(abs(settings.scale(for: landscape) - 0.5) < 0.0001)
        settings.resizeMode = .percentage
        settings.percentage = 50
        #expect(settings.scale(for: landscape) == 0.5)
    }

    @Test func unitsAndEnlarging() {
        var settings = ExportSettings()
        settings.resizes = true
        settings.resizeMode = .longEdge
        settings.sizeUnit = .inches
        settings.edge = 10
        settings.resolution = 300
        #expect(settings.scale(for: landscape) == 0.5, "10 in at 300 ppi is 3000 px")
        settings.resolutionUnit = .pixelsPerCentimeter
        settings.resolution = 100
        settings.sizeUnit = .centimeters
        settings.edge = 30
        #expect(abs(settings.scale(for: landscape) - 0.5) < 0.0001)
        settings.sizeUnit = .pixels
        settings.edge = 12000
        #expect(settings.scale(for: landscape) == 1, "Don't Enlarge")
        settings.doesNotEnlarge = false
        #expect(settings.scale(for: landscape) == 2)
    }

    @Test func olderSettingsKeepDefaultsForNewOptions() throws {
        let settings = try JSONDecoder().decode(ExportSettings.self, from: Data(#"{"format": "png", "quality": 42}"#.utf8))
        #expect(settings.format == .png)
        #expect(settings.quality == 42)
        #expect(settings.metadata == .all)
    }
}

@Suite("Export presets")
@MainActor
struct ExportPresetTests {
    @Test func builtInPresetsMatchTheTicket() throws {
        let email = try #require(ExportPresets.builtIn.first { $0.name == "For Email" }?.settings)
        #expect(email.format == .jpeg && email.resizes && email.resizeMode == .longEdge && email.edge == 500 && email.resolution == 72)
        let website = try #require(ExportPresets.builtIn.first { $0.name == "For Website" }?.settings)
        #expect(website.resizes && website.edge == 1500 && website.resolution == 72)
        let full = try #require(ExportPresets.builtIn.first { $0.name == "Full Sized JPEGs" }?.settings)
        #expect(full.format == .jpeg && !full.resizes && full.metadata == .all)
    }

    @Test func userPresetsSaveRenameAndDelete() throws {
        let directory = try TemporaryDirectory()
        let presets = ExportPresets(directory: directory.url)
        var settings = ExportSettings()
        settings.format = .tiff
        try presets.save(ExportPreset(name: "Print", settings: settings))
        #expect(presets.all.map(\.name) == ["For Email", "For Website", "Full Sized JPEGs", "Print"])
        try presets.rename("Print", to: "Print TIFFs")
        #expect(presets.preset(named: "Print TIFFs")?.settings.format == .tiff)
        #expect(presets.preset(named: "Print") == nil)
        presets.delete(named: "Print TIFFs")
        #expect(presets.userPresets.isEmpty)
    }

    @Test func previousSettingsAreRemembered() {
        let presets = ExportPresets(directory: URL(filePath: "/nonexistent"))
        var settings = ExportSettings()
        settings.quality = 33
        presets.previous = settings
        #expect(presets.previous?.quality == 33)
    }
}

@Suite("Export file names")
struct ExportNamingTests {
    @Test func templates() throws {
        let directory = try TemporaryDirectory()
        let item = try makeItem(in: directory)
        var settings = ExportSettings()
        func name(_ index: Int = 0, total: Int = 3) -> String {
            ExportNaming.fileName(for: item, index: index, total: total, settings: settings)
        }
        #expect(name() == "IMG_0001.jpg")
        settings.extensionCase = .uppercase
        #expect(name() == "IMG_0001.JPG")
        settings.extensionCase = .lowercase
        settings.renames = true
        settings.customText = "Beach"
        settings.startNumber = 7
        settings.namingTemplate = .customNameSequence
        #expect(name(2) == "Beach-9.jpg")
        settings.namingTemplate = .customNameOfTotal
        #expect(name(1) == "Beach (2 of 3).jpg")
        settings.namingTemplate = .filenameSequence
        #expect(name(0) == "IMG_0001-7.jpg")
        settings.namingTemplate = .dateFilename
        #expect(name().hasSuffix("-IMG_0001.jpg") && name().hasPrefix("2026-"))
        settings.format = .original
        settings.renames = false
        #expect(name() == "IMG_0001.jpg", "the original's extension")
    }

    @Test func clashesAreSettled() throws {
        let directory = try TemporaryDirectory()
        let a = try makeItem(in: directory, name: "A.JPG")
        let output = try directory.subdirectory("Out")
        var settings = ExportSettings()
        settings.renames = true
        settings.namingTemplate = .customName
        settings.customText = "Trip"
        // Two photos named alike in one export are told apart.
        let plan = ExportPlan(items: [a, a], settings: settings, folder: output)
        #expect(plan.entries.map(\.url.lastPathComponent) == ["Trip.jpg", "Trip-2.jpg"])

        try Data().write(to: output.appending(path: "Trip.jpg"))
        #expect(plan.conflicts.map(\.url.lastPathComponent) == ["Trip.jpg"])
        #expect(plan.resolving(.skip).entries.map(\.url.lastPathComponent) == ["Trip-2.jpg"])
        #expect(plan.resolving(.overwrite).entries.map(\.url.lastPathComponent) == ["Trip.jpg", "Trip-2.jpg"])
        #expect(plan.resolving(.uniqueName).entries.map(\.url.lastPathComponent) == ["Trip-3.jpg", "Trip-2.jpg"])

        settings.usesSubfolder = true
        settings.subfolderName = "Picks"
        let nested = ExportPlan(items: [a], settings: settings, folder: output)
        #expect(nested.entries[0].url.deletingLastPathComponent().lastPathComponent == "Picks")
        let beside = ExportPlan(items: [a], settings: ExportSettings(), folder: nil)
        #expect(beside.entries[0].url.deletingLastPathComponent() == directory.url, "same folder as the original")
    }
}

@Suite("Exporting photos")
struct PhotoExporterTests {
    private func export(_ item: ExportItem, _ settings: ExportSettings, watermark: PhotoExporter.Watermark? = nil,
                        in directory: TemporaryDirectory) async throws -> URL {
        let url = directory.url.appending(path: "Out/\(UUID().uuidString).\(settings.format.fileExtension ?? "jpg")")
        try await PhotoExporter.export(item, to: url, settings: settings, watermark: watermark)
        return url
    }

    @Test func jpegsAreSizedWithTheirResolutionAndQuality() async throws {
        let directory = try TemporaryDirectory()
        let item = try makeItem(in: directory)
        var settings = ExportSettings()
        settings.resizes = true
        settings.resizeMode = .longEdge
        settings.edge = 32
        settings.resolution = 72
        let small = try await export(item, settings, in: directory)
        let props = try properties(small)
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 32)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 24)
        #expect(props[kCGImagePropertyDPIWidth] as? Double == 72)

        settings.resizes = false
        settings.quality = 5
        let low = try await export(item, settings, in: directory)
        settings.quality = 100
        let high = try await export(item, settings, in: directory)
        let size = { (url: URL) in (try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int) ?? 0 }
        #expect(try size(low) < size(high))

        settings.limitsFileSize = true
        settings.fileSizeLimit = max(1, (try size(high)) / 1024)
        let limited = try await export(item, settings, in: directory)
        #expect(try size(limited) <= settings.fileSizeLimit * 1024)
    }

    @Test(arguments: [ExportSettings.Format.heic, .tiff, .png, .psd])
    func otherFormats(format: ExportSettings.Format) async throws {
        let directory = try TemporaryDirectory()
        let item = try makeItem(in: directory)
        var settings = ExportSettings()
        settings.format = format
        settings.bitDepth = 16
        settings.tiffCompression = .lzw
        settings.colorSpace = .displayP3
        let url = try await export(item, settings, in: directory)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let expected: String = switch format {
        case .heic: UTType.heic.identifier
        case .tiff: UTType.tiff.identifier
        case .png: UTType.png.identifier
        default: "com.adobe.photoshop-image"
        }
        #expect(CGImageSourceGetType(source) as String? == expected)
        let props = try properties(url)
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 64)
        if format == .png || format == .tiff {
            #expect(props[kCGImagePropertyDepth] as? Int == 16, "16 bits/component")
        }
        if format == .tiff {
            #expect((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFCompression] as? Int == 5, "LZW")
        }
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.colorSpace?.name == CGColorSpace.displayP3)
    }

    @Test func originalsAreCopiedUntouched() async throws {
        let directory = try TemporaryDirectory()
        let item = try makeItem(in: directory)
        var settings = ExportSettings()
        settings.format = .original
        let url = try await export(item, settings, in: directory)
        #expect(try Data(contentsOf: url) == Data(contentsOf: item.source))
    }

    @Test func metadataFollowsInclude() async throws {
        let directory = try TemporaryDirectory()
        var metadata = PhotoMetadata()
        metadata[.title] = "Morning Light"
        metadata[.city] = "Savannah"
        let item = try makeItem(in: directory, metadata: metadata, keywords: ["Beach", "Family"], rating: 4)
        var settings = ExportSettings()

        let all = try await export(item, settings, in: directory)
        var props = try properties(all)
        #expect((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] as? String == "EOS R5")
        #expect(props[kCGImagePropertyGPSDictionary] != nil)
        #expect(xmp(all, "dc:title") == "Morning Light", "metadata typed into PixelLoupe")
        #expect(xmp(all, "photoshop:City") == "Savannah")
        #expect((props[kCGImagePropertyIPTCDictionary] as? [CFString: Any])?[kCGImagePropertyIPTCKeywords] as? [String] == ["Beach", "Family"])
        #expect(xmp(all, "xmp:Rating") == "4")
        #expect(props[kCGImagePropertyOrientation] as? Int ?? 1 == 1)

        settings.removesLocationInfo = true
        settings.metadata = .allExceptCameraAndRaw
        let noCamera = try await export(item, settings, in: directory)
        props = try properties(noCamera)
        #expect((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] == nil)
        #expect((props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel] == nil)
        #expect(props[kCGImagePropertyGPSDictionary] == nil, "Remove Location Info")
        #expect(xmp(noCamera, "dc:title") == "Morning Light")

        settings.metadata = .copyrightOnly
        let copyright = try await export(item, settings, in: directory)
        props = try properties(copyright)
        #expect((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] == nil)
        #expect(xmp(copyright, "dc:title") == nil)
        #expect(xmp(copyright, "dc:rights") == "© Example Studio", "the copyright is kept")
    }

    @Test func watermarksAreDrawn() async throws {
        let directory = try TemporaryDirectory()
        let item = try makeItem(in: directory)
        var watermark = WatermarkSettings()
        watermark.text = "████"
        watermark.size = .fit
        watermark.anchor = .center
        watermark.shadow.isEnabled = false
        var settings = ExportSettings()
        settings.format = .png
        let url = try await export(item, settings, watermark: .init(settings: watermark, imageURL: nil), in: directory)
        let image = try #require(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: -32, y: -24, width: 64, height: 48))
        #expect(pixel[0] > 240 && pixel[1] > 240 && pixel[2] > 240, "white watermark in the middle")
    }

    @Test func runsExportEveryPhotoAndReportProgress() async throws {
        let directory = try TemporaryDirectory()
        let items = try (1...3).map { try makeItem(in: directory, name: "P\($0).JPG") }
        let output = try directory.subdirectory("Exported")
        let plan = ExportPlan(items: items + [ExportItem(source: directory.url.appending(path: "Missing.JPG"), adjustments: .init(),
                                                         metadata: .init(), keywords: [], rating: 0, captureDate: .now)],
                              settings: ExportSettings(), folder: output)
        let progress = ProgressLog()
        let result = await PhotoExporter.run(plan, settings: ExportSettings(), watermark: nil) { completed, total in
            progress.values.append("\(completed)/\(total)")
        }
        #expect(Set(result.exported.map(\.lastPathComponent)) == ["P1.jpg", "P2.jpg", "P3.jpg"])
        #expect(result.failures.count == 1 && result.failures[0].hasPrefix("Missing.jpg"))
        #expect(progress.values.last == "4/4")
    }

    @MainActor private final class ProgressLog {
        var values: [String] = []
    }
}

@Suite("Export dialog")
@MainActor
struct ExportDialogTests {
    private func dialog(_ count: Int = 2) throws -> (ExportDialogController, TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        let items = try (0..<count).map { try makeItem(in: directory, name: "IMG_\($0).JPG") }
        Defaults.store.removeObject(forKey: "HiddenDefaultWatermarks")
        let dialog = ExportDialogController(
            items: items, settings: ExportSettings(),
            presets: ExportPresets(directory: directory.url.appending(path: "Presets")),
            watermarks: WatermarkPresets(directory: directory.url.appending(path: "Watermarks"))
        )
        return (dialog, directory)
    }

    @Test func choosingAPresetLoadsItsSettings() throws {
        let (dialog, directory) = try dialog()
        _ = directory
        #expect(dialog.window?.title == "Export 2 Files")
        #expect(dialog.exampleLabel.stringValue == "IMG_0.jpg")
        dialog.choosePreset(named: "For Email")
        #expect(dialog.settings.edge == 500)
        #expect(dialog.resizeCheckbox.state == .on)
        #expect(dialog.widthField.stringValue == "500")
        #expect(dialog.heightField.isHidden, "long edge takes one value")
        #expect(dialog.resolutionField.stringValue == "72")
    }

    @Test func controlsFollowTheFormat() throws {
        let (dialog, directory) = try dialog()
        _ = directory
        #expect(dialog.qualityRow.slider.isEnabled)
        #expect(!dialog.bitDepthPopUp.isEnabled)
        dialog.formatPopUp.selectItem(withTitle: "TIFF")
        dialog.formatPopUp.sendAction(dialog.formatPopUp.action, to: dialog.formatPopUp.target)
        #expect(dialog.settings.format == .tiff)
        #expect(!dialog.qualityRow.slider.isEnabled)
        #expect(dialog.bitDepthPopUp.isEnabled && dialog.compressionPopUp.isEnabled)
        #expect(dialog.exampleLabel.stringValue == "IMG_0.tif")
        dialog.formatPopUp.selectItem(withTitle: "Original")
        dialog.formatPopUp.sendAction(dialog.formatPopUp.action, to: dialog.formatPopUp.target)
        #expect(!dialog.resizeCheckbox.isEnabled && !dialog.watermarkCheckbox.isEnabled, "originals are copied as they are")
    }

    @Test func addingAndRemovingUserPresets() throws {
        let (dialog, directory) = try dialog()
        _ = directory
        dialog.formatPopUp.selectItem(withTitle: "PNG")
        dialog.formatPopUp.sendAction(dialog.formatPopUp.action, to: dialog.formatPopUp.target)
        try dialog.addPreset(named: "Web PNGs")
        #expect(dialog.presets.preset(named: "Web PNGs")?.settings.format == .png)
        #expect(dialog.removePresetButton.isEnabled)
        dialog.choosePreset(named: "For Email")
        #expect(!dialog.removePresetButton.isEnabled, "built-in presets stay")
        dialog.removePreset(named: "Web PNGs")
        #expect(dialog.presets.userPresets.isEmpty)
    }

    @Test func doneKeepsSettingsAndCancelDoesNot() throws {
        let (dialog, directory) = try dialog()
        _ = directory
        var results: [(ExportSettings?, Bool)] = []
        dialog.onFinish = { results.append(($0, $1)) }
        dialog.done(nil)
        dialog.cancel(nil)
        dialog.export(nil)
        #expect(results.map { $0.0 != nil } == [true, false, true])
        #expect(results.map(\.1) == [false, false, true])
    }

    @Test func exportCommandsHaveLightroomsShortcuts() throws {
        let file = try #require(MainMenu.make().items.first { $0.submenu?.title == "File" }?.submenu)
        let export = try #require(file.items.first { $0.title == "Export…" })
        #expect(export.keyEquivalent == "e" && export.keyEquivalentModifierMask == [.command, .shift])
        let previous = try #require(file.items.first { $0.title == "Export with Previous" })
        #expect(previous.keyEquivalentModifierMask == [.command, .shift, .option])
        let presets = try #require(file.items.first { $0.title == "Export with Preset" }?.submenu)
        presets.delegate?.menuNeedsUpdate?(presets)
        #expect(presets.items.map(\.title).contains("For Email"))
    }

    /// Draws the dialog into a PNG (for reviewing its layout): PIXELLOUPE_EXPORT_SNAPSHOT=path.
    @Test func snapshot() throws {
        guard let path = ProcessInfo.processInfo.environment["PIXELLOUPE_EXPORT_SNAPSHOT"] else { return }
        let (dialog, directory) = try dialog(6)
        _ = directory
        let view = try #require(dialog.window?.contentView)
        dialog.window?.layoutIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
    }
}
