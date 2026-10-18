import AppKit
import CoreData
import Testing
@testable import PixelLoupe

@Suite("Compare viewport")
struct CompareViewportTests {
    let imageSize = CGSize(width: 6000, height: 4000)
    let pane = CGRect(x: 0, y: 0, width: 600, height: 500)

    @Test func fitZoomFitsTheWholePhoto() {
        // 600 points × 2 = 1200 pixels across for 6000 pixels → 20%.
        #expect(CompareViewport.fitZoom(imageSize: imageSize, paneSize: pane.size, backingScale: 2) == 0.2)
        let fitted = CompareViewport(zoom: 0.2).imageRect(imageSize: imageSize, paneBounds: pane, backingScale: 2)
        #expect(fitted.size == CGSize(width: 600, height: 400))
        #expect(fitted.midX == pane.midX && fitted.midY == pane.midY, "centered when it fits")
    }

    @Test func zoomedInShowsTheCenterRegion() {
        // At 100% on a 2× display the pane shows 1200 × 1000 photo pixels around the center.
        let region = CompareViewport(zoom: 1).visibleImageRegion(imageSize: imageSize, paneBounds: pane, backingScale: 2)
        #expect(abs(region.width - 1200) < 0.01 && abs(region.height - 1000) < 0.01)
        #expect(abs(region.midX - 3000) < 0.01 && abs(region.midY - 2000) < 0.01)
    }

    @Test func panningMovesAndStopsAtTheEdges() {
        var viewport = CompareViewport(zoom: 1)
        viewport.pan(by: CGVector(dx: -300, dy: 0), imageSize: imageSize, paneBounds: pane, backingScale: 2)
        #expect(viewport.center.x > 0.5, "dragging left reveals more of the right side")
        viewport.pan(by: CGVector(dx: -100_000, dy: 100_000), imageSize: imageSize, paneBounds: pane, backingScale: 2)
        let region = viewport.visibleImageRegion(imageSize: imageSize, paneBounds: pane, backingScale: 2)
        #expect(abs(region.maxX - 6000) < 0.5, "stops at the right edge")
        #expect(abs(region.minY) < 0.5, "stops at the bottom edge")
    }

    @Test func sliderMappingRoundTrips() {
        for zoom in [0.2, 0.5, 1, 2, 4] {
            let value = CompareViewport.sliderValue(forZoom: zoom, fit: 0.2)
            #expect(abs(CompareViewport.zoom(forSliderValue: value, fit: 0.2) - zoom) < 0.0001)
        }
        #expect(CompareViewport.sliderValue(forZoom: 0.2, fit: 0.2) == 0)
        #expect(CompareViewport.sliderValue(forZoom: 4, fit: 0.2) == 1)
    }
}

@Suite("Compare pair")
struct ComparePairTests {
    let order = ["a", "b", "c", "d"]

    @Test func usesTheFirstTwoSelectedPhotos() {
        #expect(ComparePair.make(selection: ["c", "a", "d"], order: order).map { [$0.select, $0.candidate] } == ["c", "a"])
    }

    @Test func singleSelectionComparesWithTheNextPhoto() {
        #expect(ComparePair.make(selection: ["b"], order: order).map { [$0.select, $0.candidate] } == ["b", "c"])
        #expect(ComparePair.make(selection: ["d"], order: order).map { [$0.select, $0.candidate] } == ["d", "c"], "the last photo uses the previous one")
        #expect(ComparePair.make(selection: ["a"], order: ["a"]) == nil)
        #expect(ComparePair.make(selection: [String](), order: order) == nil)
    }

    @Test func steppingTheCandidateSkipsTheSelect() {
        #expect(ComparePair.step(candidate: "a", select: "b", by: 1, order: order) == "c")
        #expect(ComparePair.step(candidate: "c", select: "b", by: -1, order: order) == "a")
        #expect(ComparePair.step(candidate: "d", select: "b", by: 1, order: order) == nil)
    }
}

@Suite("Compare view")
struct CompareViewTests {
    let directory: TemporaryDirectory
    let store: CatalogStore
    let state = LibraryState()
    let ids: [NSManagedObjectID]

    init() throws {
        directory = try TemporaryDirectory()
        store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url)
        let context = store.viewContext
        let photos = (0..<4).map { index in
            let photo = Photo(context: context)
            photo.id = UUID()
            photo.fileName = "IMG_\(index).jpg"
            photo.filePath = "/missing/IMG_\(index).jpg"
            photo.pixelWidth = 6000
            photo.pixelHeight = 4000
            photo.rating = Int16(index)
            photo.captureDate = Date(); photo.importDate = Date(); photo.editDate = Date()
            return photo
        }
        try context.save()
        let ids = photos.map(\.objectID)
        self.ids = ids
        state.photoOrder = ids
        state.comparePhotos = (ids[0], ids[1])
        state.selectedPhotoIDs = [ids[0], ids[1]]
        state.presentation = .compare
    }

    private func makeCompare() throws -> (CompareViewController, NSWindow) {
        let compare = CompareViewController(store: store, state: state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = compare
        window.setContentSize(NSSize(width: 1200, height: 700))
        compare.view.layoutSubtreeIfNeeded()
        compare.refresh()
        return (compare, window)
    }

    private func label(_ id: String, in view: NSView) -> String? {
        view.descendants.compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == id }?.stringValue
    }

    private func panes(_ view: NSView) -> [ComparePhotoView] {
        view.descendants.compactMap { $0 as? ComparePhotoView }
    }

    private func slider(_ view: NSView) -> NSSlider {
        view.descendants.compactMap { $0 as? NSSlider }.first { $0.accessibilityIdentifier() == "compareZoom" }!
    }

    @Test func showsSelectAndCandidateWithTheirDetails() throws {
        let (compare, _) = try makeCompare()
        #expect(label("compareTab.Select", in: compare.view) == "Select")
        #expect(label("compareTab.Candidate", in: compare.view) == "Candidate")
        #expect(label("compareName.Select", in: compare.view) == "IMG_0.jpg")
        #expect(label("compareName.Candidate", in: compare.view) == "IMG_1.jpg")
        #expect(label("compareRating.Candidate", in: compare.view) == RatingFormatter.stars(1))
    }

    @Test func lockedZoomAppliesToBothUnlockedOnlyToTheActivePhoto() throws {
        let (compare, _) = try makeCompare()
        let panes = panes(compare.view)
        let slider = slider(compare.view)
        slider.doubleValue = 0.8
        slider.sendAction(slider.action, to: slider.target)
        let lockedZoom = try #require(panes[0].viewport?.zoom)
        #expect(panes[1].viewport?.zoom == lockedZoom)

        let lock = compare.view.descendants.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "compareLock" }!
        lock.performClick(nil)
        #expect(!compare.isLocked)
        slider.doubleValue = 0.3
        slider.sendAction(slider.action, to: slider.target)
        #expect(panes[0].viewport!.zoom < lockedZoom, "the active (Select) photo zooms")
        #expect(panes[1].viewport?.zoom == lockedZoom, "the other photo doesn't")

        let sync = compare.view.descendants.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "compareSync" }!
        sync.performClick(nil)
        #expect(panes[1].viewport == panes[0].viewport, "Sync matches the Select photo")
    }

    @Test func swapAndCandidateStepping() throws {
        let (compare, _) = try makeCompare()
        compare.swap(nil)
        #expect(state.comparePhotos?.select == ids[1] && state.comparePhotos?.candidate == ids[0])
        #expect(label("compareName.Select", in: compare.view) == "IMG_1.jpg")

        compare.stepCandidate(by: 1)
        #expect(state.comparePhotos?.candidate == ids[2], "skips the Select photo")
        #expect(label("compareName.Candidate", in: compare.view) == "IMG_2.jpg")
        #expect(state.selectedPhotoIDs.first == (state.activeCompareIndex == 0 ? ids[1] : ids[2]), "the active photo is selected first")
    }
}

@Suite("Compare fixes")
struct CompareFixTests {
    let directory: TemporaryDirectory
    let store: CatalogStore
    let ids: [NSManagedObjectID]

    init() throws {
        directory = try TemporaryDirectory()
        store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url)
        let context = store.viewContext
        let photos = (0..<3).map { index in
            let photo = Photo(context: context)
            photo.id = UUID()
            photo.fileName = "IMG_\(index).jpg"
            photo.filePath = "/missing/IMG_\(index).jpg"
            photo.pixelWidth = 3000
            photo.pixelHeight = 4000
            photo.captureDate = Date(); photo.importDate = Date(); photo.editDate = Date()
            return photo
        }
        try context.save()
        ids = photos.map(\.objectID)
    }

    /// Regression: in full screen the divider took the extra width and squeezed the photos to the edges.
    @Test func panesShareTheWidthAndStayFittedWhenResized() throws {
        let state = LibraryState()
        state.photoOrder = ids
        state.comparePhotos = (ids[0], ids[1])
        state.presentation = .compare
        let compare = CompareViewController(store: store, state: state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = compare
        window.setContentSize(NSSize(width: 1000, height: 600))
        compare.view.layoutSubtreeIfNeeded()
        compare.refresh()
        let panes = compare.view.descendants.compactMap { $0 as? ComparePhotoView }
        let smallZoom = try #require(panes[0].viewport?.zoom)

        window.setContentSize(NSSize(width: 2400, height: 1300))
        compare.view.layoutSubtreeIfNeeded()
        for pane in panes {
            #expect(abs(pane.frame.width - 1199.5) < 2, "each pane gets half the width, not \(pane.frame.width)")
            #expect(pane.isFitted)
        }
        let largeZoom = try #require(panes[0].viewport?.zoom)
        #expect(largeZoom > smallZoom * 1.5, "a fitted photo grows with its pane")
    }

    @Test func compareFromDevelopSwitchesToLibrary() throws {
        let controller = CatalogWindowController(store: store)
        defer { controller.close() }
        controller.state.photoOrder = ids
        controller.state.selectedPhotoIDs = [ids[0], ids[2]]
        controller.state.mode = .develop
        #expect(controller.perform(.compare))
        #expect(controller.state.mode == .library)
        #expect(controller.state.presentation == .compare)
        #expect(controller.state.comparePhotos?.select == ids[0] && controller.state.comparePhotos?.candidate == ids[2])
    }

    @Test func settingsOpenOverAFullScreenApp() throws {
        let window = try #require(SettingsWindowController().window)
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(window.collectionBehavior.contains(.moveToActiveSpace))
    }
}
