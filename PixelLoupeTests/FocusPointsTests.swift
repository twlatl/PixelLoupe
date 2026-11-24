import CoreGraphics
import Foundation
import Testing
@testable import PixelLoupe

/// Show Focus Points (RAW-308): reading the AF point from maker notes and placing it on the photo as shown.
struct FocusPointsTests {
    // MARK: - Reading

    /// A little-endian TIFF with IFD0 (Make), an EXIF directory and a Sony maker note holding `FocusLocation`.
    private static func sonyFile(make: String = "SONY", header: Bool = true, focusLocation: [UInt16]) -> Data {
        var data = Data()
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: Int) { u16(tag); u16(type); u32(count); u32(value) }
        let makeBytes = Array(make.utf8) + [0]
        let ifd0 = 8, makeAt = ifd0 + 30, exifAt = (makeAt + makeBytes.count + 1) & ~1
        let makerNoteAt = exifAt + 18, headerSize = header ? 12 : 0
        let makerIFD = makerNoteAt + headerSize, valuesAt = makerIFD + 18
        data.append(contentsOf: [0x49, 0x49]); u16(42); u32(ifd0)
        u16(2); entry(271, 2, makeBytes.count, makeAt); entry(34665, 4, 1, exifAt); u32(0)
        data.append(contentsOf: makeBytes)
        while data.count < exifAt { data.append(0) }
        u16(1); entry(0x927C, 7, valuesAt + 8 - makerNoteAt, makerNoteAt); u32(0)
        if header { data.append(contentsOf: Array("SONY DSC ".utf8) + [0, 0, 0]) }
        u16(1); entry(0x2027, 3, 4, valuesAt); u32(0)
        for value in focusLocation { u16(Int(value)) }
        return data
    }

    @Test func readsSonyFocusLocation() throws {
        let file = try #require(TIFFFile(data: Self.sonyFile(focusLocation: [9504, 6336, 7395, 3141])))
        let points = try #require(FocusPoints.read(from: file))
        #expect(points.areas.count == 1)
        #expect(abs(points.areas[0].minX - 7395.0 / 9504) < 1e-9)
        #expect(abs(points.areas[0].minY - 3141.0 / 6336) < 1e-9)
        #expect(points.areas[0].size == .zero)
    }

    @Test func readsSonyMakerNoteWithoutHeader() throws {
        let file = try #require(TIFFFile(data: Self.sonyFile(header: false, focusLocation: [6000, 4000, 3000, 2000])))
        #expect(FocusPoints.read(from: file)?.areas.first?.origin == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func manualFocusHasNoPoint() throws {
        let file = try #require(TIFFFile(data: Self.sonyFile(focusLocation: [9504, 6336, 0, 0])))
        #expect(FocusPoints.read(from: file) == nil)
    }

    @Test func otherMakesHaveNoPointYet() throws {
        let file = try #require(TIFFFile(data: Self.sonyFile(make: "Canon", focusLocation: [9504, 6336, 7395, 3141])))
        #expect(FocusPoints.read(from: file) == nil)
    }

    // MARK: - Placing

    private static func framePoint(_ x: CGFloat, _ y: CGFloat, exif: Int, turns: Int = 0, mirrored: Bool = false) -> CGPoint {
        FocusPoints.framePoint(
            CGPoint(x: x, y: y), fileOrientation: exif,
            orientation: PhotoAdjustments.Orientation(quarterTurns: turns, isMirrored: mirrored)
        )
    }

    /// The stored image's top-left corner, through each EXIF orientation, in frame coordinates (origin bottom-left).
    @Test(arguments: [
        (1, CGPoint(x: 0, y: 1)), (2, CGPoint(x: 1, y: 1)), (3, CGPoint(x: 1, y: 0)), (4, CGPoint(x: 0, y: 0)),
        (5, CGPoint(x: 0, y: 1)), (6, CGPoint(x: 1, y: 1)), (7, CGPoint(x: 1, y: 0)), (8, CGPoint(x: 0, y: 0)),
    ])
    func cameraOrientation(exif: Int, expected: CGPoint) {
        #expect(Self.framePoint(0, 0, exif: exif) == expected)
    }

    /// A point right of center near the top of the sensor, with the camera turned for a portrait (EXIF 8: stored
    /// row 0 is the photo's left side), lands in the photo's upper left.
    @Test func portraitPointLandsWhereThePhotoShowsIt() {
        // Stored (u, v) = (0.75, 0.25); EXIF 8 shows it at (0.25, 0.25) from the top-left.
        let point = Self.framePoint(0.75, 0.25, exif: 8)
        #expect(abs(point.x - 0.25) < 1e-9)
        #expect(abs(point.y - 0.75) < 1e-9)
    }

    @Test func rotateAndFlipFollowThePhoto() {
        // Rotate Left: the right edge comes to the top.
        #expect(Self.framePoint(1, 0.5, exif: 1, turns: 1) == CGPoint(x: 0.5, y: 1))
        // Flip Horizontal.
        #expect(Self.framePoint(0.25, 0.5, exif: 1, mirrored: true) == CGPoint(x: 0.75, y: 0.5))
        // Rotate Right is three quarter turns left.
        #expect(Self.framePoint(1, 0.5, exif: 1, turns: 3) == CGPoint(x: 0.5, y: 0))
    }

    @Test func markerIsCenteredOnThePointInTheCrop() throws {
        // A 1000×500 frame cropped to its right half, shown at 500×500 points.
        var crop = PhotoAdjustments.Crop()
        crop.rect = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let frame = PreviewFrame.cropped(shown: CGRect(x: 0, y: 0, width: 500, height: 500), crop: crop, frameSize: CGSize(width: 1000, height: 500))
        let path = FocusPoints.markerPath(frameAreas: [CGRect(x: 0.75, y: 0.5, width: 0, height: 0)], in: frame)
        let box = path.boundingBox
        #expect(abs(box.midX - 250) < 1e-6)
        #expect(abs(box.midY - 250) < 1e-6)
        #expect(box.width == 20)
    }

    @Test func pointCroppedOutIsNotDrawn() {
        var crop = PhotoAdjustments.Crop()
        crop.rect = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let frame = PreviewFrame.cropped(shown: CGRect(x: 0, y: 0, width: 500, height: 500), crop: crop, frameSize: CGSize(width: 1000, height: 500))
        let path = FocusPoints.markerPath(frameAreas: [CGRect(x: 0.25, y: 0.5, width: 0, height: 0)], in: frame)
        #expect(path.isEmpty)
    }
}
