import CoreData
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PixelLoupe

/// Scoring photos for Assisted Culling in the background (RAW-71).
@Suite("Culling analysis")
@MainActor
struct CullingAnalysisTests {
    private struct Setup {
        let directory: TemporaryDirectory
        let store: CatalogStore
        let photos: [Photo]
        var analysis: CullingAnalysis { store.cullingAnalysis }
    }

    /// Two photos with thumbnails, and a video.
    private func makeSetup() throws -> Setup {
        let directory = try TemporaryDirectory()
        let folderURL = try directory.subdirectory("Photos")
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let context = store.viewContext
        let folder = Folder(context: context)
        folder.path = folderURL.path(percentEncoded: false)
        folder.name = "Photos"
        var photos: [Photo] = []
        for (index, name) in ["IMG_0.jpg", "IMG_1.jpg", "MOV_2.mov"].enumerated() {
            let url = folderURL.appending(path: name)
            let photo = Photo(context: context)
            photo.id = UUID()
            photo.fileName = name
            photo.filePath = url.path(percentEncoded: false)
            photo.fileType = url.pathExtension.uppercased()
            photo.captureDate = Date(timeIntervalSince1970: Double(index))
            photo.importDate = Date()
            photo.editDate = Date()
            photo.folder = folder
            photo.isVideo = name.hasPrefix("MOV")
            if !photo.isVideo {
                try Self.writeTexture(to: url, width: 640, height: 480)
                try Self.writeTexture(to: store.thumbnails.url(for: photo.id), width: 320, height: 240)
            }
            photos.append(photo)
        }
        try context.save()
        context.undoManager?.removeAllActions()
        return Setup(directory: directory, store: store, photos: photos)
    }

    /// A JPEG of grey noise: crisp detail all over, and no faces.
    private static func writeTexture(to url: URL, width: Int, height: Int) throws {
        var bytes = (0..<(width * height)).map { _ in UInt8.random(in: 40...215) }
        let image = try #require(bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )?.makeImage()
        })
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private func analyze(_ setup: Setup, _ photos: [Photo], again: Bool = false) async {
        setup.analysis.start(after: .zero)
        defer { setup.analysis.stop() }
        setup.analysis.analyze(photos, again: again)
        await setup.analysis.waitUntilIdle()
    }

    @Test func askedForPhotosAreScoredWithoutAnUndoStep() async throws {
        let setup = try makeSetup()
        var progress: [LibraryState.ImportStatus?] = []
        setup.analysis.onProgress = { progress.append($0) }

        await analyze(setup, setup.photos)

        let photo = setup.photos[0]
        #expect(photo.cullVersion == CullingAnalyzer.version)
        #expect(!photo.cullFocusPending)
        #expect(photo.cullSubjectFocus >= 0, "focus is measured from the original")
        #expect(photo.cullFaceCount == 0)
        #expect(photo.cullEyesOpenMin == -1 && photo.cullEyeFocus == -1, "no faces, so the eye scores are unknown")
        #expect(!photo.cullMisfire && !photo.cullExposureIssue && !photo.cullDocument)
        #expect(setup.photos[1].cullVersion == CullingAnalyzer.version)
        #expect(setup.photos[2].cullVersion == 0, "videos are skipped")
        #expect(setup.store.viewContext.undoManager?.canUndo == false)
        #expect(progress.first??.total == 2)
        #expect(progress.last! == nil)
    }

    @Test func aVirtualCopyIsScoredAsItsMaster() async throws {
        let setup = try makeSetup()
        let copyID = try #require(PhotoEditing(store: setup.store).createVirtualCopies(of: [setup.photos[0].objectID]).first)
        let copy = try #require(try setup.store.viewContext.existingObject(with: copyID) as? Photo)

        await analyze(setup, [copy])

        let master = setup.photos[0]
        #expect(master.cullVersion == CullingAnalyzer.version)
        #expect(copy.cullVersion == CullingAnalyzer.version)
        #expect(copy.cullSubjectFocus == master.cullSubjectFocus)
        #expect(copy.cullMisfire == master.cullMisfire)
    }

    @Test func analyzedPhotosAreOnlyScoredAgainWhenAsked() async throws {
        let setup = try makeSetup()
        let photo = setup.photos[0]
        photo.cullVersion = CullingAnalyzer.version
        photo.cullSubjectFocus = 0.123
        try setup.store.viewContext.save()

        await analyze(setup, [photo])
        #expect(photo.cullSubjectFocus == 0.123)

        await analyze(setup, [photo], again: true)
        #expect(photo.cullSubjectFocus != 0.123)
    }

    @Test func scoresFromAnOlderAnalyzerCountAsUnanalyzed() async throws {
        let setup = try makeSetup()
        let photo = setup.photos[0]
        photo.cullVersion = CullingAnalyzer.version - 1
        photo.cullSubjectFocus = 0.123
        try setup.store.viewContext.save()

        await analyze(setup, [photo])
        #expect(photo.cullVersion == CullingAnalyzer.version)
        #expect(photo.cullSubjectFocus != 0.123)
    }

    @Test func aMissingOriginalIsScoredFromItsThumbnailAndItsFocusMeasuredWhenItsBack() async throws {
        let setup = try makeSetup()
        let photo = setup.photos[0]
        let hidden = setup.directory.url.appending(path: "hidden.jpg")
        try FileManager.default.moveItem(at: photo.fileURL, to: hidden)

        await analyze(setup, [photo])
        #expect(photo.cullVersion == CullingAnalyzer.version)
        #expect(photo.cullFocusPending)
        #expect(photo.cullSubjectFocus == -1, "a thumbnail is too small to judge focus by")
        #expect(photo.cullQuality >= 0, "the rest is judged on the thumbnail")

        try FileManager.default.moveItem(at: hidden, to: photo.fileURL)
        // Opening the catalog again, once its files have been checked, measures the focus still to be measured.
        setup.store.availability.start()
        defer { setup.store.availability.stop() }
        await setup.store.availability.waitForRefresh()
        setup.analysis.start(after: .zero)
        defer { setup.analysis.stop() }
        await setup.analysis.waitUntilIdle()
        #expect(!photo.cullFocusPending)
        #expect(photo.cullSubjectFocus >= 0)
    }
}
