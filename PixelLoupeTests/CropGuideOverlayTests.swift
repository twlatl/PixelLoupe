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
        #expect(seen == [.thirds, .fifths, .diagonal, .halves, .triangle, .goldenRatio, .goldenSpiral, .grid])
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

    @Test func goldenRatioLines() {
        let lines = CropGuideOverlay.goldenRatio.segments(in: rect)
        let fractions = verticals(lines).map { (($0 - rect.minX) / rect.width * 1000).rounded() / 1000 }
        #expect(fractions == [0.382, 0.618])
        #expect(horizontals(lines).map { (($0 - rect.minY) / rect.height * 1000).rounded() / 1000 } == [0.382, 0.618])
        #expect(CropGuideOverlay.goldenRatio.orientationCount == 1)
    }

    @Test(arguments: [0, 1])
    func triangleLinesMeetTheDiagonalSquarely(orientation: Int) {
        let lines = CropGuideOverlay.triangle.segments(in: rect, orientation: orientation)
        #expect(lines.count == 3)
        let diagonal = lines[0]
        let corners = [diagonal.start, diagonal.end]
        let expected = orientation == 0
            ? [CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.minY)]
            : [CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY)]
        #expect(corners == expected, "orientation \(orientation) runs corner to corner")
        let d = CGPoint(x: diagonal.end.x - diagonal.start.x, y: diagonal.end.y - diagonal.start.y)
        for line in lines.dropFirst() {
            #expect(!corners.contains(line.start) && [rect.minX, rect.maxX].contains(line.start.x), "from the other corners")
            let v = CGPoint(x: line.end.x - line.start.x, y: line.end.y - line.start.y)
            #expect(abs(v.x * d.x + v.y * d.y) < 0.001, "at a right angle")
            // The foot lies on the diagonal.
            let cross = (line.end.x - diagonal.start.x) * d.y - (line.end.y - diagonal.start.y) * d.x
            #expect(abs(cross) < 0.01)
        }
    }

    @Test func goldenSpiralFitsTheCropAndTurnsEightWays() throws {
        let spiral = CropGuideOverlay.goldenSpiral
        #expect(spiral.segments(in: rect).isEmpty)
        #expect(spiral.orientationCount == 8)
        var eyes: [CGPoint] = []
        var starts: Set<String> = []
        for orientation in 0..<spiral.orientationCount {
            let curve = try #require(spiral.curves(in: rect, orientation: orientation).first)
            #expect(curve.count > 100)
            #expect(curve.allSatisfy { rect.insetBy(dx: -0.01, dy: -0.01).contains($0) }, "inside the crop")
            #expect(zip(curve, curve.dropFirst()).allSatisfy { hypot($1.x - $0.x, $1.y - $0.y) < 15 }, "one continuous line")
            let start = try #require(curve.first)
            #expect([rect.minX, rect.maxX].contains { abs($0 - start.x) < 0.001 } && [rect.minY, rect.maxY].contains { abs($0 - start.y) < 0.001 },
                    "starts in a corner")
            starts.insert("\(start.x.rounded()),\(start.y.rounded())")
            eyes.append(try #require(curve.last))
        }
        #expect(starts.count == 4, "every corner")
        // The eye lands in each quarter, twice: once winding each way.
        let quarters = eyes.map { "\($0.x < rect.midX ? "left" : "right") \($0.y < rect.midY ? "bottom" : "top")" }
        #expect(Set(quarters).count == 4)
        #expect(Set(quarters).allSatisfy { quarter in quarters.filter { $0 == quarter }.count == 2 })
        let curves = try (0..<8).map { try #require(spiral.curves(in: rect, orientation: $0).first) }
        for i in 0..<8 {
            for j in (i + 1)..<8 {
                #expect(zip(curves[i], curves[j]).contains { hypot($0.x - $1.x, $0.y - $1.y) > 20 }, "\(i) and \(j) differ")
            }
        }
        // The first arc spans the whole short side, ending at the far corner of the first square.
        let base = try #require(spiral.curves(in: CGRect(x: 0, y: 0, width: CropGuideOverlay.phi, height: 1)).first)
        #expect(base.first.map { abs($0.x) < 0.0001 && abs($0.y) < 0.0001 } == true, "starts at the bottom-left corner")
        #expect(base.contains { abs($0.x - 1) < 0.0001 && abs($0.y - 1) < 0.0001 })
        #expect(spiral.curves(in: rect, orientation: 0) != spiral.curves(in: rect, orientation: 4))
        #expect(CropGuideOverlay.thirds.curves(in: rect).isEmpty)
    }

    @Test func orientationsAreRememberedPerGuide() {
        let key = "CropGuideOrientations"
        let previous = Defaults.store.object(forKey: key)
        defer { Defaults.store.set(previous, forKey: key) }
        Defaults.store.removeObject(forKey: key)
        #expect(CropGuideOverlay.goldenSpiral.savedOrientation == 0)
        CropGuideOverlay.goldenSpiral.savedOrientation = 5
        CropGuideOverlay.triangle.savedOrientation = 1
        #expect(CropGuideOverlay.goldenSpiral.savedOrientation == 5)
        #expect(CropGuideOverlay.triangle.savedOrientation == 1)
        CropGuideOverlay.triangle.savedOrientation = 7
        #expect(CropGuideOverlay.triangle.savedOrientation == 0, "out of range falls back")
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
        let guideKey = "CropGuideOverlay", toolKey = "CropToolOverlay", orientationsKey = "CropGuideOrientations"
        let previous = (Defaults.store.object(forKey: guideKey), Defaults.store.object(forKey: toolKey),
                        Defaults.store.object(forKey: orientationsKey))
        defer {
            Defaults.store.set(previous.0, forKey: guideKey)
            Defaults.store.set(previous.1, forKey: toolKey)
            Defaults.store.set(previous.2, forKey: orientationsKey)
        }
        Defaults.store.removeObject(forKey: guideKey)
        Defaults.store.removeObject(forKey: orientationsKey)
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

        // ⇧O turns the Golden Spiral and remembers it; the symmetric guides don't turn.
        let orientationItem = NSMenuItem(title: "Cycle Orientation",
                                         action: #selector(CatalogWindowController.cycleCropGuideOrientation(_:)), keyEquivalent: "")
        #expect(!controller.validateUserInterfaceItem(orientationItem), "Halves has no orientations")
        item.tag = try #require(CropGuideOverlay.allCases.firstIndex(of: .goldenSpiral))
        controller.chooseCropGuideOverlay(item)
        #expect(controller.validateUserInterfaceItem(orientationItem))
        #expect(controller.perform(.cropGuideOrientation))
        #expect(controller.perform(.cropGuideOrientation))
        #expect(overlay.guideOrientation == 2)
        #expect(CropGuideOverlay.goldenSpiral.savedOrientation == 2)
        item.tag = try #require(CropGuideOverlay.allCases.firstIndex(of: .halves))
        controller.chooseCropGuideOverlay(item)
        #expect(overlay.guideOrientation == 0)
        item.tag = try #require(CropGuideOverlay.allCases.firstIndex(of: .goldenSpiral))
        controller.chooseCropGuideOverlay(item)
        #expect(overlay.guideOrientation == 2, "each guide comes back the way it was")
        item.tag = try #require(CropGuideOverlay.allCases.firstIndex(of: .halves))
        controller.chooseCropGuideOverlay(item)

        // Outside the crop tool O is Masking's Show Overlay again, and the guide items are disabled.
        state.developTool = .mask
        #expect(controller.perform(.maskOverlay))
        #expect(overlay.guideOverlay == .halves)
        #expect(!controller.validateUserInterfaceItem(item))
        #expect(!controller.perform(.cropGuideOrientation), "⇧O does nothing outside the crop tool")
    }

    @Test func shiftOIsTheGuideOrientation() throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0,
                                                  context: nil, characters: "O", charactersIgnoringModifiers: "O", isARepeat: false, keyCode: 31))
        #expect(KeyCommand(event: event) == .cropGuideOrientation)
    }
}
