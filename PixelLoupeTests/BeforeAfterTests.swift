import AppKit
import CoreData
import CoreImage
import Testing
@testable import PixelLoupe

@Suite("Before/After")
struct BeforeAfterTests {
    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    private func pixel(_ image: CIImage, at point: CGPoint) -> (r: Float, g: Float, b: Float) {
        var value = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &value, rowBytes: 16, bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
        return (value[0], value[1], value[2])
    }

    @Test func leftRightPutsBeforeOnTheLeft() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let panes = try #require(BeforeAfterView.leftRight.panes(in: bounds, gap: 8))
        #expect(panes.before == CGRect(x: 0, y: 0, width: 496, height: 600))
        #expect(panes.after == CGRect(x: 504, y: 0, width: 496, height: 600))
    }

    @Test func topBottomPutsBeforeOnTop() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let panes = try #require(BeforeAfterView.topBottom.panes(in: bounds, gap: 8))
        // Origin bottom-left: the before pane is the upper one.
        #expect(panes.before == CGRect(x: 0, y: 304, width: 1000, height: 296))
        #expect(panes.after == CGRect(x: 0, y: 0, width: 1000, height: 296))
    }

    @Test func singlePhotoViewsHaveNoPanes() {
        #expect(BeforeAfterView.beforeOnly.panes(in: CGRect(x: 0, y: 0, width: 100, height: 100), gap: 8) == nil)
        #expect(BeforeAfterView.split.panes(in: CGRect(x: 0, y: 0, width: 100, height: 100), gap: 8) == nil)
        #expect(!BeforeAfterView.split.isSideBySide && BeforeAfterView.topBottom.isSideBySide)
    }

    @Test func splitShowsBeforeLeftAndAfterRight() {
        let extent = CGRect(x: 0, y: 0, width: 200, height: 100)
        let before = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: extent)
        let after = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: extent)

        let split = BeforeAfterContent.split.compose(before: before, after: after)
        #expect(split.extent == extent)
        #expect(pixel(split, at: CGPoint(x: 50, y: 50)).r == 1, "before on the left")
        #expect(pixel(split, at: CGPoint(x: 150, y: 50)).b == 1, "after on the right")

        #expect(pixel(BeforeAfterContent.before.compose(before: before, after: after), at: CGPoint(x: 150, y: 50)).r == 1)
        #expect(BeforeAfterContent.after.compose(before: before, after: after) === after)
    }

    @Test func beforeIsStretchedToTheAftersExtent() {
        let before = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 190, height: 95))
        let after = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        let split = BeforeAfterContent.split.compose(before: before, after: after)
        #expect(split.extent == after.extent)
        #expect(pixel(split, at: CGPoint(x: 99, y: 99)).r == 1, "the left half is all before, to the line")
    }

    @Test func beforeDropsTheEditsButKeepsTheFraming() {
        var edited = PhotoAdjustments()
        edited.light.exposure = 1.5
        edited.presence.saturation = 0.3
        edited.crop.rect = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        edited.crop.angle = 3
        edited.orientation.quarterTurns = 1
        edited.transform.vertical = 0.4
        edited.masks = [PhotoAdjustments.LocalAdjustment()]

        let before = edited.before
        #expect(before.light == PhotoAdjustments.Light())
        #expect(before.presence == PhotoAdjustments.Presence())
        #expect(before.masks.isEmpty)
        #expect(before.crop == edited.crop)
        #expect(before.orientation == edited.orientation)
        #expect(before.transform == edited.transform)
        #expect(PhotoAdjustments().before == PhotoAdjustments())
    }
}

@Suite("Before/After in Develop")
struct BeforeAfterDevelopTests {
    let directory: TemporaryDirectory
    let store: CatalogStore
    let ids: [NSManagedObjectID]

    init() async throws {
        directory = try TemporaryDirectory()
        let source = try directory.subdirectory("Source")
        try Fixtures.writeJPEG(to: source.appending(path: "a.jpg"), width: 600, height: 400)
        store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "T.pixelloupe"))
        _ = try await ImportService(store: store).importPhotos(from: [source])
        ids = try store.viewContext.fetch(Photo.fetchRequest()).map(\.objectID)
    }

    @Test func keysToggleTheViewsInDevelopOnly() async throws {
        let controller = CatalogWindowController(store: store)
        defer { controller.close() }
        controller.showWindow(nil)
        let state = controller.state
        state.photoOrder = ids
        state.selectedPhotoIDs = [ids[0]]

        #expect(!controller.perform(.beforeAfter(.leftRight)), "Y does nothing in Library")
        #expect(state.beforeAfter == nil)

        #expect(controller.perform(.showDevelop))
        #expect(controller.perform(.beforeAfter(.leftRight)))
        #expect(state.beforeAfter == .leftRight)
        #expect(controller.perform(.beforeAfter(.split)), "⇧Y switches straight to Split Screen")
        #expect(state.beforeAfter == .split)
        #expect(controller.perform(.beforeAfter(.split)), "the same key again goes back")
        #expect(state.beforeAfter == nil)

        #expect(controller.perform(.beforeAfter(.beforeOnly)), "\\ shows the before")
        #expect(state.beforeAfter == .beforeOnly)
        #expect(controller.perform(.beforeAfter(.beforeOnly)), "\\ again shows the after")
        #expect(state.beforeAfter == nil)

        // The crop tool shows the photo its own way: opening it ends Before/After, and Y closes it.
        #expect(controller.perform(.beforeAfter(.topBottom)))
        #expect(controller.perform(.cropTool))
        #expect(state.developTool == .crop && state.beforeAfter == nil)
        #expect(controller.perform(.beforeAfter(.topBottom)))
        #expect(state.developTool == .adjust && state.beforeAfter == .topBottom)
    }

    @Test func menuItemsAreCheckedForTheCurrentView() throws {
        let controller = CatalogWindowController(store: store)
        defer { controller.close() }
        controller.showWindow(nil)
        controller.state.photoOrder = ids
        controller.state.selectedPhotoIDs = [ids[0]]
        let menu = try #require(MainMenu.make().items.first { $0.title == "View" }?.submenu?.items.first { $0.title == "Before/After" }?.submenu)
        let split = try #require(menu.items.first { $0.title == "Split Screen" })

        #expect(!controller.validateUserInterfaceItem(split), "only in Develop")
        #expect(controller.perform(.showDevelop))
        #expect(controller.perform(.beforeAfter(.split)))
        #expect(controller.validateUserInterfaceItem(split))
        #expect(split.state == .on)
        let leftRight = try #require(menu.items.first { $0.title == "Left/Right" })
        #expect(controller.validateUserInterfaceItem(leftRight) && leftRight.state == .off)

        controller.showBeforeAfter(leftRight)
        #expect(controller.state.beforeAfter == .leftRight)
    }

    @Test func labelsTheBeforeAndAfter() async throws {
        let controller = CatalogWindowController(store: store)
        defer { controller.close() }
        controller.showWindow(nil)
        let state = controller.state
        state.photoOrder = ids
        state.selectedPhotoIDs = [ids[0]]
        #expect(controller.perform(.showDevelop))
        let overlay = try #require(controller.window?.contentView?.descendants.compactMap { $0 as? BeforeAfterOverlayView }.first)

        func waitFor(_ condition: () -> Bool) async throws {
            for _ in 0..<50 where !condition() {
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                controller.window?.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        #expect(controller.perform(.beforeAfter(.leftRight)))
        try await waitFor { if case .sideBySide? = overlay.arrangement { true } else { false } }
        guard case .sideBySide(let before, let after)? = overlay.arrangement else {
            Issue.record("no side-by-side arrangement: \(String(describing: overlay.arrangement))")
            return
        }
        #expect(before.maxX < after.minX, "before left of after")
        #expect(abs(before.width - after.width) < 1 && abs(before.height - after.height) < 1, "both the same size")
        overlay.layoutSubtreeIfNeeded()
        #expect(overlay.shownLabels == ["Before", "After"])

        #expect(controller.perform(.beforeAfter(.split)))
        try await waitFor { if case .split? = overlay.arrangement { true } else { false } }
        guard case .split(let photo, let dividerX)? = overlay.arrangement else {
            Issue.record("no split arrangement")
            return
        }
        #expect(abs(dividerX - photo.midX) <= 1, "the line is down the middle")
        overlay.layoutSubtreeIfNeeded()
        #expect(overlay.shownLabels == ["Before", "After"])

        #expect(controller.perform(.beforeAfter(.beforeOnly)))
        try await waitFor { if case .beforeOnly? = overlay.arrangement { true } else { false } }
        overlay.layoutSubtreeIfNeeded()
        #expect(overlay.shownLabels == ["Before"])

        #expect(controller.perform(.beforeAfter(.beforeOnly)))
        try await waitFor { overlay.arrangement == nil }
        #expect(overlay.arrangement == nil)
        overlay.layoutSubtreeIfNeeded()
        #expect(overlay.shownLabels.isEmpty)
    }
}
