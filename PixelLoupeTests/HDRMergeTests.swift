import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

/// Bracketed exposures of a synthetic scene, written as Linear DNGs.
struct Bracket {
    let directory: TemporaryDirectory
    let width: Int
    let height: Int
    let scene: (Int, Int) -> Float
    var sources: [PhotoMergeSource] = []

    /// A textured scene from about 0.007 to 3.9 (two stops over white), shot at `stops` around the
    /// middle exposure. `shifts` moves each frame's content (pixels right and down), `ghostIn` adds a
    /// dark square to one frame (something that moved), and `metadata` says whether shutter speeds are
    /// recorded.
    init(
        width: Int = 480, height: Int = 320, stops: [Double] = [-2, 0, 2], shifts: [(Int, Int)]? = nil,
        ghostIn frame: Int? = nil, metadata: Bool = true, name: String = "IMG"
    ) throws {
        directory = try TemporaryDirectory()
        self.width = width
        self.height = height
        let scene: (Int, Int) -> Float = { x, y in
            let ramp = Float(0.01) * pow(300, Float(x) / Float(width - 1))
            // Fine, irregular texture so registration has something to lock onto.
            var hash = UInt32(truncatingIfNeeded: (x / 3) &* 73_856_093 ^ (y / 3) &* 19_349_663)
            hash ^= hash >> 13
            hash = hash &* 0x5BD1_E995
            hash ^= hash >> 15
            let texture = 0.7 + 0.6 * Float(hash % 1000) / 1000
            return ramp * texture
        }
        self.scene = scene
        for (index, stop) in stops.enumerated() {
            let gain = Float(pow(2, stop))
            let (dx, dy) = shifts?[index] ?? (0, 0)
            let image = DNGFixtures.image(width: width, height: height) { x, y in
                var value = scene(x - dx, y - dy) * gain
                if frame == index, (200..<260).contains(x), (60..<120).contains(y) { value = 0.05 }
                return SIMD3(repeating: min(value, 1))
            }
            let url = directory.url.appending(path: "\(name)_\(index).dng")
            var dng = DNGMetadata(make: "Canon", model: "EOS R5", captureDate: Date(timeIntervalSince1970: 1_791_000_000 + Double(index)))
            if metadata {
                dng.exposureTime = pow(2, stop) / 100
                dng.aperture = 8
                dng.iso = 100
            }
            try LinearDNGWriter.write(image, metadata: dng, to: url)
            sources.append(PhotoMergeSource(
                url: url, exposureTime: dng.exposureTime, aperture: dng.aperture, iso: dng.iso,
                make: dng.make, model: dng.model, captureDate: dng.captureDate
            ))
        }
    }

    /// The merged radiance at a pixel, relative to the middle exposure (undoing the scaling to 0…1).
    static func value(_ image: LinearDNGImage, x: Int, y: Int) -> SIMD3<Float> {
        let i = (y * image.width + x) * 3
        let k = Float(pow(2, image.headroom ?? 0))
        return SIMD3(Float(image.pixels[i]), Float(image.pixels[i + 1]), Float(image.pixels[i + 2])) * k
    }

    /// Mean relative error against the scene over a region, skipping `margin` pixels at the edges.
    func error(of image: LinearDNGImage, margin: Int = 12, where include: (Int, Int) -> Bool = { _, _ in true }) -> Float {
        var total: Float = 0
        var count = 0
        for y in stride(from: margin, to: height - margin, by: 2) {
            for x in stride(from: margin, to: width - margin, by: 2) where include(x, y) {
                let expected = scene(x, y)
                total += abs(Self.value(image, x: x, y: y).x - expected) / expected
                count += 1
            }
        }
        return total / Float(max(count, 1))
    }
}

@Suite("HDR merge")
struct HDRMergeTests {
    private var noAlign: HDRMergeOptions {
        var options = HDRMergeOptions()
        options.autoAlign = false
        options.autoSettings = false
        return options
    }

    @Test func recoversHighlightsAndShadows() throws {
        let bracket = try Bracket()
        let merger = try HDRMerger(sources: bracket.sources)
        let result = try merger.merge(options: noAlign, scale: 1)
        #expect(result.image.width == bracket.width && result.image.height == bracket.height)
        #expect(bracket.error(of: result.image) < 0.03)
        // The scene runs two stops over white; the middle exposure alone clips at 1.
        let bright = Bracket.value(result.image, x: bracket.width - 20, y: bracket.height / 2).x
        #expect(abs(bright - bracket.scene(bracket.width - 20, bracket.height / 2)) / bright < 0.05)
        #expect(bright > 2)
    }

    @Test func autoSettingsToneMapsTheRange() throws {
        let bracket = try Bracket()
        let merger = try HDRMerger(sources: bracket.sources)
        var options = noAlign
        let plain = try merger.merge(options: options, scale: 1).image
        options.autoSettings = true
        let toned = try merger.merge(options: options, scale: 1).image
        func mean(_ image: LinearDNGImage, columns: Range<Int>) -> Float {
            var total: Float = 0
            for y in stride(from: 20, to: bracket.height - 20, by: 4) {
                for x in columns { total += Bracket.value(image, x: x, y: y).y }
            }
            return total / Float(((bracket.height - 40) / 4) * columns.count)
        }
        // The scene spans about nine stops left to right; tone mapping brings the ends closer.
        let plainSpan = log2(mean(plain, columns: 440..<460) / mean(plain, columns: 20..<40))
        let tonedSpan = log2(mean(toned, columns: 440..<460) / mean(toned, columns: 20..<40))
        #expect(plainSpan > 7)
        #expect(tonedSpan < plainSpan * 0.75, "\(tonedSpan) of \(plainSpan) stops")
        #expect(tonedSpan > 1, "still brighter on the right")
    }

    @Test func middleExposureIsTheReference() throws {
        let bracket = try Bracket(stops: [2, -2, 0])
        let merger = try HDRMerger(sources: bracket.sources)
        #expect(merger.reference.url == bracket.sources[2].url)
        #expect(merger.frames.map(\.source.url) == [bracket.sources[1].url, bracket.sources[2].url, bracket.sources[0].url])
        #expect(merger.frames.map(\.gain).map { ($0 * 100).rounded() / 100 } == [0.25, 1, 4])
    }

    @Test func estimatesExposuresWithoutShutterSpeeds() throws {
        let bracket = try Bracket(metadata: false)
        let merger = try HDRMerger(sources: bracket.sources)
        for (frame, expected) in zip(merger.frames, [0.25, 1, 4]) {
            #expect(abs(frame.gain - expected) / expected < 0.03, "estimated \(frame.gain), expected \(expected)")
        }
        #expect(bracket.error(of: try merger.merge(options: noAlign, scale: 1).image) < 0.04)
    }

    @Test func mergesAtPreviewScale() throws {
        let bracket = try Bracket()
        let result = try HDRMerger(sources: bracket.sources).merge(options: noAlign, scale: 0.5)
        #expect(result.image.width == bracket.width / 2 && result.image.height == bracket.height / 2)
    }

    @Test func alignsShiftedFrames() throws {
        let bracket = try Bracket(width: 640, height: 400, shifts: [(7, -5), (0, 0), (-6, 4)])
        let merger = try HDRMerger(sources: bracket.sources)
        // Offsets move each frame back onto the reference, in Core Image's axes (y up).
        let offsets = merger.alignmentOffsets()
        #expect(abs(offsets[0].dx + 7) < 1 && abs(offsets[0].dy + 5) < 1, "\(offsets[0])")
        #expect(offsets[1] == .zero)
        #expect(abs(offsets[2].dx - 6) < 1 && abs(offsets[2].dy - 4) < 1, "\(offsets[2])")
        let unaligned = bracket.error(of: try merger.merge(options: noAlign, scale: 1).image)
        var options = noAlign
        options.autoAlign = true
        let aligned = bracket.error(of: try merger.merge(options: options, scale: 1).image)
        #expect(aligned < 0.04)
        #expect(aligned < unaligned / 2)
    }

    @Test func alignsWideBracketsThroughTheirNeighbors() throws {
        // A 7-shot bracket 2 EV apart, as on Ted's 10-29 panorama: the ends share little with the middle
        // exposure, so each frame registers to the next one in and the shifts add up.
        let shifts = [(5, 3), (4, -2), (3, 1), (0, 0), (-3, 2), (-4, -3), (-5, 4)]
        let bracket = try Bracket(width: 640, height: 400, stops: [-6, -4, -2, 0, 2, 4, 6], shifts: shifts)
        let merger = try HDRMerger(sources: bracket.sources)
        let offsets = merger.alignmentOffsets()
        for index in 0..<6 {
            let (dx, dy) = shifts[index]
            // Back onto the reference, in Core Image's axes (y up).
            #expect(abs(offsets[index].dx + CGFloat(dx)) < 1.5 && abs(offsets[index].dy - CGFloat(dy)) < 1.5, "\(index): \(offsets[index])")
        }
        // The brightest is nearly all clipped: whatever it registers as, never a wild shift.
        #expect(hypot(offsets[6].dx, offsets[6].dy) <= HDRMerger.largestShift * 640, "\(offsets[6])")
    }

    @Test func deghostingKeepsTheReferenceWhereFramesDisagree() throws {
        // A dark square appears only in the brightest frame, over the midtones.
        let bracket = try Bracket(ghostIn: 2)
        let merger = try HDRMerger(sources: bracket.sources)
        let inGhost: (Int, Int) -> Bool = { x, y in (204..<256).contains(x) && (64..<116).contains(y) }
        let ghosted = try merger.merge(options: noAlign, scale: 1)
        #expect(bracket.error(of: ghosted.image, where: inGhost) > 0.3)
        #expect(ghosted.ghostMask == nil)

        var options = noAlign
        options.deghost = .medium
        let clean = try merger.merge(options: options, scale: 1)
        #expect(bracket.error(of: clean.image, where: inGhost) < 0.05)
        // Away from the object, the merge is unchanged.
        #expect(bracket.error(of: clean.image, where: { x, _ in x > 300 }) < 0.03)
        let mask = try #require(clean.ghostMask)
        #expect(mask.value(atX: 0.48, y: 0.28) > 0.5)
        #expect(mask.value(atX: 0.8, y: 0.8) < 0.1)
    }

    @Test func rejectsSelectionsThatCannotMerge() throws {
        let bracket = try Bracket()
        #expect(throws: PhotoMergeError.tooFewPhotos) { try HDRMerger(sources: [bracket.sources[0]]) }

        let jpeg = try Fixtures.writeJPEG(to: bracket.directory.url.appending(path: "a.jpg"), width: 480, height: 320)
        let jpegSource = PhotoMergeSource(url: jpeg, exposureTime: 0.01, aperture: 8, iso: 100, make: "Canon", model: "EOS R5")
        #expect(throws: PhotoMergeError.notRaw("a.jpg")) { try HDRMerger(sources: [bracket.sources[0], jpegSource]) }

        let small = try Bracket(width: 400, height: 320, name: "SMALL")
        #expect(throws: PhotoMergeError.differentSizes) { try HDRMerger(sources: [bracket.sources[0], small.sources[1]]) }

        var other = bracket.sources[1]
        other.model = "EOS R6"
        #expect(throws: PhotoMergeError.differentCameras) { try HDRMerger(sources: [bracket.sources[0], other]) }
    }

    @Test func warnsWhenExposuresMatch() throws {
        let same = try Bracket(stops: [0, 0])
        #expect(try HDRMerger(sources: same.sources).warning != nil)
        let bracket = try Bracket()
        #expect(try HDRMerger(sources: bracket.sources).warning == nil)
    }

    @Test func dngMetadataComesFromTheReference() throws {
        let bracket = try Bracket()
        let merger = try HDRMerger(sources: bracket.sources)
        let metadata = merger.dngMetadata()
        #expect(metadata.make == "Canon" && metadata.model == "EOS R5")
        #expect(metadata.exposureTime == 0.01 && metadata.aperture == 8 && metadata.iso == 100)
        #expect(metadata.captureDate == Date(timeIntervalSince1970: 1_791_000_001))
    }

    @Test func writtenMergeOpensAsRaw() throws {
        let bracket = try Bracket()
        let merger = try HDRMerger(sources: bracket.sources)
        let result = try merger.merge(options: noAlign, scale: 1)
        let url = bracket.directory.url.appending(path: "IMG_0-HDR.dng")
        try LinearDNGWriter.write(result.image, metadata: merger.dngMetadata(), to: url)
        let decoded = try DNGFixtures.decodeLinear(url)
        let x = bracket.width - 20, y = bracket.height / 2
        let expected = bracket.scene(x, y)
        #expect(abs(DNGFixtures.pixel(decoded, x: x, y: y).x - expected) / expected < 0.05)
    }
}

@Suite("HDR merge options")
struct HDRMergeOptionsTests {
    @Test func defaultsMatchLightroom() {
        let options = HDRMergeOptions()
        #expect(options.autoAlign && options.autoSettings)
        #expect(options.deghost == .none && !options.showsDeghostOverlay && !options.createsStack)
    }

    @Test func remembersTheLastOptions() throws {
        let defaults = try #require(UserDefaults(suiteName: "HDRMergeOptionsTests-\(UUID().uuidString)"))
        #expect(HDRMergeOptions.load(from: defaults) == HDRMergeOptions())
        var options = HDRMergeOptions()
        options.deghost = .high
        options.createsStack = true
        options.save(to: defaults)
        #expect(HDRMergeOptions.load(from: defaults) == options)
    }

    @Test func deghostSliderHasFourStops() {
        #expect(HDRMergeOptions.Deghost.allCases.map(\.title) == ["None", "Low", "Medium", "High"])
    }
}
