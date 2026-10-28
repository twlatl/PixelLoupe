import AppKit
import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

/// Masking and Spot Removal show the photo cropped and straightened, like every tool but Crop, while masks and
/// spots stay placed on the whole frame (RAW-202).
@MainActor
@Suite("Masking and Spot Removal show the crop (RAW-202)")
struct CropInMaskingTests {
    private let frameSize = CGSize(width: 400, height: 300)
    private var crop: PhotoAdjustments.Crop {
        var crop = PhotoAdjustments.Crop()
        crop.angle = 8
        crop.rect = CGRect(x: 0.3, y: 0.2, width: 0.5, height: 0.6)
        return crop
    }

    @Test("The preview frame puts a frame point where the cropped, straightened render shows it")
    func frameMatchesTheRender() throws {
        let extent = CGRect(origin: .zero, size: frameSize)
        let dot = CGPoint(x: 260, y: 90)
        let frameImage = CIImage(color: .white).cropped(to: CGRect(x: dot.x - 2, y: dot.y - 2, width: 4, height: 4))
            .composited(over: CIImage(color: .black).cropped(to: extent))
        let rendered = CropRenderer.apply(crop, to: frameImage, frame: extent, rendering: .cropped)

        // Where the dot lands in the render: the brightness-weighted center of its pixels.
        let width = Int(rendered.extent.width), height = Int(rendered.extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        context.render(rendered, toBitmap: &pixels, rowBytes: width * 16, bounds: rendered.extent, format: .RGBAf, colorSpace: nil)
        var weight = 0.0, sumX = 0.0, sumY = 0.0
        for row in 0..<height {
            for column in 0..<width {
                let value = Double(pixels[(row * width + column) * 4])
                weight += value
                sumX += value * (Double(column) + 0.5)
                sumY += value * (Double(height - row) - 0.5)   // Bitmap rows run top to bottom.
            }
        }
        try #require(weight > 0, "the dot is inside the crop")

        let shown = CGRect(x: 10, y: 20, width: rendered.extent.width, height: rendered.extent.height)
        let frame = PreviewFrame.cropped(shown: shown, crop: crop, frameSize: frameSize)
        let view = frame.viewPoint(dot)
        #expect(abs(view.x - (shown.minX + sumX / weight)) < 1.5 && abs(view.y - (shown.minY + sumY / weight)) < 1.5)
        #expect(frame.angle == 8 && frame.visible == shown)
        #expect(frame.rect.width > shown.width && frame.rect.height > shown.height, "the whole frame reaches past the crop")

        let back = frame.framePoint(view)
        #expect(abs(back.x - dot.x) < 1e-6 && abs(back.y - dot.y) < 1e-6)
    }

    @Test("An uncropped photo's frame is the photo shown")
    func uncropped() {
        let shown = CGRect(x: 10, y: 20, width: 400, height: 300)
        #expect(PreviewFrame.cropped(shown: shown, crop: .init(), frameSize: frameSize) == PreviewFrame(rect: shown))
        #expect(PreviewFrame(rect: shown).viewPoint(CGPoint(x: 5, y: 7)) == CGPoint(x: 15, y: 27))
    }

    /// The frame for the crop shown filling a 200 × 180 pt rect at (20, 20), and a window and overlay to click in.
    private func setUp<Overlay: NSView>(_ overlay: Overlay) -> (window: NSWindow, frame: PreviewFrame) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        overlay.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        window.contentView?.addSubview(overlay)
        let frame = PreviewFrame.cropped(shown: CGRect(x: 120, y: 100, width: 200, height: 180), crop: crop, frameSize: frameSize)
        return (window, frame)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func unit(_ point: CGPoint, _ frame: PreviewFrame) -> CGPoint {
        let inFrame = frame.framePoint(point)
        return CGPoint(x: inFrame.x / frame.rect.width, y: inFrame.y / frame.rect.height)
    }

    @Test("A brush stroke on a cropped photo lands where it was painted on the whole frame")
    func brushOnCroppedPhoto() throws {
        let overlay = MaskOverlayView()
        let (window, frame) = setUp(overlay)
        overlay.previewFrame = frame
        var mask = PhotoAdjustments.LocalAdjustment()
        mask.components = [.init(shape: .brush(.init()))]
        overlay.adjustment = mask
        var painted: PhotoAdjustments.LocalAdjustment?
        var clickedEmpty = 0
        overlay.onChange = { adjustment, _, _ in painted = adjustment }
        overlay.onClickEmpty = { clickedEmpty += 1 }

        let point = CGPoint(x: 170, y: 150)
        overlay.mouseDown(with: event(.leftMouseDown, at: point, in: window))
        overlay.mouseUp(with: event(.leftMouseUp, at: point, in: window))
        guard case .brush(let brush)? = painted?.components.first?.shape, let start = brush.strokes.first?.points.first else {
            Issue.record("no stroke"); return
        }
        // Strokes are stored rounded to 1e-5.
        let expected = unit(point, frame)
        #expect(abs(start.x - expected.x) < 1e-5 && abs(start.y - expected.y) < 1e-5)
        #expect(clickedEmpty == 0)

        // In the matte around the crop (but on the frame), no stroke starts.
        painted = nil
        overlay.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 110, y: 150), in: window))
        #expect(painted == nil && clickedEmpty == 1)
    }

    @Test("A gradient's handle past the crop can still be dragged, through the straightening")
    func handlePastTheCrop() throws {
        let overlay = MaskOverlayView()
        let (window, frame) = setUp(overlay)
        overlay.previewFrame = frame
        // A radial gradient centered off the crop, to the left of it.
        var mask = PhotoAdjustments.LocalAdjustment()
        let ellipse = PhotoAdjustments.RadialGradient(center: .init(x: 0.15, y: 0.5), radiusX: 0.05, radiusY: 0.05)
        mask.components = [.init(shape: .radial(ellipse))]
        overlay.adjustment = mask
        var moved: PhotoAdjustments.LocalAdjustment?
        overlay.onChange = { adjustment, _, _ in moved = adjustment }

        let center = frame.viewPoint(CGPoint(x: 0.15 * frame.rect.width, y: 0.5 * frame.rect.height))
        #expect(!frame.visible.contains(center), "the handle is outside the crop")
        let target = CGPoint(x: center.x + 20, y: center.y)
        overlay.mouseDown(with: event(.leftMouseDown, at: center, in: window))
        overlay.mouseDragged(with: event(.leftMouseDragged, at: target, in: window))
        overlay.mouseUp(with: event(.leftMouseUp, at: target, in: window))
        guard case .radial(let dragged)? = moved?.components.first?.shape else { Issue.record("not dragged"); return }
        let expected = unit(target, frame)
        #expect(abs(dragged.center.x - expected.x) < 1e-3 && abs(dragged.center.y - expected.y) < 1e-3)
    }

    @Test("A spot placed on a cropped photo lands on the whole frame; the matte places nothing")
    func spotOnCroppedPhoto() {
        let overlay = RetouchOverlayView()
        let (window, frame) = setUp(overlay)
        overlay.previewFrame = frame
        var placed: [PhotoAdjustments.UnitPoint] = []
        var deselected = 0
        overlay.onPlace = { placed.append($0) }
        overlay.onSelect = { if $0 == nil { deselected += 1 } }

        let point = CGPoint(x: 250, y: 200)
        overlay.mouseDown(with: event(.leftMouseDown, at: point, in: window))
        overlay.mouseUp(with: event(.leftMouseUp, at: point, in: window))
        let expected = unit(point, frame)
        #expect(placed.count == 1 && abs(placed[0].x - expected.x) < 1e-9 && abs(placed[0].y - expected.y) < 1e-9)

        overlay.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 110, y: 150), in: window))
        #expect(placed.count == 1 && deselected == 1)
    }

    @Test("Dragging a spot on a straightened crop moves it with the pointer")
    func dragSpotThroughTheAngle() {
        let overlay = RetouchOverlayView()
        let (window, frame) = setUp(overlay)
        overlay.previewFrame = frame
        let spot = PhotoAdjustments.Spot(kind: .heal, center: .init(x: 0.55, y: 0.5), source: .init(x: 0.6, y: 0.5), radius: 0.03)
        overlay.spots = [spot]
        var moved: [PhotoAdjustments.Spot] = []
        overlay.onChange = { spots, _, _, _ in moved = spots }

        let start = frame.viewPoint(CGPoint(x: 0.55 * frame.rect.width, y: 0.5 * frame.rect.height))
        let end = CGPoint(x: start.x + 15, y: start.y + 10)
        overlay.mouseDown(with: event(.leftMouseDown, at: start, in: window))
        overlay.mouseDragged(with: event(.leftMouseDragged, at: end, in: window))
        overlay.mouseUp(with: event(.leftMouseUp, at: end, in: window))
        let expected = unit(end, frame)
        #expect(abs((moved.first?.center.x ?? 0) - expected.x) < 1e-6 && abs((moved.first?.center.y ?? 0) - expected.y) < 1e-6)
    }
}

/// In the catalog window: Masking and Spot Removal draw the photo cropped and straightened.
@MainActor
@Suite("Develop shows the crop in Masking and Spot Removal (RAW-202)", .serialized)
struct DevelopCropInMaskingTests {
    private func find<View: NSView>(_ id: String, _ type: View.Type, in view: NSView) -> View? {
        if let view = view as? View, view.accessibilityIdentifier() == id { return view }
        return view.subviews.lazy.compactMap { self.find(id, type, in: $0) }.first
    }

    @Test("Masking and Spot Removal show the crop; only the Crop tool shows the whole frame")
    func toolsShowTheCrop() async throws {
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
        var adjustments = PhotoAdjustments()
        adjustments.crop.angle = 5
        adjustments.crop.rect = CGRect(x: 0.4, y: 0.3, width: 0.5, height: 0.5)
        photo.adjustments = adjustments
        try store.viewContext.save()

        let controller = CatalogWindowController(store: store)
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        controller.state.selectedPhotoIDs = [try #require(controller.state.photoOrder.first)]
        controller.state.mode = .develop
        controller.state.developTool = .mask
        let develop = controller.rootViewController.main.develop
        let start = Date()
        while !develop.hasDrawnPhoto, Date().timeIntervalSince(start) < 30 { try await Task.sleep(for: .milliseconds(50)) }
        let content = try #require(window.contentView)
        /// Waits for the next draw.
        func redraw() async throws { try await Task.sleep(for: .milliseconds(250)) }
        try await redraw()

        let masks = try #require(find("maskOverlay", MaskOverlayView.self, in: content))
        let frame = masks.previewFrame
        #expect(frame.angle == 5, "straightened")
        #expect(abs(frame.rect.width - frame.visible.width * 2) < 2 && abs(frame.rect.height - frame.visible.height * 2) < 2,
                "the whole frame is twice the crop shown")
        // The crop's left edge is 40% of the way across the frame.
        #expect(abs(frame.visible.minX - frame.rect.minX - frame.rect.width * 0.4) < 2)
        #expect(abs(frame.visible.width / frame.visible.height - 1.5) < 0.02, "the crop's shape: half of a 600 × 400 frame each way")

        controller.state.developTool = .retouch
        try await redraw()
        let spots = try #require(find("retouchOverlay", RetouchOverlayView.self, in: content))
        #expect(spots.previewFrame.angle == 5 && abs(spots.previewFrame.visible.width - frame.visible.width) < 1)
    }
}
