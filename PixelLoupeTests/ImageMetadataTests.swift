import Foundation
import Testing
@testable import PixelLoupe

@Suite("Image metadata")
struct ImageMetadataTests {
    @Test func parsesExifDateWithOffset() throws {
        let date = try #require(ImageMetadata.parseExifDate("2026:10:12 09:30:15", offset: "-04:00"))
        #expect(date == ISO8601DateFormatter().date(from: "2026-10-12T13:30:15Z"))
    }

    @Test func parsesExifDateWithoutOffsetInLocalTime() throws {
        let date = try #require(ImageMetadata.parseExifDate("2026:01:02 03:04:05", offset: nil))
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(components == DateComponents(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5))
    }

    @Test(arguments: ["", "2026:10:12", "garbage", "    :  :     :  :  "])
    func rejectsMalformedDates(string: String) {
        #expect(ImageMetadata.parseExifDate(string, offset: nil) == nil)
    }

    @Test func readsMetadataFromFile() throws {
        let directory = try TemporaryDirectory()
        let url = try Fixtures.writeJPEG(
            to: directory.url.appending(path: "photo.jpg"),
            offset: "+02:00",
            keywords: ["Beach", "Sunset", "beach"]
        )
        let metadata = try #require(ImageMetadata.read(from: url))
        #expect(metadata.cameraMake == "Canon")
        #expect(metadata.cameraModel == "EOS R5")
        #expect(metadata.lensModel == "RF24-70mm F2.8 L IS USM")
        #expect(metadata.pixelWidth == 64)
        #expect(metadata.pixelHeight == 48)
        #expect(metadata.captureDate == ISO8601DateFormatter().date(from: "2026-10-12T07:30:00Z"))
        #expect(metadata.keywords == ["Beach", "Sunset"], "keywords are de-duplicated case-insensitively")
    }

    @Test func nonImageReturnsNil() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "notes.jpg")
        try Data("not an image".utf8).write(to: url)
        #expect(ImageMetadata.read(from: url) == nil)
    }

    @Test(arguments: ["CR3", "cr2", "NEF", "ARW", "DNG", "RAF", "ORF", "RW2"])
    func rawFormatsAreSupported(ext: String) {
        let url = URL(filePath: "/tmp/photo.\(ext)")
        #expect(SupportedImageTypes.isSupported(url))
        #expect(SupportedImageTypes.isRaw(url))
    }

    @Test(arguments: ["jpg", "JPEG", "heic", "HEIF", "tif", "tiff", "png"])
    func standardFormatsAreSupported(ext: String) {
        let url = URL(filePath: "/tmp/photo.\(ext)")
        #expect(SupportedImageTypes.isSupported(url))
        #expect(!SupportedImageTypes.isRaw(url))
    }

    @Test(arguments: ["txt", "xmp", "pdf", ""])
    func otherFilesAreNotSupported(ext: String) {
        #expect(!SupportedImageTypes.isSupported(URL(filePath: "/tmp/file.\(ext)")))
    }
}
