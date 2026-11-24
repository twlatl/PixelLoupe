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
        let file = try #require(TIFFFile(data: Self.sonyFile(make: "Leica", focusLocation: [9504, 6336, 7395, 3141])))
        #expect(FocusPoints.read(from: file) == nil)
    }

    /// A little-endian TIFF with IFD0 (Make) and an EXIF directory holding `exif` entries (type, value inline) and
    /// a maker note, built by `makerNote` from its offset in the file.
    private static func file(make: String, exif: [(UInt16, Int)] = [], makerNote: (Int) -> Data) -> Data {
        var data = Data()
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: Int) { u16(tag); u16(type); u32(count); u32(value) }
        let makeBytes = Array(make.utf8) + [0]
        let ifd0 = 8, makeAt = ifd0 + 30, exifAt = (makeAt + makeBytes.count + 1) & ~1
        let makerNoteAt = exifAt + 2 + 12 * (exif.count + 1) + 4
        let note = makerNote(makerNoteAt)
        data.append(contentsOf: [0x49, 0x49]); u16(42); u32(ifd0)
        u16(2); entry(271, 2, makeBytes.count, makeAt); entry(34665, 4, 1, exifAt); u32(0)
        data.append(contentsOf: makeBytes)
        while data.count < exifAt { data.append(0) }
        u16(exif.count + 1)
        for (tag, value) in exif { entry(Int(tag), 4, 1, value) }
        entry(0x927C, 7, note.count, makerNoteAt); u32(0)
        data.append(note)
        return data
    }

    private static func words(_ values: [Int], bigEndian: Bool = false) -> Data {
        var data = Data()
        for value in values {
            let word = UInt16(bitPattern: Int16(value))
            withUnsafeBytes(of: bigEndian ? word.bigEndian : word.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// A Canon maker note with an `AFInfo2` record for three points, of which `inFocus` (a bit mask) were in focus.
    private static func canonFile(areaMode: Int = 2, inFocus: Int) -> Data {
        file(make: "Canon") { at in
            // AF image 6000×4000; points at the center, 1500 right and 1000 up, and 1500 left and 1000 down.
            let record = [0, areaMode, 3, 3, 6000, 4000, 6000, 4000, 200, 200, 200, 100, 100, 100, 0, 1500, -1500, 0, 1000, -1000, inFocus, 0]
            var note = Self.words([1, 0x26, 3, record.count, 0, at + 18, 0, 0, 0])
            note.append(Self.words(record))
            return note
        }
    }

    @Test func readsCanonPointsInFocus() throws {
        let file = try #require(TIFFFile(data: Self.canonFile(inFocus: 0b010)))
        let points = try #require(FocusPoints.read(from: file))
        #expect(points.areas.count == 1)
        // 1500 right of center and 1000 up (Y is up), as a 200×100 box.
        #expect(abs(points.areas[0].midX - 0.75) < 1e-9)
        #expect(abs(points.areas[0].midY - 0.25) < 1e-9)
        #expect(abs(points.areas[0].width - 200.0 / 6000) < 1e-9)
        #expect(abs(points.areas[0].height - 100.0 / 4000) < 1e-9)
    }

    @Test func canonWithNoPointInFocusHasNone() throws {
        let noneInFocus = try #require(TIFFFile(data: Self.canonFile(inFocus: 0)))
        #expect(FocusPoints.read(from: noneInFocus) == nil)
        let manual = try #require(TIFFFile(data: Self.canonFile(areaMode: 0, inFocus: 1)))
        #expect(FocusPoints.read(from: manual) == nil)
    }

    /// A Nikon maker note ("Nikon\0", version, then a big-endian TIFF) with `AFInfo2` version 0300.
    private static func nikonFile(coordinatesAvailable: Bool = true) -> Data {
        file(make: "NIKON CORPORATION") { _ in
            var info = Data("0300".utf8) + Data([0, 0, 8, coordinatesAvailable ? 1 : 0])
            info.append(Data(count: 0x2A - info.count))
            info.append(Self.words([8256, 5504, 6744, 2436, 520, 520], bigEndian: true))
            var inner = Data([0x4D, 0x4D, 0, 42, 0, 0, 0, 8])
            inner.append(Self.words([1, 0xB7, 7], bigEndian: true))
            inner.append(contentsOf: [0, 0, 0, UInt8(info.count), 0, 0, 0, 26, 0, 0, 0, 0])
            inner.append(info)
            return Data("Nikon\0".utf8) + Data([2, 0x10, 0, 0]) + inner
        }
    }

    @Test func readsNikonAFArea() throws {
        let file = try #require(TIFFFile(data: Self.nikonFile()))
        let points = try #require(FocusPoints.read(from: file))
        #expect(abs(points.areas[0].midX - 6744.0 / 8256) < 1e-9)
        #expect(abs(points.areas[0].midY - 2436.0 / 5504) < 1e-9)
        #expect(abs(points.areas[0].width - 520.0 / 8256) < 1e-9)
    }

    @Test func nikonWithoutCoordinatesHasNone() throws {
        let file = try #require(TIFFFile(data: Self.nikonFile(coordinatesAvailable: false)))
        #expect(FocusPoints.read(from: file) == nil)
    }

    /// A Fujifilm EXIF block: a 1920×1280 EXIF image size and a maker note with `FocusMode` and `FocusPixel`.
    private static func fujiExif(focusMode: Int = 0, focusPixel: (Int, Int)) -> Data {
        file(make: "FUJIFILM", exif: [(0xA002, 1920), (0xA003, 1280)]) { _ in
            var note = Data("FUJIFILM".utf8) + Self.words([12, 0, 2])
            note.append(Self.words([0x1021, 3, 1, 0, focusMode, 0]))
            note.append(Self.words([0x1023, 3, 2, 0, focusPixel.0, focusPixel.1]))
            note.append(Self.words([0, 0]))
            return note
        }
    }

    @Test func readsFujifilmFocusPixel() throws {
        let file = try #require(TIFFFile(data: Self.fujiExif(focusPixel: (1440, 320))))
        let points = try #require(FocusPoints.read(from: file))
        #expect(points.areas == [CGRect(x: 0.75, y: 0.25, width: 0, height: 0)])
    }

    @Test func fujifilmManualFocusHasNoPoint() throws {
        let file = try #require(TIFFFile(data: Self.fujiExif(focusMode: 1, focusPixel: (1440, 320))))
        #expect(FocusPoints.read(from: file) == nil)
    }

    @Test func readsFocusPixelFromARAF() {
        // RAF header with the embedded JPEG's offset and length at bytes 84 and 88; the JPEG holds APP1 Exif.
        let exif = Self.fujiExif(focusPixel: (480, 960))
        var jpeg = Data([0xFF, 0xD8, 0xFF, 0xE1])
        let length = 2 + 6 + exif.count
        jpeg.append(contentsOf: [UInt8(length >> 8), UInt8(length & 0xFF)])
        jpeg.append(Data("Exif\0\0".utf8) + exif)
        jpeg.append(contentsOf: [0xFF, 0xD9])
        var raf = Data("FUJIFILMCCD-RAW 0201FF383501".utf8)
        raf.append(Data(count: 100 - raf.count))
        for value in [100, jpeg.count] { raf.replaceSubrange((value == 100 ? 84 : 88)..<(value == 100 ? 88 : 92), with: withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) }) }
        raf.append(jpeg)
        #expect(FocusPoints.read(from: raf)?.areas == [CGRect(x: 0.25, y: 0.75, width: 0, height: 0)])
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
