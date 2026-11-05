import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import WebKit
@testable import PixelLoupe

/// A solid image `width` × `height`, written as a PNG or JPEG (by `url`'s extension).
private func writeLogo(to url: URL, width: Int, height: Int, red: CGFloat = 1, green: CGFloat = 0, blue: CGFloat = 0) throws -> URL {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let type = url.pathExtension.lowercased() == "png" ? UTType.png : UTType.jpeg
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return url
}

@Suite("Logo images")
struct LogoImagesTests {
    @Test func choosingALogoCopiesIt() throws {
        let directory = try TemporaryDirectory()
        let logos = LogoImages(directory: directory.url.appending(path: "Logos"))
        let original = try writeLogo(to: directory.url.appending(path: "Studio.PNG"), width: 40, height: 20)
        let name = try logos.importImage(from: original)
        #expect(name.hasSuffix(".png"))
        try FileManager.default.removeItem(at: original)
        #expect(logos.exists(named: name), "kept after the original is gone")
        #expect(!logos.exists(named: "gone.png"))

        let jpeg = try writeLogo(to: directory.url.appending(path: "Studio.jpeg"), width: 40, height: 20)
        #expect(try logos.importImage(from: jpeg).hasSuffix(".jpg"))
    }

    @Test func aLargeLogoIsReadSmaller() async throws {
        let directory = try TemporaryDirectory()
        let url = try writeLogo(to: directory.url.appending(path: "Wide.png"), width: 4800, height: 1200)
        let image = try #require(await LogoImages.load(url))
        #expect(image.width == LogoImages.maxPixels)
        #expect(image.height == LogoImages.maxPixels / 4)
        let small = try writeLogo(to: directory.url.appending(path: "Small.png"), width: 300, height: 100)
        #expect(await LogoImages.load(small)?.width == 300, "never enlarged")
        #expect(await LogoImages.load(directory.url.appending(path: "Missing.png")) == nil)
    }
}

@Suite("Contact sheet logo")
struct ContactSheetLogoTests {
    private func settings(headline: String = "Proofs") -> ContactSheetSettings {
        var settings = ContactSheetSettings()
        settings.pageSize = .letter
        settings.columns = 4
        settings.headline = headline
        settings.logoName = "logo.png"
        return settings
    }

    @Test func theLogoSitsAboveTheHeadline() throws {
        let layout = ContactSheetLayout(settings: settings(), photoCount: 20, logoAspect: 3)
        let logo = try #require(layout.logoRect)
        let headline = try #require(layout.headlineRect)
        #expect(logo == CGRect(x: ContactSheetLayout.margin, y: 792 - ContactSheetLayout.margin - ContactSheetLayout.logoHeight,
                               width: 3 * ContactSheetLayout.logoHeight, height: ContactSheetLayout.logoHeight))
        #expect(abs(headline.maxY - (logo.minY - ContactSheetLayout.logoGap)) < 0.001)
        #expect(layout.cell(at: 0).maxY <= headline.minY - ContactSheetLayout.headerGap + 0.001)
        let without = ContactSheetLayout(settings: settings(), photoCount: 20)
        #expect(without.logoRect == nil, "nothing until the logo has been read")
        #expect(layout.cell(at: 0).maxY < without.cell(at: 0).maxY, "the logo pushes the photos down")
    }

    @Test func aWideLogoIsNarrowedToTheMargins() throws {
        let logo = try #require(ContactSheetLayout(settings: settings(), photoCount: 20, logoAspect: 30).logoRect)
        #expect(abs(logo.width - (612 - 2 * ContactSheetLayout.margin)) < 0.001)
        #expect(abs(logo.height - logo.width / 30) < 0.001)
    }

    @Test func aLogoOnItsOwnStillLeavesRoomBeforeThePhotos() throws {
        let layout = ContactSheetLayout(settings: settings(headline: ""), photoCount: 20, logoAspect: 2)
        let logo = try #require(layout.logoRect)
        #expect(layout.headlineRect == nil)
        #expect(abs(layout.cell(at: 0).maxY - (logo.minY - ContactSheetLayout.headerGap)) < 0.001)
        #expect(ContactSheetLayout(settings: settings(), photoCount: 20, logoAspect: 0).logoRect == nil, "an unreadable size is no logo")
    }

    @Test func theLogoIsDrawnInItsPlace() throws {
        var settings = settings()
        settings.backgroundColor = .white
        let directory = try TemporaryDirectory()
        let source = try #require(CGImageSourceCreateWithURL(
            try writeLogo(to: directory.url.appending(path: "Blue.png"), width: 60, height: 20, red: 0, green: 0, blue: 1) as CFURL, nil))
        let logo = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let layout = ContactSheetLayout(settings: settings, photoCount: 1, logoAspect: ContactSheetLayout.aspect(of: logo))
        let rect = try #require(layout.logoRect)
        let width = Int(layout.pageSize.width), height = Int(layout.pageSize.height)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ContactSheetRenderer.drawPage(0, layout: layout, settings: settings, logo: logo, in: context) { _ in
            ContactSheetRenderer.Cell(image: nil, aspect: 1, name: "IMG_0.jpg", caption: "")
        }
        let image = try #require(context.makeImage())
        let data = try #require(image.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        func rgb(_ x: CGFloat, _ y: CGFloat) -> [UInt8] {
            let offset = (image.height - 1 - Int(y)) * image.bytesPerRow + Int(x) * 4
            return [bytes[offset], bytes[offset + 1], bytes[offset + 2]]
        }
        #expect(rgb(rect.midX, rect.midY) == [0, 0, 255])
        #expect(rgb(rect.maxX + 4, rect.midY) == [255, 255, 255], "drawn at its own shape")
    }

    @Test func theLogoIsRemembered() throws {
        let suite = "ContactSheetLogoTests.remember"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        settings().remember(in: defaults)
        #expect(ContactSheetSettings.remembered(in: defaults).logoName == "logo.png")
        #expect(ContactSheetSettings.remembered(in: defaults).headline == "")
    }

    @Test func generateDrawsTheLogo() async throws {
        let directory = try TemporaryDirectory()
        let source = try #require(CGImageSourceCreateWithURL(
            try writeLogo(to: directory.url.appending(path: "Logo.png"), width: 300, height: 100) as CFURL, nil))
        let logo = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let photo = ContactSheetPhoto(source: PhotoSourceLocation(original: URL(filePath: "/missing/IMG_1.jpg")), fileName: "IMG_1.jpg")
        let plain = directory.url.appending(path: "Plain.pdf"), withLogo = directory.url.appending(path: "Logo.pdf")
        try await ContactSheetPDF.write([photo], settings: settings(), to: plain) { _ in }
        try await ContactSheetPDF.write([photo], settings: settings(), logo: logo, to: withLogo) { _ in }
        let plainSize = try #require(try FileManager.default.attributesOfItem(atPath: plain.path(percentEncoded: false))[.size] as? Int)
        let logoSize = try #require(try FileManager.default.attributesOfItem(atPath: withLogo.path(percentEncoded: false))[.size] as? Int)
        #expect(logoSize > plainSize, "the logo's image is in the PDF")
    }
}

@Suite("Contact sheet logo model") @MainActor
struct ContactSheetLogoModelTests {
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func choosingALogoReadsItAndLaysTheSheetOutAgain() async throws {
        let suite = "ContactSheetLogoModelTests.choose"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try TemporaryDirectory()
        let logos = LogoImages(directory: directory.url.appending(path: "Logos"))
        let name = try logos.importImage(from: try writeLogo(to: directory.url.appending(path: "Logo.png"), width: 200, height: 100))
        let model = ContactSheetModel(photoCount: 10, defaults: defaults, logos: logos)
        var changes = 0
        model.onChange = { changes += 1 }

        model.settings.logoName = name
        try await waitFor { model.logo != nil }
        #expect(model.logo?.width == 200)
        #expect(model.layout.logoRect?.width == 2 * ContactSheetLayout.logoHeight)
        #expect(changes == 2, "once when chosen, again when it has been read")

        model.settings.logoName = nil
        #expect(model.logo == nil)
        #expect(model.layout.logoRect == nil)
    }

    @Test func aLogoDeletedSinceIsNoLogo() throws {
        let suite = "ContactSheetLogoModelTests.deleted"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try TemporaryDirectory()
        var settings = ContactSheetSettings()
        settings.logoName = "gone.png"
        settings.remember(in: defaults)
        let logos = LogoImages(directory: directory.url)
        #expect(ContactSheetModel(photoCount: 1, defaults: defaults, logos: logos).settings.logoName == nil)
        #expect(WebGalleryModel(photoCount: 1, defaults: defaults, logos: logos).settings.logoName == nil)
    }
}

@Suite("Web gallery logo")
struct WebGalleryLogoTests {
    private func photo(_ file: URL) -> WebGalleryWriter.Photo {
        WebGalleryWriter.Photo(photo: ContactSheetPhoto(source: PhotoSourceLocation(original: file), fileName: file.lastPathComponent))
    }

    @Test func theLogoGoesAboveTheHeadline() throws {
        var settings = WebGallerySettings()
        settings.headline = "Proofs"
        settings.logoName = "ABC.png"
        #expect(WebGalleryHTML.logoPath(settings: settings) == "images/logo.png")
        let header = WebGalleryHTML.header(settings: settings)
        #expect(header.contains("<img class=\"logo\" src=\"images/logo.png\" alt=\"\">\n<h1>Proofs</h1>"),
                "decoration beside the headline")

        settings.headline = ""
        settings.logoName = "ABC.jpg"
        #expect(WebGalleryHTML.header(settings: settings) == "<header>\n<img class=\"logo\" src=\"images/logo.jpg\" alt=\"Logo\">\n</header>\n",
                "a header of its own")
        settings.logoName = nil
        #expect(WebGalleryHTML.header(settings: settings).isEmpty)
        #expect(WebGalleryHTML.stylesheet(settings: settings).contains("header .logo {"))
    }

    @Test func theLogoIsRemembered() throws {
        let suite = "WebGalleryLogoTests.remember"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = WebGallerySettings()
        settings.logoName = "ABC.png"
        settings.remember(in: defaults)
        #expect(WebGallerySettings.remembered(in: defaults).logoName == "ABC.png")
    }

    @Test func generateCopiesTheLogoIn() async throws {
        let directory = try TemporaryDirectory()
        let file = try Fixtures.writeJPEG(to: directory.url.appending(path: "IMG_1.jpg"), width: 300, height: 200)
        let logo = try writeLogo(to: directory.url.appending(path: "Studio.png"), width: 120, height: 40)
        var settings = WebGallerySettings()
        settings.logoName = "ABC.png"
        let folder = directory.url.appending(path: "Gallery")
        _ = try await WebGalleryWriter.write([photo(file)], settings: settings, sourceName: "", watermark: nil, logo: logo, to: folder) { _ in }
        for path in WebGalleryWriter.files(count: 1, pages: 1, logo: "images/logo.png") {
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: path).path(percentEncoded: false)), "\(path)")
        }
        #expect(try Data(contentsOf: folder.appending(path: "images/logo.png")) == Data(contentsOf: logo))
        #expect(try String(contentsOf: folder.appending(path: "index.html"), encoding: .utf8).contains("src=\"images/logo.png\""))

        // Chosen, but its file is missing: no broken image on the pages.
        let missing = directory.url.appending(path: "Missing")
        _ = try await WebGalleryWriter.write([photo(file)], settings: settings, sourceName: "", watermark: nil, to: missing) { _ in }
        #expect(try !String(contentsOf: missing.appending(path: "index.html"), encoding: .utf8).contains("logo"))
    }

    @Test func installingReplacesTheLogo() async throws {
        let directory = try TemporaryDirectory()
        let fileManager = FileManager.default
        let folder = directory.url.appending(path: "Site")
        try fileManager.createDirectory(at: folder.appending(path: "images"), withIntermediateDirectories: true)
        for (path, text) in [("images/logo.jpg", "old"), ("images/banner.png", "mine")] {
            try Data(text.utf8).write(to: folder.appending(path: path))
        }
        let file = try Fixtures.writeJPEG(to: directory.url.appending(path: "IMG_1.jpg"), width: 300, height: 200)
        let logo = try writeLogo(to: directory.url.appending(path: "Studio.png"), width: 120, height: 40)
        var settings = WebGallerySettings()
        settings.logoName = "ABC.png"
        let temporary = directory.url.appending(path: "Temporary")
        _ = try await WebGalleryWriter.write([photo(file)], settings: settings, sourceName: "", watermark: nil, logo: logo,
                                             to: temporary) { _ in }
        try await WebGalleryWriter.install(from: temporary, into: folder)

        func exists(_ path: String) -> Bool { fileManager.fileExists(atPath: folder.appending(path: path).path(percentEncoded: false)) }
        #expect(exists("images/logo.png"))
        #expect(!exists("images/logo.jpg"), "the earlier gallery's logo")
        #expect(exists("images/banner.png"))
        #expect(exists("images/thumbs/001.jpg"))
    }
}

@Suite("Web gallery logo window") @MainActor
struct WebGalleryLogoWindowTests {
    @Test func thePreviewShowsTheLogoAndFollowsItsChanges() async throws {
        let suite = "WebGalleryLogoWindowTests.preview"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try TemporaryDirectory()
        let logos = LogoImages(directory: directory.url.appending(path: "Logos"))
        let wide = try logos.importImage(from: try writeLogo(to: directory.url.appending(path: "Wide.png"), width: 300, height: 100))
        let tall = try logos.importImage(from: try writeLogo(to: directory.url.appending(path: "Tall.png"), width: 50, height: 100))
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let photo = ContactSheetPhoto(source: PhotoSourceLocation(original: URL(filePath: "/missing/IMG_1.jpg")), fileName: "IMG_1.jpg")
        let controller = WebGalleryWindowController(photos: [photo], thumbnails: store.thumbnails, sourceName: "Dunes",
                                                    defaults: defaults, logos: logos)
        controller.showWindow(nil)
        defer { controller.close() }
        let webView = controller.webView
        func waitFor(_ script: String, toBe expected: String) async throws -> Bool {
            for _ in 0..<200 {
                if !webView.isLoading, let value = try? await webView.evaluateJavaScript(script), "\(value)" == expected { return true }
                try await Task.sleep(for: .milliseconds(50))
            }
            return false
        }
        let size = "(function () { const logo = document.querySelector('header img.logo'); "
            + "return logo && logo.complete ? logo.naturalWidth + 'x' + logo.naturalHeight : 'none'; })()"
        #expect(try await waitFor("document.readyState", toBe: "complete"))
        _ = try await webView.evaluateJavaScript("window.marker = 1")

        controller.model.settings.logoName = wide
        #expect(try await waitFor(size, toBe: "300x100"))
        controller.model.settings.logoName = tall
        #expect(try await waitFor(size, toBe: "50x100"), "the new logo, though its path is the same")
        controller.model.settings.logoName = nil
        #expect(try await waitFor(size + " + ' ' + window.marker", toBe: "none 1"), "swapped without reloading the page")
    }
}
