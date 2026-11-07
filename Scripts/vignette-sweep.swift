// Builds the Post-Crop Vignette fidelity cases (RAW-275): flat-gray and tone-pattern sources and one Lightroom
// settings XMP per case, in the fidelity layout (<fixtures>/effects-vignette/<case>/{source.tif, settings.xmp}).
// Lightroom's exports (reference.tif) are then made by the PixelLoupe Fidelity plugin
// (Scripts/PixelLoupeFidelity.lrplugin), and Scripts/fidelity.sh compares PixelLoupe's renders with them.
//
//   xcrun swift Scripts/vignette-sweep.swift <fixtures folder> [photo.CR2]
//   xcrun swift Scripts/vignette-sweep.swift --calibration <calibration folder>
//
// --calibration writes the cases the renderer's constants were fitted from instead (<folder>/vignette-calibration),
// outside the fidelity fixtures so the suite doesn't run them: Paint Overlay at −100 and +100 on flat gray (where the
// mask reads straight off the export) over a Midpoint × Feather grid and Roundness, and Highlights at more amounts.
//
// Both sources are 2048 × 1366 (3:2, Lightroom's export size on the long edge, so nothing is resampled):
// - flat: neutral gray at half the encoded range. The vignette's falloff (Midpoint, Feather, Roundness, the crop)
//   reads straight off it.
// - tones: 16 × 16 blocks in a fixed pseudo-random order of 32 neutral levels, with every fourth block a moderately
//   saturated color, so every distance from the center sees every tone. Amount, the styles and Highlights read off it.
// With a photo, a "photo" case is added at Ted's reported settings: the plugin first exports the photo from Lightroom
// with the vignette off as its source, so only the vignette differs.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

var arguments = CommandLine.arguments
let calibration = arguments.count > 1 && arguments[1] == "--calibration"
if calibration { arguments.remove(at: 1) }
guard (2...3).contains(arguments.count), !(calibration && arguments.count == 3) else {
    FileHandle.standardError.write(Data("usage: vignette-sweep.swift <fixtures folder> [photo.CR2] | --calibration <folder>\n".utf8))
    exit(64)
}
let family = URL(fileURLWithPath: arguments[1]).appending(path: calibration ? "vignette-calibration" : "effects-vignette")
let manager = FileManager.default
try manager.createDirectory(at: family, withIntermediateDirectories: true)

// MARK: The sources

let width = 2048, height = 1366, block = 16

/// HSV to RGB, 0…1.
func rgb(hue: Double, saturation: Double, value: Double) -> (Double, Double, Double) {
    let c = value * saturation, h = hue / 60, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
    let (r, g, b): (Double, Double, Double) = switch h {
    case ..<1: (c, x, 0)
    case ..<2: (x, c, 0)
    case ..<3: (0, c, x)
    case ..<4: (0, x, c)
    case ..<5: (x, 0, c)
    default: (c, 0, x)
    }
    let m = value - c
    return (r + m, g + m, b + m)
}

/// A fixed hash, so the pattern is the same on every run.
func hash(_ x: Int, _ y: Int) -> UInt32 {
    var h = UInt32(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663)
    h ^= h >> 13; h = h &* 0x5BD1_E995; h ^= h >> 15
    return h
}

func write(_ name: String, color: (Int, Int) -> (Double, Double, Double)) throws -> URL {
    var pixels = [UInt16](repeating: 0, count: width * height * 3)
    for y in 0..<height {
        for x in 0..<width {
            let c = color(x, y), index = (y * width + x) * 3
            pixels[index] = UInt16((c.0 * 65535).rounded())
            pixels[index + 1] = UInt16((c.1 * 65535).rounded())
            pixels[index + 2] = UInt16((c.2 * 65535).rounded())
        }
    }
    let url = family.appending(path: ".\(name).tif")
    let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
    guard let provider = CGDataProvider(data: data as CFData),
          let space = CGColorSpace(name: CGColorSpace.displayP3),
          let image = CGImage(
              width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 6, space: space,
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)
    else { fatalError("couldn't make \(name)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("couldn't write \(url.path)") }
    return url
}

let flat = try write("flat") { _, _ in (0.5, 0.5, 0.5) }
let tones = try write("tones") { x, y in
    let h = hash(x / block, y / block)
    let value = 0.02 + 0.98 * Double(h % 32) / 31
    guard (h >> 8) % 4 == 0 else { return (value, value, value) }
    return rgb(hue: Double((h >> 12) % 6) * 60, saturation: 0.45, value: value)
}

// MARK: The cases

/// One case's vignette and crop, in Lightroom's units. Style: 1 Highlight Priority, 2 Color Priority, 3 Paint Overlay.
struct Vignette {
    var amount = -60
    var midpoint = 50
    var feather = 50
    var roundness = 0
    var highlights = 0
    var style = 1
    /// Left, top, right, bottom, 0…1; nil for no crop.
    var crop: (Double, Double, Double, Double)? = nil
}

/// Every vignette and crop setting is written, so applying a case over an earlier one leaves nothing behind.
func xmp(_ v: Vignette) -> String {
    let crop = v.crop ?? (0, 0, 1, 1)
    let attributes = [
        "crs:PostCropVignetteAmount=\"\(v.amount)\"", "crs:PostCropVignetteMidpoint=\"\(v.midpoint)\"",
        "crs:PostCropVignetteFeather=\"\(v.feather)\"", "crs:PostCropVignetteRoundness=\"\(v.roundness)\"",
        "crs:PostCropVignetteStyle=\"\(v.style)\"", "crs:PostCropVignetteHighlightContrast=\"\(v.highlights)\"",
        "crs:HasCrop=\"\(v.crop == nil ? "False" : "True")\"", "crs:CropAngle=\"0\"",
        "crs:CropLeft=\"\(crop.0)\"", "crs:CropTop=\"\(crop.1)\"", "crs:CropRight=\"\(crop.2)\"", "crs:CropBottom=\"\(crop.3)\"",
    ]
    return """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:ProcessVersion="11.0" crs:HasSettings="True"
          \(attributes.joined(separator: "\n  "))/>
        </rdf:RDF></x:xmpmeta><?xpacket end="w"?>

        """
}

func signed(_ value: Int) -> String { value < 0 ? String(format: "m%03d", -value) : String(format: "p%03d", value) }

let styles = [(1, "hp"), (2, "cp"), (3, "po")]
var cases: [(name: String, source: URL, vignette: Vignette)] = []
if calibration {
    for amount in [-100, 100] {
        for midpoint in stride(from: 0, through: 100, by: 25) {
            for feather in stride(from: 0, through: 100, by: 25) {
                cases.append((String(format: "grid-%@-m%03d-f%03d", signed(amount), midpoint, feather), flat,
                              Vignette(amount: amount, midpoint: midpoint, feather: feather, style: 3)))
            }
        }
        for roundness in [-100, -50, 50, 100] {
            cases.append(("round-\(signed(amount))-r\(signed(roundness))", flat, Vignette(amount: amount, roundness: roundness, style: 3)))
        }
    }
    // Roundness with other midpoints, and on a portrait crop.
    for (midpoint, roundness) in [(0, -100), (0, 100), (100, -100), (100, 100)] {
        cases.append((String(format: "round-m100-m%03d-r%@", midpoint, signed(roundness)), flat,
                      Vignette(amount: -100, midpoint: midpoint, roundness: roundness, style: 3)))
    }
    for roundness in [-100, 100] {
        cases.append(("round-m100-portrait-r\(signed(roundness))", flat, Vignette(amount: -100, roundness: roundness, style: 3, crop: (0.3, 0, 0.7, 1))))
    }
    // Whether Feather's reach depends on the style or the amount.
    for (style, name) in styles {
        for amount in [-100, -60, -30, 60] {
            for feather in [75, 100] {
                cases.append((String(format: "feather-%@-%@-f%03d", name, signed(amount), feather), flat,
                              Vignette(amount: amount, feather: feather, style: style)))
            }
        }
    }
    // Highlights at other amounts and styles' colors.
    for amount in [-30, -100] {
        for highlights in [50, 100] {
            for (style, name) in styles.prefix(2) {
                cases.append((String(format: "highlights-%@-%@-%03d", name, signed(amount), highlights), tones,
                              Vignette(amount: amount, highlights: highlights, style: style)))
            }
        }
    }
}
if !calibration {
// Amount and style, on the tones.
for (style, name) in styles {
    for amount in [-100, -60, -30, 30, 60, 100] {
        cases.append(("amount-\(name)-\(signed(amount))", tones, Vignette(amount: amount, style: style)))
    }
}
// The falloff's shape, one slider at a time around −60 Highlight Priority, on flat gray.
cases.append(("shape-base", flat, Vignette()))
for midpoint in [0, 25, 75, 100] { cases.append((String(format: "midpoint-%03d", midpoint), flat, Vignette(midpoint: midpoint))) }
for feather in [0, 25, 75, 100] { cases.append((String(format: "feather-%03d", feather), flat, Vignette(feather: feather))) }
for roundness in [-100, -50, 50, 100] { cases.append(("roundness-\(signed(roundness))", flat, Vignette(roundness: roundness))) }
// Highlights, where Lightroom offers it.
for (style, name) in styles.prefix(2) {
    for highlights in [25, 50, 100] {
        cases.append((String(format: "highlights-%@-%03d", name, highlights), tones, Vignette(highlights: highlights, style: style)))
    }
}
// The vignette follows the crop: a portrait crop, and an off-center one.
cases.append(("crop-portrait", flat, Vignette(crop: (0.3, 0, 0.7, 1))))
cases.append(("crop-offcenter", flat, Vignette(crop: (0.05, 0.1, 0.6, 0.65))))
}

for (name, source, vignette) in cases {
    let folder = family.appending(path: name)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let linked = folder.appending(path: "source.tif")
    try? manager.removeItem(at: linked)
    try manager.linkItem(at: source, to: linked)
    try xmp(vignette).write(to: folder.appending(path: "settings.xmp"), atomically: true, encoding: .utf8)
}

// The photo, at Ted's reported settings (−60 Highlight Priority, the rest at Lightroom's defaults). The plugin exports
// raw.<ext> with the vignette off as source.tif, then applies the vignette to that.
var count = cases.count
if !calibration, arguments.count == 3 {
    let photo = URL(fileURLWithPath: arguments[2])
    let folder = family.appending(path: "photo-" + photo.deletingPathExtension().lastPathComponent)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let raw = folder.appending(path: "raw." + photo.pathExtension)
    if !manager.fileExists(atPath: raw.path) { try manager.copyItem(at: photo, to: raw) }
    try xmp(Vignette()).write(to: folder.appending(path: "settings.xmp"), atomically: true, encoding: .utf8)
    count += 1
}

print("\(count) cases in \(family.path)")
