// Builds the Color Grading fidelity cases (RAW-242): a step-wedge source and one Lightroom settings XMP per case, in
// the fidelity layout (<fixtures>/color-grading/<case>/{source.tif, settings.xmp}). Lightroom's exports
// (reference.tif) are then made by the PixelLoupe Fidelity plugin (Scripts/PixelLoupeFidelity.lrplugin), and
// Scripts/fidelity.sh compares PixelLoupe's renders with them.
//
//   xcrun swift Scripts/color-grading-sweep.swift <fixtures folder> [photo.CR2]
//
// The wedge is 2048 × 512 (Lightroom's export size, so it isn't resampled): 32 brightness steps across, in eight
// rows of 64 × 64 blocks: neutral gray, then red, yellow, green, cyan, blue and magenta at a moderate saturation,
// then neutral again. Every case shares it (hard links). With a photo, a "photo" case is added: the plugin first
// exports the photo from Lightroom without Color Grading as its source, so only Color Grading differs.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard (2...3).contains(arguments.count) else {
    FileHandle.standardError.write(Data("usage: color-grading-sweep.swift <fixtures folder> [photo.CR2]\n".utf8))
    exit(64)
}
let family = URL(fileURLWithPath: arguments[1]).appending(path: "color-grading")
let manager = FileManager.default
try manager.createDirectory(at: family, withIntermediateDirectories: true)

// MARK: The wedge

let steps = 32, rows = 8, block = 64
let width = steps * block, height = rows * block

/// sRGB-style HSV to RGB, 0…1.
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

/// Row colors: hue, or nil for neutral.
let rowHues: [Double?] = [nil, 0, 60, 120, 180, 240, 300, nil]
var pixels = [UInt16](repeating: 0, count: width * height * 3)
for row in 0..<rows {
    for step in 0..<steps {
        // From a little above black to white, evenly in encoded values.
        let value = 0.02 + 0.98 * Double(step) / Double(steps - 1)
        let color = rowHues[row].map { rgb(hue: $0, saturation: 0.35, value: value) } ?? (value, value, value)
        let channels = [color.0, color.1, color.2].map { UInt16(($0 * 65535).rounded()) }
        // Rows from the top.
        for y in row * block..<(row + 1) * block {
            for x in step * block..<(step + 1) * block {
                let index = (y * width + x) * 3
                pixels[index] = channels[0]
                pixels[index + 1] = channels[1]
                pixels[index + 2] = channels[2]
            }
        }
    }
}

let wedge = family.appending(path: ".wedge.tif")
let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
guard let provider = CGDataProvider(data: data as CFData),
      let space = CGColorSpace(name: CGColorSpace.displayP3),
      let image = CGImage(
          width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 6, space: space,
          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
      let destination = CGImageDestinationCreateWithURL(wedge as CFURL, UTType.tiff.identifier as CFString, 1, nil)
else { fatalError("couldn't make the wedge") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("couldn't write \(wedge.path)") }

// MARK: The cases

/// One case's Color Grading, in Lightroom's units.
struct Grade {
    var wheels: [String: (hue: Int, saturation: Int, luminance: Int)] = [:]
    var blending = 50
    var balance = 0
}

/// Every Color Grading setting is written, so applying a case over an earlier one leaves nothing behind. Lightroom
/// keeps the Shadows and Highlights wheels' hue and saturation under their Split Toning names
/// (`SplitToningShadowHue`, `SplitToningShadowSaturation`); it ignores `ColorGradeShadowHue`/`Sat`.
func xmp(_ grade: Grade) -> String {
    var attributes: [String] = []
    for wheel in ["Shadow", "Midtone", "Highlight", "Global"] {
        let value = grade.wheels[wheel] ?? (0, 0, 0)
        let splitToning = wheel == "Shadow" || wheel == "Highlight"
        attributes += splitToning
            ? ["crs:SplitToning\(wheel)Hue=\"\(value.hue)\"", "crs:SplitToning\(wheel)Saturation=\"\(value.saturation)\""]
            : ["crs:ColorGrade\(wheel)Hue=\"\(value.hue)\"", "crs:ColorGrade\(wheel)Sat=\"\(value.saturation)\""]
        attributes.append("crs:ColorGrade\(wheel)Lum=\"\(value.luminance)\"")
    }
    attributes += ["crs:ColorGradeBlending=\"\(grade.blending)\"", "crs:SplitToningBalance=\"\(grade.balance)\""]
    return """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:ProcessVersion="11.0" crs:HasSettings="True"
          \(attributes.joined(separator: "\n  "))/>
        </rdf:RDF></x:xmpmeta><?xpacket end="w"?>

        """
}

var cases: [(name: String, grade: Grade)] = []
let wheelNames = [("Shadow", "shadows"), ("Midtone", "midtones"), ("Highlight", "highlights")]
// Each tonal wheel alone, around the wheel at three strengths.
for (wheel, name) in wheelNames {
    for hue in stride(from: 0, to: 360, by: 60) {
        for saturation in [25, 50, 100] {
            cases.append((String(format: "%@-h%03d-s%03d", name, hue, saturation), Grade(wheels: [wheel: (hue, saturation, 0)])))
        }
    }
}
// Global alone.
for hue in stride(from: 0, to: 360, by: 60) {
    cases.append((String(format: "global-h%03d-s050", hue), Grade(wheels: ["Global": (hue, 50, 0)])))
}
for saturation in [25, 100] {
    cases.append((String(format: "global-h180-s%03d", saturation), Grade(wheels: ["Global": (180, saturation, 0)])))
}
// Luminance alone.
for (wheel, name) in wheelNames + [("Global", "global")] {
    for luminance in [-100, 100] {
        cases.append(("\(name)-lum\(luminance > 0 ? "+" : "")\(luminance)", Grade(wheels: [wheel: (0, 0, luminance)])))
    }
}
// How far Shadows reaches.
for blending in [0, 50, 100] {
    cases.append((String(format: "blending-%03d", blending), Grade(wheels: ["Shadow": (180, 50, 0)], blending: blending)))
}
// Where shadows end and highlights begin.
for balance in [-100, 0, 100] {
    let name = balance < 0 ? "balance-m100" : balance > 0 ? "balance-p100" : "balance-000"
    cases.append((name, Grade(wheels: ["Shadow": (180, 50, 0), "Highlight": (30, 50, 0)], balance: balance)))
}
// Ted's settings from the RAW-242 report, on the wedge.
let reported = Grade(wheels: ["Shadow": (170, 79, 0), "Midtone": (179, 30, 0), "Highlight": (266, 19, 0)], blending: 67)
cases.append(("reported", reported))

for (name, grade) in cases {
    let folder = family.appending(path: name)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = folder.appending(path: "source.tif")
    try? manager.removeItem(at: source)
    try manager.linkItem(at: wedge, to: source)
    try xmp(grade).write(to: folder.appending(path: "settings.xmp"), atomically: true, encoding: .utf8)
}

// The photo: the plugin exports raw.<ext> without Color Grading as source.tif, then grades that.
if arguments.count == 3 {
    let photo = URL(fileURLWithPath: arguments[2])
    let folder = family.appending(path: "photo-" + photo.deletingPathExtension().lastPathComponent)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let raw = folder.appending(path: "raw." + photo.pathExtension)
    if !manager.fileExists(atPath: raw.path) { try manager.copyItem(at: photo, to: raw) }
    try xmp(reported).write(to: folder.appending(path: "settings.xmp"), atomically: true, encoding: .utf8)
    cases.append((folder.lastPathComponent, reported))
}

print("\(cases.count) cases in \(family.path)")
