import AppKit
import Foundation
import Testing
@testable import PixelLoupe

/// The Remove tool in Develop (RAW-260): Q opens it, painting removes, Detect Objects waits for Remove, and the
/// spots are the same ones Spot Removal (now ⇧Q) shows.
@MainActor
@Suite("Remove tool (RAW-260)", .serialized)
struct RemoveToolTests {
    @Test("Q is Remove and ⇧Q Spot Removal, as in Lightroom")
    func keys() {
        func event(_ characters: String, shift: Bool) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 12)!
        }
        #expect(KeyCommand(event: event("q", shift: false)) == .removeTool)
        #expect(KeyCommand(event: event("Q", shift: true)) == .spotRemovalTool)
    }

    /// A catalog window in Develop showing one 600 × 400 photo, with the Remove tool open.
    private func openRemove(_ directory: TemporaryDirectory) async throws -> (CatalogWindowController, DevelopViewController, Photo) {
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let photo = Photo(context: store.viewContext)
        photo.id = UUID()
        photo.fileName = "IMG.jpg"
        let url = directory.url.appending(path: photo.fileName)
        try Fixtures.writeJPEG(to: url, width: 600, height: 400)
        photo.filePath = url.path(percentEncoded: false)
        photo.fileType = "JPG"
        photo.pixelWidth = 600
        photo.pixelHeight = 400
        photo.orientation = 1
        photo.captureDate = Date()
        photo.importDate = Date()
        photo.editDate = Date()
        try store.viewContext.save()

        let controller = CatalogWindowController(store: store)
        controller.showWindow(nil)
        controller.state.selectedPhotoIDs = [try #require(controller.state.photoOrder.first)]
        controller.state.mode = .develop
        #expect(controller.perform(.removeTool))
        #expect(controller.state.developTool == .remove)
        let develop = controller.rootViewController.main.develop
        let start = Date()
        while !develop.hasDrawnPhoto, Date().timeIntervalSince(start) < 30 { try await Task.sleep(for: .milliseconds(50)) }
        return (controller, develop, photo)
    }

    private func stroke(_ points: [(Double, Double)], size: Double = 0.03) -> PhotoAdjustments.BrushStroke {
        PhotoAdjustments.BrushStroke(points: points.map { .init(x: $0.0, y: $0.1) }, size: size, feather: 0.1, flow: 1, density: 1)
    }

    @Test("Painting with Detect Objects off removes at once; the spot can be refilled, turned into a heal, and deleted")
    func paintRemovesAtOnce() async throws {
        let directory = try TemporaryDirectory()
        let (controller, develop, photo) = try await openRemove(directory)
        defer { controller.close() }
        let panel = develop.removePanelForTesting, overlay = develop.removeOverlayForTesting
        #expect(!overlay.isHidden && !panel.view.isHidden)
        let detects = panel.detectsObjects
        defer { Defaults.store.set(detects, forKey: "RemoveDetectsObjects") }
        Defaults.store.set(false, forKey: "RemoveDetectsObjects")
        let fresh = RemovePanelViewController()
        #expect(!fresh.detectsObjects)

        // Detect Objects is off in this panel only once its checkbox says so.
        let checkbox = try #require(panel.view.descendants.first { $0.accessibilityIdentifier() == "removeDetectObjects" } as? NSButton)
        if checkbox.state == .on { checkbox.performClick(nil) }
        panel.setMode(.remove)
        overlay.mode = .remove
        overlay.onStroke?(stroke([(0.3, 0.5), (0.4, 0.5)]))
        var spots = photo.adjustments.spots
        #expect(spots.count == 1)
        let spot = try #require(spots.first)
        #expect(spot.kind == .remove && spot.area != nil && spot.seed != 0 && spot.isFilled)
        #expect(abs(spot.center.x - 0.35) < 0.01, "its pin is at the middle of the area")
        #expect(overlay.selectedID == spot.id && !panel.cardForTesting.isHidden, "selected, with its Selected card")
        #expect(DevelopHistory.steps(for: photo).last?.name == "Remove")

        // Refresh picks another fill.
        let refresh = try #require(panel.view.descendants.first { $0.accessibilityIdentifier() == "removeRefresh" } as? NSButton)
        refresh.performClick(nil)
        spots = photo.adjustments.spots
        #expect(spots[0].seed != spot.seed && spots[0].area == spot.area)

        // Fill ▸ Heal copies from beside it instead.
        let fill = try #require(panel.view.descendants.first { $0.accessibilityIdentifier() == "removeFill" } as? NSPopUpButton)
        fill.selectItem(at: 1)
        fill.sendAction(fill.action, to: fill.target)
        spots = photo.adjustments.spots
        #expect(spots[0].kind == .heal && !spots[0].isFilled)
        #expect(abs(spots[0].source.x - spots[0].center.x) > 0.01, "it has somewhere to copy from")

        // Spot Removal shows the same spot; Delete removes it in Remove.
        #expect(controller.perform(.removePhoto))
        #expect(photo.adjustments.spots.isEmpty)
    }

    @Test("With Detect Objects on, a stroke waits for Remove (or Esc) and can be added to")
    func detectWaitsForRemove() async throws {
        let directory = try TemporaryDirectory()
        let (controller, develop, photo) = try await openRemove(directory)
        defer { controller.close() }
        let panel = develop.removePanelForTesting, overlay = develop.removeOverlayForTesting
        let checkbox = try #require(panel.view.descendants.first { $0.accessibilityIdentifier() == "removeDetectObjects" } as? NSButton)
        let detects = panel.detectsObjects
        defer { Defaults.store.set(detects, forKey: "RemoveDetectsObjects") }
        if checkbox.state == .off { checkbox.performClick(nil) }
        panel.setMode(.remove)

        // A loop around the middle of the photo.
        let loop = (0..<16).map { i -> (Double, Double) in
            let angle = Double(i) / 15 * 2 * .pi
            return (0.5 + 0.1 * cos(angle), 0.5 + 0.15 * sin(angle))
        }
        overlay.onStroke?(stroke(loop, size: 0.01))
        #expect(panel.pending == .detecting && overlay.isDetecting)
        let start = Date()
        while panel.pending == .detecting, Date().timeIntervalSince(start) < 20 { try await Task.sleep(for: .milliseconds(50)) }
        guard case .ready(let area)? = panel.pending else {
            Issue.record("the stroke's area is waiting")
            return
        }
        #expect(!area.isEmpty && photo.adjustments.spots.isEmpty, "nothing removed yet")
        #expect(overlay.pendingArea == area)

        // Painting adds to it.
        overlay.onStroke?(stroke([(0.8, 0.8)]))
        guard case .ready(let grown)? = panel.pending else { Issue.record("still waiting"); return }
        #expect(grown.brush.strokes.count == area.brush.strokes.count + 1)

        // Esc cancels; a new one, then Return removes it.
        #expect(controller.perform(.exit))
        #expect(panel.pending == nil && overlay.pendingArea == nil && photo.adjustments.spots.isEmpty)
        #expect(!controller.perform(.exit) || controller.state.developTool == .remove, "Esc with nothing waiting does what it did")
        overlay.onStroke?(stroke(loop, size: 0.01))
        while panel.pending == .detecting, Date().timeIntervalSince(start) < 40 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(controller.perform(.toggleEnlarge))
        #expect(panel.pending == nil)
        #expect(photo.adjustments.spots.count == 1 && photo.adjustments.spots[0].kind == .remove)
    }

    @Test("In Heal and Clone a click places a round spot the brush's size")
    func clickPlacesACircle() async throws {
        let directory = try TemporaryDirectory()
        let (controller, develop, photo) = try await openRemove(directory)
        defer { controller.close() }
        let panel = develop.removePanelForTesting, overlay = develop.removeOverlayForTesting
        let mode = panel.mode
        defer { panel.setMode(mode) }
        panel.setMode(.clone)
        overlay.onPlace?(.init(x: 0.25, y: 0.25))
        let spot = try #require(photo.adjustments.spots.first)
        #expect(spot.kind == .clone && spot.area == nil && abs(spot.radius - panel.brushSize) < 1e-9)
        #expect(spot.source != spot.center)
        // ⇧Q opens Spot Removal on the same spots.
        #expect(controller.perform(.spotRemovalTool))
        #expect(controller.state.developTool == .retouch)
    }

    @Test("Zoomed in Remove, Space held is a hand that moves the photo; a tap still toggles the zoom")
    func spaceIsTheHandWhenZoomed() async throws {
        let directory = try TemporaryDirectory()
        let (controller, develop, photo) = try await openRemove(directory)
        defer { controller.close() }
        let window = try #require(controller.window)
        let overlay = develop.removeOverlayForTesting
        func space(_ type: NSEvent.EventType, repeating: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                             characters: " ", charactersIgnoringModifiers: " ", isARepeat: repeating, keyCode: 49)!
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: overlay.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        // At fit, Space is Toggle Zoom as everywhere.
        controller.state.zoom.isZoomed = false
        #expect(!develop.handleHandKey(space(.keyDown)))
        #expect(!overlay.isHandHeld)

        // Zoomed: the hand, and a drag moves the photo rather than painting.
        controller.state.zoom.isZoomed = true
        #expect(controller.handleKeyDown(space(.keyDown)) && overlay.isHandHeld)
        #expect(overlay.cursor(at: CGPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)) == .openHand)
        #expect(controller.state.zoom.isZoomed, "not Toggle Zoom")
        var panned = CGVector.zero
        let pan = overlay.onPan
        overlay.onPan = { delta in panned.dx += delta.dx; panned.dy += delta.dy; pan?(delta) }
        overlay.isSpaceDown = { true }
        let middle = CGPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)
        overlay.mouseDown(with: mouse(.leftMouseDown, middle))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: middle.x + 30, y: middle.y + 10)))
        overlay.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: middle.x + 30, y: middle.y + 10)))
        #expect(abs(panned.dx - 30) < 0.5 && abs(panned.dy - 10) < 0.5)
        #expect(photo.adjustments.spots.isEmpty, "nothing painted")
        #expect(controller.handleKeyDown(space(.keyDown, repeating: true)) && overlay.isHandHeld, "held, it stays")
        #expect(develop.handleHandKey(space(.keyUp)))
        #expect(!overlay.isHandHeld && controller.state.zoom.isZoomed, "after moving the photo, letting go keeps the zoom")

        // A tap without a drag zooms out.
        #expect(controller.handleKeyDown(space(.keyDown)))
        #expect(develop.handleHandKey(space(.keyUp)))
        #expect(!controller.state.zoom.isZoomed)
    }

    @Test("A selected spot's area is outlined, not covered, so the removal shows through")
    func selectedAreaIsOutlined() throws {
        let overlay = RemoveOverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        overlay.previewFrame = PreviewFrame(rect: CGRect(x: 0, y: 0, width: 400, height: 300))
        var spot = PhotoAdjustments.Spot()
        spot.kind = .remove
        spot.area = PhotoAdjustments.RemoveArea(brush: PhotoAdjustments.BrushMask(strokes: [stroke([(0.5, 0.5)], size: 0.15)]))
        spot.fitCircleToArea(aspect: 400.0 / 300)
        overlay.spots = [spot]
        overlay.selectedID = spot.id
        overlay.toolOverlay = .never
        let rep = try #require(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
        overlay.cacheDisplay(in: overlay.bounds, to: rep)
        if let out = ProcessInfo.processInfo.environment["PL_SNAPSHOT_DIRECTORY"] {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: out).appending(path: "outline.png"))
        }
        func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            // The rep's points from the top.
            rep.colorAt(x: Int(x * CGFloat(rep.pixelsWide) / 400), y: Int((300 - y) * CGFloat(rep.pixelsHigh) / 300))?.alphaComponent ?? 0
        }
        // The brush reaches 0.15 × 400 = 60 points from the middle.
        #expect(alpha(200 + 30, 150) < 0.05, "the middle is clear")
        let ring = stride(from: 54.0, through: 62.0, by: 1).map { alpha(200 + $0, 150) }.max() ?? 0
        #expect(ring > 0.5, "the edge is outlined: \(ring)")
    }

    @Test("Holding Option while painting a waiting area flips Add and Subtract")
    func optionFlipsSubtract() throws {
        let overlay = RemoveOverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        overlay.previewFrame = PreviewFrame(rect: CGRect(x: 0, y: 0, width: 400, height: 300))
        var strokes: [PhotoAdjustments.BrushStroke] = []
        overlay.onStroke = { strokes.append($0) }
        func drag(option: Bool) {
            let flags: NSEvent.ModifierFlags = option ? .option : []
            func mouse(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 150), modifierFlags: flags, timestamp: 0,
                                   windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            overlay.mouseDown(with: mouse(.leftMouseDown, 100))
            overlay.mouseDragged(with: mouse(.leftMouseDragged, 200))
            overlay.mouseUp(with: mouse(.leftMouseUp, 300))
        }
        // Nothing waiting: there's nothing to take away from, so Option doesn't erase.
        drag(option: true)
        overlay.pendingArea = PhotoAdjustments.RemoveArea(brush: PhotoAdjustments.BrushMask(strokes: [stroke([(0.5, 0.5)])]))
        drag(option: false)
        drag(option: true)
        overlay.subtracts = true
        drag(option: false)
        drag(option: true)
        #expect(strokes.map(\.isErasing) == [false, false, true, true, false])
    }

    @Test("While Option is held the Selected card's Mask buttons show the way the brush paints")
    func optionShowsOnTheMaskButtons() async throws {
        let directory = try TemporaryDirectory()
        let (controller, develop, _) = try await openRemove(directory)
        defer { controller.close() }
        let overlay = develop.removeOverlayForTesting
        let panel = develop.removePanelForTesting
        let picker = panel.maskPickerForTesting
        #expect(picker.selectedSegment == 0, "Add")
        overlay.isOptionDown = true
        #expect(picker.selectedSegment == 1, "Option: Subtract")
        overlay.isOptionDown = false
        #expect(picker.selectedSegment == 0)

        // Choose Subtract; Option shows Add, and letting go shows Subtract again.
        picker.selectedSegment = 1
        _ = picker.sendAction(picker.action, to: picker.target)
        #expect(panel.subtracts && overlay.subtracts)
        overlay.isOptionDown = true
        #expect(picker.selectedSegment == 0, "Option: Add")
        #expect(panel.subtracts, "the choice itself doesn't change")
        overlay.isOptionDown = false
        #expect(picker.selectedSegment == 1)
    }
}
