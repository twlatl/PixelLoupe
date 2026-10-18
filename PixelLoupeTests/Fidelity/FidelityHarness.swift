import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import PixelLoupe

/// Renders photos with settings imported from Lightroom's XMP, and compares them with Lightroom's
/// own exports.
///
/// A fixtures folder holds `<family>/<case>/` directories, each with `source.<ext>` (the photo),
/// `settings.xmp` (the develop settings: a sidecar or a preset) and `reference.tif` (Lightroom's
/// 16-bit Display P3 export at 2048 px). The family is the folder name (`basic`, `curve`, `hsl`, …).
struct FidelityHarness {
    struct Case: Equatable {
        var family: String
        var name: String
        var source: URL
        var settings: URL
        var reference: URL
    }

    struct Metrics: Equatable {
        var meanDeltaE: Double
        var p95DeltaE: Double
        var ssim: Double
        /// How far the render's size is from the reference's, in pixels.
        var sizeDifference: Int
    }

    /// Where a family is expected to land. Revisit after the first run on real exports.
    struct Target: Equatable {
        var meanDeltaE: Double
        var p95DeltaE: Double
        /// Geometry families must match within this many pixels.
        var pixels: Int?
    }

    static let defaultTarget = Target(meanDeltaE: 3, p95DeltaE: 6, pixels: nil)
    static let targets: [String: Target] = [
        "default": defaultTarget,
        "crop": Target(meanDeltaE: 3, p95DeltaE: 6, pixels: 1),
        "transform": Target(meanDeltaE: 3, p95DeltaE: 6, pixels: 2),
    ]

    static func target(for family: String) -> Target { targets[family] ?? defaultTarget }

    struct Result {
        var testCase: Case
        var metrics: Metrics
        var target: Target
        var render: CGImage
        var reference: CGImage
        var differences: [ColorDifference.Lab]? = nil

        var passes: Bool {
            metrics.meanDeltaE <= target.meanDeltaE && metrics.p95DeltaE <= target.p95DeltaE
                && metrics.sizeDifference <= (target.pixels ?? Int.max)
        }
    }

    // MARK: Cases

    static func discover(in folder: URL) -> [Case] {
        let manager = FileManager.default
        var cases: [Case] = []
        let families = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        for family in families.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let directories = (try? manager.contentsOfDirectory(at: family, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
            for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                guard let source = files.first(where: { $0.deletingPathExtension().lastPathComponent == "source" }),
                      let settings = files.first(where: { $0.lastPathComponent == "settings.xmp" }),
                      let reference = files.first(where: { $0.deletingPathExtension().lastPathComponent == "reference" && ["tif", "tiff"].contains($0.pathExtension.lowercased()) })
                else { continue }
                cases.append(Case(family: family.lastPathComponent, name: directory.lastPathComponent, source: source, settings: settings, reference: reference))
            }
        }
        return cases
    }

    // MARK: Rendering

    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    /// The photo with the case's settings imported by the mapper, scaled to `size` (the reference's).
    static func render(_ testCase: Case, size: CGSize, context: CIContext) throws -> CGImage {
        let data = try Data(contentsOf: testCase.settings)
        guard let table = XMPDevelopSettings.parse(data) else { throw FidelityError.unreadableSettings(testCase.settings.lastPathComponent) }
        guard let source = DevelopSource(url: testCase.source) else { throw FidelityError.unreadableSource(testCase.source.lastPathComponent) }
        var adjustments = PhotoAdjustments()
        let input = LightroomDevelopMapper.Input(
            settings: table, processVersion: table["ProcessVersion"]?.string, whiteBalance: nil, isRaw: source.isRaw,
            imageSize: source.nativeSize)
        _ = LightroomDevelopMapper.apply(input, to: &adjustments)
        let scale = source.scale(toFit: max(size.width, size.height), adjustments: adjustments)
        var image = source.image(with: adjustments, scale: scale)
        // Land exactly on the reference's size (the render can be a pixel off from rounding).
        if Int(image.extent.width) != Int(size.width) || Int(image.extent.height) != Int(size.height) {
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: size.width / image.extent.width, y: size.height / image.extent.height))
        }
        let bounds = CGRect(origin: .zero, size: size)
        guard let rendered = context.createCGImage(image.cropped(to: bounds), from: bounds, format: .RGBA8, colorSpace: displayP3) else {
            throw FidelityError.renderFailed(testCase.name)
        }
        return rendered
    }

    static func loadReference(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FidelityError.unreadableReference(url.lastPathComponent)
        }
        return image
    }

    /// 8-bit RGBA pixels of `image` in Display P3.
    static func pixels(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: displayP3,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }

    // MARK: Comparing

    static func compare(render: CGImage, reference: CGImage) -> (metrics: Metrics, deltaE: [Double]) {
        let width = min(render.width, reference.width), height = min(render.height, reference.height)
        let a = pixels(render, width: width, height: height), b = pixels(reference, width: width, height: height)
        var deltas = [Double](repeating: 0, count: width * height)
        var lumaA = [Double](repeating: 0, count: width * height), lumaB = lumaA
        for index in 0..<(width * height) {
            let i = index * 4
            let one = ColorDifference.lab(displayP3: Double(a[i]) / 255, Double(a[i + 1]) / 255, Double(a[i + 2]) / 255)
            let two = ColorDifference.lab(displayP3: Double(b[i]) / 255, Double(b[i + 1]) / 255, Double(b[i + 2]) / 255)
            deltas[index] = ColorDifference.deltaE2000(one, two)
            lumaA[index] = one.l / 100
            lumaB[index] = two.l / 100
        }
        let sorted = deltas.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let metrics = Metrics(
            meanDeltaE: deltas.reduce(0, +) / Double(max(deltas.count, 1)), p95DeltaE: p95,
            ssim: ColorDifference.ssim(lumaA, lumaB, width: width, height: height),
            sizeDifference: max(abs(render.width - reference.width), abs(render.height - reference.height)))
        return (metrics, deltas)
    }

    static func run(_ testCase: Case, context: CIContext = CIContext(options: [.workingColorSpace: displayP3])) throws -> Result {
        let reference = try loadReference(testCase.reference)
        let render = try render(testCase, size: CGSize(width: reference.width, height: reference.height), context: context)
        let (metrics, _) = compare(render: render, reference: reference)
        return Result(testCase: testCase, metrics: metrics, target: target(for: testCase.family), render: render, reference: reference)
    }

    // MARK: Report

    /// A self-contained HTML page: a table of every case against its target, then each case's render, reference
    /// and difference (ΔE 0 black … 10 white) side by side.
    static func report(_ results: [Result], title: String = "PixelLoupe fidelity report") -> String {
        func png(_ image: CGImage) -> String {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return "" }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            return "data:image/png;base64," + (data as Data).base64EncodedString()
        }
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var html = """
            <!doctype html><meta charset="utf-8"><title>\(escape(title))</title>
            <style>body{font:14px -apple-system,sans-serif;margin:24px;color:#222}table{border-collapse:collapse}
            td,th{padding:4px 10px;border-bottom:1px solid #ddd;text-align:right}td:first-child,th:first-child,td:nth-child(2),th:nth-child(2){text-align:left}
            .fail{color:#b00020;font-weight:600}.pass{color:#0a7d33}.row{display:flex;gap:12px;margin:8px 0 28px}.row figure{margin:0}
            .row img{max-width:32vw;height:auto;border:1px solid #ccc}figcaption{font-size:12px;color:#666}</style>
            <h1>\(escape(title))</h1><table><tr><th>Family</th><th>Case</th><th>Mean ΔE</th><th>p95 ΔE</th><th>SSIM</th><th>Size off</th><th>Target</th><th></th></tr>
            """
        for result in results {
            let m = result.metrics, t = result.target
            html += "<tr><td>\(escape(result.testCase.family))</td><td>\(escape(result.testCase.name))</td>"
            html += String(format: "<td>%.2f</td><td>%.2f</td><td>%.3f</td><td>%d px</td><td>≤ %.0f / %.0f</td>", m.meanDeltaE, m.p95DeltaE, m.ssim, m.sizeDifference, t.meanDeltaE, t.p95DeltaE)
            html += result.passes ? "<td class=pass>pass</td></tr>" : "<td class=fail>FAIL</td></tr>"
        }
        html += "</table>"
        let passed = results.filter(\.passes).count
        html += "<p>\(passed) of \(results.count) within target.</p>"
        for result in results {
            let (_, deltas) = compare(render: result.render, reference: result.reference)
            html += "<h3>\(escape(result.testCase.family)) / \(escape(result.testCase.name))</h3><div class=row>"
            html += "<figure><img src=\"\(png(result.render))\"><figcaption>PixelLoupe</figcaption></figure>"
            html += "<figure><img src=\"\(png(result.reference))\"><figcaption>Lightroom</figcaption></figure>"
            if let difference = differenceImage(deltas, width: min(result.render.width, result.reference.width), height: min(result.render.height, result.reference.height)) {
                html += "<figure><img src=\"\(png(difference))\"><figcaption>Difference (ΔE 0 black … 10 white)</figcaption></figure>"
            }
            html += "</div>"
        }
        return html
    }

    static func differenceImage(_ deltas: [Double], width: Int, height: Int) -> CGImage? {
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            let v = UInt8((min(deltas[index], 10) / 10 * 255).rounded())
            data[index * 4] = v; data[index * 4 + 1] = v; data[index * 4 + 2] = v
        }
        return data.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    enum FidelityError: Error, CustomStringConvertible {
        case unreadableSettings(String), unreadableSource(String), unreadableReference(String), renderFailed(String)

        var description: String {
            switch self {
            case .unreadableSettings(let name): "Couldn't read develop settings from \(name)"
            case .unreadableSource(let name): "Couldn't open the photo \(name)"
            case .unreadableReference(let name): "Couldn't read the reference \(name)"
            case .renderFailed(let name): "Couldn't render \(name)"
            }
        }
    }
}
