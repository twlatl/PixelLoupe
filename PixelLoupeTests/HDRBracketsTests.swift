import Foundation
import ImageIO
import Testing
@testable import PixelLoupe

@Suite("HDR Panorama bracket sets")
struct HDRBracketsTests {
    /// Photos taken a tenth of a second apart within a set and 8 seconds apart between sets. `bias`
    /// is each set's compensation; `base` gives each set's metered shutter speed (the 0 EV frame's),
    /// and `fastest` clamps shutter speeds as a camera does.
    static func bracketed(
        positions: Int, bias: [Double], base: (Int) -> Double = { _ in 1.0 / 400 },
        fastest: Double = 1.0 / 4000, recordsBias: Bool = true
    ) -> [PhotoMergeSource] {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var photos: [PhotoMergeSource] = []
        for position in 0..<positions {
            for (shot, step) in bias.enumerated() {
                let number = photos.count + 260
                photos.append(PhotoMergeSource(
                    url: URL(fileURLWithPath: "/tmp/DSC00\(number).ARW"),
                    exposureTime: max(fastest, base(position) * pow(2, step)), aperture: 8, iso: 100,
                    make: "SONY", model: "ILCE-7RM5",
                    captureDate: start.addingTimeInterval(Double(position) * 8 + Double(shot) * 0.13),
                    exposureBias: recordsBias ? step : nil
                ))
            }
        }
        return photos
    }

    static let five: [Double] = [-4, -2, 0, 2, 4]
    static let seven: [Double] = [-6, -4, -2, 0, 2, 4, 6]

    @Test func fiveShotSetsSplitByPosition() throws {
        let photos = Self.bracketed(positions: 9, bias: Self.five)
        let sets = try #require(HDRBrackets.sets(photos))
        #expect(sets.count == 9 && sets.allSatisfy { $0.count == 5 })
        #expect(sets[0].map(\.name) == (260...264).map { "DSC00\($0).ARW" })
        #expect(sets[8].last?.name == "DSC00304.ARW")
    }

    @Test func sevenShotSetsSplitThoughTheDarkestShareAShutterSpeed() throws {
        // As on 10-29: each position meters differently, and −6 and −4 both clamp to 1/4000 s, so the
        // shutter speeds don't repeat from set to set, but the compensation does.
        let metered: [Double] = [1.0 / 400, 1.0 / 320, 1.0 / 500, 1.0 / 250]
        let photos = Self.bracketed(positions: 19, bias: Self.seven, base: { metered[$0 % metered.count] })
        #expect(photos[0].exposureTime == photos[1].exposureTime)
        let sets = try #require(HDRBrackets.sets(photos))
        #expect(sets.count == 19 && sets.allSatisfy { $0.count == 7 })
        #expect(sets.allSatisfy { $0.map(\.exposureBias) == Self.seven })
    }

    @Test func selectionOrderDoesntMatter() throws {
        let photos = Self.bracketed(positions: 4, bias: Self.five)
        // Selected backwards, with the second set first.
        let shuffled = Array(photos[5..<10]) + photos[0..<5].reversed() + photos[10...].reversed()
        let sets = try #require(HDRBrackets.sets(shuffled))
        #expect(sets.flatMap { $0 } == photos)
    }

    @Test func withoutCompensationExposuresAreMatched() throws {
        // Bracketed in manual exposure: no compensation recorded, the base exposure moves set to set.
        let photos = Self.bracketed(positions: 4, bias: [-2, 0, 2], base: { [1.0 / 100, 1.0 / 125, 1.0 / 80, 1.0 / 100][$0] },
                                    recordsBias: false)
        let sets = try #require(HDRBrackets.sets(photos))
        #expect(sets.count == 4 && sets.allSatisfy { $0.count == 3 })
        // Compensation recorded as 0 for every photo doesn't split them, so exposure does.
        let zeroBias = photos.map { photo in
            var photo = photo
            photo.exposureBias = 0
            return photo
        }
        #expect(HDRBrackets.sets(zeroBias)?.count == 4)
    }

    @Test func photosThatArentSetsOfOneBracketArentSplit() {
        // One photo missing from a set.
        #expect(HDRBrackets.sets(Array(Self.bracketed(positions: 4, bias: Self.five).dropLast())) == nil)
        // A set shot in another order.
        var reordered = Self.bracketed(positions: 3, bias: Self.five)
        let first = reordered[5].captureDate
        reordered[5].captureDate = reordered[6].captureDate
        reordered[6].captureDate = first
        #expect(HDRBrackets.sets(reordered) == nil)
        // The same compensation twice in a set (and the same exposure).
        #expect(HDRBrackets.sets(Self.bracketed(positions: 3, bias: [-2, 0, 0])) == nil)
        // One exposure per position: a plain panorama.
        #expect(HDRBrackets.sets(Self.bracketed(positions: 6, bias: [0])) == nil)
        // No exposure details at all.
        let unknown = Self.bracketed(positions: 3, bias: Self.five, recordsBias: false).map { photo in
            var photo = photo
            photo.exposureTime = 0
            return photo
        }
        #expect(HDRBrackets.sets(unknown) == nil)
        #expect(HDRBrackets.sets(Array(Self.bracketed(positions: 1, bias: [-2, 0, 2]))) == nil)
    }

    @Test func compensationIsReadFromTheFile() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "bracket.jpg")
        try Fixtures.writeJPEG(to: url, exif: [kCGImagePropertyExifExposureBiasValue: -2.0])
        let source = PhotoMergeSource(url: url, exposureTime: 0, aperture: 0, iso: 0, make: nil, model: nil)
        #expect(source.exposureBias == nil)
        #expect(source.readingExposureBias().exposureBias == -2)
    }

    /// Ted's 10-29 shoot, when its volume is mounted: four panoramas and what else was shot around them.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: Self.shoot.path(percentEncoded: false))))
    func theTenTwentyNinePanoramasSplit() throws {
        func photos(_ numbers: ClosedRange<Int>) -> [PhotoMergeSource] {
            numbers.map { number in
                let url = Self.shoot.appending(path: String(format: "DSC%05d.ARW", number))
                let shooting = ShootingInfo.read(from: url)
                var source = PhotoMergeSource(
                    url: url, exposureTime: shooting.exposureTime ?? 0, aperture: shooting.aperture ?? 0,
                    iso: shooting.iso ?? 0, make: "SONY", model: "ILCE-7RM5", captureDate: Self.captureDate(url)
                )
                source.exposureBias = shooting.exposureBias
                return source
            }
        }
        for (numbers, positions, shots) in [(260...304, 9, 5), (305...437, 19, 7), (438...500, 9, 7), (501...535, 7, 5)] {
            let sets = try #require(HDRBrackets.sets(photos(numbers)), "\(numbers)")
            #expect(sets.count == positions && sets.allSatisfy { $0.count == shots }, "\(numbers)")
        }
        // Two single shots, then the first panorama: not one bracket.
        #expect(HDRBrackets.sets(photos(258...264)) == nil)
    }

    nonisolated static let shoot = URL(fileURLWithPath: "/Volumes/Pictures/Panorama Test/2026/10-29", isDirectory: true)

    static func captureDate(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let subseconds = (exif[kCGImagePropertyExifSubsecTimeOriginal] as? String).flatMap { Double("0.\($0)") } ?? 0
        return formatter.date(from: original)?.addingTimeInterval(subseconds)
    }
}
