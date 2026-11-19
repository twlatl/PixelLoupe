import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PixelLoupe

/// RAW-304: real camera profiles on real photos, for looking at and for measuring against Lightroom (RAW-126 decision 6).
/// Run by `Scripts/camera-profiles.sh`; nobody's profiles or photos are in the repository.
///
/// - `PIXELLOUPE_DCP_PROFILES`: a folder of `.dcp` files.
/// - `PIXELLOUPE_DCP_PHOTOS`: a folder of RAW files. A Lightroom export of a photo with a profile, named
///   "<photo> - <profile name>" (`DSC00384 - Classic Chrome.jpg`, any image type), is compared with PixelLoupe's.
/// - `PIXELLOUPE_DCP_OUTPUT`: where the renderings and `report.md` go.
struct DNGCameraProfileSampleTests {
    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PIXELLOUPE_DCP_PROFILES"] != nil))
    func realProfilesReadAndRender() throws {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        func files(_ folder: URL) -> [URL] {
            ((try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        let profileFiles = files(URL(filePath: try #require(environment["PIXELLOUPE_DCP_PROFILES"]))).filter { $0.pathExtension.lowercased() == "dcp" }
        try #require(!profileFiles.isEmpty, "no .dcp files in PIXELLOUPE_DCP_PROFILES")
        let output = URL(filePath: environment["PIXELLOUPE_DCP_OUTPUT"] ?? NSTemporaryDirectory() + "PixelLoupe-CameraProfiles")
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        var report = "# Camera profiles\n\n## Profiles\n\n| File | Name | Camera | Lights | Hue/saturation map | Look table | Tone curve | Exposure offset |\n|---|---|---|---|---|---|---|---|\n"

        let library = AdobeProfileLibrary(directory: output.appending(path: "Library-\(UUID().uuidString)"))
        defer { try? fileManager.removeItem(at: library.directory) }
        var profiles: [DNGCameraProfile] = []
        for file in profileFiles {
            let profile = try #require(DNGCameraProfile.load(file), "\(file.lastPathComponent) didn't read")
            func size(_ table: AdobeProfile.LookTable?) -> String {
                table.map { "\($0.hueDivisions) × \($0.saturationDivisions) × \($0.valueDivisions)\($0.valueIsSRGB ? " sRGB" : "")" } ?? "none"
            }
            report += "| \(file.lastPathComponent) | \(profile.name) | \(profile.cameraModel) | \(profile.calibrations.map { String($0.illuminant) }.joined(separator: ", ")) "
                + "| \(size(profile.calibrations.first?.hueSaturationMap)) | \(size(profile.lookTable)) "
                + "| \(profile.toneCurve.map { "\($0.count) points" } ?? "none") | \(profile.baselineExposureOffset) |\n"
            #expect(!profile.name.isEmpty && !profile.cameraModel.isEmpty)
            library.register(profile)
            profiles.append(profile)
        }

        let all = environment["PIXELLOUPE_DCP_PHOTOS"].map { files(URL(filePath: $0)) } ?? []
        let photos = all.filter { SupportedImageTypes.isRaw($0) }
        if !photos.isEmpty {
            report += "\n## Photos\n\nMean brightness is L\\* over the frame. ΔE2000 is against a Lightroom export of the same photo and profile, where there is one.\n\n"
                + "| Photo | Profile | Mean L\\* | Bake (s) | ΔE2000 mean | ΔE2000 p95 |\n|---|---|---|---|---|---|\n"
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        for photo in photos {
            let source = try #require(DevelopSource(url: photo), "\(photo.lastPathComponent) didn't open")
            source.profiles = library
            let stem = photo.deletingPathExtension().lastPathComponent
            // PixelLoupe leaves a profile's hue/saturation map out. On the profile's own camera it's rendered with the
            // map as well, to see which is nearer Lightroom.
            let metadata = ImageMetadata.read(from: photo)
            var choices: [(profile: DNGCameraProfile?, name: String, withMap: Bool)] = [(nil, "Default", false)]
            for profile in profiles {
                choices.append((profile, profile.name, false))
                if profile.isFor(cameraMake: metadata?.cameraMake, model: metadata?.cameraModel),
                   profile.calibrations.contains(where: { $0.hueSaturationMap != nil }) {
                    choices.append((profile, profile.name, true))
                }
            }
            for (profile, exportName, withMap) in choices {
                library.appliesHueSaturationMaps = withMap
                let name = exportName + (withMap ? " (with map)" : "")
                var adjustments = PhotoAdjustments()
                adjustments.profile.adobeID = profile?.id
                let clock = ContinuousClock.now
                let image = source.image(with: adjustments, scale: source.scale(toFit: 1600))
                let baked = clock.duration(to: .now)
                let rendering = output.appending(path: "\(stem) - \(name).jpg")
                try context.writeJPEGRepresentation(of: image, to: rendering, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92])
                let ours = Self.blocks(image, context: context)
                let brightness = ours.map(\.l).reduce(0, +) / Double(max(ours.count, 1))
                var line = "| \(stem) | \(name) | \(String(format: "%.1f", brightness)) | \(String(format: "%.2f", Double(baked.components.attoseconds) / 1e18 + Double(baked.components.seconds))) "
                // Lightroom's export of the same photo and profile, beside the photo.
                let export = all.first { !SupportedImageTypes.isRaw($0) && $0.deletingPathExtension().lastPathComponent == "\(stem) - \(exportName)" }
                if let export, let theirs = CIImage(contentsOf: export, options: [.applyOrientationProperty: true]).map({ Self.blocks($0, context: context) }),
                   theirs.count == ours.count {
                    let differences = zip(ours, theirs).map { ColorDifference.deltaE2000($0, $1) }.sorted()
                    line += "| \(String(format: "%.2f", differences.reduce(0, +) / Double(differences.count))) "
                        + "| \(String(format: "%.2f", differences[differences.count * 95 / 100])) |\n"
                } else {
                    line += "| | |\n"
                }
                report += line
            }
        }
        try Data(report.utf8).write(to: output.appending(path: "report.md"))
        print(report)
    }

    /// The image as a 48 × 32 grid of block averages (so a pixel's worth of misalignment doesn't count), in Lab.
    private static func blocks(_ image: CIImage, context: CIContext) -> [ColorDifference.Lab] {
        let columns = 48, rows = 32
        let extent = image.extent
        let scaled = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: CGFloat(columns) / extent.width, y: CGFloat(rows) / extent.height)))
        var pixels = [Float](repeating: 0, count: columns * rows * 4)
        context.render(scaled, toBitmap: &pixels, rowBytes: columns * 16, bounds: CGRect(x: 0, y: 0, width: columns, height: rows),
                       format: .RGBAf, colorSpace: displayP3)
        return (0..<(columns * rows)).map {
            ColorDifference.lab(displayP3: Double(pixels[$0 * 4]).clamped(to: 0...1), Double(pixels[$0 * 4 + 1]).clamped(to: 0...1),
                                Double(pixels[$0 * 4 + 2]).clamped(to: 0...1))
        }
    }
}
