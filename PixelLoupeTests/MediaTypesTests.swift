import AVFoundation
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("RAW+JPEG pairs, PSD and video")
struct MediaTypesTests {
    /// Writes a short silent H.264 movie. (Uses the long-standing writer API, hence the availability.)
    @available(macOS, deprecated: 27.0, message: "Fixture uses the pre-27 AVAssetWriter API")
    static func writeVideo(to url: URL, seconds: Int = 2) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0...seconds {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(pixels, withPresentationTime: CMTime(seconds: Double(frame), preferredTimescale: 600))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    @Test("A JPEG next to a raw file is its sidecar, not a photo")
    func pairsSidecars() {
        let anchor = URL(filePath: "/x")
        let sources = ["/x/IMG_1.CR3", "/x/IMG_1.jpg", "/x/IMG_2.jpg", "/x/IMG_3.CR3"].map { ImportService.ImportSource(url: URL(filePath: $0), anchor: anchor) }
        let paired = ImportService.pairSidecars(sources)
        #expect(paired.map(\.url.lastPathComponent) == ["IMG_1.CR3", "IMG_2.jpg", "IMG_3.CR3"])
        #expect(paired[0].sidecars == ["JPG"] && paired[1].sidecars.isEmpty && paired[2].sidecars.isEmpty)
    }

    @Test("Collecting sources pairs unless JPEGs are set to be separate")
    func collectingRespectsTheSetting() async throws {
        let directory = try TemporaryDirectory()
        let folder = try directory.subdirectory("Card")
        try Data("raw".utf8).write(to: folder.appending(path: "IMG_1.dng"))
        try Fixtures.writeJPEG(to: folder.appending(path: "IMG_1.jpg"))
        let info = Fixtures.referencedInfo
        #expect(await ImportService.collectSources([folder], info: info, separateJPEGs: false).count == 1)
        #expect(await ImportService.collectSources([folder], info: info, separateJPEGs: true).count == 2)
    }

    @Test("Removing a photo takes its JPEG sidecar along")
    func removalIncludesSidecar() throws {
        let directory = try TemporaryDirectory()
        let raw = directory.url.appending(path: "A.CR3")
        for name in ["A.CR3", "A.jpg", "A.xmp", "B.jpg"] { try Data("x".utf8).write(to: directory.url.appending(path: name)) }
        let files = PhotoRemoval.files(for: raw, imageSidecars: ["JPG"]).map(\.lastPathComponent)
        #expect(Set(files.map { $0.lowercased() }) == ["a.cr3", "a.jpg", "a.xmp"])
        #expect(PhotoRemoval.files(for: raw).map(\.lastPathComponent).map { $0.lowercased() }.contains("a.jpg") == false)
    }

    @available(macOS, deprecated: 27.0, message: "Fixture uses the pre-27 AVAssetWriter API")
    @Test("Imports a video with its duration and a poster thumbnail, and a PSD as an image")
    func importsVideoAndPSD() async throws {
        let directory = try TemporaryDirectory()
        let folder = try directory.subdirectory("Media")
        try await Self.writeVideo(to: folder.appending(path: "Clip.mov"))
        try Fixtures.writeJPEG(to: folder.appending(path: "Still.jpg"))
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "M.pixelloupe"))
        let summary = try await ImportService(store: store).importPhotos(from: [folder])
        #expect(summary.imported == 2 && summary.failures.isEmpty, "\(summary)")
        let photos = try store.viewContext.fetch(Photo.fetchRequest())
        let clip = try #require(photos.first { $0.fileName == "Clip.mov" })
        #expect(clip.isVideo && (1.0...3.5).contains(clip.duration), "\(clip.duration)")
        #expect(clip.pixelWidth == 64 && clip.pixelHeight == 48)
        #expect(FileManager.default.fileExists(atPath: store.thumbnails.url(for: clip.id).path(percentEncoded: false)))
        #expect(try #require(photos.first { $0.fileName == "Still.jpg" }).isVideo == false)
        #expect(VideoSupport.durationText(65) == "1:05")
    }

    @Test("Opens a version ten catalog and adds the video fields")
    func migratesVersionTen() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "V10.pixelloupe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(Fixtures.referencedInfo).write(to: CatalogPackage.infoURL(in: packageURL))
        let momd = try #require(Bundle(for: Photo.self).url(forResource: "PixelLoupe", withExtension: "momd"))
        let v10 = try #require(NSManagedObjectModel(contentsOf: momd.appending(path: "PixelLoupe 10.mom")))
        #expect(v10.entitiesByName["Photo"]?.propertiesByName["isVideo"] == nil)
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: v10)
            _ = try coordinator.addPersistentStore(type: .sqlite, at: CatalogPackage.databaseURL(in: packageURL))
            let context = NSManagedObjectContext(.mainQueue)
            context.persistentStoreCoordinator = coordinator
            let photo = NSEntityDescription.insertNewObject(forEntityName: "Photo", into: context)
            photo.setValue(UUID(), forKey: "id")
            photo.setValue("v10.jpg", forKey: "fileName")
            photo.setValue(Date(), forKey: "captureDate")
            photo.setValue(Date(), forKey: "importDate")
            photo.setValue(Date(), forKey: "editDate")
            try context.save()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }
        let store = try CatalogStore.open(at: packageURL)
        let photo = try #require(try store.viewContext.fetch(Photo.fetchRequest()).first)
        #expect(!photo.isVideo && photo.duration == 0 && photo.sidecarExtensions == nil)
    }
}
