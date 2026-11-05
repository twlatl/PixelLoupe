import AppKit
import CoreData
import Testing
@testable import PixelLoupe

/// Serialized: the tests share the saved guide and Tool Overlay settings.
@Suite("Crop guide overlay", .serialized)
struct CropGuideOverlayTests {
    let rect = CGRect(x: 10, y: 20, width: 300, height: 200)

    private func verticals(_ segments: [CropGuideOverlay.Segment]) -> [CGFloat] {
        segments.filter { $0.start.x == $0.end.x }.map(\.start.x).sorted()
    }

    private func horizontals(_ segments: [CropGuideOverlay.Segment]) -> [CGFloat] {
        segments.filter { $0.start.y == $0.end.y }.map(\.start.y).sorted()
    }

    @Test func cycleFollowsLightroomAndWraps() {
        var overlay = CropGuideOverlay.default
        var seen: [CropGuideOverlay] = []
        for _ in CropGuideOverlay.allCases {
            seen.append(overlay)
            overlay = overlay.next
        }
        #expect(seen == [.thirds, .fifths, .diagonal, .halves, .grid])
        #expect(overlay == .thirds, "O wraps back to Thirds")
    }

    @Test func divisions() {
        let thirds = CropGuideOverlay.thirds.segments(in: rect)
        #expect(verticals(thirds) == [110, 210])
        #expect(horizontals(thirds).map { ($0 * 1000).rounded() / 1000 } == [86.667, 153.333])
        #expect(thirds.allSatisfy { rect.insetBy(dx: -0.01, dy: -0.01).contains($0.start) && rect.insetBy(dx: -0.01, dy: -0.01).contains($0.end) })

        let fifths = CropGuideOverlay.fifths.segments(in: rect)
        #expect(verticals(fifths) == [70, 130, 190, 250])
        #expect(horizontals(fifths) == [60, 100, 140, 180])

        let halves = CropGuideOverlay.halves.segments(in: rect)
        #expect(verticals(halves) == [rect.midX])
        #expect(horizontals(halves) == [rect.midY])
    }

    @Test func diagonalsRunAt45DegreesToTheLongSide() {
        let lines = CropGuideOverlay.diagonal.segments(in: rect)
        #expect(lines.count == 4)
        for line in lines {
            #expect(abs(line.end.x - line.start.x) == 200 && abs(line.end.y - line.start.y) == 200, "45°, ending on the far long side")
            #expect([rect.minY, rect.maxY].contains(line.end.y))
        }
        #expect(lines.contains(.init(start: CGPoint(x: 10, y: 20), end: CGPoint(x: 210, y: 220))))
        #expect(lines.contains(.init(start: CGPoint(x: 310, y: 220), end: CGPoint(x: 110, y: 20))))

        // Portrait: the lines end on the left and right sides instead.
        let portrait = CropGuideOverlay.diagonal.segments(in: CGRect(x: 0, y: 0, width: 100, height: 160))
        #expect(portrait.allSatisfy { [0, 100].contains($0.end.x) && abs($0.end.y - $0.start.y) == 100 })
    }

    @Test func gridHasSquareCellsAcrossTheLongSide() {
        let grid = CropGuideOverlay.grid.segments(in: rect)
        let xs = verticals(grid)
        let ys = horizontals(grid)
        let spacing = rect.width / CGFloat(CropGuideOverlay.gridCells)
        #expect(xs.count == CropGuideOverlay.gridCells - 1)
        #expect(zip(xs, xs.dropFirst()).allSatisfy { abs($1 - $0 - spacing) < 0.001 })
        #expect(zip(ys, ys.dropFirst()).allSatisfy { abs($1 - $0 - spacing) < 0.001 }, "square cells")
        #expect(ys.allSatisfy { $0 > rect.minY && $0 < rect.maxY })
        #expect(abs((ys.first! - rect.minY) - (rect.maxY - ys.last!)) < 0.001, "centred on the short side")
        #expect(CropGuideOverlay.grid.segments(in: .zero).isEmpty)
    }

    @Test func choiceIsRemembered() {
        let key = "CropGuideOverlay"
        let previous = Defaults.store.object(forKey: key)
        defer { Defaults.store.set(previous, forKey: key) }
        Defaults.store.removeObject(forKey: key)
        #expect(CropGuideOverlay.saved == .thirds)
        CropGuideOverlay.saved = .diagonal
        #expect(CropGuideOverlay.saved == .diagonal)
        Defaults.store.set("bogus", forKey: key)
        #expect(CropGuideOverlay.saved == .thirds)
    }

    /// Draws the overlay over a transparent view and reads the brightest alpha in a column band.
    private func alpha(of view: CropOverlayView, columns: ClosedRange<CGFloat>, y: CGFloat) throws -> CGFloat {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let row = Int((view.bounds.height - y) * scale)
        return stride(from: columns.lowerBound * scale, through: columns.upperBound * scale, by: 1)
            .compactMap { rep.colorAt(x: Int($0), y: row)?.alphaComponent }
            .max() ?? 0
    }

    @Test func theDrawnGuideFollowsTheChoice() throws {
        let view = CropOverlayView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        view.frameRect = view.bounds
        view.toolOverlay = .always
        view.guideOverlay = .thirds
        #expect(try alpha(of: view, columns: 147...153, y: 50) == 0, "Thirds has no centre line")
        #expect(try alpha(of: view, columns: 97...103, y: 50) > 0)

        view.guideOverlay = .halves
        #expect(try alpha(of: view, columns: 147...153, y: 50) > 0, "Halves draws the centre line")
        #expect(try alpha(of: view, columns: 97...103, y: 50) == 0)

        view.toolOverlay = .auto
        #expect(try alpha(of: view, columns: 147...153, y: 50) == 0, "Auto hides it until a drag")
        view.flashGuideName()
        #expect(view.showsGuide, "…or until O changes it")
        #expect(try alpha(of: view, columns: 147...153, y: 50) > 0)
    }
}

@Suite("Crop guide overlay keys", .serialized)
struct CropGuideOverlayKeyTests {
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

    @Test func oCyclesTheGuideOnlyWhileCropping() throws {
        let guideKey = "CropGuideOverlay", toolKey = "CropToolOverlay"
        let previous = (Defaults.store.object(forKey: guideKey), Defaults.store.object(forKey: toolKey))
        defer {
            Defaults.store.set(previous.0, forKey: guideKey)
            Defaults.store.set(previous.1, forKey: toolKey)
        }
        Defaults.store.removeObject(forKey: guideKey)
        Defaults.store.set(CropPanelViewController.ToolOverlay.never.rawValue, forKey: toolKey)

        let controller = CatalogWindowController(store: store)
        defer { controller.close() }
        controller.showWindow(nil)
        let state = controller.state
        state.photoOrder = ids
        state.selectedPhotoIDs = [ids[0]]
        #expect(controller.perform(.cropTool))
        let overlay = try #require(controller.window?.contentView?.descendants.compactMap { $0 as? CropOverlayView }.first)
        #expect(overlay.guideOverlay == .thirds)
        #expect(overlay.toolOverlay == .never)
        #expect(controller.perform(.maskOverlay), "O cycles the guide in the crop tool")
        #expect(overlay.guideOverlay == .fifths)
        #expect(overlay.toolOverlay == .always, "O turns Never into Always so the change shows")
        #expect(CropGuideOverlay.saved == .fifths)

        // The menu picks one directly and checks the current one.
        let item = NSMenuItem(title: "Halves", action: #selector(CatalogWindowController.chooseCropGuideOverlay(_:)), keyEquivalent: "")
        item.tag = try #require(CropGuideOverlay.allCases.firstIndex(of: .halves))
        controller.chooseCropGuideOverlay(item)
        #expect(overlay.guideOverlay == .halves)
        #expect(controller.validateUserInterfaceItem(item) && item.state == .on)

        // Outside the crop tool O is Masking's Show Overlay again, and the guide items are disabled.
        state.developTool = .mask
        #expect(controller.perform(.maskOverlay))
        #expect(overlay.guideOverlay == .halves)
        #expect(!controller.validateUserInterfaceItem(item))
    }
}
