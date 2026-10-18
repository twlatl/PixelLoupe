import AppKit
import CoreData
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PixelLoupe

@Suite("Dragging photos out of the app")
@MainActor
struct DragOutTests {
    /// A catalog with one 64 × 48 JPEG, rotated a quarter turn and cropped to its left half.
    private struct Setup {
        let directory: TemporaryDirectory
        let store: CatalogStore
        let photo: Photo
    }

    private func makeSetup() throws -> Setup {
        let directory = try TemporaryDirectory()
        let url = try Fixtures.writeJPEG(to: directory.subdirectory("Photos").appending(path: "IMG_0001.JPG"))
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let photo = Photo(context: store.viewContext)
        photo.id = UUID()
        photo.fileName = url.lastPathComponent
        photo.filePath = url.path(percentEncoded: false)
        photo.fileType = "JPG"
        photo.captureDate = Date()
        photo.importDate = Date()
        photo.editDate = Date()
        var adjustments = PhotoAdjustments()
        adjustments.orientation.quarterTurns = 1
        adjustments.crop.rect = CGRect(x: 0, y: 0, width: 1, height: 0.5)
        photo.adjustments = adjustments
        try store.viewContext.save()
        return Setup(directory: directory, store: store, photo: photo)
    }

    private func pasteboard(with writer: any NSPasteboardWriting) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("DragOutTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([writer])
        return pasteboard
    }

    @Test func dragsOfferAFileAndStillDropOnCollections() throws {
        let setup = try makeSetup()
        let writer = PhotoDrag.pasteboardWriter(for: setup.photo.objectID, store: setup.store)
        let dragged = try #require(writer as? DraggedPhoto)
        #expect(dragged.fileName == "IMG_0001.jpg")
        let pasteboard = pasteboard(with: writer)
        defer { pasteboard.releaseGlobally() }
        // PixelLoupe's own drop targets (collections in the sidebar) still read the photo.
        #expect(PhotoDrag.objectIDs(from: pasteboard, store: setup.store) == [setup.photo.objectID])
        #expect(pasteboard.types?.contains(.fileURL) == true, "other apps see a file")
    }

    /// Finder, Messages, Mail, TextEdit, Photoshop and Pixelmator read the drag's file URL when it's
    /// dropped; that renders the JPEG (once).
    @Test func appsReadingTheFileURLGetARenderedJPEG() throws {
        let setup = try makeSetup()
        let writer = PhotoDrag.pasteboardWriter(for: setup.photo.objectID, store: setup.store)
        let pasteboard = pasteboard(with: writer)
        defer { pasteboard.releaseGlobally() }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let url = try #require(urls.first)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(url.lastPathComponent == "IMG_0001.jpg")
        #expect((writer as? DraggedPhoto)?.renderedFile() == url, "rendered once per drag")
        try checkJPEG(at: url)
    }

    /// An upright, cropped sRGB JPEG with the original's metadata.
    private func checkJPEG(at url: URL) throws {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        // 64 × 48 turned a quarter is 48 × 64; the crop keeps half its height.
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 48)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 32)
        #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1, "the pixels are already upright")
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFModel] as? String == "EOS R5", "the original's metadata is kept")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.colorSpace?.name == CGColorSpace.sRGB)
    }

    /// Apps may ask from any thread (Messages asked on a file-coordination queue).
    @Test func theFileCanBeRequestedOffTheMainThread() async throws {
        let setup = try makeSetup()
        let dragged = try #require(PhotoDrag.pasteboardWriter(for: setup.photo.objectID, store: setup.store) as? DraggedPhoto)
        let url: URL? = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let item = NSPasteboardItem()
                dragged.pasteboard(nil, item: item, provideDataForType: .fileURL)
                continuation.resume(returning: item.string(forType: .fileURL).flatMap(URL.init(string:)))
            }
        }
        let file = try #require(url)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try checkJPEG(at: file)
    }

    @Test func aMissingFileOffersNothing() throws {
        let setup = try makeSetup()
        let dragged = try #require(PhotoDrag.pasteboardWriter(for: setup.photo.objectID, store: setup.store) as? DraggedPhoto)
        try FileManager.default.removeItem(at: setup.photo.fileURL)
        #expect(dragged.renderedFile() == nil)
        let item = NSPasteboardItem()
        dragged.pasteboard(nil, item: item, provideDataForType: .fileURL)
        #expect(item.string(forType: .fileURL) == nil)
    }
}
