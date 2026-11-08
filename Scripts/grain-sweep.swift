// Builds the Grain fidelity cases (RAW-283, for RAW-245): a camera-size gray chart and one Lightroom settings XMP per
// case, in the fidelity layout (<fixtures>/effects-grain/<case>/{source.tif, settings.xmp, base.txt, export-size.txt}).
// Lightroom's exports (reference.tif) are then made by the PixelLoupe Fidelity plugin
// (Scripts/PixelLoupeFidelity.lrplugin), and Scripts/fidelity.sh compares PixelLoupe's grain with them.
//
//   xcrun swift Scripts/grain-sweep.swift <fixtures folder> [photo.NEF]
//
// Grain is random, so the cases aren't compared pixel by pixel. Each case names a base case (base.txt): the same
// source at the same size with grain off. The harness measures the grain alone (the case's export minus its base's)
// in each app and compares its statistics: strength in a few spatial bands, its mean, and its color, per tone.
//
// The chart is 6016 × 4016 (a 24 MP camera), so grain is rendered at the resolution a photo's would be:
// - top half: neutral gray at half the encoded range;
// - bottom half: a 12-step neutral wedge from near black to near white, so the grain's strength can be read per tone.
// Cases are exported at full size (export-size.txt says "full"), except the resolution subset at 2048 px on the long
// edge, which shows whether Lightroom ties grain to the photo's pixels or the output's.
// With a photo, three "photo" cases are added (Amount 0, 50, 100): the plugin first exports the photo from Lightroom
// with grain off as their source, so only the grain differs.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard (2...3).contains(arguments.count) else {
    FileHandle.standardError.write(Data("usage: grain-sweep.swift <fixtures folder> [photo.NEF]\n".utf8))
    exit(64)
}
let family = URL(fileURLWithPath: arguments[1]).appending(path: "effects-grain")
let manager = FileManager.default
try manager.createDirectory(at: family, withIntermediateDirectories: true)

// MARK: The chart

let width = 6016, height = 4016, steps = 12

func level(_ x: Int, _ y: Int) -> Double {
    guard y >= height / 2 else { return 0.5 }
    let step = min(x * steps / width, steps - 1)
    return 0.02 + 0.96 * Double(step) / Double(steps - 1)
}

func writeChart() throws -> URL {
    var pixels = [UInt16](repeating: 0, count: width * height * 3)
    for y in 0..<height {
        for x in 0..<width {
            let value = UInt16((level(x, y) * 65535).rounded()), index = (y * width + x) * 3
            pixels[index] = value; pixels[index + 1] = value; pixels[index + 2] = value
        }
    }
    let url = family.appending(path: ".chart.tif")
    let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
    guard let provider = CGDataProvider(data: data as CFData),
          let space = CGColorSpace(name: CGColorSpace.displayP3),
          let image = CGImage(
              width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 6, space: space,
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)
    else { fatalError("couldn't make the chart") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("couldn't write \(url.path)") }
    return url
}

let chart = try writeChart()

// MARK: The cases

/// One case's grain, in Lightroom's units (GrainSize, GrainFrequency is Roughness).
struct Grain {
    var amount = 50
    var size = 25
    var roughness = 50
}

/// Every grain setting is written, so applying a case over an earlier one leaves nothing behind.
func xmp(_ g: Grain) -> String {
    """
    <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
      crs:ProcessVersion="11.0" crs:HasSettings="True"
      crs:GrainAmount="\(g.amount)" crs:GrainSize="\(g.size)" crs:GrainFrequency="\(g.roughness)"/>
    </rdf:RDF></x:xmpmeta><?xpacket end="w"?>

    """
}

/// A case: its grain, its base case (nil for a base itself) and its export size ("full", or the long edge in pixels).
struct Case {
    var name: String
    var grain: Grain
    var base: String?
    var size = "full"
}

var cases: [Case] = []
// Amount, at Lightroom's default Size and Roughness. Amount 0 is the base of every full-size chart case.
let base = "amount-000"
cases.append(Case(name: base, grain: Grain(amount: 0), base: nil))
for amount in [25, 50, 75, 100] { cases.append(Case(name: String(format: "amount-%03d", amount), grain: Grain(amount: amount), base: base)) }
// Size and Roughness, one at a time around Amount 50. (Size 25 and Roughness 50 are amount-050.)
for size in [0, 10, 50, 75, 100] { cases.append(Case(name: String(format: "size-%03d", size), grain: Grain(size: size), base: base)) }
for roughness in [0, 25, 75, 100] { cases.append(Case(name: String(format: "roughness-%03d", roughness), grain: Grain(roughness: roughness), base: base)) }
// Resolution: the same grain exported at 2048 px on the long edge.
let smallBase = "small-amount-000"
cases.append(Case(name: smallBase, grain: Grain(amount: 0), base: nil, size: "2048"))
for size in [0, 25, 100] { cases.append(Case(name: String(format: "small-size-%03d", size), grain: Grain(size: size), base: smallBase, size: "2048")) }

func writeCase(_ c: Case, source: (URL) throws -> Void) throws {
    let folder = family.appending(path: c.name)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    try source(folder)
    try xmp(c.grain).write(to: folder.appending(path: "settings.xmp"), atomically: true, encoding: .utf8)
    try (c.size + "\n").write(to: folder.appending(path: "export-size.txt"), atomically: true, encoding: .utf8)
    let baseFile = folder.appending(path: "base.txt")
    if let base = c.base { try (base + "\n").write(to: baseFile, atomically: true, encoding: .utf8) } else { try? manager.removeItem(at: baseFile) }
}

for c in cases {
    try writeCase(c) { folder in
        let linked = folder.appending(path: "source.tif")
        try? manager.removeItem(at: linked)
        try manager.linkItem(at: chart, to: linked)
    }
}

// The photo at Amount 0, 50 and 100 (Size 25, Roughness 50). The plugin exports raw.<ext> with grain off, at full
// size, as each case's source.tif, then applies the case's grain to that.
var count = cases.count
if arguments.count == 3 {
    let photo = URL(fileURLWithPath: arguments[2])
    let stem = "photo-" + photo.deletingPathExtension().lastPathComponent
    for amount in [0, 50, 100] {
        let c = Case(name: String(format: "%@-amount-%03d", stem, amount), grain: Grain(amount: amount),
                     base: amount == 0 ? nil : String(format: "%@-amount-000", stem))
        try writeCase(c) { folder in
            let raw = folder.appending(path: "raw." + photo.pathExtension)
            if !manager.fileExists(atPath: raw.path) { try manager.copyItem(at: photo, to: raw) }
        }
        count += 1
    }
}

print("\(count) cases in \(family.path)")
