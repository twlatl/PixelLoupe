import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PixelLoupe

/// Frames of a synthetic scene focused at different depths: each frame is sharp in some places and
/// blurred in the rest. Written as Linear DNGs (the RAW path) or PNGs.
struct FocusFixture {
    /// How a frame sits over the scene: scaled and turned about its center, then moved (pixels, y down).
    struct Placement {
        var scale = 1.0
        var degrees = 0.0
        var dx = 0.0
        var dy = 0.0

        /// Where the frame's pixel (x, y) looks in the scene.
        func scenePoint(_ x: Double, _ y: Double, width: Int, height: Int) -> (x: Double, y: Double) {
            let cx = Double(width) / 2, cy = Double(height) / 2
            let angle = degrees * .pi / 180
            let px = x - cx, py = y - cy
            return (scale * (cos(angle) * px - sin(angle) * py) + cx + dx, scale * (sin(angle) * px + cos(angle) * py) + cy + dy)
        }
    }

    let directory: TemporaryDirectory
    let width: Int
    let height: Int
    /// The scene in focus, 0…1, top row first, with a margin of `margin` pixels all around the frame.
    let sharp: [Float]
    let margin = 40
    var sources: [PhotoMergeSource] = []

    private var sceneWidth: Int { width + 2 * margin }
    private var sceneHeight: Int { height + 2 * margin }

    /// A scene with fine texture (what focus shows) over coarse blocks (which survive the blur, so
    /// blurred frames still line up).
    init(width: Int = 480, height: Int = 320, seed: UInt32 = 0) throws {
        directory = try TemporaryDirectory()
        self.width = width
        self.height = height
        func hash(_ x: Int, _ y: Int, _ salt: UInt32) -> Float {
            var h = UInt32(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663) ^ (salt &* 0x9E37_79B9)
            h ^= h >> 13
            h = h &* 0x5BD1_E995
            h ^= h >> 15
            return Float(h % 1000) / 1000
        }
        let sceneWidth = width + 2 * margin, sceneHeight = height + 2 * margin
        var scene = [Float](repeating: 0, count: sceneWidth * sceneHeight)
        for y in 0..<sceneHeight {
            for x in 0..<sceneWidth {
                scene[y * sceneWidth + x] = 0.15 + 0.35 * hash(x / 3, y / 3, seed) + 0.35 * hash(x / 28, y / 28, seed &+ 7)
            }
        }
        sharp = scene
    }

    /// The scene at a point of the frame's grid (bilinear), from `pixels` (sharp or blurred).
    private func sample(_ pixels: [Float], _ x: Double, _ y: Double) -> Float {
        PanoramaAligner.bilinear(pixels, width: sceneWidth, height: sceneHeight, x: Float(x) + Float(margin), y: Float(y) + Float(margin))
    }

    /// The sharp scene at a frame pixel of an unmoved frame.
    func scene(_ x: Int, _ y: Int) -> Float { sharp[(y + margin) * sceneWidth + x + margin] }

    /// Adds a frame that's in focus where `inFocus(x, y)` says (in scene pixels) and blurred elsewhere.
    mutating func addFrame(
        raw: Bool = true, placement: Placement = Placement(), brightness: Float = 1, second: Double? = nil,
        inFocus: (Double, Double) -> Bool
    ) throws {
        let blurred = PanoramaAligner.gaussianBlur(sharp, width: sceneWidth, height: sceneHeight, sigma: 3)
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let at = placement.scenePoint(Double(x), Double(y), width: width, height: height)
                values[y * width + x] = min(1, sample(inFocus(at.x, at.y) ? sharp : blurred, at.x, at.y) * brightness)
            }
        }
        let index = sources.count
        let date = Date(timeIntervalSince1970: 1_791_000_000 + (second ?? Double(index)))
        let url = directory.url.appending(path: "DSC_\(String(format: "%04d", index)).\(raw ? "dng" : "png")")
        if raw {
            let image = DNGFixtures.image(width: width, height: height) { x, y in SIMD3(repeating: values[y * width + x]) }
            try LinearDNGWriter.write(image, metadata: DNGMetadata(make: "Sony", model: "ILCE-7CR", captureDate: date), to: url)
        } else {
            try Self.writePNG(values, width: width, height: height, to: url)
        }
        sources.append(PhotoMergeSource(url: url, exposureTime: 0.01, aperture: 2.8, iso: 100, make: "Sony", model: "ILCE-7CR", captureDate: date))
    }

    /// `count` frames, each in focus in its own vertical band of the scene, left to right.
    mutating func addBands(_ count: Int, raw: Bool = true) throws {
        for band in 0..<count {
            let width = Double(width)
            try addFrame(raw: raw) { x, _ in Int(max(0, min(x, width - 1)) * Double(count) / width) == band }
        }
    }

    static func writePNG(_ values: [Float], width: Int, height: Int, to url: URL) throws {
        // Gamma-encoded gray, as a photo would be.
        let bytes = values.map { UInt8(pow(min(max($0, 0), 1), 1 / 2.2) * 255 + 0.5) }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// The green channel of a merged image, top row first.
    static func green(_ image: LinearDNGImage) -> [Float] {
        (0..<(image.width * image.height)).map { Float(image.pixels[$0 * 3 + 1]) }
    }

    /// How much fine detail `pixels` has in a rectangle: the mean size of the Laplacian.
    static func detail(_ pixels: [Float], width: Int, x: Range<Int>, y: Range<Int>) -> Float {
        var total: Float = 0
        for row in y {
            for column in x {
                let i = row * width + column
                total += abs(4 * pixels[i] - pixels[i - 1] - pixels[i + 1] - pixels[i - width] - pixels[i + width])
            }
        }
        return total / Float(x.count * y.count)
    }
}

@Suite("Focus stack")
struct FocusStackTests {
    private var sharpest: FocusStackOptions {
        var options = FocusStackOptions()
        options.radius = 4
        options.smoothing = 0
        return options
    }

    @Test func depthMapTakesEachBandFromTheFrameInFocusThere() throws {
        var fixture = try FocusFixture()
        try fixture.addBands(3)
        let merger = try FocusStackMerger(sources: fixture.sources)
        let result = try merger.merge(options: sharpest, scale: 1)
        #expect(result.mergedCount == 3)
        #expect(merger.skipped.isEmpty)
        #expect(abs(result.image.width - fixture.width) <= 4 && abs(result.image.height - fixture.height) <= 4)

        // The depth map: black in the first band, mid gray in the second, white in the third.
        let map = try #require(result.depthMap)
        for (band, expected) in [0, 128, 255].enumerated() {
            var values: [Int] = []
            for y in stride(from: map.height / 4, to: map.height * 3 / 4, by: 7) {
                for x in stride(from: map.width * (band * 6 + 2) / 18, to: map.width * (band * 6 + 4) / 18, by: 5) {
                    values.append(Int(map.pixels[y * map.width + x]))
                }
            }
            let right = values.count { abs($0 - expected) <= 2 }
            #expect(Double(right) > 0.95 * Double(values.count), "band \(band): \(right) of \(values.count)")
        }

        // The result is as detailed in every band as the scene, which no single frame is.
        let merged = FocusFixture.green(result.image)
        let scene = (0..<(fixture.width * fixture.height)).map { fixture.scene($0 % fixture.width, $0 / fixture.width) }
        for band in 0..<3 {
            let x = (fixture.width * band / 3 + 20)..<(fixture.width * (band + 1) / 3 - 20)
            let y = 20..<(result.image.height - 20)
            let ours = FocusFixture.detail(merged, width: result.image.width, x: x, y: y)
            let wanted = FocusFixture.detail(scene, width: fixture.width, x: x, y: y)
            #expect(ours > 0.85 * wanted, "band \(band): \(ours) of \(wanted)")
        }
    }

    @Test func reportsTheDepthMapAsItBuilds() throws {
        var fixture = try FocusFixture()
        try fixture.addBands(3)
        let merger = try FocusStackMerger(sources: fixture.sources)
        var maps: [FocusDepthMap] = []
        var fractions: [Double] = []
        let result = try merger.merge(options: FocusStackOptions(), scale: 1, progress: { fractions.append($0) }, depthMap: { maps.append($0) })
        // One after each frame, then the smoothed one.
        #expect(maps.count == 4)
        #expect(maps.last == result.depthMap)
        // After the first frame nothing but the first frame has been chosen.
        #expect(maps[0].pixels.allSatisfy { $0 == 0 })
        #expect(fractions == fractions.sorted() && fractions.last == 1)
    }

    @Test func smoothingSoftensTheDepthMap() throws {
        var fixture = try FocusFixture()
        try fixture.addBands(2)
        let merger = try FocusStackMerger(sources: fixture.sources)
        func row(_ smoothing: Int) throws -> [Int] {
            var options = FocusStackOptions()
            options.smoothing = smoothing
            let map = try #require(try merger.merge(options: options, scale: 1).depthMap)
            let start = map.height / 2 * map.width
            return map.pixels[start..<(start + map.width)].map { Int($0) }
        }
        // Across the line between the two frames: the first frame on one side, the second on the other,
        // and with more smoothing a gentler slope between them.
        func steepest(_ row: [Int]) -> Int { zip(row, row.dropFirst()).map { abs($1 - $0) }.max() ?? 0 }
        let hard = try row(0), soft = try row(10)
        #expect(hard.first == 0 && hard.last == 255 && soft.first == 0 && soft.last == 255)
        #expect(steepest(soft) < steepest(hard), "steepest step \(steepest(soft)) with smoothing, \(steepest(hard)) without")
    }

    @Test func weightedAverageWeighsEachBandByTheFrameInFocusThere() throws {
        var fixture = try FocusFixture()
        try fixture.addBands(3)
        let merger = try FocusStackMerger(sources: fixture.sources)
        var options = sharpest
        options.method = .weightedAverage
        var maps: [FocusDepthMap] = []
        let result = try merger.merge(options: options, scale: 1, depthMap: { maps.append($0) })
        #expect(result.mergedCount == 3)
        // It has no depth map to show as it builds.
        #expect(maps.isEmpty)

        // In the middle of each band, most of the weight is the frame that's in focus there.
        let weights = try merger.weightMaps(options: options, scale: 1)
        #expect(weights.frames.count == 3)
        #expect(weights.width == result.image.width && weights.height == result.image.height)
        for band in 0..<3 {
            var shares = [Float](repeating: 0, count: 3)
            var count: Float = 0
            for y in stride(from: weights.height / 4, to: weights.height * 3 / 4, by: 7) {
                for x in stride(from: weights.width * (band * 6 + 2) / 18, to: weights.width * (band * 6 + 4) / 18, by: 5) {
                    for frame in 0..<3 { shares[frame] += weights.frames[frame][y * weights.width + x] }
                    count += 1
                }
            }
            #expect(abs(shares.reduce(0, +) / count - 1) < 0.01)
            #expect(shares[band] / count > 0.8, "band \(band): \(shares.map { $0 / count })")
        }

        // The result is sharper than the frames' plain average (in each band, one sharp frame and two
        // blurred ones), and close to the scene.
        let merged = FocusFixture.green(result.image)
        let scene = (0..<(fixture.width * fixture.height)).map { fixture.scene($0 % fixture.width, $0 / fixture.width) }
        let blurred = PanoramaAligner.gaussianBlur(scene, width: fixture.width, height: fixture.height, sigma: 3)
        let plain = zip(scene, blurred).map { ($0 + 2 * $1) / 3 }
        for band in 0..<3 {
            let x = (fixture.width * band / 3 + 20)..<(fixture.width * (band + 1) / 3 - 20)
            let y = 20..<(result.image.height - 20)
            let ours = FocusFixture.detail(merged, width: result.image.width, x: x, y: y)
            let wanted = FocusFixture.detail(scene, width: fixture.width, x: x, y: y)
            let average = FocusFixture.detail(plain, width: fixture.width, x: x, y: y)
            #expect(ours > 0.8 * wanted && ours > 1.5 * average, "band \(band): \(ours) of \(wanted), plain average \(average)")
        }
    }

    @Test func smoothingSoftensTheWeightedAveragesWeights() throws {
        var fixture = try FocusFixture()
        try fixture.addBands(2)
        let merger = try FocusStackMerger(sources: fixture.sources)
        // The first frame's share along the middle row.
        func row(_ smoothing: Int) throws -> [Float] {
            var options = FocusStackOptions()
            options.method = .weightedAverage
            options.smoothing = smoothing
            let weights = try merger.weightMaps(options: options, scale: 1)
            let start = weights.height / 2 * weights.width
            return Array(weights.frames[0][start..<(start + weights.width)])
        }
        // All the first frame at one end and none of it at the other, and with more smoothing a gentler
        // slope where the two frames meet.
        func steepest(_ row: [Float]) -> Float { zip(row, row.dropFirst()).map { abs($1 - $0) }.max() ?? 0 }
        let hard = try row(0), soft = try row(10)
        for row in [hard, soft] {
            #expect(row[row.count / 8] > 0.9 && row[row.count * 7 / 8] < 0.1, "\(row[row.count / 8]) and \(row[row.count * 7 / 8])")
        }
        #expect(steepest(soft) < 0.5 * steepest(hard), "steepest step \(steepest(soft)) with smoothing, \(steepest(hard)) without")
    }

    @Test func pyramidTakesTheDetailOfWhicheverFrameHasIt() throws {
        // Two frames, in focus in alternate stripes. (Stripes much narrower than this, which would show
        // detail at two depths side by side as hairs are, don't line up: where a synthetic frame
        // switches from sharp to blurred is itself a feature, and there are too many of them.)
        var fixture = try FocusFixture()
        func near(_ x: Double) -> Bool { Int(max(0, x) / 120) % 2 == 0 }
        try fixture.addFrame { x, _ in near(x) }
        try fixture.addFrame { x, _ in !near(x) }
        let merger = try FocusStackMerger(sources: fixture.sources)
        var options = FocusStackOptions()
        options.method = .pyramid
        var maps: [FocusDepthMap] = []
        var fractions: [Double] = []
        let result = try merger.merge(options: options, scale: 1, progress: { fractions.append($0) }, depthMap: { maps.append($0) })
        #expect(result.mergedCount == 2 && merger.skipped.isEmpty)
        // It has no depth map.
        #expect(maps.isEmpty && result.depthMap == nil)
        #expect(fractions == fractions.sorted() && fractions.last == 1)

        // As detailed as the scene throughout, which neither frame is.
        let width = fixture.width, height = fixture.height
        let scene = (0..<(width * height)).map { fixture.scene($0 % width, $0 / width) }
        let blurred = PanoramaAligner.gaussianBlur(scene, width: width, height: height, sigma: 3)
        let x = 30..<(result.image.width - 30), y = 30..<(result.image.height - 30)
        let ours = FocusFixture.detail(FocusFixture.green(result.image), width: result.image.width, x: x, y: y)
        let wanted = FocusFixture.detail(scene, width: width, x: x, y: y)
        #expect(ours > 0.85 * wanted, "\(ours) of \(wanted)")
        for first in [true, false] {
            let frame = (0..<(width * height)).map { near(Double($0 % width)) == first ? scene[$0] : blurred[$0] }
            let single = FocusFixture.detail(frame, width: width, x: x, y: y)
            #expect(ours > 1.25 * single, "\(ours) against a single frame's \(single)")
        }
    }

    @Test func pyramidKeepsBrightnessAndColor() throws {
        // Three frames, each in focus in its own band.
        var fixture = try FocusFixture()
        try fixture.addBands(3)
        let merger = try FocusStackMerger(sources: fixture.sources)
        var options = FocusStackOptions()
        options.method = .pyramid
        let result = try merger.merge(options: options, scale: 1)
        let reference = try merger.merge(options: FocusStackOptions(), scale: 1)
        #expect(result.image.width == reference.image.width && result.image.height == reference.image.height)
        // Over areas large enough for the texture to average out, every channel is what Depth Map's
        // stack (pixels taken straight from the frames) has there: no drift from taking the pyramid
        // apart and putting it back.
        let width = result.image.width, height = result.image.height
        func mean(_ image: LinearDNGImage, _ channel: Int, _ column: Int, _ row: Int) -> Float {
            var total: Float = 0
            for y in (row * 60 + 20)..<(row * 60 + 80) {
                for x in (column * 60 + 20)..<(column * 60 + 80) { total += Float(image.pixels[(y * width + x) * 3 + channel]) }
            }
            return total / 3600
        }
        for row in 0..<((height - 40) / 60) {
            for column in 0..<((width - 40) / 60) {
                for channel in 0..<3 {
                    let ours = mean(result.image, channel, column, row), theirs = mean(reference.image, channel, column, row)
                    #expect(abs(ours - theirs) < 0.02 * theirs, "block \(column), \(row) channel \(channel): \(ours) against \(theirs)")
                }
            }
        }
        #expect(result.image.headroom == reference.image.headroom)
    }

    @Test func linesUpFramesThatMovedScaledAndTurned() throws {
        var fixture = try FocusFixture(width: 640, height: 480)
        let placements = [
            FocusFixture.Placement(),
            FocusFixture.Placement(scale: 1.01, degrees: 0.2, dx: 3, dy: -2),
            FocusFixture.Placement(scale: 1.02, degrees: 0.4, dx: 6, dy: -4),
        ]
        for placement in placements { try fixture.addFrame(placement: placement) { _, _ in true } }
        let merger = try FocusStackMerger(sources: fixture.sources)
        try merger.align()
        #expect(merger.skipped.isEmpty)

        let height = Double(fixture.height)
        for (index, placement) in placements.enumerated() {
            let transform = try #require(merger.frames[index].transform)
            for (x, y) in [(40.0, 40.0), (600, 60), (320, 240), (80, 430), (590, 440)] {
                // Top-left pixel coordinates to Core Image's and back.
                let found = CGPoint(x: x, y: height - y).applying(transform)
                let expected = placement.scenePoint(x, y, width: fixture.width, height: fixture.height)
                let distance = hypot(Double(found.x) - expected.x, height - Double(found.y) - expected.y)
                #expect(distance < 0.5, "frame \(index) at (\(x), \(y)) is \(distance) pixels off")
            }
        }

        // The result shows what every frame shows, and it's the scene there: the frames were put back in place.
        let indices = Array(merger.frames.indices)
        let canvas = merger.commonRect(indices, scale: 1)
        #expect(canvas.width < 640 && canvas.width > 600 && canvas.height < 480 && canvas.height > 440)
        let result = try merger.merge(options: sharpest, scale: 1)
        #expect(result.image.width == Int(canvas.width) && result.image.height == Int(canvas.height))
        let merged = FocusFixture.green(result.image)
        let left = Int(canvas.minX), top = fixture.height - Int(canvas.maxY)
        var difference: Float = 0
        var count: Float = 0
        for y in stride(from: 10, to: result.image.height - 10, by: 3) {
            for x in stride(from: 10, to: result.image.width - 10, by: 3) {
                difference += abs(merged[y * result.image.width + x] - fixture.scene(x + left, y + top))
                count += 1
            }
        }
        #expect(difference / count < 0.03, "mean difference \(difference / count)")
    }

    @Test func leavesOutAFrameThatDoesNotLineUp() throws {
        var fixture = try FocusFixture()
        var other = try FocusFixture(seed: 99)
        try other.addFrame(second: 1.5) { _, _ in true }
        try fixture.addBands(3)
        let stray = other.sources[0]
        let merger = try FocusStackMerger(sources: fixture.sources + [stray])
        // Between the second and third frames, by when it was taken.
        #expect(merger.frames.map(\.source.url) == [fixture.sources[0].url, fixture.sources[1].url, stray.url, fixture.sources[2].url])
        let result = try merger.merge(options: sharpest, scale: 1)
        #expect(merger.skipped == [stray])
        #expect(result.mergedCount == 3)

        // With nothing left to line up with, there's no stack.
        let pair = try FocusStackMerger(sources: [fixture.sources[0], stray])
        #expect(throws: FocusStackError.tooFewAligned) { try pair.merge(options: FocusStackOptions(), scale: 1) }
    }

    @Test func leavesOutExcludedFrames() throws {
        var fixture = try FocusFixture()
        try fixture.addBands(3)
        let merger = try FocusStackMerger(sources: fixture.sources)
        let result = try merger.merge(options: sharpest, scale: 1, excluding: [fixture.sources[1].url])
        #expect(result.mergedCount == 2)
        #expect(merger.skipped.isEmpty)
        // The middle band has no frame in focus now.
        let merged = FocusFixture.green(result.image)
        let y = 20..<(result.image.height - 20)
        let middle = FocusFixture.detail(merged, width: result.image.width, x: 200..<280, y: y)
        let first = FocusFixture.detail(merged, width: result.image.width, x: 40..<120, y: y)
        #expect(middle < 0.5 * first)

        #expect(throws: FocusStackError.tooFewAligned) {
            try merger.merge(options: FocusStackOptions(), scale: 1, excluding: Set(fixture.sources.dropFirst().map(\.url)))
        }
    }

    @Test func stacksPartOfThePicture() throws {
        var fixture = try FocusFixture()
        try fixture.addBands(3)
        let merger = try FocusStackMerger(sources: fixture.sources)
        let whole = try merger.merge(options: sharpest, scale: 1)
        let region = CGRect(x: 100, y: 60, width: 200, height: 120)
        let part = try merger.merge(options: sharpest, scale: 1, region: region)
        #expect(part.image.width == 200 && part.image.height == 120)
        // The same pixels as that part of the whole (away from the bands' edges, where the depth map,
        // worked out from the part alone, can differ a little).
        let all = FocusFixture.green(whole.image), some = FocusFixture.green(part.image)
        var difference: Float = 0
        var count: Float = 0
        for y in 10..<110 {
            for x in 80..<180 {
                difference += abs(some[y * 200 + x] - all[(y + 60) * whole.image.width + x + 100])
                count += 1
            }
        }
        #expect(difference / count < 0.01, "mean difference \(difference / count)")
    }

    /// What's built up frame by frame stays on the GPU, in textures. Read back to main memory instead
    /// (as it was first done, and still is where a texture can't be had), the stack is the same.
    @Test(arguments: FocusStackOptions.Method.allCases)
    func stacksTheSameOnTheGPUAsThroughMainMemory(method: FocusStackOptions.Method) throws {
        var fixture = try FocusFixture()
        try fixture.addBands(3)
        var options = FocusStackOptions()
        options.method = method
        let onGPU = try FocusStackMerger(sources: fixture.sources)
        let throughMemory = try FocusStackMerger(sources: fixture.sources)
        throughMemory.staysOnGPU = false
        let first = try onGPU.merge(options: options, scale: 1), second = try throughMemory.merge(options: options, scale: 1)
        #expect(first.image.width == second.image.width && first.image.height == second.image.height)
        #expect(first.depthMap?.pixels == second.depthMap?.pixels)
        var largest: Float = 0
        for (a, b) in zip(first.image.pixels, second.image.pixels) { largest = max(largest, abs(Float(a) - Float(b))) }
        #expect(largest < 0.002, "largest difference \(largest)")
        // The part of the picture, too: its place in the whole is where a flipped texture would show.
        let region = CGRect(x: 100, y: 40, width: 200, height: 120)
        let part = try onGPU.merge(options: options, scale: 1, region: region)
        let samePart = try throughMemory.merge(options: options, scale: 1, region: region)
        largest = 0
        for (a, b) in zip(part.image.pixels, samePart.image.pixels) { largest = max(largest, abs(Float(a) - Float(b))) }
        #expect(largest < 0.002, "largest difference in a part \(largest)")
    }

    @Test func matchesEachFramesBrightnessToTheFirst() throws {
        var fixture = try FocusFixture()
        try fixture.addFrame { _, _ in true }
        try fixture.addFrame(brightness: 0.9) { _, _ in true }
        let merger = try FocusStackMerger(sources: fixture.sources)
        try merger.align()
        #expect(merger.frames[0].gain == 1)
        #expect(abs(merger.frames[1].gain - 1 / 0.9) < 0.02)
    }

    @Test func stacksPhotosThatAreNotRaw() throws {
        var fixture = try FocusFixture()
        try fixture.addBands(3, raw: false)
        let merger = try FocusStackMerger(sources: fixture.sources)
        #expect(!merger.isRaw)
        let full = try merger.merge(options: sharpest, scale: 1)
        #expect(full.mergedCount == 3)
        let merged = FocusFixture.green(full.image)
        let scene = (0..<(fixture.width * fixture.height)).map { fixture.scene($0 % fixture.width, $0 / fixture.width) }
        for band in 0..<3 {
            let x = (fixture.width * band / 3 + 20)..<(fixture.width * (band + 1) / 3 - 20)
            let y = 20..<(full.image.height - 20)
            let ours = FocusFixture.detail(merged, width: full.image.width, x: x, y: y)
            let wanted = FocusFixture.detail(scene, width: fixture.width, x: x, y: y)
            #expect(ours > 0.8 * wanted, "band \(band): \(ours) of \(wanted)")
        }

        // A preview: half the size, the same picture.
        let half = try merger.merge(options: sharpest, scale: 0.5)
        #expect(abs(half.image.width - fixture.width / 2) <= 3 && abs(half.image.height - fixture.height / 2) <= 3)
        #expect(half.mergedCount == 3)
    }

    @Test func saysWhyPhotosCannotBeStacked() throws {
        var fixture = try FocusFixture()
        try fixture.addFrame { _, _ in true }
        #expect(FocusStackMerger.problem(merging: fixture.sources) as? PhotoMergeError == .tooFewPhotos)
        try fixture.addFrame(raw: false) { _, _ in true }
        #expect(FocusStackMerger.problem(merging: fixture.sources) as? FocusStackError == .mixedKinds)
        #expect(throws: FocusStackError.mixedKinds) { try FocusStackMerger(sources: fixture.sources) }

        var small = try FocusFixture(width: 240, height: 160)
        try small.addFrame { _, _ in true }
        var mixed = try FocusFixture()
        try mixed.addFrame { _, _ in true }
        #expect(throws: PhotoMergeError.differentSizes) { try FocusStackMerger(sources: mixed.sources + small.sources) }
    }

    @Test func ordersFramesByWhenTheyWereTaken() {
        func source(_ name: String, _ second: Double?) -> PhotoMergeSource {
            PhotoMergeSource(
                url: URL(filePath: "/tmp/\(name)"), exposureTime: 0, aperture: 0, iso: 0, make: nil, model: nil,
                captureDate: second.map { Date(timeIntervalSince1970: $0) }
            )
        }
        let sources = [source("b.jpg", 5), source("a10.jpg", 3), source("a9.jpg", 3), source("z.jpg", nil), source("c.jpg", 1)]
        #expect(FocusStackMerger.ordered(sources).map(\.name) == ["c.jpg", "a9.jpg", "a10.jpg", "b.jpg", "z.jpg"])
    }

    @Test func runnerWritesTheStackBesideItsName() async throws {
        var fixture = try FocusFixture()
        try fixture.addBands(3)
        #expect(PhotoMergeKind.focusStack.suffix == "Focus")
        #expect(PhotoMergeKind.focusStack.progressTitle == "Merging Focus Stack")
        #expect(PhotoMergeKind.focusStack.cancelTitle == "Cancel Focus Stack Merge")
        let destination = fixture.directory.url.appending(path: "DSC_0000-Focus.dng")
        let thumbnails = fixture.directory.url.appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        let result = try await FocusStackRunner.run(
            sources: fixture.sources.reversed(), options: FocusStackOptions(), destination: destination, thumbnailDirectory: thumbnails
        )
        #expect(result.mergedCount == 3 && result.photoCount == 3 && result.skipped.isEmpty)
        #expect(result.output.url == destination)
        #expect(result.output.referenceURL == fixture.sources[0].url)
        #expect(result.output.stackOrder == fixture.sources.map(\.url))
        #expect(result.output.fileSize > 0)
        let decoded = try DNGFixtures.decodeLinear(destination)
        #expect(decoded.width == result.output.pixelWidth && decoded.height == result.output.pixelHeight)
        #expect(FileManager.default.fileExists(atPath: ThumbnailStore.url(for: result.output.id, in: thumbnails).path(percentEncoded: false)))
    }
}

@Suite("Focus stack TIFF")
struct FocusStackTIFFTests {
    @Test func photosThatAreNotRawBecomeATIFFThatLooksLikeThem() async throws {
        var fixture = try FocusFixture()
        for _ in 0..<3 { try fixture.addFrame(raw: false) { _, _ in true } }
        #expect(FocusStackMerger.fileExtension(for: fixture.sources) == "tif")
        let destination = fixture.directory.url.appending(path: "DSC_0000-Focus.tif")
        let thumbnails = fixture.directory.url.appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        let result = try await FocusStackRunner.run(
            sources: fixture.sources, options: FocusStackOptions(), destination: destination, thumbnailDirectory: thumbnails
        )
        #expect(result.mergedCount == 3)

        let file = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        #expect(CGImageSourceGetType(file) as String? == UTType.tiff.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(file, 0, nil))
        #expect(image.width == result.output.pixelWidth && image.height == result.output.pixelHeight)
        #expect(image.bitsPerComponent == 16)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyOrientation] as? Int == 1)

        // Every frame is the same picture, so the stack is that picture: the same grays as the PNGs.
        func grays(_ image: CGImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height)
            let context = try #require(CGContext(
                data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, bitmapInfo: CGImageAlphaInfo.none.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return bytes
        }
        let frame = try #require(CGImageSourceCreateWithURL(fixture.sources[0].url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == frame.width && image.height == frame.height)
        let ours = try grays(image), theirs = try grays(frame)
        var difference = 0
        for i in ours.indices { difference += abs(Int(ours[i]) - Int(theirs[i])) }
        #expect(Double(difference) / Double(ours.count) < 1.5, "mean difference \(Double(difference) / Double(ours.count)) of 255")
    }

    @Test func rawPhotosStayADNG() throws {
        var fixture = try FocusFixture()
        try fixture.addFrame { _, _ in true }
        try fixture.addFrame { _, _ in true }
        #expect(FocusStackMerger.fileExtension(for: fixture.sources) == "dng")
    }
}

@Suite("Focus stack options")
struct FocusStackOptionsTests {
    @Test func defaults() {
        let options = FocusStackOptions()
        #expect(options.method == .depthMap)
        #expect(options.radius == 8)
        #expect(options.smoothing == 4)
        #expect(options.createsStack)
    }

    @Test func remembersTheLastOptions() throws {
        let defaults = try #require(UserDefaults(suiteName: "FocusStackOptionsTests-\(UUID().uuidString)"))
        #expect(FocusStackOptions.load(from: defaults) == FocusStackOptions())
        var options = FocusStackOptions()
        options.method = .pyramid
        options.radius = 20
        options.smoothing = 7
        options.createsStack = false
        options.save(to: defaults)
        #expect(FocusStackOptions.load(from: defaults) == options)
    }

    @Test func readsSettingsWithMissingOrImpossibleValues() throws {
        let saved = Data(#"{"radius": 400, "smoothing": -3, "method": 9}"#.utf8)
        let options = try JSONDecoder().decode(FocusStackOptions.self, from: saved)
        #expect(options.radius == 50)
        #expect(options.smoothing == 0)
        #expect(options.method == .depthMap)
        #expect(options.createsStack)
    }

    @Test func resetKeepsCreateStack() {
        var options = FocusStackOptions()
        options.method = .weightedAverage
        options.radius = 30
        options.smoothing = 9
        options.createsStack = false
        options.resetRendering()
        #expect(options.method == .depthMap && options.radius == 8 && options.smoothing == 4)
        #expect(!options.createsStack)
    }
}

/// Photo Merge ▸ Focus Stack on a real stack, which lives outside the repository: these run only when
/// `PIXELLOUPE_FOCUS_SAMPLES` names its folder (Scripts/focus-stack.sh sets it), never in CI.
/// `PIXELLOUPE_FOCUS_OUTPUT` names a folder for the results and timings; the full-resolution stack
/// runs only with `PIXELLOUPE_FOCUS_FULL` set too, and `PIXELLOUPE_FOCUS_REGION` ("x,y,width,height")
/// stacks that part alone at full resolution, with its depth maps.
@Suite("Focus stack samples", .enabled(if: FocusSamples.folder != nil), .serialized)
struct FocusStackSampleTests {
    @Test func stacksTheSamples() async throws {
        let sources = try FocusSamples.sources()
        var start = Date()
        func lap(_ what: String) {
            FocusSamples.note("\(what): \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
            start = Date()
        }
        let merger = try FocusStackMerger(sources: sources)
        try merger.align()
        lap("read and aligned \(sources.count) photos")
        for frame in merger.frames {
            guard let t = frame.transform else {
                FocusSamples.note("\(frame.source.name): left out")
                continue
            }
            FocusSamples.note(String(
                format: "%@: scale %.5f turn %.4f° move (%.1f, %.1f) gain %.4f", frame.source.name,
                Double(hypot(t.a, t.b)), Double(atan2(t.b, t.a)) * 180 / .pi, Double(t.tx), Double(t.ty), frame.gain
            ))
        }
        #expect(merger.skipped.isEmpty)

        let scale = FocusSamples.regions.isEmpty ? min(1, 2400 / max(merger.nativeSize.width, merger.nativeSize.height)) : 0.05
        var raw: FocusDepthMap?
        var seen = 0
        var defaults = FocusStackOptions()
        defaults.method = FocusSamples.method
        let preview = try merger.merge(options: defaults, scale: scale, depthMap: { map in
            seen += 1
            if seen == merger.frames.count { raw = map }
        })
        lap("preview at \(preview.image.width) × \(preview.image.height)")
        if let output = FocusSamples.output {
            if merger.isRaw {
                try LinearDNGWriter.write(preview.image, metadata: merger.dngMetadata(), to: output.appending(path: "preview.dng"))
            } else {
                try FocusStackTIFFWriter.write(preview.image, like: merger.reference.url, to: output.appending(path: "preview.tif"))
            }
            if let map = preview.depthMap { try FocusSamples.write(map, to: output.appending(path: "preview-depth.png")) }
            if let raw { try FocusSamples.write(raw, to: output.appending(path: "preview-depth-unsmoothed.png")) }
        }

        // Part of the picture at full resolution, with its depth maps, for looking closely at a problem:
        // once with the default settings, and once for each of `PIXELLOUPE_FOCUS_VARIANTS`.
        if let output = FocusSamples.output {
          for (number, region) in FocusSamples.regions.enumerated() {
            for (smoothing, radius) in [(FocusStackOptions().smoothing, FocusStackOptions().radius)] + FocusSamples.variants {
                var options = defaults
                options.smoothing = smoothing
                options.radius = radius
                var maps: [FocusDepthMap] = []
                let part = try merger.merge(options: options, scale: 1, region: region, depthMap: { maps.append($0) })
                let name = "region\(number + 1)-s\(smoothing)-r\(radius)"
                lap("\(name) \(region) at full resolution")
                if merger.isRaw {
                    try LinearDNGWriter.write(part.image, metadata: merger.dngMetadata(), to: output.appending(path: "\(name).dng"))
                } else {
                    try FocusStackTIFFWriter.write(part.image, like: merger.reference.url, to: output.appending(path: "\(name).tif"))
                }
                if let map = part.depthMap { try FocusSamples.write(map, to: output.appending(path: "\(name)-depth.png")) }
                if maps.count >= 2 { try FocusSamples.write(maps[maps.count - 2], to: output.appending(path: "\(name)-depth-unsmoothed.png")) }
            }
          }
        }

        guard FocusSamples.full, let output = FocusSamples.output else { return }
        // The whole picture at full resolution, on the frames already lined up, with its depth map.
        let name = "\(sources[0].url.deletingPathExtension().lastPathComponent)-Focus.\(FocusStackMerger.fileExtension(for: sources))"
        let destination = output.appending(path: name)
        let result = try merger.merge(options: defaults, scale: 1)
        lap("full stack at \(result.image.width) × \(result.image.height)")
        if merger.isRaw {
            try LinearDNGWriter.write(result.image, metadata: merger.dngMetadata(), to: destination)
        } else {
            try FocusStackTIFFWriter.write(result.image, like: merger.reference.url, to: destination)
        }
        if let map = result.depthMap { try FocusSamples.write(map, to: output.appending(path: "full-depth.png")) }
        lap("written")
        #expect(result.mergedCount == sources.count)
    }
}

nonisolated enum FocusSamples {
    static var folder: URL? {
        ProcessInfo.processInfo.environment["PIXELLOUPE_FOCUS_SAMPLES"].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static var output: URL? {
        ProcessInfo.processInfo.environment["PIXELLOUPE_FOCUS_OUTPUT"].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// `PIXELLOUPE_FOCUS_REGION`: "x,y,width,height" in full-size pixels from the top left; several, with ";" between.
    static var regions: [CGRect] {
        (ProcessInfo.processInfo.environment["PIXELLOUPE_FOCUS_REGION"] ?? "").split(separator: ";").compactMap { part in
            let numbers = part.split(separator: ",").compactMap { Double($0) }
            return numbers.count == 4 ? CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]) : nil
        }
    }

    /// `PIXELLOUPE_FOCUS_VARIANTS`: "smoothing:radius,…", more settings to stack the region with.
    static var variants: [(Int, Int)] {
        (ProcessInfo.processInfo.environment["PIXELLOUPE_FOCUS_VARIANTS"] ?? "").split(separator: ",").compactMap { pair in
            let numbers = pair.split(separator: ":").compactMap { Int($0) }
            return numbers.count == 2 ? (numbers[0], numbers[1]) : nil
        }
    }

    /// `PIXELLOUPE_FOCUS_METHOD`: "average" stacks with Weighted Average and "pyramid" with Pyramid;
    /// otherwise Depth Map.
    static var method: FocusStackOptions.Method {
        switch ProcessInfo.processInfo.environment["PIXELLOUPE_FOCUS_METHOD"] {
        case "average": .weightedAverage
        case "pyramid": .pyramid
        default: .depthMap
        }
    }

    static var full: Bool { ProcessInfo.processInfo.environment["PIXELLOUPE_FOCUS_FULL"] != nil }

    /// Every photo in the samples folder, as the catalog would hand them over.
    static func sources() throws -> [PhotoMergeSource] {
        let folder = try #require(folder)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { SupportedImageTypes.isRaw($0) || ["jpg", "jpeg", "heic", "tif", "tiff", "png"].contains($0.pathExtension.lowercased()) }
            // Not a stack made from them earlier, which the app saves beside them.
            .filter { !$0.deletingPathExtension().lastPathComponent.contains("-Focus") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.enumerated().map { index, url in
            PhotoMergeSource(
                url: url, exposureTime: 0, aperture: 0, iso: 0, make: nil, model: nil,
                captureDate: Date(timeIntervalSince1970: 1_791_000_000 + Double(index))
            )
        }
    }

    static func note(_ line: String) {
        print("FOCUS: \(line)")
        guard let output else { return }
        let url = output.appending(path: "timings.txt")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func write(_ map: FocusDepthMap, to url: URL) throws {
        let provider = try #require(CGDataProvider(data: Data(map.pixels) as CFData))
        let image = try #require(CGImage(
            width: map.width, height: map.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: map.width,
            space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
