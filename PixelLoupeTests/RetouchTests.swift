import AppKit
import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Spot removal and red eye")
struct RetouchTests {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let size = CGSize(width: 400, height: 300)

    private func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> [Float] {
        var data = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return data
    }

    /// A flat mid-gray photo with a dark dot (the "blemish") at (120, 150) and a textured stripe at x ∈ 280…300.
    private func photo(base: Double = 0.5, blemish: Bool = true) -> CIImage {
        let width = Int(size.width), height = Int(size.height)
        var data = [Float](repeating: Float(base), count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = ((height - 1 - y) * width + x) * 4
            data[i + 3] = 1
            if blemish, hypot(Double(x) - 120, Double(y) - 150) < 8 { data[i] = 0.1; data[i + 1] = 0.1; data[i + 2] = 0.1 }
            // A fine texture on the right, for the heal to carry over.
            if x >= 260, x < 320 { let v = Float(base) + (((x + y) / 2) % 2 == 0 ? 0.08 : -0.08); data[i] = v; data[i + 1] = v; data[i + 2] = v }
        } }
        return CIImage(bitmapData: data.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16, size: size, format: .RGBAf, colorSpace: nil)
    }

    private func spot(kind: PhotoAdjustments.Spot.Kind, source: (Double, Double), feather: Double = 0.3, opacity: Double = 1) -> PhotoAdjustments.Spot {
        .init(kind: kind, center: .init(x: 120 / 400, y: 150 / 300), source: .init(x: source.0 / 400, y: source.1 / 300),
              radius: 14.0 / 400, feather: feather, opacity: opacity)
    }

    // MARK: Spots

    @Test("Cloning covers the blemish with the source and leaves the rest alone")
    func clone() {
        let image = photo()
        #expect(pixel(image, 120, 150)[0] < 0.2, "the blemish is there")
        let result = RetouchRenderer.apply(spots: [spot(kind: .clone, source: (200, 150))], redEyes: [], to: image)
        #expect(abs(pixel(result, 120, 150)[0] - 0.5) < 0.01, "covered")
        #expect(abs(pixel(result, 200, 150)[0] - 0.5) < 0.001, "the source is untouched")
        #expect(pixel(result, 120 + 40, 150)[0] == pixel(image, 160, 150)[0], "outside the spot nothing changes")
    }

    @Test("The edge fades by the feather, and opacity lets some of the original through")
    func featherAndOpacity() {
        let image = photo(blemish: false)
        var textured = image
        // A source that is different (the stripe's mean is 0.5; use a darker region by shifting the photo).
        textured = photo(base: 0.5, blemish: true)
        let hard = RetouchRenderer.apply(spots: [spot(kind: .clone, source: (200, 150), feather: 0)], redEyes: [], to: textured)
        let soft = RetouchRenderer.apply(spots: [spot(kind: .clone, source: (200, 150), feather: 0.9)], redEyes: [], to: textured)
        // Near the rim (13 of 14 px out) the blemish edge is visible; with a hard edge more is replaced.
        #expect(abs(pixel(hard, 120 + 7, 150)[0] - 0.5) <= abs(pixel(soft, 120 + 7, 150)[0] - 0.5) + 0.01)
        let half = RetouchRenderer.apply(spots: [spot(kind: .clone, source: (200, 150), opacity: 0.5)], redEyes: [], to: textured)
        let v = pixel(half, 120, 150)[0]
        #expect(v > 0.2 && v < 0.4, "halfway between the blemish (0.1) and the source (0.5): \(v)")
    }

    @Test("Healing keeps the source's texture but takes the colors around the spot")
    func heal() {
        // The photo is darker around the spot than around the source, which has the texture.
        let width = Int(size.width), height = Int(size.height)
        var data = [Float](repeating: 0.3, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = ((height - 1 - y) * width + x) * 4
            data[i + 3] = 1
            if x >= 180 { let v: Float = 0.6 + (((x + y) / 2) % 2 == 0 ? 0.05 : -0.05); data[i] = v; data[i + 1] = v; data[i + 2] = v }
        } }
        let image = CIImage(bitmapData: data.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16, size: size, format: .RGBAf, colorSpace: nil)
        let spot = PhotoAdjustments.Spot(kind: .heal, center: .init(x: 120 / 400, y: 150 / 300), source: .init(x: 240 / 400, y: 150 / 300), radius: 20.0 / 400, feather: 0.3)
        let healed = RetouchRenderer.apply(spots: [spot], redEyes: [], to: image)
        let cloned = RetouchRenderer.apply(spots: [{ var s = spot; s.kind = .clone; return s }()], redEyes: [], to: image)
        let inside = pixel(healed, 120, 150)[0], clonedInside = pixel(cloned, 120, 150)[0]
        #expect(clonedInside > 0.5, "a clone drags the bright source in: \(clonedInside)")
        #expect(abs(inside - 0.3) < 0.08, "a heal matches the dark surroundings: \(inside)")
    }

    @Test("Spots that are off, empty or outside the frame change nothing; the source may overhang the edge")
    func edges() {
        let image = photo()
        #expect(RetouchRenderer.apply(spots: [], redEyes: [], to: image) === image)
        var invisible = spot(kind: .clone, source: (200, 150))
        invisible.opacity = 0
        #expect(RetouchRenderer.apply(spots: [invisible], redEyes: [], to: image) === image)
        var outside = spot(kind: .clone, source: (200, 150))
        outside.center = .init(x: 3, y: 3)
        #expect(pixel(RetouchRenderer.apply(spots: [outside], redEyes: [], to: image), 120, 150)[0] < 0.2)
        var overhang = spot(kind: .clone, source: (-100, 150))
        overhang.source = .init(x: -0.25, y: 0.5)
        let result = RetouchRenderer.apply(spots: [overhang], redEyes: [], to: image)
        #expect(result.extent == image.extent && pixel(result, 120, 150)[3] == 1)
    }

    // MARK: Red eye

    @Test("Red eye turns a red pupil dark and neutral, only inside the eye")
    func redEye() {
        let width = Int(size.width), height = Int(size.height)
        var data = [Float](repeating: 0.6, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = ((height - 1 - y) * width + x) * 4
            data[i + 3] = 1
            if hypot(Double(x) - 200, Double(y) - 150) < 6 { data[i] = 0.9; data[i + 1] = 0.15; data[i + 2] = 0.15 }
        } }
        let image = CIImage(bitmapData: data.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16, size: size, format: .RGBAf, colorSpace: nil)
        let eye = PhotoAdjustments.RedEyeSpot(center: .init(x: 0.5, y: 0.5), radius: 8.0 / 400, strength: 1, darken: 0.5)
        let fixed = RetouchRenderer.apply(spots: [], redEyes: [eye], to: image)
        let center = pixel(fixed, 200, 150)
        #expect(center[0] < 0.3 && abs(center[0] - center[1]) < 0.1, "dark and not red: \(center)")
        #expect(pixel(fixed, 260, 150)[0] == pixel(image, 260, 150)[0], "the skin around is untouched")
        var weak = eye
        weak.strength = 0.3
        #expect(pixel(RetouchRenderer.apply(spots: [], redEyes: [weak], to: image), 200, 150)[0] > center[0])
    }

    @Test("Clicking near an eye finds the red blob; nothing red finds nothing")
    func findsEye() {
        let width = Int(size.width), height = Int(size.height)
        var data = [Float](repeating: 0.5, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = ((height - 1 - y) * width + x) * 4
            data[i + 3] = 1
            if hypot(Double(x) - 210, Double(y) - 160) < 7 { data[i] = 0.9; data[i + 1] = 0.1; data[i + 2] = 0.1 }
        } }
        let image = CIImage(bitmapData: data.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16, size: size, format: .RGBAf, colorSpace: nil)
        let found = RetouchRenderer.findRedEye(near: .init(x: 200 / 400, y: 150 / 300), in: image, context: context)
        #expect(found != nil)
        if let found {
            #expect(abs(found.center.x * 400 - 210) < 1.5 && abs(found.center.y * 300 - 160) < 1.5)
            #expect(found.radius * 400 > 5 && found.radius * 400 < 10)
        }
        #expect(RetouchRenderer.findRedEye(near: .init(x: 0.1, y: 0.1), in: image, context: context) == nil)
    }

    // MARK: Pipeline and model

    @Test("Spots and red eyes are applied to the decoded photo, before the other edits")
    func pipeline() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "a.jpg")
        try Fixtures.writeJPEG(to: url, width: 200, height: 150)
        let source = try #require(DevelopSource(url: url))
        var adjustments = PhotoAdjustments()
        adjustments.spots = [.init(kind: .clone, center: .init(x: 0.3, y: 0.5), source: .init(x: 0.7, y: 0.5), radius: 0.05)]
        adjustments.redEyes = [.init(center: .init(x: 0.6, y: 0.4), radius: 0.02)]
        adjustments.light.exposure = 0.3
        let image = source.image(with: adjustments, scale: 1)
        #expect(image.extent.size == CGSize(width: 200, height: 150))
        #expect(context.createCGImage(image, from: image.extent) != nil)
        var data = PhotoAdjustments(data: adjustments.encoded)
        #expect(data == adjustments)
        data.spots.removeAll()
        #expect(data != adjustments)
        let old = try JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{"light":{"exposure":0.2}}"#.utf8))
        #expect(old.spots.isEmpty && old.redEyes.isEmpty)
    }

    // MARK: Lightroom

    private func map(_ text: String, size: CGSize = CGSize(width: 6000, height: 4000)) throws -> (PhotoAdjustments, [LightroomDevelopMapper.Difference]) {
        var adjustments = PhotoAdjustments()
        let differences = LightroomDevelopMapper.apply(
            .init(settings: try #require(try LuaTableParser.parse(text).table), processVersion: "11.0", whiteBalance: nil, isRaw: true, imageSize: size),
            to: &adjustments)
        return (adjustments, differences)
    }

    @Test("Older spot data imports with its y axis flipped, its source, kind and opacity")
    func importsRetouchInfo() throws {
        let (adjustments, differences) = try map("""
            { RetouchInfo = {
                { centerX = 0.25, centerY = 0.4, opacity = 0.8, radius = 0.02, sourceState = "sourceUserSelected", sourceX = 0.35, sourceY = 0.45, spotType = "clone" },
                { centerX = 0.5, centerY = 0.5, opacity = 1, radius = 0.01, sourceState = "sourceAutoComputed", spotType = "heal" }, } }
            """)
        #expect(differences.isEmpty && adjustments.spots.count == 2)
        let clone = adjustments.spots[0]
        #expect(clone.kind == .clone && clone.opacity == 0.8 && clone.radius == 0.02)
        #expect(abs(clone.center.x - 0.25) < 1e-9 && abs(clone.center.y - 0.6) < 1e-9)
        #expect(abs(clone.source.x - 0.35) < 1e-9 && abs(clone.source.y - 0.55) < 1e-9)
        // No source given: beside the spot, inside the photo.
        let heal = adjustments.spots[1]
        #expect(heal.kind == .heal && heal.source.x > 0.5 && heal.source.x < 0.97 && heal.source.y == heal.center.y)
    }

    @Test("Newer spot areas import from their circle mask")
    func importsRetouchAreas() throws {
        let (adjustments, differences) = try map("""
            { RetouchAreas = { { Feather = 40, HealVersion = 2, Method = "gaussian", SpotType = "heal", SourceState = "sourceUserSelected",
                SourceX = 0.6, SourceY = 0.3, Opacity = 0.9,
                Masks = { { What = "Mask/CircleGradient", X = 0.4, Y = 0.2, SizeX = 0.01, SizeY = 0.015 }, }, }, } }
            """)
        #expect(differences.isEmpty)
        let spot = try #require(adjustments.spots.first)
        #expect(spot.kind == .heal && spot.feather == 0.4 && spot.opacity == 0.9)
        #expect(abs(spot.center.x - 0.4) < 1e-9 && abs(spot.center.y - 0.8) < 1e-9 && abs(spot.source.y - 0.7) < 1e-9)
        // Radius: the larger of the axes' sizes in pixels (0.015 × 4000 = 60) over the long edge (6000).
        #expect(abs(spot.radius - 0.01) < 1e-9)
    }

    @Test("Spot types PixelLoupe doesn't know are reported")
    func importsUnknownSpot() throws {
        let (adjustments, differences) = try map("""
            { RetouchInfo = { { centerX = 0.5, centerY = 0.5, radius = 0.01, spotType = "generative" }, } }
            """)
        #expect(adjustments.spots.isEmpty && differences == [LightroomDevelopMapper.aiRemove])
    }

    @Test("Red eyes import from the pupil ellipse")
    func importsRedEye() throws {
        let (adjustments, differences) = try map("""
            { RedEyeInfo = { { adaptivePupilColor = 1, pupilDarkenAmount = 0.7, pupilSize = 0.5, showPetEyeHighlight = 0,
                pupil = { density = 0.5, ellipse = { alpha = 0, centerX = 0.3, centerY = 0.35, sizeX = 0.01, sizeY = 0.015 }, redBias = 0.5, strength = 0.8 } }, } }
            """)
        #expect(differences.isEmpty)
        let eye = try #require(adjustments.redEyes.first)
        #expect(abs(eye.center.x - 0.3) < 1e-9 && abs(eye.center.y - 0.65) < 1e-9)
        #expect(abs(eye.radius - 0.01) < 1e-9 && eye.strength == 0.8 && eye.darken == 0.7)
        #expect(try map("{ RedEyeInfo = {  }, RetouchInfo = {  } }").0.isDefault)
    }
}

@Suite("Spot removal overlay and panel")
@MainActor
struct RetouchOverlayTests {
    private let window: NSWindow
    private let overlay: RetouchOverlayView
    private var placed: [PhotoAdjustments.UnitPoint] = []

    final class Log {
        var placed: [PhotoAdjustments.UnitPoint] = []
        var changes: [(spots: [PhotoAdjustments.Spot], eyes: [PhotoAdjustments.RedEyeSpot], isFinal: Bool, action: String)] = []
        var selected: [UUID?] = []
    }
    private let log = Log()

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
        overlay = RetouchOverlayView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        window.contentView?.addSubview(overlay)
        overlay.frameRect = CGRect(x: 10, y: 10, width: 400, height: 300)
        let log = log
        overlay.onPlace = { log.placed.append($0) }
        overlay.onSelect = { log.selected.append($0) }
        overlay.onChange = { log.changes.append(($0, $1, $2, $3)) }
    }

    private func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func spot() -> PhotoAdjustments.Spot {
        .init(kind: .clone, center: .init(x: 0.25, y: 0.5), source: .init(x: 0.75, y: 0.5), radius: 0.03)
    }

    @Test("A click on empty photo asks to place a spot there, in unit coordinates")
    func place() {
        overlay.mouseDown(with: event(.leftMouseDown, 210, 160))
        overlay.mouseUp(with: event(.leftMouseUp, 210, 160))
        let point = log.placed.first
        #expect(log.placed.count == 1 && abs(point!.x - 0.5) < 1e-9 && abs(point!.y - 0.5) < 1e-9)
        // Off the photo selects nothing.
        overlay.mouseDown(with: event(.leftMouseDown, 5, 5))
        #expect(log.placed.count == 1 && log.selected.last == .some(nil))
    }

    @Test("Dragging a spot's circle moves it; dragging its source moves only the source")
    func drag() {
        let spot = spot()
        overlay.spots = [spot]
        // The spot is at view (110, 160); its source at (310, 160).
        overlay.mouseDown(with: event(.leftMouseDown, 110, 160))
        overlay.mouseDragged(with: event(.leftMouseDragged, 150, 190))
        overlay.mouseUp(with: event(.leftMouseUp, 150, 190))
        #expect(log.selected.last == .some(spot.id))
        let moved = log.changes.last!.spots[0]
        #expect(abs(moved.center.x - 0.35) < 1e-9 && abs(moved.center.y - 0.6) < 1e-9 && moved.source == spot.source)
        #expect(log.changes.last!.isFinal && log.changes.first!.isFinal == false)

        overlay.spots = [spot]
        overlay.mouseDown(with: event(.leftMouseDown, 310, 160))
        overlay.mouseDragged(with: event(.leftMouseDragged, 290, 160))
        overlay.mouseUp(with: event(.leftMouseUp, 290, 160))
        let sourceMoved = log.changes.last!.spots[0]
        #expect(sourceMoved.center == spot.center && abs(sourceMoved.source.x - 0.7) < 1e-9)
    }

    @Test("A click without dragging only selects")
    func clickSelects() {
        overlay.spots = [spot()]
        overlay.mouseDown(with: event(.leftMouseDown, 110, 160))
        overlay.mouseUp(with: event(.leftMouseUp, 110, 160))
        #expect(log.changes.isEmpty && log.selected.last == .some(overlay.spots[0].id))
    }

    @Test("The panel keeps the placed items listed and deletes the selected one")
    func panel() {
        let panel = RetouchPanelViewController()
        _ = panel.view
        var results: [(Int, Int)] = []
        panel.onChange = { spots, eyes, _, _ in results.append((spots.count, eyes.count)) }
        let a = spot(), b = PhotoAdjustments.RedEyeSpot()
        panel.display(spots: [a], redEyes: [b], selecting: b.id)
        #expect(panel.selectedID == b.id)
        #expect(panel.deleteSelectedSpot() && results.last! == (1, 0) && panel.selectedID == nil)
        #expect(!panel.deleteSelectedSpot(), "nothing selected")
        panel.setMode(.clone)
        #expect(panel.mode == .clone)
    }

    @Test("Zoomed in, dragging off the spots pans; a click still places, and spots still drag (RAW-151)")
    func zoomedPan() {
        var pans: [CGVector] = []
        overlay.isZoomed = { true }
        overlay.onPan = { pans.append($0) }
        overlay.mouseDown(with: event(.leftMouseDown, 210, 160))
        overlay.mouseDragged(with: event(.leftMouseDragged, 220, 150))
        overlay.mouseDragged(with: event(.leftMouseDragged, 230, 145))
        overlay.mouseUp(with: event(.leftMouseUp, 230, 145))
        #expect(pans == [CGVector(dx: 10, dy: -10), CGVector(dx: 10, dy: -5)])
        #expect(log.placed.isEmpty && log.changes.isEmpty)

        overlay.mouseDown(with: event(.leftMouseDown, 210, 160))
        overlay.mouseDragged(with: event(.leftMouseDragged, 211, 160))
        overlay.mouseUp(with: event(.leftMouseUp, 211, 160))
        #expect(pans.count == 2 && log.placed.count == 1)

        overlay.spots = [spot()]
        overlay.mouseDown(with: event(.leftMouseDown, 110, 160))
        overlay.mouseDragged(with: event(.leftMouseDragged, 150, 190))
        overlay.mouseUp(with: event(.leftMouseUp, 150, 190))
        #expect(pans.count == 2 && log.changes.last?.action == "Move Spot")
    }

    @Test("Without a zoom, dragging off the spots doesn't pan")
    func fitDoesNotPan() {
        var pans = 0
        overlay.onPan = { _ in pans += 1 }
        overlay.mouseDown(with: event(.leftMouseDown, 210, 160))
        overlay.mouseDragged(with: event(.leftMouseDragged, 260, 160))
        overlay.mouseUp(with: event(.leftMouseUp, 260, 160))
        #expect(pans == 0 && log.placed.count == 1)
    }

    @Test("Each spot's row has a button that deletes it, at the right edge of the list (RAW-151)")
    func rowDeleteButton() throws {
        let panel = RetouchPanelViewController()
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = panel.view
        let a = spot(), b = spot(), eye = PhotoAdjustments.RedEyeSpot()
        panel.display(spots: [a, b], redEyes: [eye], selecting: a.id)
        window.layoutIfNeeded()
        window.setContentSize(NSSize(width: 340, height: 700))
        window.layoutIfNeeded()

        var sent: (spots: [PhotoAdjustments.Spot], eyes: [PhotoAdjustments.RedEyeSpot], action: String)?
        panel.onChange = { spots, eyes, isFinal, action in
            sent = (spots, eyes, action)
            #expect(isFinal)
        }
        let table = try #require(subview("spotList", of: NSTableView.self, in: panel.view))
        let row = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        let delete = try #require(subview("deleteSpot.1", of: NSButton.self, in: row))
        #expect(delete.accessibilityLabel() == "Delete Clone 2")
        let list = try #require(table.enclosingScrollView)
        let frame = delete.convert(delete.bounds, to: list)
        #expect(list.bounds.contains(frame) && frame.maxX > list.bounds.maxX - 30, "button \(frame) list \(list.bounds)")

        delete.performClick(nil)
        #expect(sent?.spots.map(\.id) == [a.id] && sent?.eyes.map(\.id) == [eye.id] && sent?.action == "Delete Spot")
        #expect(panel.selectedID == a.id, "deleting another row leaves the selection alone")

        let eyeRow = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        try #require(subview("deleteSpot.1", of: NSButton.self, in: eyeRow)).performClick(nil)
        #expect(sent?.spots.map(\.id) == [a.id] && sent?.eyes.isEmpty == true)
    }

    private func subview<View: NSView>(_ identifier: String, of type: View.Type, in view: NSView) -> View? {
        if let view = view as? View, view.accessibilityIdentifier() == identifier { return view }
        return view.subviews.lazy.compactMap { self.subview(identifier, of: type, in: $0) }.first
    }
}
