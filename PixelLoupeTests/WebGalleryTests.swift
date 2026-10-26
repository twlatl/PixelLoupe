import AppKit
import ImageIO
import Foundation
import Testing
import WebKit
@testable import PixelLoupe

@Suite("Web gallery pages")
struct WebGalleryPagesTests {
    @Test func photosFallIntoPagesOfTheChosenSize() {
        let pages = WebGalleryPages(photoCount: 100, photosPerPage: 48)
        #expect(pages.count == 3)
        #expect(pages.photos(onPage: 0) == 0..<48)
        #expect(pages.photos(onPage: 2) == 96..<100)
        #expect(pages.photos(onPage: 3).isEmpty)
        #expect(pages.summary == "48 photos per page · 3 pages")
        #expect(WebGalleryPages(photoCount: 0, photosPerPage: 48).count == 1, "a page even without photos")
        #expect(WebGalleryPages(photoCount: 24, photosPerPage: 24).summary == "24 photos per page · 1 page")
    }

    @Test func pageFilesAreIndexThenNumbered() {
        #expect(WebGalleryPages.fileName(ofPage: 0) == "index.html")
        #expect(WebGalleryPages.fileName(ofPage: 1) == "page-2.html")
        #expect(WebGalleryPages.fileName(ofPage: 11) == "page-12.html")
        for page in [0, 1, 11] { #expect(WebGalleryPages.page(named: WebGalleryPages.fileName(ofPage: page)) == page) }
        #expect(WebGalleryPages.page(named: "page-1.html") == nil, "the first page is index.html")
        #expect(WebGalleryPages.page(named: "page-x.html") == nil)
        #expect(WebGalleryPages.page(named: "gallery.css") == nil)
    }

    @Test func numberedLinksLeaveOutLongRuns() {
        #expect(WebGalleryPages(photoCount: 5 * 24, photosPerPage: 24).numberedLinks(around: 0) == [0, 1, 2, 3, 4])
        let pages = WebGalleryPages(photoCount: 20 * 24, photosPerPage: 24)
        #expect(pages.numberedLinks(around: 0) == [0, 1, 2, nil, 19])
        #expect(pages.numberedLinks(around: 9) == [0, nil, 7, 8, 9, 10, 11, nil, 19])
        #expect(pages.numberedLinks(around: 3) == [0, 1, 2, 3, 4, 5, nil, 19], "a gap of one page shows the page")
        #expect(pages.numberedLinks(around: 19) == [0, nil, 17, 18, 19])
    }

    @Test func imagesAreNumberedInOrder() {
        #expect(WebGalleryHTML.imageName(index: 0, count: 5) == "001.jpg")
        #expect(WebGalleryHTML.imageName(index: 41, count: 999) == "042.jpg")
        #expect(WebGalleryHTML.imageName(index: 41, count: 1000) == "0042.jpg", "wide enough for the last photo")
        #expect(WebGalleryHTML.index(ofImageNamed: "0042.jpg") == 41)
        #expect(WebGalleryHTML.index(ofImageNamed: "000.jpg") == nil)
        #expect(WebGalleryHTML.index(ofImageNamed: "IMG_1.jpg") == nil)
    }
}

@Suite("Web gallery HTML")
struct WebGalleryHTMLTests {
    private func photos(_ count: Int) -> [ContactSheetPhoto] {
        (0..<count).map { index in
            ContactSheetPhoto(source: PhotoSourceLocation(original: URL(filePath: "/missing/IMG_\(index).jpg")),
                              aspect: index.isMultiple(of: 2) ? 1.5 : 2.0 / 3, fileName: "IMG_\(index).jpg",
                              title: index == 1 ? "Dune <at> dusk" : nil)
        }
    }

    private func figures(in html: String) -> Int {
        html.components(separatedBy: "<figure ").count - 1
    }

    @Test func eachPageHoldsItsPhotos() {
        var settings = WebGallerySettings()
        settings.photosPerPage = 24
        let photos = photos(30)
        let first = WebGalleryHTML.page(0, photos: photos, settings: settings, sourceName: "Dunes")
        let second = WebGalleryHTML.page(1, photos: photos, settings: settings, sourceName: "Dunes")
        #expect(figures(in: first) == 24)
        #expect(figures(in: second) == 6)
        #expect(first.contains("src=\"images/thumbs/001.jpg\""))
        #expect(second.contains("<figure id=\"25\">"), "numbered across the gallery, for linking")
        #expect(second.contains("src=\"images/thumbs/030.jpg\""))
        #expect(first.contains("<title>Dunes (1 of 2)</title>"), "the source names it without a headline")
        #expect(first.contains("<link rel=\"stylesheet\" href=\"gallery.css\">"))
        #expect(!first.contains("IMG_0"), "file names aren't published unless they're the caption")
    }

    @Test func photosKeepTheirShapeAndPortraitsFitTheHeight() {
        let html = WebGalleryHTML.page(0, photos: photos(2), settings: WebGallerySettings(), sourceName: "")
        #expect(html.contains("class=\"landscape\" src=\"images/thumbs/001.jpg\" width=\"800\" height=\"533\""))
        #expect(html.contains("class=\"portrait\" src=\"images/thumbs/002.jpg\" width=\"533\" height=\"800\""))
        #expect(html.contains("alt=\"Dune &lt;at&gt; dusk\""), "the title, escaped, as alt text")
        #expect(html.contains("alt=\"Photo 1\""), "numbered without a title or caption")
        #expect(html.contains("loading=\"lazy\""))
    }

    @Test func theHeaderIsEscapedAndLeftOutWhenEmpty() {
        var settings = WebGallerySettings()
        let empty = WebGalleryHTML.page(0, photos: photos(1), settings: settings, sourceName: "All Photographs")
        #expect(!empty.contains("<header>"))
        #expect(empty.contains("<title>All Photographs</title>"))

        settings.headline = "  Smith & Jones <Proofs>  "
        settings.description = "Day one\n\"Dunes\""
        let html = WebGalleryHTML.page(0, photos: photos(1), settings: settings, sourceName: "All Photographs")
        #expect(html.contains("<h1>Smith &amp; Jones &lt;Proofs&gt;</h1>"))
        #expect(html.contains("<p class=\"description\">Day one\n&quot;Dunes&quot;</p>"))
        #expect(html.contains("<title>Smith &amp; Jones &lt;Proofs&gt;</title>"))
    }

    @Test func captionsShowTheChosenFieldAndKeepTheirLine() {
        var settings = WebGallerySettings()
        let none = WebGalleryHTML.page(0, photos: photos(2), settings: settings, sourceName: "")
        #expect(!none.contains("<figcaption>"))

        settings.showsCaption = true
        settings.captionField = .title
        let html = WebGalleryHTML.page(0, photos: photos(2), settings: settings, sourceName: "")
        #expect(html.contains("<figcaption>&nbsp;</figcaption>"), "a photo without a title keeps the row even")
        #expect(html.contains("<figcaption>Dune &lt;at&gt; dusk</figcaption>"))
    }

    @Test func navigationLinksThePages() {
        var settings = WebGallerySettings()
        settings.photosPerPage = 24
        let single = WebGalleryHTML.page(0, photos: photos(24), settings: settings, sourceName: "")
        #expect(!single.contains("<nav"), "one page needs no navigation")

        let photos = photos(60)
        let first = WebGalleryHTML.page(0, photos: photos, settings: settings, sourceName: "")
        #expect(first.contains("<span class=\"disabled\">‹ Previous</span>"))
        #expect(first.contains("<span aria-current=\"page\">1</span>"))
        #expect(first.contains("<a href=\"page-3.html\">3</a>"))
        #expect(first.contains("<a rel=\"next\" href=\"page-2.html\">Next ›</a>"))

        let middle = WebGalleryHTML.page(1, photos: photos, settings: settings, sourceName: "")
        #expect(middle.contains("<a rel=\"prev\" href=\"index.html\">‹ Previous</a>"))
        #expect(middle.contains("<a href=\"index.html\">1</a>"))
        #expect(middle.contains("<a rel=\"next\" href=\"page-3.html\">Next ›</a>"))

        settings.showsPageNumbers = false
        let last = WebGalleryHTML.page(2, photos: photos, settings: settings, sourceName: "")
        #expect(last.contains("<a rel=\"prev\" href=\"page-2.html\">‹ Previous</a>"))
        #expect(last.contains("<span class=\"disabled\">Next ›</span>"))
        #expect(!last.contains("aria-current"), "Page Numbers off: only Previous and Next")
    }

    @Test func theStylesheetFollowsTheSettings() {
        var settings = WebGallerySettings()
        settings.columns = 6
        settings.textColor = .init(red: 1, green: 0.5, blue: 0)
        settings.backgroundColor = .init(red: 0, green: 0, blue: 0)
        let css = WebGalleryHTML.stylesheet(settings: settings)
        #expect(css.contains("--columns: 6;"))
        #expect(css.contains("@media (max-width: 700px) { :root { --columns: 2; } }"))
        #expect(css.contains("@media (max-width: 400px) { :root { --columns: 1; } }"))
        #expect(css.contains("--text: #ff8000;"))
        #expect(css.contains("--background: #000000;"))

        settings.columns = 1
        #expect(WebGalleryHTML.stylesheet(settings: settings).contains("@media (max-width: 700px) { :root { --columns: 1; } }"))
    }

    @Test func eachPhotoLinksToItsLargeImageAndThePageLoadsTheLightbox() {
        let html = WebGalleryHTML.page(0, photos: photos(2), settings: WebGallerySettings(), sourceName: "")
        #expect(html.contains("<a href=\"images/large/002.jpg\" data-photo=\"1\"><img class=\"portrait\" src=\"images/thumbs/002.jpg\""),
                "a plain link, so it works without JavaScript")
        #expect(html.contains("<script src=\"photos.js\"></script>\n<script src=\"gallery.js\"></script>\n</body>"))
    }

    private struct ScriptPhoto: Decodable, Equatable {
        let large: String, alt: String, caption: String, page: String
    }

    private func decode(_ script: String) throws -> [ScriptPhoto] {
        let prefix = "window.galleryPhotos = "
        #expect(script.hasPrefix(prefix))
        #expect(script.hasSuffix(";\n"))
        let json = script.dropFirst(prefix.count).dropLast(2)
        return try JSONDecoder().decode([ScriptPhoto].self, from: Data(json.utf8))
    }

    @Test func thePhotosScriptListsTheWholeGallery() throws {
        var settings = WebGallerySettings()
        settings.photosPerPage = 24
        let all = try decode(WebGalleryHTML.photosScript(photos: photos(30), settings: settings))
        #expect(all.count == 30)
        #expect(all[0] == ScriptPhoto(large: "images/large/001.jpg", alt: "Photo 1", caption: "", page: "index.html"))
        #expect(all[1].alt == "Dune <at> dusk", "JSON, not HTML: the script sets it as text")
        #expect(all[24].page == "page-2.html")
        #expect(all.allSatisfy { $0.caption.isEmpty }, "no captions unless they show")

        settings.showsCaption = true
        let captioned = try decode(WebGalleryHTML.photosScript(photos: photos(2), settings: settings))
        #expect(captioned.map(\.caption) == ["IMG_0.jpg", "IMG_1.jpg"])
        #expect(WebGalleryHTML.photosScript(photos: [], settings: settings) == "window.galleryPhotos = [];\n")
    }

    @Test func theScriptStandsAlone() {
        // No libraries or network: it has to work offline and from file://.
        #expect(!WebGalleryHTML.script.contains("http"))
        #expect(!WebGalleryHTML.script.contains("fetch("))
        #expect(!WebGalleryHTML.script.contains("import "))
    }

    @Test func theEmailIsALinkHiddenFromHarvesters() {
        #expect(WebGalleryHTML.entities("a@b") == "&#97;&#64;&#98;")
        #expect(WebGalleryHTML.entities("é") == "&#233;")

        var settings = WebGallerySettings()
        settings.email = "  ted@example.com \n"
        let html = WebGalleryHTML.page(0, photos: photos(1), settings: settings, sourceName: "")
        #expect(!html.contains("@"), "no address in plain text")
        #expect(!html.contains("mailto"))
        let link = WebGalleryHTML.emailLink("ted@example.com")
        #expect(html.contains("<header>\n<p class=\"email\">\(link)</p>\n</header>"), "trimmed; a header of its own without a headline")
        #expect(link.hasPrefix("<a href=\"\(WebGalleryHTML.entities("mailto:ted@example.com"))\">"))

        // A browser reads it back as the address.
        let parsed = NSAttributedString(html: Data(link.utf8), documentAttributes: nil)
        #expect(parsed?.string == "ted@example.com")
        #expect(parsed?.attribute(.link, at: 0, effectiveRange: nil) as? URL == URL(string: "mailto:ted@example.com"))

        settings.email = "   "
        #expect(!WebGalleryHTML.page(0, photos: photos(1), settings: settings, sourceName: "").contains("<header>"))
    }

    @Test func headAndBodyGoInAsTypedAtTheEnds() {
        var settings = WebGallerySettings()
        settings.headHTML = "<script async src=\"https://example.com/a.js\"></script>"
        settings.bodyHTML = "<footer>© 2026 & <b>me</b></footer>\n"
        let html = WebGalleryHTML.page(0, photos: photos(1), settings: settings, sourceName: "")
        #expect(html.contains("<link rel=\"stylesheet\" href=\"gallery.css\">\n<script async src=\"https://example.com/a.js\"></script>\n</head>"))
        #expect(html.contains("<script src=\"gallery.js\"></script>\n<footer>© 2026 & <b>me</b></footer>\n</body>"),
                "after the gallery's own scripts, not escaped")

        let preview = WebGalleryHTML.page(0, photos: photos(1), settings: settings, sourceName: "", includesCustomCode: false)
        #expect(!preview.contains("example.com"))
        #expect(!preview.contains("<footer>"))
        #expect(preview.contains("gallery.css\">\n</head>\n<body>"))

        settings.headHTML = "  \n "
        settings.bodyHTML = ""
        #expect(WebGalleryHTML.page(0, photos: photos(1), settings: settings, sourceName: "").contains("gallery.css\">\n</head>\n<body>"))
    }

    @Test func borderAndShadowAreClassesOnTheGrid() {
        var settings = WebGallerySettings()
        #expect(WebGalleryHTML.page(0, photos: photos(1), settings: settings, sourceName: "").contains("<main class=\"grid\">"))
        settings.showsBorder = true
        settings.showsShadow = true
        #expect(WebGalleryHTML.page(0, photos: photos(1), settings: settings, sourceName: "").contains("<main class=\"grid border shadow\">"))
        #expect(WebGalleryHTML.stylesheet(settings: settings).contains(".border .cell img { padding: 3%; background: #fff; }"))
    }
}

@Suite("Web gallery settings")
struct WebGallerySettingsTests {
    @Test func layoutChoicesAreRememberedButNotTheText() throws {
        let suite = "WebGallerySettingsTests.remember"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = WebGallerySettings()
        settings.headline = "Proofs"
        settings.description = "Day one"
        settings.textColor = .init(red: 0.2, green: 0.3, blue: 0.4)
        settings.backgroundColor = .init(red: 0, green: 0, blue: 0)
        settings.columns = 7
        settings.showsBorder = true
        settings.showsShadow = true
        settings.showsCaption = true
        settings.captionField = .exposure
        settings.showsPageNumbers = false
        settings.photosPerPage = 192
        settings.email = "ted@example.com"
        settings.headHTML = "<meta name=\"robots\" content=\"noindex\">"
        settings.bodyHTML = "<footer>Hi</footer>"
        settings.remember(in: defaults)

        var expected = settings
        expected.headline = ""
        expected.description = ""
        #expect(WebGallerySettings.remembered(in: defaults) == expected)
        #expect(ContactSheetSettings.remembered(in: defaults) == ContactSheetSettings(), "kept apart from contact sheets")
    }

    @Test func unknownOrMissingValuesKeepTheirDefaults() throws {
        let data = Data(#"{"columns": 40, "photosPerPage": 50, "captionField": "shoeSize", "showsBorder": true}"#.utf8)
        let settings = try JSONDecoder().decode(WebGallerySettings.self, from: data)
        #expect(settings.columns == WebGallerySettings.columnRange.upperBound)
        #expect(settings.photosPerPage == 48, "only the offered choices")
        #expect(settings.captionField == .fileName)
        #expect(settings.showsBorder)
        #expect(settings.showsPageNumbers)
        #expect(settings.jpegQuality == 85)
        #expect(settings.watermarkName == nil)
    }

    @Test func qualityStaysInRangeOnItsSteps() throws {
        #expect(WebGallerySettings.clampedQuality(83) == 85)
        #expect(WebGallerySettings.clampedQuality(0) == 10)
        #expect(WebGallerySettings.clampedQuality(140) == 100)
        let data = Data(#"{"jpegQuality": 3, "watermarkName": "Mine"}"#.utf8)
        let settings = try JSONDecoder().decode(WebGallerySettings.self, from: data)
        #expect(settings.jpegQuality == 10)
        #expect(settings.watermarkName == "Mine")
    }

    @Test func outputChoicesAreRemembered() throws {
        let suite = "WebGallerySettingsTests.output"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = WebGallerySettings()
        settings.jpegQuality = 60
        settings.watermarkName = WatermarkPresets.simpleCopyrightName
        settings.remember(in: defaults)
        let remembered = WebGallerySettings.remembered(in: defaults)
        #expect(remembered.jpegQuality == 60)
        #expect(remembered.watermarkName == WatermarkPresets.simpleCopyrightName)
    }
}

/// Progress reported on the main actor.
@MainActor private final class Reported {
    var values: [Double] = []
}

@Suite("Web gallery generate")
struct WebGalleryWriterTests {
    private func photo(_ file: URL, creator: String? = nil) -> WebGalleryWriter.Photo {
        let snapshot = ContactSheetPhoto(source: PhotoSourceLocation(original: file), fileName: file.lastPathComponent)
        var metadata = PhotoMetadata()
        metadata[.creator] = creator
        metadata[.creatorEmail] = creator.map { "\($0.lowercased())@example.com" }
        let item = ExportItem(source: file, adjustments: PhotoAdjustments(), metadata: metadata, keywords: [], rating: 0,
                              captureDate: .now)
        return WebGalleryWriter.Photo(photo: snapshot, item: item)
    }

    private func size(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    @Test func listsEveryFileItWrites() {
        #expect(WebGalleryWriter.files(count: 2, pages: 1) == [
            "index.html", "gallery.css", "photos.js", "gallery.js",
            "images/thumbs/001.jpg", "images/large/001.jpg", "images/thumbs/002.jpg", "images/large/002.jpg",
        ])
    }

    @Test func writesThePagesAndBothSizesOfEachPhoto() async throws {
        let directory = try TemporaryDirectory()
        let wide = try Fixtures.writeJPEG(to: directory.url.appending(path: "Wide.jpg"), width: 3000, height: 2000,
                                          gps: (latitude: 53.35, longitude: -6.26, altitude: nil))
        let small = try Fixtures.writeJPEG(to: directory.url.appending(path: "Small.jpg"), width: 600, height: 900)
        let folder = directory.url.appending(path: "Gallery")
        var settings = WebGallerySettings()
        settings.photosPerPage = 24
        let reported = Reported()
        let result = try await WebGalleryWriter.write([photo(wide, creator: "Ted"), photo(small)], settings: settings,
                                                      sourceName: "Dunes", watermark: nil, to: folder) { reported.values.append($0) }
        #expect(result.failures.isEmpty)
        #expect(reported.values.last == 1)
        for file in WebGalleryWriter.files(count: 2, pages: 1) {
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: file).path(percentEncoded: false)), "\(file)")
        }
        #expect(size(of: folder.appending(path: "images/large/001.jpg")) == CGSize(width: 2048, height: 1365))
        #expect(size(of: folder.appending(path: "images/thumbs/001.jpg")) == CGSize(width: 800, height: 533))
        #expect(size(of: folder.appending(path: "images/large/002.jpg")) == CGSize(width: 600, height: 900), "never enlarged")
        #expect(size(of: folder.appending(path: "images/thumbs/002.jpg")) == CGSize(width: 533, height: 800))

        // sRGB, with the creator but without the location, camera or contact details.
        let source = try #require(CGImageSourceCreateWithURL(folder.appending(path: "images/large/001.jpg") as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyProfileName] as? String)?.contains("sRGB") == true)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] == nil)
        let metadata = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        #expect(CGImageMetadataCopyTagWithPath(metadata, nil, "dc:creator" as CFString) != nil)
        #expect(CGImageMetadataCopyTagWithPath(metadata, nil, "Iptc4xmpCore:CreatorContactInfo" as CFString) == nil)

        let index = try String(contentsOf: folder.appending(path: "index.html"), encoding: .utf8)
        #expect(index.contains("<title>Dunes</title>"))
    }

    @Test func theWatermarkGoesOnTheLargeImagesOnly() async throws {
        let directory = try TemporaryDirectory()
        let file = try Fixtures.writeJPEG(to: directory.url.appending(path: "IMG_1.jpg"), width: 2400, height: 1600)
        let plain = directory.url.appending(path: "Plain"), marked = directory.url.appending(path: "Marked")
        _ = try await WebGalleryWriter.write([photo(file)], settings: WebGallerySettings(), sourceName: "", watermark: nil, to: plain) { _ in }
        var watermark = WatermarkSettings()
        watermark.text = "© Test"
        _ = try await WebGalleryWriter.write([photo(file)], settings: WebGallerySettings(), sourceName: "",
                                             watermark: PhotoExporter.Watermark(settings: watermark, imageURL: nil), to: marked) { _ in }
        func data(_ folder: URL, _ path: String) throws -> Data { try Data(contentsOf: folder.appending(path: path)) }
        #expect(try data(plain, "images/thumbs/001.jpg") == data(marked, "images/thumbs/001.jpg"))
        #expect(try data(plain, "images/large/001.jpg") != data(marked, "images/large/001.jpg"))
    }

    @Test func lowerQualityMeansSmallerFiles() async throws {
        let directory = try TemporaryDirectory()
        let file = try Fixtures.writeJPEG(to: directory.url.appending(path: "IMG_1.jpg"), width: 2400, height: 1600)
        var settings = WebGallerySettings()
        var sizes: [Int] = []
        for quality in [100.0, 20.0] {
            settings.jpegQuality = quality
            let folder = directory.url.appending(path: "Q\(Int(quality))")
            _ = try await WebGalleryWriter.write([photo(file)], settings: settings, sourceName: "", watermark: nil, to: folder) { _ in }
            sizes.append(try Data(contentsOf: folder.appending(path: "images/large/001.jpg")).count)
        }
        #expect(sizes[1] < sizes[0])
    }

    @Test func anUnreadablePhotoFallsBackToItsThumbnailOrIsReported() async throws {
        let directory = try TemporaryDirectory()
        let thumbnail = try Fixtures.writeJPEG(to: directory.url.appending(path: "thumb.jpg"), width: 300, height: 200)
        let missing = ContactSheetPhoto(source: PhotoSourceLocation(original: URL(filePath: "/missing/IMG_1.jpg")), fileName: "IMG_1.jpg")
        let gone = ContactSheetPhoto(source: PhotoSourceLocation(original: URL(filePath: "/missing/IMG_2.jpg")), fileName: "IMG_2.jpg")
        let folder = directory.url.appending(path: "Gallery")
        let result = try await WebGalleryWriter.write(
            [WebGalleryWriter.Photo(photo: missing, fallback: thumbnail), WebGalleryWriter.Photo(photo: gone)],
            settings: WebGallerySettings(), sourceName: "", watermark: nil, to: folder
        ) { _ in }
        #expect(result.failures == ["IMG_2.jpg"])
        #expect(try Data(contentsOf: folder.appending(path: "images/large/001.jpg")) == Data(contentsOf: thumbnail))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "images/large/002.jpg").path(percentEncoded: false)))
    }

    @Test func cancelling() async throws {
        let directory = try TemporaryDirectory()
        let file = try Fixtures.writeJPEG(to: directory.url.appending(path: "IMG_1.jpg"), width: 2400, height: 1600)
        let folder = directory.url.appending(path: "Gallery")
        let photos = Array(repeating: photo(file), count: 200)
        let task = Task {
            try await WebGalleryWriter.write(photos, settings: WebGallerySettings(), sourceName: "", watermark: nil, to: folder) { _ in }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func installingReplacesOnlyTheGallerysFiles() async throws {
        let directory = try TemporaryDirectory()
        let fileManager = FileManager.default
        let folder = directory.url.appending(path: "Site")
        // An earlier, larger gallery, and a file of the user's.
        try fileManager.createDirectory(at: folder.appending(path: "images/large"), withIntermediateDirectories: true)
        for (path, text) in [("index.html", "old"), ("page-5.html", "old"), ("notes.txt", "mine"), ("images/large/099.jpg", "old"),
                             ("images/large/cover.png", "mine")] {
            try Data(text.utf8).write(to: folder.appending(path: path))
        }
        let file = try Fixtures.writeJPEG(to: directory.url.appending(path: "IMG_1.jpg"), width: 300, height: 200)
        let temporary = directory.url.appending(path: "Temporary")
        _ = try await WebGalleryWriter.write([photo(file)], settings: WebGallerySettings(), sourceName: "", watermark: nil, to: temporary) { _ in }
        try await WebGalleryWriter.install(from: temporary, into: folder)

        func exists(_ path: String) -> Bool { fileManager.fileExists(atPath: folder.appending(path: path).path(percentEncoded: false)) }
        for path in WebGalleryWriter.files(count: 1, pages: 1) { #expect(exists(path), "\(path)") }
        #expect(try String(contentsOf: folder.appending(path: "index.html"), encoding: .utf8) != "old")
        #expect(!exists("page-5.html"), "the earlier gallery's extra page")
        #expect(!exists("images/large/099.jpg"), "the earlier gallery's extra image")
        #expect(exists("notes.txt"))
        #expect(exists("images/large/cover.png"))
    }
}

@Suite("Web gallery window") @MainActor
struct WebGalleryWindowTests {
    @Test func theWindowMenuOpensAGalleryOfTheSelectedPhotos() throws {
        let (store, ids, directory) = try makeSurveyStore(4)
        _ = directory
        let controller = CatalogWindowController(store: store)
        controller.showWindow(nil)
        defer { controller.close() }
        controller.state.photoOrder = ids
        controller.state.selectedPhotoIDs = [ids[2], ids[0]]

        let item = NSMenuItem(title: "Web Gallery", action: #selector(CatalogWindowController.showWebGallery(_:)), keyEquivalent: "")
        #expect(controller.validateUserInterfaceItem(item))
        controller.showWebGallery(nil)
        let gallery = try #require(controller.webGalleryControllers.first)
        #expect(gallery.photos.map(\.fileName) == ["IMG_0.jpg", "IMG_2.jpg"], "the selected photos in grid order")
        #expect(gallery.window?.isVisible == true)
        #expect(gallery.window?.subtitle == "2 photos · All Photographs")

        controller.showWebGallery(nil)
        #expect(controller.webGalleryControllers.count == 2)
        controller.webGalleryControllers[1].close()
        #expect(controller.webGalleryControllers.count == 1, "forgotten once closed")
        controller.close()
        #expect(gallery.window?.isVisible == false, "closing the catalog closes its galleries")
        #expect(controller.webGalleryControllers.isEmpty)
    }

    @Test func disabledWithNothingToShow() throws {
        let (store, ids, directory) = try makeSurveyStore(2)
        _ = directory
        let controller = CatalogWindowController(store: store)
        let item = NSMenuItem(title: "Web Gallery", action: #selector(CatalogWindowController.showWebGallery(_:)), keyEquivalent: "")
        controller.state.photoOrder = []
        #expect(!controller.validateUserInterfaceItem(item), "an empty grid")

        for id in ids { try #require(try store.viewContext.existingObject(with: id) as? Photo).isVideo = true }
        controller.state.photoOrder = ids
        #expect(!controller.validateUserInterfaceItem(item), "only videos")
    }

    @Test func theMenuItemIsControlOptionCommandW() throws {
        let menu = MainMenu.make()
        let window = try #require(menu.items.first { $0.title == "Window" }?.submenu)
        let item = try #require(window.items.first { $0.action == #selector(PixelLoupeActions.showWebGallery(_:)) })
        #expect(item.title == "Web Gallery")
        #expect(item.keyEquivalent == "w")
        #expect(item.keyEquivalentModifierMask == [.control, .option, .command])
    }

    /// Waits for the preview to finish loading, then runs `script` in it.
    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        let deadline = Date.now.addingTimeInterval(10)
        repeat { try await Task.sleep(for: .milliseconds(50)) } while webView.isLoading && Date.now < deadline
        return try await webView.evaluateJavaScript(script)
    }

    @Test func generateWritesTheFolderInTheBackground() async throws {
        let suite = "WebGalleryWindowTests.generate"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let file = try Fixtures.writeJPEG(to: directory.url.appending(path: "IMG_1.jpg"), width: 300, height: 200)
        let photo = ContactSheetPhoto(source: PhotoSourceLocation(original: file), fileName: "IMG_1.jpg")
        let controller = WebGalleryWindowController(photos: [photo], thumbnails: store.thumbnails, sourceName: "Dunes", defaults: defaults)
        let folder = directory.url.appending(path: "Site")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        controller.write(to: folder)
        #expect(controller.model.progress != nil)
        await controller.generateTask?.value
        #expect(controller.model.progress == nil)
        #expect(controller.generateTask == nil)
        for path in WebGalleryWriter.files(count: 1, pages: 1) {
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: path).path(percentEncoded: false)), "\(path)")
        }
    }

    @Test func typingInHeadAndBodyReachesTheGeneratedPages() async throws {
        let suite = "WebGalleryWindowTests.code"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let file = try Fixtures.writeJPEG(to: directory.url.appending(path: "IMG_1.jpg"), width: 300, height: 200)
        let photo = ContactSheetPhoto(source: PhotoSourceLocation(original: file), fileName: "IMG_1.jpg")
        let controller = WebGalleryWindowController(photos: [photo], thumbnails: store.thumbnails, sourceName: "", defaults: defaults)
        controller.showWindow(nil)
        defer { controller.close() }
        controller.window?.layoutIfNeeded()

        func textViews(in view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews(in:))
        }
        let editors = textViews(in: try #require(controller.window?.contentView)).filter { !$0.isFieldEditor }
        let head = try #require(editors.first { $0.accessibilityLabel() == "Head" })
        let body = try #require(editors.first { $0.accessibilityLabel() == "Body" })
        controller.window?.makeFirstResponder(head)
        head.insertText("<meta name=\"robots\" content=\"noindex\">", replacementRange: NSRange(location: 0, length: 0))
        controller.window?.makeFirstResponder(body)
        body.insertText("<footer>Hi</footer>", replacementRange: NSRange(location: 0, length: 0))
        #expect(controller.model.settings.headHTML == "<meta name=\"robots\" content=\"noindex\">")
        #expect(controller.model.settings.bodyHTML == "<footer>Hi</footer>")

        let folder = directory.url.appending(path: "Site")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        controller.write(to: folder)
        await controller.generateTask?.value
        let index = try String(contentsOf: folder.appending(path: "index.html"), encoding: .utf8)
        #expect(index.contains("<meta name=\"robots\" content=\"noindex\">\n</head>"))
        #expect(index.contains("<footer>Hi</footer>\n</body>"))
    }

    @Test func typingTheHeadlineUpdatesTheHeaderWithoutReloading() async throws {
        let suite = "WebGalleryWindowTests.header"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url)
        let photos = (0..<30).map {
            ContactSheetPhoto(source: PhotoSourceLocation(original: URL(filePath: "/missing/IMG_\($0).jpg")), fileName: "IMG_\($0).jpg")
        }
        let controller = WebGalleryWindowController(photos: photos, thumbnails: store.thumbnails, sourceName: "Dunes", defaults: defaults)
        controller.model.settings.photosPerPage = 24
        controller.showWindow(nil)
        defer { controller.close() }
        let webView = controller.webView
        _ = try await evaluate("window.marker = 1", in: webView)
        let header = "(document.querySelector('body > header') || {}).innerHTML + ' | ' + document.title + ' | ' + window.marker"

        controller.model.settings.headline = "Pro"
        controller.model.settings.headline = "Proofs <1>"
        #expect(try await waitFor(header, toBe: "\n<h1>Proofs &lt;1&gt;</h1>\n | Proofs <1> (1 of 2) | 1", in: webView))

        controller.model.settings.description = "Day one"
        controller.model.settings.email = "ted@example.com"
        #expect(try await waitFor("document.querySelector('header .email a').href + ' ' + document.querySelector('header .description').textContent + ' ' + window.marker",
                                  toBe: "mailto:ted@example.com Day one 1", in: webView))

        controller.model.settings.headline = ""
        controller.model.settings.description = ""
        controller.model.settings.email = ""
        #expect(try await waitFor("(document.querySelector('header') === null) + ' ' + document.title + ' ' + window.marker",
                                  toBe: "true Dunes (1 of 2) 1", in: webView), "no header left, and still not reloaded")

        // Pages served later have it too.
        controller.model.settings.headline = "Later"
        webView.load(URLRequest(url: WebGalleryPreviewSource.url(ofPage: 1)))
        #expect(try await waitFor("document.querySelector('h1').textContent + ' ' + document.title", toBe: "Later Later (2 of 2)", in: webView))
    }

    @Test func outputSettingsDontReloadThePreview() async throws {
        let suite = "WebGalleryWindowTests.output"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url)
        let photo = ContactSheetPhoto(source: PhotoSourceLocation(original: URL(filePath: "/missing/IMG_1.jpg")), fileName: "IMG_1.jpg")
        let controller = WebGalleryWindowController(photos: [photo], thumbnails: store.thumbnails, sourceName: "", defaults: defaults)
        controller.showWindow(nil)
        defer { controller.close() }
        _ = try await evaluate("window.marker = 1", in: controller.webView)
        controller.model.jpegQuality = 40
        controller.model.settings.headHTML = "<script>window.ran = 1</script>"
        controller.model.settings.bodyHTML = "<p id=body>Hi</p>"
        #expect(try await evaluate("window.marker", in: controller.webView) as? Int == 1, "not reloaded")
        controller.model.settings.showsBorder = true
        var reloaded = false
        for _ in 0..<100 where !reloaded {
            reloaded = try await evaluate("typeof window.marker", in: controller.webView) as? String == "undefined"
        }
        #expect(reloaded)
        #expect(try await evaluate("typeof window.ran + ' ' + (document.getElementById('body') === null)", in: controller.webView) as? String
                == "undefined true", "Head and Body stay out of the preview")
    }

    /// Polls `script` in the preview until it returns `expected` (pages load and scripts run after a moment).
    private func waitFor(_ script: String, toBe expected: String, in webView: WKWebView) async throws -> Bool {
        for _ in 0..<100 {
            if (try? await evaluate(script, in: webView)).map({ "\($0)" }) == expected { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test func theLightboxStepsThroughTheWholeGallery() async throws {
        let suite = "WebGalleryWindowTests.lightbox"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url)
        let photos = (0..<30).map {
            ContactSheetPhoto(source: PhotoSourceLocation(original: URL(filePath: "/missing/IMG_\($0).jpg")), fileName: "IMG_\($0).jpg")
        }
        let controller = WebGalleryWindowController(photos: photos, thumbnails: store.thumbnails, sourceName: "", defaults: defaults)
        controller.model.settings.photosPerPage = 24
        controller.showWindow(nil)
        defer { controller.close() }
        let webView = controller.webView
        let state = "[document.querySelector('.lightbox') ? !document.querySelector('.lightbox').hidden : false, location.hash].join(' ')"
        #expect(try await waitFor("typeof window.galleryPhotos", toBe: "object", in: webView))

        // A click opens it on that photo.
        _ = try await evaluate("document.querySelector('a[data-photo=\"2\"]').click()", in: webView)
        #expect(try await waitFor(state, toBe: "true #3", in: webView))
        #expect(try await evaluate("document.querySelector('.lightbox img').getAttribute('src')", in: webView) as? String
                == "images/large/003.jpg")
        #expect(try await evaluate("document.querySelector('.lightbox .previous').hidden", in: webView) as? Bool == false)

        // → steps on, past the end of the page.
        _ = try await evaluate("location.hash = '#24'", in: webView)
        #expect(try await waitFor(state, toBe: "true #24", in: webView))
        _ = try await evaluate("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight' }))", in: webView)
        #expect(try await waitFor(state, toBe: "true #25", in: webView))
        #expect(controller.currentPage == 0)

        // Esc on another page's photo goes to that page, without opening it again there.
        _ = try await evaluate("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))", in: webView)
        #expect(try await waitFor("location.pathname + location.hash", toBe: "/page-2.html#25", in: webView))
        #expect(try await waitFor("typeof window.galleryPhotos", toBe: "object", in: webView))
        #expect(try await waitFor("document.querySelector('.lightbox') === null", toBe: "1", in: webView))

        // A link to a photo opens it; the last photo has no Next.
        webView.load(URLRequest(url: try #require(URL(string: "#30", relativeTo: WebGalleryPreviewSource.url(ofPage: 1)))))
        #expect(try await waitFor(state, toBe: "true #30", in: webView))
        #expect(try await evaluate("document.querySelector('.lightbox .next').hidden", in: webView) as? Bool == true)
        _ = try await evaluate("document.querySelector('.lightbox .close').click()", in: webView)
        #expect(try await waitFor(state, toBe: "false ", in: webView))
    }

    @Test func thePreviewShowsTheGalleryAndFollowsTheSettings() async throws {
        let suite = "WebGalleryWindowTests.preview"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url)
        let photos = (0..<100).map {
            ContactSheetPhoto(source: PhotoSourceLocation(original: URL(filePath: "/missing/IMG_\($0).jpg")), fileName: "IMG_\($0).jpg")
        }
        let controller = WebGalleryWindowController(photos: photos, thumbnails: store.thumbnails, sourceName: "Dunes", defaults: defaults)
        controller.showWindow(nil)
        defer { controller.close() }

        let webView = controller.webView
        #expect(try await evaluate("document.querySelectorAll('figure').length", in: webView) as? Int == 48)
        #expect(try await evaluate("document.title", in: webView) as? String == "Dunes (1 of 3)")
        #expect(controller.currentPage == 0)

        // Its page links work.
        webView.load(URLRequest(url: WebGalleryPreviewSource.url(ofPage: 2)))
        #expect(try await evaluate("document.querySelectorAll('figure').length", in: webView) as? Int == 4)
        #expect(controller.currentPage == 2)

        // A change reloads the page being viewed.
        controller.model.settings.headline = "Proofs"
        #expect(try await evaluate("document.querySelector('h1').textContent", in: webView) as? String == "Proofs")
        #expect(controller.currentPage == 2)

        // Fewer pages than the one being viewed: the last.
        controller.model.settings.photosPerPage = 96
        #expect(try await evaluate("document.querySelectorAll('figure').length", in: webView) as? Int == 4)
        #expect(controller.currentPage == 1)

        // The stylesheet follows too.
        controller.model.settings.columns = 3
        let columns = try await evaluate("getComputedStyle(document.documentElement).getPropertyValue('--columns').trim()", in: webView)
        #expect(columns as? String == "3")
    }
}
