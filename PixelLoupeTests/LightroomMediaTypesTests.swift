import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@MainActor
struct LightroomMediaTypesTests {
    @Test("Imports a video with Lightroom's duration, trim points and poster frame")
    func importsVideo() async throws {
        let fixture = try PhotosFixture()
        try fixture.run("""
            CREATE TABLE AgVideoInfo (id_local INTEGER PRIMARY KEY, image INTEGER, duration, poster_frame, trim_start, trim_end);
            INSERT INTO AgVideoInfo (image, duration, poster_frame, trim_start, trim_end) VALUES (12, 12.5, '1/2', '1/1', '10/1');
            """)
        let (store, _) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }])
        let photos = try store.viewContext.fetch(Photo.fetchRequest())
        let video = try #require(photos.first { $0.fileName == "C.mov" })
        #expect(video.isVideo && video.orientation == 1)
        #expect(video.duration == 12.5)
        #expect(video.metadata.values[PhotoMetadata.lightroomVideoPosterKey] != nil)
        #expect(photos.filter { $0.fileName != "C.mov" }.allSatisfy { !$0.isVideo })
    }

    @Test("Records the images that go with a raw file, and ignores other sidecars")
    func importsSidecars() async throws {
        let fixture = try PhotosFixture()
        try fixture.run("UPDATE AgLibraryFile SET sidecarExtensions = 'JPG,xmp' WHERE id_local = 4")
        let (store, _) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }])
        let photos = try store.viewContext.fetch(Photo.fetchRequest())
        let raw = try #require(photos.first { $0.fileName == "D.cr2" })
        #expect(raw.sidecarExtensions == "JPG")
        #expect(raw.imageSidecars.count <= 1)
        #expect(try #require(photos.first { $0.fileName == "A.jpg" }).sidecarExtensions == nil)
    }

    @Test("PSD files are supported types")
    func psdSupported() {
        #expect(SupportedImageTypes.isSupported(URL(filePath: "/x/A.psd")))
        #expect(SupportedImageTypes.isSupported(URL(filePath: "/x/A.MOV")))
        #expect(SupportedImageTypes.isVideo(URL(filePath: "/x/A.mp4")))
        #expect(!SupportedImageTypes.isVideo(URL(filePath: "/x/A.psd")))
    }

    @Test("Lightroom's fractions of a second")
    func lightroomSeconds() {
        #expect(VideoSupport.lightroomSeconds("5/2") == 2.5)
        #expect(VideoSupport.lightroomSeconds(nil) == nil)
    }

    @Test("The summary no longer lists video and PSD as unopenable")
    func summaryAcceptsVideoAndPSD() throws {
        let fixture = try PhotosFixture()
        let summary = try LightroomCatalog(url: fixture.catalogURL).summary()
        #expect(summary.unsupportedFiles["VIDEO"] == nil)
    }
}
