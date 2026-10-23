import AppKit
import CoreData
import ImageIO
import Testing
@testable import PixelLoupe

@Suite("Write Keywords as PixelLoupe Hierarchy")
@MainActor
struct KeywordHierarchyExportTests {
    /// The values of an XMP array in an exported file.
    private func xmpArray(_ url: URL, _ path: String) -> [String]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
              let values = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] else { return nil }
        return values.compactMap { CGImageMetadataTagCopyValue($0) as? String }.sorted()
    }

    @Test func pathsRunFromTheTopOfTheTree() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let context = store.viewContext
        func tag(_ name: String, under parent: PixelLoupe.Tag? = nil, exported: Bool = true) -> PixelLoupe.Tag {
            let tag = PixelLoupe.Tag(context: context)
            tag.name = name
            tag.parent = parent
            tag.includeOnExport = exported
            return tag
        }
        let places = tag("Places", exported: false)
        let ireland = tag("Ireland", under: places)
        let dublin = tag("Dublin", under: ireland)
        let secret = tag("Secret", exported: false)
        let boats = tag("Boats")
        #expect(PixelLoupe.Tag.exportPaths(for: [dublin, ireland, boats, secret]) == ["Boats", "Places|Ireland", "Places|Ireland|Dublin"])
    }

    @Test func theHierarchyIsWrittenOnlyWhenAskedAndReplacesTheOriginals() async throws {
        let directory = try TemporaryDirectory()
        let source = try Fixtures.writeJPEG(to: directory.url.appending(path: "IMG_0001.JPG"))
        // An original carrying a stale hierarchy (written by another app).
        let stale = directory.url.appending(path: "Stale.JPG")
        do {
            let image = try #require(CGImageSourceCreateWithURL(source as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            let metadata = CGImageMetadataCreateMutable()
            CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.adobe.com/lightroom/1.0/" as CFString, "lr" as CFString, nil)
            let tag = try #require(CGImageMetadataTagCreate("http://ns.adobe.com/lightroom/1.0/" as CFString, "lr" as CFString,
                                                            "hierarchicalSubject" as CFString, .arrayUnordered, ["Old|Path"] as CFArray))
            CGImageMetadataSetTagWithPath(metadata, nil, "lr:hierarchicalSubject" as CFString, tag)
            let destination = try #require(CGImageDestinationCreateWithURL(stale as CFURL, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        let item = ExportItem(source: stale, adjustments: PhotoAdjustments(), metadata: PhotoMetadata(), keywords: ["Dublin", "Ireland"],
                              keywordPaths: ["Places|Ireland", "Places|Ireland|Dublin"], rating: 0, captureDate: .now)
        var settings = ExportSettings()
        settings.format = .jpeg

        let off = directory.url.appending(path: "Off.jpg")
        try await PhotoExporter.export(item, to: off, settings: settings, watermark: nil)
        #expect(xmpArray(off, "dc:subject") == ["Dublin", "Ireland"])
        #expect(xmpArray(off, "lr:hierarchicalSubject") == nil, "the original's stale hierarchy isn't kept")

        settings.writesKeywordHierarchy = true
        let on = directory.url.appending(path: "On.jpg")
        try await PhotoExporter.export(item, to: on, settings: settings, watermark: nil)
        #expect(xmpArray(on, "lr:hierarchicalSubject") == ["Places|Ireland", "Places|Ireland|Dublin"])
        #expect(xmpArray(on, "dc:subject") == ["Dublin", "Ireland"], "the flat keywords are still written")
    }

    @Test func theOptionIsSavedAndDefaultsOff() throws {
        #expect(!ExportSettings().writesKeywordHierarchy)
        var settings = ExportSettings()
        settings.writesKeywordHierarchy = true
        #expect(try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(settings)).writesKeywordHierarchy)
        #expect(try !JSONDecoder().decode(ExportSettings.self, from: Data("{}".utf8)).writesKeywordHierarchy)
    }

    @Test func theCheckboxFollowsTheMetadataChoice() throws {
        let form = ExportSettingsForm(settings: ExportSettings(), watermarks: WatermarkPresets(directory: try TemporaryDirectory().url))
        _ = form.section(.metadata, stateKey: "KeywordHierarchyTests")
        #expect(form.keywordHierarchyCheckbox.isEnabled && form.keywordHierarchyCheckbox.title == "Write Keywords as PixelLoupe Hierarchy")
        form.keywordHierarchyCheckbox.performClick(nil)
        #expect(form.settings.writesKeywordHierarchy)
        form.metadataPopUp.selectItem(withTitle: "Copyright Only")
        form.metadataPopUp.sendAction(form.metadataPopUp.action, to: form.metadataPopUp.target)
        #expect(!form.keywordHierarchyCheckbox.isEnabled, "no keywords are written with Copyright Only")
    }

    @Test func flickrTagsAreThePathsWhenAsked() throws {
        let item = PublishItem(
            export: ExportItem(source: URL(filePath: "/IMG.jpg"), adjustments: PhotoAdjustments(), metadata: PhotoMetadata(),
                               keywords: ["Dublin"], keywordPaths: ["Places|Ireland|Dublin"], rating: 0, captureDate: .now),
            title: nil, remote: nil, hasEdits: true, index: 0, total: 1)
        let account = FlickrCredentials(userID: "1@N00", username: "u", fullName: "", token: "t", tokenSecret: "s")
        var settings = PublishSettings(.flickr)
        let flat = FlickrPublisher(api: FlickrAPI(credentials: account), settings: settings, watermark: nil)
        #expect(flat.uploadParameters(item)["tags"] == "Dublin")
        settings.export.writesKeywordHierarchy = true
        let hierarchical = FlickrPublisher(api: FlickrAPI(credentials: account), settings: settings, watermark: nil)
        #expect(hierarchical.uploadParameters(item)["tags"] == "Places|Ireland|Dublin")
    }
}
