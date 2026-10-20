import AppKit
import CoreData
import CoreGraphics
import PDFKit
import Testing
@testable import PixelLoupe

@Suite("Contact sheet layout")
struct ContactSheetLayoutTests {
    private func settings(columns: Int = 4, page: ContactSheetSettings.PageSize = .letter,
                          orientation: ContactSheetSettings.Orientation = .portrait) -> ContactSheetSettings {
        var settings = ContactSheetSettings()
        settings.columns = columns
        settings.pageSize = page
        settings.orientation = orientation
        return settings
    }

    @Test func wholeColumnsAcrossAndAsManyRowsAsFit() {
        let layout = ContactSheetLayout(settings: settings(), photoCount: 45)
        // Letter is 612 × 792 points; 0.5 in margins leave 540 × 720.
        #expect(layout.cellSize == (540 - 3 * ContactSheetLayout.gutter) / 4)
        #expect(layout.columns == 4)
        #expect(layout.rows == 5)
        #expect(layout.pageCount == 3)
        #expect(layout.photos(onPage: 0) == 0..<20)
        #expect(layout.photos(onPage: 2) == 40..<45)
        #expect(layout.summary == "4 × 5 per page · 3 pages")

        // The grid fills the width between the margins, top row first.
        let first = layout.cell(at: 0), last = layout.cell(at: 3)
        #expect(abs(first.minX - ContactSheetLayout.margin) < 0.001)
        #expect(abs(last.maxX - (612 - ContactSheetLayout.margin)) < 0.001)
        #expect(abs(first.maxY - (792 - ContactSheetLayout.margin)) < 0.001)
        #expect(layout.cell(at: 4).maxY < first.minY, "the fifth photo starts the second row")
        #expect(layout.cell(at: 19).minY >= ContactSheetLayout.margin, "the last row stays above the bottom margin")
    }

    @Test func largerPhotosMeanFewerPerPage() {
        let small = ContactSheetLayout(settings: settings(columns: 8), photoCount: 100)
        let large = ContactSheetLayout(settings: settings(columns: 2), photoCount: 100)
        #expect(large.cellSize > small.cellSize)
        #expect(large.photosPerPage < small.photosPerPage)
        #expect(large.pageCount > small.pageCount)
    }

    @Test func onePageEvenWithoutPhotos() {
        #expect(ContactSheetLayout(settings: settings(), photoCount: 0).pageCount == 1)
    }

    @Test func columnsStayInRange() {
        #expect(ContactSheetLayout(settings: settings(columns: 0), photoCount: 1).columns == 1)
        #expect(ContactSheetLayout(settings: settings(columns: 50), photoCount: 1).columns == ContactSheetSettings.columnRange.upperBound)
    }

    @Test func oneColumnOnALandscapePageShrinksToFit() {
        let layout = ContactSheetLayout(settings: settings(columns: 1, orientation: .landscape), photoCount: 3)
        #expect(layout.pageSize == CGSize(width: 792, height: 612))
        #expect(layout.rows == 1)
        #expect(layout.cellSize == 612 - 2 * ContactSheetLayout.margin)
        #expect(abs(layout.cell(at: 0).midX - 396) < 0.001, "centered across the page")
        #expect(layout.pageCount == 3)
    }

    @Test func theHeaderPushesThePhotosDown() throws {
        let plain = ContactSheetLayout(settings: settings(), photoCount: 20)
        var titled = settings()
        titled.headline = "  Wedding — Day One  "
        titled.description = "Proofs for the couple"
        let layout = ContactSheetLayout(settings: titled, photoCount: 20)
        let headline = try #require(layout.headlineRect)
        let description = try #require(layout.descriptionRect)
        #expect(abs(headline.maxY - (792 - ContactSheetLayout.margin)) < 0.001)
        #expect(description.maxY <= headline.minY)
        #expect(layout.cell(at: 0).maxY <= description.minY - ContactSheetLayout.headerGap + 0.001)
        #expect(layout.rows < plain.rows)

        titled.headline = "   "
        titled.description = ""
        let blank = ContactSheetLayout(settings: titled, photoCount: 20)
        #expect(blank.headlineRect == nil && blank.descriptionRect == nil, "blank text takes no room")
    }

    @Test func aLongDescriptionTakesAtMostAThirdOfThePage() throws {
        var long = settings()
        long.description = String(repeating: "A very long description of the shoot. ", count: 400)
        let layout = ContactSheetLayout(settings: long, photoCount: 20)
        #expect(try #require(layout.descriptionRect).height <= (792 - 2 * ContactSheetLayout.margin) / 3)
        #expect(layout.rows >= 1)
    }

    @Test func captionsSitUnderTheirPhotosWithoutOverlappingTheNextRow() {
        var captioned = settings()
        captioned.showsCaption = true
        let layout = ContactSheetLayout(settings: captioned, photoCount: 20)
        #expect(layout.captionHeight > 0)
        let caption = layout.captionRect(under: layout.cell(at: 0))
        #expect(caption.maxY <= layout.cell(at: 0).minY)
        #expect(layout.cell(at: 4).maxY < caption.minY)
        #expect(ContactSheetLayout(settings: settings(), photoCount: 20).captionHeight == 0)
    }

    @Test func photosFitTheirCellAtTheirOwnShape() {
        let cell = CGRect(x: 10, y: 20, width: 100, height: 100)
        #expect(ContactSheetLayout.imageFrame(aspect: 2, in: cell) == CGRect(x: 10, y: 45, width: 100, height: 50))
        #expect(ContactSheetLayout.imageFrame(aspect: 0.5, in: cell) == CGRect(x: 35, y: 20, width: 50, height: 100))
        #expect(ContactSheetLayout.imageFrame(aspect: 0, in: cell) == cell)
    }
}

@Suite("Contact sheet settings")
struct ContactSheetSettingsTests {
    @Test func layoutChoicesAreRememberedButNotTheText() throws {
        let suite = "ContactSheetSettingsTests.remember"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ContactSheetSettings()
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
        settings.pageSize = .a3
        settings.orientation = .landscape
        settings.remember(in: defaults)

        var expected = settings
        expected.headline = ""
        expected.description = ""
        #expect(ContactSheetSettings.remembered(in: defaults) == expected)
    }

    @Test func unknownOrMissingValuesKeepTheirDefaults() throws {
        let json = #"{"columns": 99, "pageSize": "folio", "showsBorder": true}"#
        let settings = try JSONDecoder().decode(ContactSheetSettings.self, from: Data(json.utf8))
        #expect(settings.columns == ContactSheetSettings.columnRange.upperBound)
        #expect(settings.pageSize == ContactSheetSettings().pageSize)
        #expect(settings.showsBorder)
        #expect(settings.textColor == .init(red: 0, green: 0, blue: 0), "black text")
        #expect(settings.backgroundColor == .white, "on white")
        #expect(settings.showsPageNumbers)
    }

    @Test func pageSizeFollowsTheRegion() {
        #expect(ContactSheetSettings.PageSize.standard(for: Locale(identifier: "en_US")) == .letter)
        #expect(ContactSheetSettings.PageSize.standard(for: Locale(identifier: "en_CA")) == .letter)
        #expect(ContactSheetSettings.PageSize.standard(for: Locale(identifier: "en_GB")) == .a4)
        #expect(ContactSheetSettings.PageSize.standard(for: Locale(identifier: "de_DE")) == .a4)
    }

    @Test func landscapeTurnsThePage() {
        var settings = ContactSheetSettings()
        settings.pageSize = .a4
        settings.orientation = .landscape
        #expect(settings.pageDimensions == CGSize(width: 841.89, height: 595.28))
    }
}

@Suite("Contact sheet model") @MainActor
struct ContactSheetModelTests {
    @Test func theImageSizeSliderGrowsPhotosToTheRight() throws {
        let suite = "ContactSheetModelTests.slider"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ContactSheetModel(photoCount: 30, defaults: defaults)
        var changes = 0
        model.onChange = { changes += 1 }

        model.imageSize = Double(ContactSheetSettings.columnRange.upperBound)
        #expect(model.settings.columns == 1, "largest photos: one column")
        model.imageSize = Double(ContactSheetSettings.columnRange.lowerBound)
        #expect(model.settings.columns == ContactSheetSettings.columnRange.upperBound)
        model.imageSize = 7.4
        #expect(model.settings.columns == 4)
        #expect(model.layout.columns == 4, "the layout follows")
        #expect(changes == 3)
        #expect(ContactSheetSettings.remembered(in: defaults).columns == 4)
    }
}

@Suite("Contact sheet photos") @MainActor
struct ContactSheetPhotoTests {
    @Test func captionsShowTheChosenField() {
        let photo = ContactSheetPhoto(
            source: PhotoSourceLocation(original: URL(filePath: "/missing/IMG_1.CR3")), fileName: "IMG_1.CR3",
            title: "Sunset", captureDate: Date(timeIntervalSince1970: 1_700_000_000), camera: "Canon EOS R5",
            exposure: ContactSheetPhoto.exposure(shutterSpeed: 1.0 / 250, aperture: 4, iso: 200), rating: 3
        )
        #expect(photo.caption(.fileName) == "IMG_1.CR3")
        #expect(photo.caption(.title) == "Sunset")
        #expect(photo.caption(.caption) == "")
        #expect(photo.caption(.camera) == "Canon EOS R5")
        #expect(photo.caption(.exposure) == "1/250 sec · ƒ / 4 · ISO 200")
        #expect(photo.caption(.rating) == "★★★")
        #expect(!photo.caption(.captureDate).isEmpty)
        #expect(photo.caption(.captureDateTime).count > photo.caption(.captureDate).count)
        #expect(ContactSheetPhoto.exposure(shutterSpeed: 0, aperture: 0, iso: 0) == nil)
        #expect(ContactSheetPhoto.exposure(shutterSpeed: 2, aperture: 0, iso: 100) == "2 sec · ISO 100")
    }

    @Test func photosKeepTheirOrderAndLeaveOutVideos() throws {
        let (store, ids, directory) = try makeSurveyStore(4)
        _ = directory
        let context = store.viewContext
        let video = try #require(try context.existingObject(with: ids[1]) as? Photo)
        video.isVideo = true
        let titled = try #require(try context.existingObject(with: ids[3]) as? Photo)
        titled.titleText = "  Harbour  "
        titled.cameraMake = "Canon"
        titled.cameraModel = "EOS R5"
        titled.orientation = 6
        try context.save()

        let photos = ContactSheetPhoto.photos([ids[3], ids[1], ids[0], ids[2]], in: store)
        #expect(photos.map(\.fileName) == ["IMG_3.jpg", "IMG_0.jpg", "IMG_2.jpg"])
        #expect(photos[0].title == "Harbour")
        #expect(photos[0].camera == "Canon EOS R5")
        #expect(abs(photos[0].aspect - 4000.0 / 6000.0) < 0.001, "turned by its EXIF orientation")
        #expect(abs(photos[1].aspect - 1.5) < 0.001)
        #expect(ContactSheetPhoto.photos([], in: store).isEmpty)
    }
}

@Suite("Contact sheet rendering")
struct ContactSheetRenderingTests {
    private func photo(_ index: Int) -> ContactSheetPhoto {
        ContactSheetPhoto(source: PhotoSourceLocation(original: URL(filePath: "/missing/IMG_\(index).jpg")), fileName: "IMG_\(index).jpg")
    }

    @Test func pagesDrawTheBackgroundAndPhotos() throws {
        var settings = ContactSheetSettings()
        settings.pageSize = .letter
        settings.backgroundColor = .init(red: 1, green: 0, blue: 0)
        settings.columns = 2
        let layout = ContactSheetLayout(settings: settings, photoCount: 1)
        let width = Int(layout.pageSize.width), height = Int(layout.pageSize.height)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let green = try #require(solidImage(red: 0, green: 1, blue: 0))
        ContactSheetRenderer.drawPage(0, layout: layout, settings: settings, in: context) { _ in
            ContactSheetRenderer.Cell(image: green, aspect: 1, name: "IMG_0.jpg", caption: "")
        }
        let image = try #require(context.makeImage())
        #expect(pixel(image, at: CGPoint(x: 5, y: 5)) == [255, 0, 0], "background in the margin")
        let center = layout.cell(at: 0)
        #expect(pixel(image, at: CGPoint(x: center.midX, y: center.midY)) == [0, 255, 0], "the photo in its cell")
    }

    @Test func theBorderIsWhiteAroundThePhoto() throws {
        var settings = ContactSheetSettings()
        settings.pageSize = .letter
        settings.backgroundColor = .init(red: 1, green: 0, blue: 0)
        settings.columns = 2
        settings.showsBorder = true
        let layout = ContactSheetLayout(settings: settings, photoCount: 1)
        let width = Int(layout.pageSize.width), height = Int(layout.pageSize.height)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let green = try #require(solidImage(red: 0, green: 1, blue: 0))
        ContactSheetRenderer.drawPage(0, layout: layout, settings: settings, in: context) { _ in
            ContactSheetRenderer.Cell(image: green, aspect: 1, name: "IMG_0.jpg", caption: "")
        }
        let image = try #require(context.makeImage())
        let cell = layout.cell(at: 0)
        #expect(pixel(image, at: CGPoint(x: cell.minX + 2, y: cell.midY)) == [255, 255, 255])
        #expect(pixel(image, at: CGPoint(x: cell.midX, y: cell.midY)) == [0, 255, 0])
    }

    @Test func generateWritesEveryPageWithTheHeadlineAsTitle() async throws {
        let directory = try TemporaryDirectory()
        var settings = ContactSheetSettings()
        settings.pageSize = .letter
        settings.columns = 4
        settings.headline = "Proofs"
        settings.showsCaption = true
        // 4 × 5 per page: 45 photos make three pages. The files are missing, so each is a placeholder.
        let photos = (0..<45).map(photo)
        let url = directory.url.appending(path: "Sheet.pdf")
        var reported: [Double] = []
        try await ContactSheetPDF.write(photos, settings: settings, to: url) { reported.append($0) }

        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == 3)
        #expect(document.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
        #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Proofs")
        #expect(document.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String == "PixelLoupe")
        let text = try #require(document.page(at: 2)?.string)
        #expect(text.contains("Proofs"), "the headline is on every page, as text")
        // PDFKit breaks the extracted text at the underscore.
        #expect(text.filter { !$0.isWhitespace }.contains("IMG_44.jpg"))
        #expect(text.contains("3 of 3"))
        #expect(reported.last == 1)
    }

    @Test func aPhotoRendersWithItsEdits() async throws {
        let directory = try TemporaryDirectory()
        let file = try Fixtures.writeJPEG(to: directory.url.appending(path: "IMG_1.jpg"), width: 300, height: 200)
        var settings = ContactSheetSettings()
        settings.pageSize = .letter
        let url = directory.url.appending(path: "Sheet.pdf")
        let photo = ContactSheetPhoto(source: PhotoSourceLocation(original: file), fileName: "IMG_1.jpg")
        try await ContactSheetPDF.write([photo], settings: settings, to: url) { _ in }
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == 1)
        let text: String = document.page(at: 0)?.string ?? ""
        #expect(!text.contains("IMG_1.jpg"), "drawn from the file, not as a placeholder")
    }

    @Test func cancellingLeavesNoFile() async throws {
        let directory = try TemporaryDirectory()
        var settings = ContactSheetSettings()
        settings.columns = 10
        let url = directory.url.appending(path: "Sheet.pdf")
        let task = Task {
            try await ContactSheetPDF.write((0..<2000).map(photo), settings: settings, to: url) { _ in }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    private func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage? {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context?.makeImage()
    }

    /// RGB at `point`, with the origin at the bottom-left.
    private func pixel(_ image: CGImage, at point: CGPoint) -> [UInt8] {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return [] }
        let row = image.height - 1 - Int(point.y), offset = row * image.bytesPerRow + Int(point.x) * 4
        return [bytes[offset], bytes[offset + 1], bytes[offset + 2]]
    }
}

@Suite("Contact sheet window") @MainActor
struct ContactSheetWindowTests {
    @Test func theWindowMenuOpensASheetOfTheSelectedPhotos() throws {
        let (store, ids, directory) = try makeSurveyStore(4)
        _ = directory
        let controller = CatalogWindowController(store: store)
        controller.showWindow(nil)
        defer { controller.close() }
        controller.state.photoOrder = ids
        controller.state.selectedPhotoIDs = [ids[2], ids[0]]

        let item = NSMenuItem(title: "Contact Sheet", action: #selector(CatalogWindowController.showContactSheet(_:)), keyEquivalent: "")
        #expect(controller.validateUserInterfaceItem(item))
        controller.showContactSheet(nil)
        let sheet = try #require(controller.contactSheetControllers.first)
        #expect(sheet.photos.map(\.fileName) == ["IMG_0.jpg", "IMG_2.jpg"], "the selected photos in grid order")
        #expect(sheet.window?.isVisible == true)
        #expect((sheet.window?.contentLayoutRect.height ?? 0) >= 560, "a usable size")
        #expect(sheet.window?.subtitle == "2 photos · All Photographs")

        // A snapshot: changing the selection doesn't change it.
        controller.state.selectedPhotoIDs = [ids[1]]
        #expect(sheet.photos.count == 2)

        // One photo selected: the whole grid, in a second window.
        controller.showContactSheet(nil)
        #expect(controller.contactSheetControllers.count == 2)
        #expect(controller.contactSheetControllers[1].photos.count == 4)

        controller.contactSheetControllers[1].close()
        #expect(controller.contactSheetControllers.count == 1, "forgotten once closed")
        controller.close()
        #expect(sheet.window?.isVisible == false, "closing the catalog closes its sheets")
        #expect(controller.contactSheetControllers.isEmpty)
    }

    @Test func disabledWithNothingToShow() throws {
        let (store, ids, directory) = try makeSurveyStore(2)
        _ = directory
        let controller = CatalogWindowController(store: store)
        let item = NSMenuItem(title: "Contact Sheet", action: #selector(CatalogWindowController.showContactSheet(_:)), keyEquivalent: "")
        controller.state.photoOrder = []
        #expect(!controller.validateUserInterfaceItem(item), "an empty grid")

        for id in ids { try #require(try store.viewContext.existingObject(with: id) as? Photo).isVideo = true }
        controller.state.photoOrder = ids
        #expect(!controller.validateUserInterfaceItem(item), "only videos")
    }

    @Test func theMenuItemIsControlOptionCommandC() throws {
        let menu = MainMenu.make()
        let window = try #require(menu.items.first { $0.title == "Window" }?.submenu)
        let item = try #require(window.items.first { $0.action == #selector(PixelLoupeActions.showContactSheet(_:)) })
        #expect(item.title == "Contact Sheet")
        #expect(item.keyEquivalent == "c")
        #expect(item.keyEquivalentModifierMask == [.control, .option, .command])
    }

    @Test func theFileIsNamedAfterTheHeadlineOrSource() throws {
        let suite = "ContactSheetWindowTests.name"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url)
        let photo = ContactSheetPhoto(source: PhotoSourceLocation(original: URL(filePath: "/missing/IMG_1.jpg")), fileName: "IMG_1.jpg")
        let controller = ContactSheetWindowController(photos: [photo], thumbnails: store.thumbnails, sourceName: "2026-10-20", defaults: defaults)
        #expect(controller.suggestedFileName == "2026-10-20.pdf")
        controller.model.settings.headline = "Smith / Jones: Proofs"
        #expect(controller.suggestedFileName == "Smith - Jones- Proofs.pdf")
        let untitled = ContactSheetWindowController(photos: [photo], thumbnails: store.thumbnails, sourceName: "", defaults: defaults)
        #expect(untitled.suggestedFileName == "Contact Sheet.pdf")
    }

    @Test func thePreviewFollowsTheSettings() throws {
        let suite = "ContactSheetWindowTests.preview"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url)
        let photos = (0..<30).map {
            ContactSheetPhoto(source: PhotoSourceLocation(original: URL(filePath: "/missing/IMG_\($0).jpg")), fileName: "IMG_\($0).jpg")
        }
        let controller = ContactSheetWindowController(photos: photos, thumbnails: store.thumbnails, sourceName: "Test", defaults: defaults)
        controller.showWindow(nil)
        defer { controller.close() }
        controller.model.settings.columns = 4
        controller.model.settings.pageSize = .letter
        controller.model.settings.orientation = .portrait
        #expect(controller.preview.layout.pageCount == 2)
        let twoPages = controller.preview.frame.height
        controller.model.settings.columns = 2
        #expect(controller.preview.layout == controller.model.layout)
        #expect(controller.preview.layout.pageCount > 2)
        #expect(controller.preview.frame.height > twoPages, "taller for more pages")
        #expect(controller.preview.pageFrame(1).minY > controller.preview.pageFrame(0).maxY)
    }
}
