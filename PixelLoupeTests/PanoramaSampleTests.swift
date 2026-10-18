import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PixelLoupe

/// Photo Merge ▸ Panorama on the RAW-95 sample photos against Lightroom's merges of them. The photos
/// (about 860 MB) live outside the repository, in `~/Source/PixelLoupe-Sample-Images/Panorama` or the
/// folder `PIXELLOUPE_PANORAMA_SAMPLES` names, so these run only where they are (never in CI). The
/// full-resolution merge, which takes a minute or two, runs only with `PIXELLOUPE_PANORAMA_FULL` set
/// (see Scripts/panorama.sh); `PIXELLOUPE_PANORAMA_OUTPUT` names a folder for the merged images and
/// side-by-side comparisons.
@Suite("Panorama samples", .enabled(if: PanoramaSamples.folder != nil), .serialized)
struct PanoramaSampleTests {
    @Test func samplesAlignAsLightroomsMergeDoes() async throws {
        let samples = try PanoramaSamples()
        let start = Date()
        let merger = try PanoramaMerger(sources: samples.sources)
        PanoramaSamples.note("read and aligned in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        #expect(merger.mergedCount == 12)
        // About 200° across: too wide for Perspective, as in Lightroom.
        #expect(!merger.allowsPerspective)
        #expect(merger.lensWarning == PanoramaMerger.lensNotice, "a Viltrox lens LensFun doesn't know")

        // Lightroom's Spherical merge is 26378 × 8836 (2.99:1).
        let spherical = try merger.size(for: .spherical)
        #expect(abs(spherical.width / spherical.height - 26378.0 / 8836) / (26378.0 / 8836) < 0.03, "\(spherical)")
        #expect(abs(spherical.width - 26378) / 26378 < 0.03, "\(spherical)")
        // Lightroom's Cylindrical is the same projection and scale, but its canvas leaves off the right
        // end of the photos (about 10°); ours keeps them, so it's as wide as Spherical.
        let cylindrical = try merger.size(for: .cylindrical)
        #expect(abs(cylindrical.height - 10102) / 10102 < 0.03, "\(cylindrical)")
        #expect(abs(cylindrical.width - spherical.width) < 2)
    }

    @Test func previewsAreQuick() async throws {
        let samples = try PanoramaSamples()
        let merger = try PanoramaMerger(sources: samples.sources)
        for projection in [PanoramaProjection.spherical, .cylindrical] {
            var options = PanoramaMergeOptions()
            options.projection = projection
            let size = try merger.size(for: projection)
            let scale = 2400 / max(size.width, size.height)
            var start = Date()
            let first = try merger.merge(options: options, scale: scale)
            let firstTime = Date().timeIntervalSince(start)
            // Changing an option reuses the alignment and seams.
            options.autoCrop = true
            start = Date()
            _ = try merger.merge(options: options, scale: scale)
            let againTime = Date().timeIntervalSince(start)
            options.boundaryWarp = 100
            start = Date()
            let warped = try merger.merge(options: options, scale: scale)
            let warpTime = Date().timeIntervalSince(start)
            PanoramaSamples.note("\(projection.title) preview \(first.image.width)×\(first.image.height) in \(String(format: "%.2f", firstTime))s, Auto Crop \(String(format: "%.2f", againTime))s, Boundary Warp 100 \(String(format: "%.2f", warpTime))s")
            #expect(againTime < 1)
            if let output = PanoramaSamples.output {
                try PanoramaSamples.write(first, to: output.appending(path: "\(projection.rawValue)-preview.jpg"))
                try PanoramaSamples.write(warped, to: output.appending(path: "\(projection.rawValue)-warp100-preview.jpg"))
            }
            // Boundary Warp at 100 fills nearly all of the rectangle.
            let covered = try #require(warped.coverage).values
            #expect(covered.reduce(0, +) / Float(covered.count) > 0.97)
            let plain = try #require(first.coverage).values
            #expect(plain.reduce(0, +) / Float(plain.count) < 0.97)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PIXELLOUPE_PANORAMA_FULL"] != nil), .timeLimit(.minutes(20)))
    func fullResolutionMergesMatchLightroomsShape() async throws {
        let samples = try PanoramaSamples()
        let output = PanoramaSamples.output ?? FileManager.default.temporaryDirectory.appending(path: "PanoramaSamples")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (projection, lightroom) in [(PanoramaProjection.spherical, "LR Spherical Output.dng"), (.cylindrical, "LR Cylindrical.dng")] {
            var options = PanoramaMergeOptions()
            options.projection = projection
            options.autoSettings = false
            let destination = output.appending(path: "DSC00245-\(projection.title).dng")
            try? FileManager.default.removeItem(at: destination)
            let start = Date()
            let result = try await PanoramaMergeRunner.run(
                sources: samples.sources, options: options, destination: destination, thumbnailDirectory: output
            )
            let seconds = Date().timeIntervalSince(start)
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            PanoramaSamples.note("\(projection.title) full merge \(result.output.pixelWidth)×\(result.output.pixelHeight) in \(String(format: "%.1f", seconds))s, peak memory \(usage.ru_maxrss / 1_048_576) MB")
            #expect(result.mergedCount == 12)
            let theirs = try #require(CIRAWFilter(imageURL: PanoramaSamples.folder!.appending(path: lightroom))).nativeSize
            let ours = CGSize(width: result.output.pixelWidth, height: result.output.pixelHeight)
            PanoramaSamples.note("\(projection.title) ours \(Int(ours.width))×\(Int(ours.height)) (\(String(format: "%.3f", ours.width / ours.height)):1), Lightroom's \(Int(theirs.width))×\(Int(theirs.height)) (\(String(format: "%.3f", theirs.width / theirs.height)):1)")
            #expect(abs(ours.height - theirs.height) / theirs.height < 0.03)
            try PanoramaSamples.compare(destination, with: PanoramaSamples.folder!.appending(path: lightroom),
                                        to: output.appending(path: "\(projection.rawValue)-compare.jpg"))
        }
    }
}

/// The RAW-95 sample photos, read as the catalog would.
nonisolated struct PanoramaSamples {
    static var folder: URL? {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["PIXELLOUPE_PANORAMA_SAMPLES"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Source/PixelLoupe-Sample-Images/Panorama").path
        var isDirectory: ObjCBool = false
        guard environment["CI"] == nil, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// Prints a timing or size, and adds it to `timings.txt` in the output folder.
    static func note(_ line: String) {
        print("Panorama samples: \(line)")
        guard let output else { return }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = output.appending(path: "timings.txt")
        let text = Data("\(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(text)
            try? handle.close()
        } else {
            try? text.write(to: url)
        }
    }

    static var output: URL? {
        ProcessInfo.processInfo.environment["PIXELLOUPE_PANORAMA_OUTPUT"].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    let sources: [PhotoMergeSource]

    init() throws {
        let folder = try #require(Self.folder)
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("DSC") && $0.pathExtension.uppercased() == "ARW" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(urls.count == 12)
        sources = urls.map(Self.source)
    }

    static func source(_ url: URL) -> PhotoMergeSource {
        let properties = CGImageSourceCreateWithURL(url as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let exifAux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let shooting = ShootingInfo(properties: properties)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return PhotoMergeSource(
            url: url, exposureTime: shooting.exposureTime ?? 0, aperture: shooting.aperture ?? 0, iso: shooting.iso ?? 0,
            make: tiff[kCGImagePropertyTIFFMake] as? String, model: tiff[kCGImagePropertyTIFFModel] as? String,
            lensModel: exifAux[kCGImagePropertyExifAuxLensModel] as? String ?? exif[kCGImagePropertyExifLensModel] as? String,
            focalLength: shooting.focalLength ?? 0,
            captureDate: (exif[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(formatter.date)
        )
    }

    /// Ours above Lightroom's, each drawn the way PixelLoupe first shows a DNG, 3000 pixels across,
    /// and a strip of each at 100% from the middle.
    static func compare(_ ours: URL, with theirs: URL, to url: URL) throws {
        let context = PhotoRenderer.context
        func drawn(_ url: URL, width: CGFloat) throws -> CIImage {
            let source = try #require(DevelopSource(url: url))
            let image = source.image(with: PhotoAdjustments(), scale: width / source.nativeSize.width)
            return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        func detail(_ url: URL) throws -> CIImage {
            let source = try #require(DevelopSource(url: url))
            let image = source.image(with: PhotoAdjustments(), scale: 1)
            let middle = CGRect(x: image.extent.midX - 750, y: image.extent.midY - 300, width: 1500, height: 600)
            return image.cropped(to: middle).transformed(by: CGAffineTransform(translationX: -middle.minX, y: -middle.minY))
        }
        let top = try drawn(ours, width: 3000), bottom = try drawn(theirs, width: 3000)
        let oursDetail = try detail(ours), theirsDetail = try detail(theirs)
        let gap: CGFloat = 20
        let height = top.extent.height + bottom.extent.height + 600 + 3 * gap
        var canvas = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 3000, height: height))
        canvas = bottom.transformed(by: CGAffineTransform(translationX: 0, y: 600 + gap)).composited(over: canvas)
        canvas = top.transformed(by: CGAffineTransform(translationX: 0, y: 600 + bottom.extent.height + 2 * gap)).composited(over: canvas)
        canvas = oursDetail.composited(over: canvas)
        canvas = theirsDetail.transformed(by: CGAffineTransform(translationX: 1500, y: 0)).composited(over: canvas)
        let cg = try #require(context.createCGImage(canvas, from: canvas.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// The merge as a JPEG, drawn the way PixelLoupe first shows it (via a temporary DNG and the
    /// Develop pipeline), with a checkerboard where the photos don't reach.
    static func write(_ result: PanoramaMergeResult, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dng = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: dng) }
        try LinearDNGWriter.write(result.image, metadata: DNGMetadata(make: "Sony", model: "ILCE-7CR"), to: dng)
        let source = try #require(DevelopSource(url: dng))
        let image = source.image(with: PhotoAdjustments(), scale: 1)
        let cg = try #require(PhotoRenderer.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }
}
