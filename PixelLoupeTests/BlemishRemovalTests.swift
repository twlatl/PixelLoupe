import AppKit
import Foundation
import os
import Testing
@testable import PixelLoupe

/// Blemish Removal (RAW-311): finding marks on skin, what's removed, the cache, and putting marks back.
@MainActor
@Suite("Blemish Removal (RAW-311)", .serialized)
struct BlemishRemovalTests {
    // MARK: - Made-up skin

    nonisolated private struct Spot {
        var x: Double, y: Double, radius: Double
        var color: (Float, Float, Float)
    }

    /// Even skin with a little texture, and soft-edged spots on it (pixels from the bottom left).
    private func skin(_ spots: [Spot], width: Int = 400, height: Int = 400, offset: Int = 0) -> BlemishDetector.Image {
        var pixels = [Float](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let noise = Float((x * 7919 + y * 104_729) % 13) / 13 * 0.01
                var color: [Float] = [0.82 + noise, 0.64 + noise, 0.54 + noise]
                for spot in spots {
                    let distance = hypot(Double(x + offset) + 0.5 - spot.x, Double(y) + 0.5 - spot.y)
                    let cover = Float(min(1, max(0, spot.radius + 1 - distance) / 2))
                    color[0] += (spot.color.0 - color[0]) * cover
                    color[1] += (spot.color.1 - color[1]) * cover
                    color[2] += (spot.color.2 - color[2]) * cover
                }
                for c in 0..<3 { pixels[(y * width + x) * 3 + c] = color[c] }
            }
        }
        return .init(width: width, height: height, pixels: pixels)
    }

    private static let red: (Float, Float, Float) = (0.72, 0.38, 0.34)
    private static let brown: (Float, Float, Float) = (0.56, 0.43, 0.36)
    private let sizes = BlemishDetector.Sizes(minimum: 2, maximum: 14)

    private func near(_ mark: BlemishDetector.Mark, _ spot: Spot) -> Bool {
        hypot(Double(mark.center.x) - spot.x, Double(mark.center.y) - spot.y) < 3
    }

    // MARK: - Finding

    @Test("Red spots on skin are found, with no face, and removed by default; flat skin has none")
    func findsSpots() {
        let spots = [Spot(x: 120, y: 130, radius: 6, color: Self.red), Spot(x: 270, y: 250, radius: 4, color: Self.red)]
        let marks = BlemishDetector.find(in: skin(spots), sizes: sizes)
        for spot in spots {
            let mark = marks.first { near($0, spot) }
            #expect(mark != nil && mark!.blemish >= 0.5 && mark!.natural < 0.5)
            if let mark { #expect(mark.radius >= spot.radius && mark.radius < spot.radius * 2.5, "covers it: \(mark.radius)") }
        }
        #expect(marks.count == 2)
        #expect(BlemishDetector.find(in: skin([]), sizes: sizes).isEmpty)
    }

    @Test("A round brown mark counts as natural, so it stays by default")
    func brownIsNatural() throws {
        let spot = Spot(x: 200, y: 200, radius: 6, color: Self.brown)
        let mark = try #require(BlemishDetector.find(in: skin([spot]), sizes: sizes).first { near($0, spot) })
        #expect(mark.natural >= 0.5 && mark.natural > mark.blemish, "natural \(mark.natural), blemish \(mark.blemish)")
    }

    @Test("What's left out (eyes, lips) isn't looked at, and neither are big patches")
    func leavesOut() {
        let lips = Spot(x: 120, y: 130, radius: 6, color: Self.red), pimple = Spot(x: 270, y: 250, radius: 6, color: Self.red)
        let box: [CGPoint] = [.init(x: 95, y: 105), .init(x: 145, y: 105), .init(x: 145, y: 155), .init(x: 95, y: 155)]
        let allowed = BlemishStore.excluding([(box, 4)], width: 400, height: 400)
        #expect(!allowed[130 * 400 + 120] && allowed[250 * 400 + 270] && allowed[(400 - 130) * 400 + 120], "rows from the bottom")
        let marks = BlemishDetector.find(in: skin([lips, pimple]), allowed: allowed, sizes: sizes)
        #expect(marks.count == 1 && near(marks[0], pimple))
        let patch = Spot(x: 200, y: 200, radius: 60, color: Self.red)
        #expect(!BlemishDetector.find(in: skin([patch]), sizes: sizes).contains { near($0, patch) })
    }

    @Test("A mark beside dark hair is left; the same mark away from it is found")
    func leavesMarksAtHair() {
        let spot = Spot(x: 200, y: 200, radius: 5, color: Self.red)
        let hair: [Spot] = stride(from: 100.0, through: 300, by: 4).map { Spot(x: $0, y: 178, radius: 9, color: (0.12, 0.08, 0.06)) }
        #expect(BlemishDetector.find(in: skin([spot]), sizes: sizes).contains { near($0, spot) })
        #expect(!BlemishDetector.find(in: skin([spot] + hair), sizes: sizes).contains { near($0, spot) })
    }

    @Test("The same marks get the same ids, again and from a slightly moved crop")
    func stableIDs() throws {
        let spot = Spot(x: 200.3, y: 200, radius: 6, color: Self.red)
        func id(offset: Int) throws -> UInt64 {
            let mark = try #require(BlemishDetector.find(in: skin([spot], offset: offset), sizes: sizes).first)
            // Where it is in a 4000-pixel frame.
            return BlemishCandidate.id(center: CGPoint(x: (mark.center.x + CGFloat(offset) + 1000) / 4000, y: (mark.center.y + 1000) / 4000), radius: mark.radius / 4000)
        }
        #expect(try id(offset: 0) == id(offset: 0))
        #expect(try id(offset: 0) == id(offset: 3))
        #expect(BlemishCandidate.id(center: .init(x: 0.3, y: 0.3), radius: 0.01) != BlemishCandidate.id(center: .init(x: 0.31, y: 0.3), radius: 0.01))
    }

    // MARK: - Settings

    private func candidate(_ id: UInt64, x: Double = 0.5, y: Double = 0.5, size: Double = 0.05, blemish: Double = 0.8, natural: Double = 0) -> BlemishCandidate {
        let matte = PhotoAdjustments.ObjectMatte(box: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size), width: 8, height: 8,
                                                 coverage: [UInt8](repeating: 255, count: 64))
        return BlemishCandidate(id: id, center: .init(x: x, y: y), radius: size / 2, matte: matte, blemish: blemish, natural: natural)
    }

    @Test("What's removed follows the thresholds and what was put back; ids that match nothing are ignored")
    func selection() {
        var setting = PhotoAdjustments.BlemishRemoval(isEnabled: true)
        let marks = [candidate(1), candidate(2, blemish: 0.4), candidate(3, natural: 0.7)]
        #expect(marks.filter(setting.removes).map(\.id) == [1])
        setting.excluded = [1, 99]
        #expect(setting.spots(for: marks).isEmpty && setting.selects(marks[0]))
        setting.naturalMarks = 0.8
        setting.blemishes = 0.7
        #expect(marks.filter(setting.removes).map(\.id) == [2, 3])
        #expect(setting.excluded == [1, 99])
        setting.blemishes = 0
        #expect(!marks.contains(where: setting.selects))
        let spot = marks[0].spot
        #expect(spot.kind == .remove && spot.id == candidate(1).spot.id && spot.seed == candidate(1).spot.seed && spot.id != marks[1].spot.id)
    }

    @Test("It's saved with the photo, and settings saved before it decode with it off")
    func codable() throws {
        var adjustments = PhotoAdjustments()
        adjustments.blemishRemoval = .init(isEnabled: true, blemishes: 0.3, naturalMarks: 0.1, excluded: [7, .max])
        let data = try JSONEncoder().encode(adjustments)
        #expect(try JSONDecoder().decode(PhotoAdjustments.self, from: data) == adjustments)
        var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old["blemishRemoval"] = nil
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.blemishRemoval == .init() && !decoded.blemishRemoval.isEnabled)
        let partial = try JSONDecoder().decode(PhotoAdjustments.BlemishRemoval.self, from: Data(#"{"isEnabled":true}"#.utf8))
        #expect(partial == .init(isEnabled: true))
    }

    // MARK: - The store

    @Test("Marks are found once, kept on disk, and found again only when the geometry changes")
    func store() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "IMG.jpg")
        try Fixtures.writeJPEG(to: url, width: 300, height: 200)
        let source = try #require(DevelopSource(url: url))
        let mark = candidate(5)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let store = BlemishStore(directory: directory.url.appending(path: "Blemishes")) { _ in
            calls.withLock { $0 += 1 }
            return [mark]
        }
        var adjustments = PhotoAdjustments()
        #expect(store.knownCandidates(for: source, adjustments: adjustments) == nil)
        #expect(store.candidates(for: source, adjustments: adjustments, waiting: true) == [mark])
        adjustments.light.exposure = 1
        adjustments.blemishRemoval.blemishes = 1
        #expect(store.knownCandidates(for: source, adjustments: adjustments) == [mark])
        _ = store.candidates(for: source, adjustments: adjustments, waiting: true)
        #expect(calls.withLock { $0 } == 1)
        let reread = BlemishStore(directory: store.directory) { _ in nil }
        #expect(reread.candidates(for: source, adjustments: adjustments, waiting: true) == [mark])
        adjustments.orientation.quarterTurns = 1
        _ = store.candidates(for: source, adjustments: adjustments, waiting: true)
        #expect(calls.withLock { $0 } == 2)
        let request = SubjectMatteStore.Request(source: source, adjustments: adjustments)
        #expect(BlemishStore.key(request).hasSuffix("-blemishes-\(BlemishDetector.version)"))

        // Couldn't look: not kept, so it's tried again.
        let failing = BlemishStore(directory: directory.url.appending(path: "None")) { _ in
            calls.withLock { $0 += 1 }
            return nil
        }
        for _ in 0..<2 { #expect(failing.candidates(for: source, adjustments: adjustments, waiting: true) == nil) }
        #expect(calls.withLock { $0 } == 4)
    }

    @Test("A render off the main thread fills what's removed, and leaves what was put back")
    func rendersFills() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "IMG.png")
        // Gray with a red square in the middle.
        let context = try #require(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.7, green: 0.7, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 147, y: 97, width: 6, height: 6))
        let image = try #require(context.makeImage())
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)

        let mark = candidate(5, size: 0.06)
        let blemishes = BlemishStore(directory: directory.url.appending(path: "Blemishes")) { _ in [mark] }
        let fills = RemoveFillStore(directory: directory.url.appending(path: "Fills"))
        func redness(_ setting: PhotoAdjustments.BlemishRemoval) async -> Float? {
            var adjustments = PhotoAdjustments()
            adjustments.blemishRemoval = setting
            let edited = adjustments
            return await Task.detached { () -> Float? in
                guard let source = DevelopSource(url: url) else { return nil }
                source.blemishes = blemishes
                source.removeFills = fills
                let image = source.image(with: edited, scale: 1)
                var data = [Float](repeating: 0, count: 4)
                CIContext().render(image, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1),
                                   format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                return data[0] - data[1]
            }.value
        }
        let off = try #require(await redness(.init()))
        let on = try #require(await redness(.init(isEnabled: true)))
        let putBack = try #require(await redness(.init(isEnabled: true, excluded: [5])))
        #expect(off > 0.5 && on < 0.1 && abs(putBack - off) < 0.01, "off \(off), on \(on), put back \(putBack)")
    }

    // MARK: - Putting marks back

    private func overlay() -> RemoveOverlayView {
        let overlay = RemoveOverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        overlay.previewFrame = PreviewFrame(rect: CGRect(x: 0, y: 0, width: 400, height: 300))
        return overlay
    }

    private func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat = 150) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func mark(_ id: UInt64, size: Double = 0.1, excluded: Bool = false) throws -> RemoveOverlayView.BlemishMark {
        .init(id: id, area: try #require(candidate(id, size: size).spot.area), isExcluded: excluded)
    }

    @Test("A click on a mark toggles it (the smallest, when they overlap); a drag paints, and a pin wins")
    func clicks() throws {
        let overlay = overlay()
        overlay.blemishMarks = [try mark(1, size: 0.05), try mark(2, size: 0.3)]
        var toggled: [UInt64] = [], strokes = 0, selected: [UUID?] = []
        overlay.onToggleBlemish = { toggled.append($0) }
        overlay.onStroke = { _ in strokes += 1 }
        overlay.onSelect = { selected.append($0) }
        func click(_ x: CGFloat) {
            overlay.mouseDown(with: mouse(.leftMouseDown, x))
            overlay.mouseUp(with: mouse(.leftMouseUp, x))
        }
        click(200)
        click(240)
        #expect(toggled == [1, 2] && strokes == 0)
        #expect(overlay.cursor(at: CGPoint(x: 200, y: 150)) == .pointingHand && overlay.cursor(at: CGPoint(x: 40, y: 150)) == .crosshair)
        click(40)
        #expect(strokes == 1)
        overlay.mouseDown(with: mouse(.leftMouseDown, 200))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, 230))
        overlay.mouseUp(with: mouse(.leftMouseUp, 260))
        #expect(strokes == 2 && toggled.count == 2)

        var spot = PhotoAdjustments.Spot()
        spot.center = .init(x: 0.5, y: 0.5)
        overlay.spots = [spot]
        click(200)
        #expect(toggled.count == 2 && selected == [spot.id])
        overlay.spots = []
        overlay.toolOverlay = .never
        click(200)
        overlay.toolOverlay = .always
        overlay.mode = .heal
        click(200)
        #expect(toggled.count == 2, "hidden, or not Remove")
    }

    @Test("A mark put back is drawn dashed: some of its outline, not all")
    func dashes() throws {
        func drawn(excluded: Bool) throws -> Int {
            let overlay = overlay()
            overlay.blemishMarks = [try mark(1, size: 0.3, excluded: excluded)]
            let rep = try #require(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
            overlay.cacheDisplay(in: overlay.bounds, to: rep)
            var count = 0
            for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.6 { count += 1 } }
            return count
        }
        let solid = try drawn(excluded: false), dashed = try drawn(excluded: true)
        #expect(solid > 100 && Double(dashed) > Double(solid) * 0.3 && Double(dashed) < Double(solid) * 0.7, "solid \(solid), dashed \(dashed)")
    }

    @Test("Apply, putting a mark back and Reset are each one undo step")
    func undo() async throws {
        let directory = try TemporaryDirectory()
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
        defer { controller.close() }
        controller.showWindow(nil)
        controller.state.selectedPhotoIDs = [try #require(controller.state.photoOrder.first)]
        controller.state.mode = .develop
        #expect(controller.perform(.removeTool))
        let develop = controller.rootViewController.main.develop
        let start = Date()
        while !develop.hasDrawnPhoto, Date().timeIntervalSince(start) < 30 { try await Task.sleep(for: .milliseconds(50)) }
        let panel = develop.removePanelForTesting, overlay = develop.removeOverlayForTesting
        let undo = try #require(store.viewContext.undoManager)

        // Outside an event the undo manager doesn't close a group per action: group by hand, as each click is in the app.
        // First close the group opening the window left open, or every step would be inside it.
        store.viewContext.processPendingChanges()
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.removeAllActions()
        undo.groupsByEvent = false
        func step(_ action: () -> Void) {
            undo.beginUndoGrouping()
            action()
            store.viewContext.processPendingChanges()
            undo.endUndoGrouping()
        }
        let apply = try #require(panel.view.descendants.first { $0.accessibilityIdentifier() == "removeBlemishApply" } as? NSSwitch)
        step { apply.performClick(nil) }
        #expect(photo.adjustments.blemishRemoval.isEnabled && undo.undoActionName == "Blemish Removal")
        step { overlay.onToggleBlemish?(42) }
        #expect(photo.adjustments.blemishRemoval.excluded == [42] && undo.undoActionName == "Exclude Blemish")
        step { overlay.onToggleBlemish?(42) }
        #expect(photo.adjustments.blemishRemoval.excluded.isEmpty && undo.undoActionName == "Include Blemish")
        step { overlay.onToggleBlemish?(42) }
        step { panel.onReset?() }
        #expect(photo.adjustments.blemishRemoval == .init())
        for expected: PhotoAdjustments.BlemishRemoval in [
            .init(isEnabled: true, excluded: [42]), .init(isEnabled: true), .init(isEnabled: true, excluded: [42]), .init(isEnabled: true), .init(),
        ] {
            undo.undo()
            #expect(photo.adjustments.blemishRemoval == expected)
        }
    }
}
