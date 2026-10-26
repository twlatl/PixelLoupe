import AppKit
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
