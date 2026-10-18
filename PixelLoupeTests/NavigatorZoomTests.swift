import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Zoom model")
struct PhotoZoomTests {
    @Test func ratiosReadLikeLightroom() {
        #expect(ZoomRatio.menu.map(\.title) == ["1:16", "1:8", "1:4", "1:3", "1:2", "2:1", "3:1", "4:1", "8:1", "11:1"])
        #expect(ZoomRatio.oneToOne.scale == 1 && ZoomRatio.oneToFour.scale == 0.25 && ZoomRatio.elevenToOne.scale == 11)
        #expect(abs(ZoomRatio.oneToThree.scale - 1.0 / 3) < 1e-9)
        let zoom = PhotoZoom()
        #expect(zoom.fit == .fit && zoom.ratio == .oneToOne && zoom.menuRatio == .threeToOne && !zoom.isZoomed)
    }

    @Test func fitFillAndRatiosScaleThePhoto() {
        let photo = CGSize(width: 6000, height: 4000), pane = CGSize(width: 1200, height: 1200)
        var zoom = PhotoZoom()
        #expect(zoom.scale(imageSize: photo, paneSize: pane) == 0.2, "fit: the long side fits")
        zoom.fit = .fill
        #expect(zoom.scale(imageSize: photo, paneSize: pane) == 0.3, "fill: the short side fills")
        zoom.isZoomed = true
        zoom.ratio = .twoToOne
        #expect(zoom.scale(imageSize: photo, paneSize: pane) == 2)
    }

    @Test func togglingZoomsInWhereClickedAndBackOut() {
        var zoom = PhotoZoom()
        zoom.toggle(at: CGPoint(x: 0.25, y: 0.75))
        #expect(zoom.isZoomed && zoom.center == CGPoint(x: 0.25, y: 0.75))
        zoom.toggle(at: CGPoint(x: 0.9, y: 0.9))
        #expect(!zoom.isZoomed && zoom.center == CGPoint(x: 0.25, y: 0.75), "zooming out keeps the place for next time")
    }

    @Test func zTogglesZoomLikeLightroom() {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
        #expect(KeyCommand(event: event) == .toggleZoom)
        let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        #expect(KeyCommand(event: space) == .toggleZoom, "Space too, as in Lightroom")
    }
}

@Suite("Navigator and zoom")
@MainActor
struct NavigatorZoomTests {
    private struct Setup {
        let directory: TemporaryDirectory
        let store: CatalogStore
        let controller: CatalogWindowController
        var state: LibraryState { controller.state }
        var window: NSWindow { controller.window! }
        var navigator: NavigatorViewController { controller.rootViewController.main.sidebar.navigator }
    }

    /// A catalog of `count` 6000 × 4000 photos (no files) and its window, with the first photo selected.
    private func setup(count: Int = 2, withFile: Bool = false) throws -> Setup {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        for index in 0..<count {
            let photo = Photo(context: store.viewContext)
            photo.id = UUID()
            photo.fileName = "IMG_\(index).jpg"
            let url = directory.url.appending(path: photo.fileName)
            if withFile { try Fixtures.writeJPEG(to: url, width: 1200, height: 800) }
            photo.filePath = url.path(percentEncoded: false)
            photo.fileType = "JPG"
            photo.pixelWidth = withFile ? 1200 : 6000
            photo.pixelHeight = withFile ? 800 : 4000
            photo.orientation = 1
            photo.captureDate = Date(timeIntervalSince1970: Double(index))
            photo.importDate = Date()
            photo.editDate = Date()
        }
        try store.viewContext.save()
        let controller = CatalogWindowController(store: store)
        controller.showWindow(nil)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: true)
        controller.window?.layoutIfNeeded()
        if let first = controller.state.photoOrder.first { controller.state.selectedPhotoIDs = [first] }
        return Setup(directory: directory, store: store, controller: controller)
    }

    private func pump(_ seconds: Double = 0.05) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @Test func sidebarShowsTheCatalogThenTheNavigator() throws {
        let setup = try setup()
        defer { setup.controller.close() }
        let window = setup.window
        #expect(window.titleVisibility == .hidden && window.title == "Test", "the title moved to the sidebar")
        let views = window.contentView!.descendants
        let name = try #require(views.first { $0.accessibilityIdentifier() == "sidebarCatalogName" } as? NSTextField)
        let storage = try #require(views.first { $0.accessibilityIdentifier() == "sidebarCatalogStorage" } as? NSTextField)
        let navigator = try #require(views.first { $0.accessibilityIdentifier() == "navigator" })
        let outline = try #require(views.first { $0.accessibilityIdentifier() == "sidebarOutline" })
        #expect(name.stringValue == "Test" && storage.stringValue == setup.store.info.storageDescription)
        func top(_ view: NSView) -> CGFloat { view.convert(view.bounds, to: nil).maxY }
        #expect(top(name) > top(storage) && top(storage) > top(navigator) && top(navigator) > top(outline), "name, storage, Navigator, then the list")
        // The sidebar button sits at the sidebar's right edge.
        #expect(Array(window.toolbar!.items.prefix(3).map(\.itemIdentifier)) == [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator])
    }

    @Test func navigatorChoicesSetTheZoomAndEnlargeFromTheGrid() throws {
        let setup = try setup()
        defer { setup.controller.close() }
        let control = setup.navigator.zoomControl
        #expect(control.selectedSegment == 0 && control.label(forSegment: 3) == "3:1")
        #expect(setup.state.presentation == .grid)

        control.selectedSegment = 2   // 1:1
        _ = control.target?.perform(control.action, with: control)
        #expect(setup.state.zoom.isZoomed && setup.state.zoom.ratio == .oneToOne)
        #expect(setup.state.presentation == .loupe, "choosing a zoom in the grid enlarges the photo")

        control.selectedSegment = 1   // FILL
        _ = control.target?.perform(control.action, with: control)
        #expect(!setup.state.zoom.isZoomed && setup.state.zoom.fit == .fill)

        let menu = try #require(control.menu(forSegment: 3))
        let eight = try #require(menu.items.first { $0.title == "8:1" })
        _ = (eight.target as AnyObject).perform(eight.action, with: eight)
        #expect(setup.state.zoom.isZoomed && setup.state.zoom.ratio == .eightToOne && setup.state.zoom.menuRatio == .eightToOne)
        #expect(control.selectedSegment == 3 && control.label(forSegment: 3) == "8:1" && eight.state == .on)
    }

    @Test func libraryEnlargedViewFillsZoomsAndShowsTheRectangle() async throws {
        let setup = try setup()
        defer { setup.controller.close() }
        let state = setup.state
        state.presentation = .loupe
        setup.window.layoutIfNeeded()
        #expect(state.zoomVisibleRect == nil, "fitted: all of it shows")

        state.zoom.fit = .fill
        setup.window.layoutIfNeeded()
        let fill = try #require(state.zoomVisibleRect)
        #expect(abs(fill.height - 1) < 0.001 || abs(fill.width - 1) < 0.001, "fill shows the photo's full short side: \(fill)")
        #expect(min(fill.width, fill.height) < 0.999, "and crops the long side")

        state.zoom.isZoomed = true
        state.zoom.ratio = .oneToOne
        state.zoom.center = CGPoint(x: 0.25, y: 0.5)
        setup.window.layoutIfNeeded()
        let actual = try #require(state.zoomVisibleRect)
        #expect(actual.width < 0.5 && actual.height < 0.5, "1:1 of a 6000-pixel photo shows a small part: \(actual)")
        #expect(abs(actual.midX - 0.25) < 0.01, "centered where asked")
        let rectangle = try #require(setup.navigator.preview.shownRect)
        #expect(rectangle == actual, "the Navigator outlines it")

        state.presentation = .grid
        #expect(setup.navigator.preview.outlineRect == nil, "no rectangle over the grid")
    }

    /// As in Lightroom: at Fit the rectangle wraps the whole photo, and it animates to the zoomed size and back.
    @Test func navigatorRectangleWrapsTheFittedPhotoAndAnimatesBetweenSizes() throws {
        let setup = try setup()
        defer { setup.controller.close() }
        let state = setup.state
        let preview = setup.navigator.preview
        preview.image = CGImage.solid(width: 300, height: 200)
        state.presentation = .loupe
        setup.window.layoutIfNeeded()
        let whole = preview.photoRect.insetBy(dx: 0.5, dy: 0.5)
        #expect(preview.outlineRect == whole, "fitted: around the whole thumbnail")
        #expect(!preview.outlineLayer.isHidden && preview.outlineLayer.path?.boundingBox == whole)

        state.zoom.isZoomed = true
        state.zoom.ratio = .oneToOne
        setup.window.layoutIfNeeded()
        let zoomed = try #require(preview.outlineRect)
        #expect(zoomed.width < whole.width / 2, "zoomed: around the part on screen")
        #expect(preview.outlineLayer.animation(forKey: NavigatorPreviewView.outlineAnimationKey) != nil, "it animates to the new size")
        #expect(preview.outlineLayer.path?.boundingBox == zoomed, "and ends there")

        // Panning moves it without animating.
        preview.outlineLayer.removeAllAnimations()
        state.zoom.center = CGPoint(x: 0.3, y: 0.5)
        setup.window.layoutIfNeeded()
        #expect(preview.outlineLayer.animation(forKey: NavigatorPreviewView.outlineAnimationKey) == nil, "panning follows at once")

        state.zoom.isZoomed = false
        setup.window.layoutIfNeeded()
        #expect(preview.outlineRect == whole, "back to the whole thumbnail")
        #expect(preview.outlineLayer.animation(forKey: NavigatorPreviewView.outlineAnimationKey) != nil, "animating back")
    }

    @Test func theEnlargedPhotoAnimatesWhenZoomingButNotWhenPanning() throws {
        let setup = try setup()
        defer { setup.controller.close() }
        let state = setup.state
        state.presentation = .loupe
        setup.window.layoutIfNeeded()
        let viewer = try #require(setup.window.contentView!.descendants.first { $0.accessibilityIdentifier() == "photoViewer" })
        let clip = try #require(viewer.layer?.sublayers?.first { $0.masksToBounds })
        let photo = try #require(clip.sublayers?.first)
        let fitted = photo.frame
        #expect(fitted.width > 0 && photo.contentsGravity == .resize, "fitted to an explicit rect, so it can animate")

        state.zoom.isZoomed = true
        #expect(photo.animation(forKey: "zoom") != nil, "zooming in animates")
        #expect(photo.frame.width > fitted.width * 2, "to the zoomed size")
        photo.removeAllAnimations()
        state.zoom.center = CGPoint(x: 0.3, y: 0.4)
        #expect(photo.animation(forKey: "zoom") == nil, "panning doesn't")
        state.zoom.isZoomed = false
        #expect(photo.animation(forKey: "zoom") != nil && photo.frame == fitted, "zooming out animates back")
    }

    @Test func navigatorBackgroundIsTheMatteColor() throws {
        let setup = try setup()
        defer { setup.controller.close() }
        let preview = setup.navigator.preview
        #expect(preview.matteColor == GridColors.background(for: preview.effectiveAppearance), "the grid's and Develop's matte")
        preview.image = nil   // just the background
        let rep = try #require(preview.bitmapImageRepForCachingDisplay(in: preview.bounds))
        preview.cacheDisplay(in: preview.bounds, to: rep)
        // Compare with the matte drawn into the same kind of bitmap, so both go through the same color conversion.
        let reference = try #require(preview.bitmapImageRepForCachingDisplay(in: preview.bounds))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: reference)
        preview.effectiveAppearance.performAsCurrentDrawingAppearance {
            preview.matteColor.setFill()
            NSRect(x: 0, y: 0, width: reference.pixelsWide, height: reference.pixelsHigh).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let corner = try #require(rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
        let matte = try #require(reference.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
        #expect(abs(corner.redComponent - matte.redComponent) < 0.02 && abs(corner.blueComponent - matte.blueComponent) < 0.02,
                "drawn behind the photo: \(corner) vs \(matte)")
    }

    @Test func clickingTheNavigatorPreviewZoomsToThatPoint() throws {
        let setup = try setup()
        defer { setup.controller.close() }
        let preview = setup.navigator.preview
        preview.image = CGImage.solid(width: 300, height: 200)
        setup.window.layoutIfNeeded()
        let rect = preview.photoRect
        let point = preview.convert(CGPoint(x: rect.minX + rect.width * 0.75, y: rect.minY + rect.height * 0.25), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: setup.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        preview.mouseDown(with: event)
        #expect(setup.state.zoom.isZoomed)
        #expect(abs(setup.state.zoom.center.x - 0.75) < 0.02 && abs(setup.state.zoom.center.y - 0.25) < 0.02)
        #expect(setup.state.presentation == .loupe)
    }

    @Test func clickingThePhotoZoomsThereAndDraggingPans() throws {
        let setup = try setup()
        defer { setup.controller.close() }
        let state = setup.state
        state.presentation = .loupe
        setup.window.layoutIfNeeded()
        let viewer = try #require(setup.window.contentView!.descendants.first { $0.accessibilityIdentifier() == "photoViewer" })
        let clicks = try #require(viewer.subviews.compactMap { $0 as? ZoomClickView }.first)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: clicks.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: setup.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // A click right of center zooms in there.
        let point = CGPoint(x: clicks.bounds.midX + clicks.bounds.width * 0.2, y: clicks.bounds.midY)
        clicks.mouseDown(with: event(.leftMouseDown, point))
        clicks.mouseUp(with: event(.leftMouseUp, point))
        #expect(state.zoom.isZoomed && state.zoom.center.x > 0.6, "zoomed in right of center: \(state.zoom.center)")
        setup.window.layoutIfNeeded()

        // Dragging left moves the view right (toward the photo's right edge).
        let before = state.zoom.center
        clicks.mouseDown(with: event(.leftMouseDown, point))
        clicks.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: point.x - 10, y: point.y)))
        clicks.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: point.x - 60, y: point.y)))
        clicks.mouseUp(with: event(.leftMouseUp, CGPoint(x: point.x - 60, y: point.y)))
        #expect(state.zoom.isZoomed, "a drag isn't a click")
        #expect(state.zoom.center.x > before.x, "panned: \(before) → \(state.zoom.center)")

        // Another click zooms back out.
        clicks.mouseDown(with: event(.leftMouseDown, point))
        clicks.mouseUp(with: event(.leftMouseUp, point))
        #expect(!state.zoom.isZoomed)
    }

    @Test func zEnlargesZoomedFromTheGridThenToggles() throws {
        let setup = try setup()
        defer { setup.controller.close() }
        #expect(setup.controller.perform(.toggleZoom))
        #expect(setup.state.presentation == .loupe && setup.state.zoom.isZoomed)
        #expect(setup.controller.perform(.toggleZoom))
        #expect(setup.state.presentation == .loupe && !setup.state.zoom.isZoomed)
    }

    @Test(.timeLimit(.minutes(3))) func developZoomsAndPublishesWhatShows() async throws {
        let setup = try setup(count: 1, withFile: true)
        defer { setup.controller.close() }
        let state = setup.state
        state.mode = .develop
        let develop = setup.controller.rootViewController.main.develop
        let start = Date()
        while !develop.canAutoLight, Date().timeIntervalSince(start) < 90 { await pump(0.2) }
        #expect(develop.canAutoLight, "the photo decoded")
        // Drawn fitted first, as it is before anyone zooms: a zoom animates from the photo on screen.
        // (A fixed wait for this was too short on a busy machine; the zoom then had nothing to move from.)
        let drawStart = Date()
        while !develop.hasDrawnPhoto, Date().timeIntervalSince(drawStart) < 30 { await pump(0.05) }
        #expect(develop.hasDrawnPhoto, "the fitted photo is drawn")

        // The animation lasts a fifth of a second, which a busy machine can let pass between two checks,
        // so the test looks for it having started rather than for it running.
        let animationsBefore = develop.zoomAnimationsStarted
        state.zoom.isZoomed = true
        state.zoom.ratio = .eightToOne   // larger than any test window, whatever its pixel size
        state.zoom.center = CGPoint(x: 0.5, y: 0.5)
        let animationStart = Date()
        while develop.zoomAnimationsStarted == animationsBefore, Date().timeIntervalSince(animationStart) < 30 {
            await pump(0.05)
        }
        #expect(develop.zoomAnimationsStarted > animationsBefore, "zooming in animates the preview")
        let zoomStart = Date()
        while state.zoomVisibleRect == nil, Date().timeIntervalSince(zoomStart) < 30 { await pump(0.1) }
        let visible = try #require(state.zoomVisibleRect)
        #expect(visible.width < 1 && visible.height < 1, "8:1 of a 1200-pixel photo doesn't fit: \(visible)")
        #expect(abs(visible.midX - 0.5) < 0.01 && abs(visible.midY - 0.5) < 0.01)

        state.zoom.isZoomed = false
        let fitStart = Date()
        while state.zoomVisibleRect != nil, Date().timeIntervalSince(fitStart) < 30 { await pump(0.1) }
        #expect(state.zoomVisibleRect == nil, "fitted again")
    }
}

private extension CGImage {
    static func solid(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
