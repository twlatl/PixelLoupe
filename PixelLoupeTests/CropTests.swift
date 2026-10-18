import AppKit
import CoreData
import CoreImage
import Testing
@testable import PixelLoupe

@Suite("Crop settings")
struct CropSettingsTests {
    @Test func olderSavedSettingsStillLoad() throws {
        // Saved before crop existed: no "crop" key, and only some sections.
        let json = #"{"light":{"isEnabled":true,"exposure":0.8,"brilliance":0,"highlights":0,"shadows":0,"brightness":0,"contrast":0,"blackPoint":0}}"#
        let adjustments = PhotoAdjustments(data: Data(json.utf8))
        #expect(adjustments.light.exposure == 0.8, "existing edits are kept")
        #expect(adjustments.crop == PhotoAdjustments.Crop())
        #expect(adjustments.vignette == PhotoAdjustments.Vignette())
    }

    @Test func cropRoundTrips() throws {
        var adjustments = PhotoAdjustments()
        adjustments.crop = .init(angle: -3.5, rect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6),
                                 aspect: .ratio(width: 7, height: 5), isAspectLocked: true, constrainToImage: false)
        #expect(adjustments.crop.isActive)
        #expect(PhotoAdjustments(data: adjustments.encoded) == adjustments)
    }

    @Test func aspectMenuMatchesLightroom() {
        let titles = CropAspect.menu.map { $0?.title ?? "—" }
        #expect(titles == ["As Shot", "Original", "Custom", "—", "1 x 1", "4 x 5  /  8 x 10", "8.5 x 11", "5 x 7",
                           "2 x 3  /  4 x 6", "—", "4 x 3", "16 x 9", "16 x 10", "—"])
        let size = CGSize(width: 6000, height: 4000)
        #expect(CropAspect.original.landscapeRatio(imageSize: size) == 1.5)
        #expect(CropAspect.custom.landscapeRatio(imageSize: size) == nil)
        #expect(CropAspect.ratio(width: 16, height: 9).landscapeRatio(imageSize: size) == 16.0 / 9)
        #expect(CropAspect.ratio(width: 11, height: 8.5).landscapeRatio(imageSize: size) == 11 / 8.5)
    }
}

@Suite("Crop geometry")
struct CropGeometryTests {
    let size = CGSize(width: 6000, height: 4000)

    @Test func insidePhotoAfterRotation() {
        #expect(CropGeometry.isInsidePhoto(CropGeometry.fullRect, angle: 0, imageSize: size))
        #expect(!CropGeometry.isInsidePhoto(CropGeometry.fullRect, angle: 5, imageSize: size), "rotated corners are empty")
        #expect(CropGeometry.isInsidePhoto(CGPoint(x: 0.5, y: 0.5), angle: 30, imageSize: size))
    }

    @Test(arguments: [-45.0, -10, -1, 2, 15, 45])
    func fittingKeepsTheCropInsideAndItsAspect(angle: Double) {
        let rect = CropGeometry.fit(CropGeometry.fullRect, angle: angle, imageSize: size)
        #expect(CropGeometry.isInsidePhoto(rect, angle: angle, imageSize: size))
        #expect(abs(rect.width - rect.height) < 0.0001, "unit aspect (the photo's) is kept")
        #expect(abs(rect.midX - 0.5) < 0.0001 && abs(rect.midY - 0.5) < 0.0001)
        #expect(rect.width > 0.3)
    }

    @Test func largestRectForARatio() {
        let square = CropGeometry.largestRect(ratio: 1, portrait: false, angle: 0, imageSize: size)
        #expect(abs(square.width * size.width - square.height * size.height) < 1, "1 x 1 in pixels")
        #expect(abs(square.height - 1) < 0.0001, "as tall as the photo")
        let portrait = CropGeometry.largestRect(ratio: 1.5, portrait: true, angle: 0, imageSize: size)
        #expect(CropGeometry.isPortrait(portrait, imageSize: size))
        #expect(abs(portrait.height * size.height / (portrait.width * size.width) - 1.5) < 0.001)
    }

    @Test func constrainingKeepsTheAnchor() {
        let rect = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.3)
        let constrained = CropGeometry.constrain(rect, toPixelRatio: 1, imageSize: size, anchor: CGPoint(x: rect.maxX, y: rect.maxY))
        #expect(abs(constrained.width * size.width - constrained.height * size.height) < 1)
        #expect(abs(constrained.maxX - rect.maxX) < 0.0001 && abs(constrained.maxY - rect.maxY) < 0.0001)
    }

    @Test func straighteningLevelsLines() throws {
        // A line rising 10° needs a 10° clockwise turn (negative).
        let rising = try #require(CropGeometry.straighteningAngle(from: .zero, to: CGPoint(x: cos(0.1745) * 100, y: sin(0.1745) * 100)))
        #expect(abs(rising + 10) < 0.05)
        // A nearly vertical line leaning 5° right of vertical is made vertical.
        let vertical = try #require(CropGeometry.straighteningAngle(from: .zero, to: CGPoint(x: sin(0.0873) * 100, y: cos(0.0873) * 100)))
        #expect(abs(vertical - 5) < 0.05)
        #expect(CropGeometry.straighteningAngle(from: .zero, to: CGPoint(x: 0.5, y: 0)) == nil, "too short")
    }
}

@Suite("Crop rendering")
struct CropRenderingTests {
    private let frame = CGRect(x: 0, y: 0, width: 600, height: 400)
    private var image: CIImage { CIImage(color: CIColor(red: 0.2, green: 0.6, blue: 0.9)).cropped(to: frame) }
    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    @Test func cropsToTheRectangle() {
        var crop = PhotoAdjustments.Crop()
        crop.rect = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5)
        let output = CropRenderer.apply(crop, to: image, frame: frame, rendering: .cropped)
        #expect(output.extent == CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    @Test func straightenedCropHasNoEmptyCorners() {
        var crop = PhotoAdjustments.Crop()
        crop.angle = 12
        crop.rect = CropGeometry.fit(crop.rect, angle: crop.angle, imageSize: frame.size)
        let output = CropRenderer.apply(crop, to: image, frame: frame, rendering: .cropped)
        for corner in [CGPoint(x: 1, y: 1), CGPoint(x: output.extent.maxX - 2, y: output.extent.maxY - 2)] {
            var pixel = [Float](repeating: 0, count: 4)
            context.render(output, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(origin: corner, size: CGSize(width: 1, height: 1)),
                           format: .RGBAf, colorSpace: nil)
            #expect(pixel[3] > 0.99, "corner \(corner) shows photo")
        }
    }

    @Test func straightenedOnlyShowsTheWholeRotatedPhoto() {
        var crop = PhotoAdjustments.Crop()
        crop.angle = 20
        crop.rect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let output = CropRenderer.apply(crop, to: image, frame: frame, rendering: .straightenedOnly)
        #expect(output.extent.width > frame.width && output.extent.height > frame.height)
        #expect(abs(output.extent.midX - frame.midX) < 0.5 && abs(output.extent.midY - frame.midY) < 0.5)
    }
}

@Suite("Crop tool")
struct CropToolTests {
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

    @Test func cropKeysFollowLightroom() async throws {
        let controller = CatalogWindowController(store: store)
        defer { controller.close() }
        controller.showWindow(nil)
        let state = controller.state
        state.photoOrder = ids
        state.selectedPhotoIDs = [ids[0]]

        #expect(controller.perform(.cropTool), "R from Library opens Develop's crop tool")
        #expect(state.mode == .develop && state.developTool == .crop)

        // Wait for the photo to decode, then flip to portrait with X.
        let develop = try #require(controller.window?.contentView?.descendants.compactMap { $0 as? CropOverlayView }.first)
        for _ in 0..<50 where develop.imageSize.width < 10 {
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(controller.perform(.flag(.rejected)), "X flips the crop instead of rejecting")
        let photo = try #require(try store.viewContext.existingObject(with: ids[0]) as? Photo)
        #expect(photo.photoFlag == .unflagged)

        #expect(controller.perform(.exit), "Esc cancels")
        #expect(state.developTool == .adjust)
        #expect(photo.adjustments.crop == PhotoAdjustments.Crop(), "nothing was saved")

        #expect(controller.perform(.cropTool))
        #expect(controller.perform(.flag(.rejected)))
        #expect(controller.perform(.toggleEnlarge), "Return applies")
        #expect(state.developTool == .adjust)
        #expect(photo.adjustments.crop.isActive, "the crop was saved")
        #expect(CropGeometry.isPortrait(photo.adjustments.crop.rect, imageSize: CGSize(width: 600, height: 400)))
        #expect(store.viewContext.undoManager?.undoActionName == "Crop & Straighten")
    }
}

@Suite("Auto straighten")
struct AutoStraightenTests {
    /// Sky over ground with the horizon rising `tilt` degrees left to right.
    private func scene(tilt: Double) -> CIImage {
        let size = CGSize(width: 1200, height: 800)
        let sky = CIImage(color: CIColor(red: 0.55, green: 0.75, blue: 0.95)).cropped(to: CGRect(origin: .zero, size: size))
        let ground = CIImage(color: CIColor(red: 0.35, green: 0.3, blue: 0.2))
            .cropped(to: CGRect(x: -800, y: -2000, width: 2800, height: 2400))
            .transformed(by: CGAffineTransform(translationX: 600, y: 400).rotated(by: tilt * .pi / 180).translatedBy(x: -600, y: -400))
        return ground.composited(over: sky).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Regression: Vision's angle must level the horizon, not double its tilt.
    @Test(arguments: [8.0, -6.0])
    func visionLevelsATiltedHorizon(tilt: Double) throws {
        let angle = try #require(HorizonDetector.visionHorizonAngle(scene(tilt: tilt)))
        #expect(abs(angle + tilt) < 0.5, "a horizon rising \(tilt)° needs \(-tilt)°, got \(angle)°")
    }

    /// Auto levels a (softened, like a real photo) horizon whichever detector answers.
    @Test(arguments: [3.0, -4.0])
    func autoLevelsATiltedHorizon(tilt: Double) async throws {
        let image = scene(tilt: tilt).clampedToExtent().applyingGaussianBlur(sigma: 1).cropped(to: scene(tilt: tilt).extent)
        let angle = try #require(await HorizonDetector.straighteningAngle(for: .init(image: image)))
        #expect(abs(angle + tilt) < 0.5, "a horizon rising \(tilt)° needs \(-tilt)°, got \(angle)°")
    }
}

@Suite("Cropped render resolution")
struct CroppedResolutionTests {
    /// Regression: renders sized from the uncropped photo came out too small after cropping.
    @Test func renderScaleAccountsForTheCrop() throws {
        let directory = try TemporaryDirectory()
        let url = try Fixtures.writeJPEG(to: directory.url.appending(path: "a.jpg"), width: 2000, height: 1000)
        let source = try #require(DevelopSource(url: url))
        var adjustments = PhotoAdjustments()
        adjustments.crop.rect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

        #expect(source.croppedSize(adjustments) == CGSize(width: 1000, height: 500))
        let scale = source.scale(toFit: 768, adjustments: adjustments)
        let image = source.image(with: adjustments, scale: scale)
        #expect(abs(max(image.extent.width, image.extent.height) - 768) <= 1, "the cropped photo fills 768 pixels")
        #expect(source.scale(toFit: 4000, adjustments: adjustments) == 1, "never upscales")
    }
}

@Suite("Rotate and flip")
struct OrientationTests {
    private let red = CIColor(red: 1, green: 0, blue: 0), blue = CIColor(red: 0, green: 0, blue: 1)
    /// 300 × 200, red on the left third, blue elsewhere.
    private var image: CIImage {
        CIImage(color: red).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 200))
            .composited(over: CIImage(color: blue).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200)))
    }
    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    private func isRed(_ image: CIImage, at point: CGPoint) -> Bool {
        var pixel = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                       format: .RGBAf, colorSpace: nil)
        return pixel[0] > 0.9
    }

    private func oriented(_ changes: [PhotoAdjustments.OrientationChange]) -> PhotoAdjustments {
        var adjustments = PhotoAdjustments()
        changes.forEach { adjustments.apply($0) }
        return adjustments
    }

    @Test func rotatingSwapsDimensionsAndTurnsTheRightWay() {
        let left = DevelopSource.orient(image, oriented([.rotateLeft]).orientation)
        #expect(left.extent == CGRect(x: 0, y: 0, width: 200, height: 300))
        #expect(isRed(left, at: CGPoint(x: 100, y: 10)), "counterclockwise: the left edge ends up at the bottom")
        let right = DevelopSource.orient(image, oriented([.rotateRight]).orientation)
        #expect(isRed(right, at: CGPoint(x: 100, y: 290)), "clockwise: the left edge ends up at the top")
    }

    @Test func flipping() {
        let horizontal = DevelopSource.orient(image, oriented([.flipHorizontal]).orientation)
        #expect(horizontal.extent.size == CGSize(width: 300, height: 200))
        #expect(isRed(horizontal, at: CGPoint(x: 290, y: 100)) && !isRed(horizontal, at: CGPoint(x: 10, y: 100)))
        let vertical = DevelopSource.orient(image, oriented([.flipVertical]).orientation)
        #expect(isRed(vertical, at: CGPoint(x: 10, y: 100)), "a vertical flip keeps left on the left")
    }

    @Test(arguments: [
        [PhotoAdjustments.OrientationChange.rotateLeft, .rotateRight],
        [.rotateLeft, .rotateLeft, .rotateLeft, .rotateLeft],
        [.flipHorizontal, .flipHorizontal],
        [.flipVertical, .flipVertical],
        [.flipHorizontal, .flipVertical, .rotateLeft, .rotateLeft],
    ])
    func inversesReturnToTheOriginal(changes: [PhotoAdjustments.OrientationChange]) {
        var adjustments = PhotoAdjustments()
        adjustments.crop.rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        adjustments.crop.angle = 5
        let original = adjustments
        changes.forEach { adjustments.apply($0) }
        #expect(adjustments.orientation.isIdentity)
        #expect(abs(adjustments.crop.rect.minX - 0.1) < 1e-9 && abs(adjustments.crop.rect.minY - 0.2) < 1e-9)
        #expect(adjustments.crop.angle == original.crop.angle)
    }

    @Test func theCropTurnsWithThePhoto() {
        // Crop the red third, then rotate left: the crop must still frame the red area.
        var adjustments = PhotoAdjustments()
        adjustments.crop.rect = CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1)
        adjustments.apply(.rotateLeft)
        let base = DevelopSource.orient(image, adjustments.orientation)
        let cropped = CropRenderer.apply(adjustments.crop, to: base, frame: base.extent, rendering: .cropped)
        #expect(cropped.extent.size == CGSize(width: 200, height: 100))
        #expect(isRed(cropped, at: CGPoint(x: 100, y: 50)))
    }

    @Test func resetReturnsCropAndPhoto() {
        var adjustments = PhotoAdjustments()
        adjustments.crop.rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        [.rotateRight, .flipHorizontal, .rotateRight, .flipVertical].forEach { adjustments.apply($0) }
        adjustments.resetOrientation()
        #expect(adjustments.orientation.isIdentity)
        #expect(abs(adjustments.crop.rect.minX - 0.1) < 1e-9 && abs(adjustments.crop.rect.width - 0.3) < 1e-9)
    }
}

@Suite("Auto straighten without a horizon")
struct EdgeStraightenTests {
    /// An "interior": a wall with door-frame verticals, a dado rail and a floor line, rotated by `tilt`.
    private func room(tilt: Double) -> CIImage {
        let size = CGRect(x: 0, y: 0, width: 1200, height: 800)
        var scene = CIImage(color: CIColor(red: 0.85, green: 0.82, blue: 0.75)).cropped(to: size.insetBy(dx: -600, dy: -600))
        let dark = CIColor(red: 0.25, green: 0.2, blue: 0.15)
        for x in [250.0, 330, 820, 900] {
            scene = CIImage(color: dark).cropped(to: CGRect(x: x, y: -600, width: 14, height: 2000)).composited(over: scene)
        }
        for y in [260.0, 520] {
            scene = CIImage(color: dark).cropped(to: CGRect(x: -600, y: y, width: 2400, height: 10)).composited(over: scene)
        }
        scene = CIImage(color: CIColor(red: 0.55, green: 0.35, blue: 0.2)).cropped(to: CGRect(x: -600, y: -600, width: 2400, height: 760))
            .composited(over: scene)
        let rotate = CGAffineTransform(translationX: 600, y: 400).rotated(by: tilt * .pi / 180).translatedBy(x: -600, y: -400)
        // Soften edges by about a pixel, as any lens and sensor do. Core Image draws these shapes
        // without anti-aliasing, and a hard edge at a small tilt becomes long pixel runs no real
        // photo has.
        return scene.clampedToExtent().applyingGaussianBlur(sigma: 1).cropped(to: scene.extent)
            .transformed(by: rotate).cropped(to: size)
    }

    @Test(arguments: [3.0, -5.5, 12.0])
    func levelsByStraightEdges(tilt: Double) throws {
        let angle = try #require(HorizonDetector.edgeAngle(room(tilt: tilt)))
        #expect(abs(angle + tilt) < 0.3, "tilted \(tilt)°, needs \(-tilt)°, got \(angle)°")
    }

    @Test func autoUsesEdgesWhenThereIsNoHorizon() async throws {
        let angle = try #require(await HorizonDetector.straighteningAngle(for: .init(image: room(tilt: 4))))
        #expect(abs(angle + 4) < 0.5)
    }

    @Test func aLevelPhotoNeedsNoRotation() throws {
        let angle = try #require(HorizonDetector.edgeAngle(room(tilt: 0)))
        #expect(abs(angle) < 0.1)
    }

    /// Regression: paving, crowds and foliage — many short edges at every angle — outvoted a
    /// photo's few long lines (a gateway canopy over a brick plaza), so Auto gave up.
    @Test(arguments: [2.0, -1.0])
    func longLinesOutweighBusyTexture(tilt: Double) throws {
        let size = CGRect(x: 0, y: 0, width: 1200, height: 800)
        var scene = CIImage(color: CIColor(red: 0.8, green: 0.85, blue: 0.9)).cropped(to: size.insetBy(dx: -600, dy: -600))
        let dark = CIColor(red: 0.2, green: 0.3, blue: 0.35)
        scene = CIImage(color: dark).cropped(to: CGRect(x: -600, y: 420, width: 2400, height: 40)).composited(over: scene)
        // "Paving": 600 short marks at random angles, seeded so the test is repeatable.
        var seed: UInt64 = 42
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let brick = CIColor(red: 0.45, green: 0.25, blue: 0.2)
        for _ in 0..<600 {
            let x = random() * 1600 - 200, y = random() * 380 - 100, angle = random() * .pi
            let mark = CIImage(color: brick).cropped(to: CGRect(x: -12, y: -3, width: 24, height: 6))
                .transformed(by: CGAffineTransform(translationX: x, y: y).rotated(by: angle))
            scene = mark.composited(over: scene)
        }
        let rotate = CGAffineTransform(translationX: 600, y: 400).rotated(by: tilt * .pi / 180).translatedBy(x: -600, y: -400)
        let image = scene.clampedToExtent().applyingGaussianBlur(sigma: 1).cropped(to: scene.extent)
            .transformed(by: rotate).cropped(to: size)
        let angle = try #require(HorizonDetector.edgeAngle(image))
        #expect(abs(angle + tilt) < 0.3, "tilted \(tilt)°, needs \(-tilt)°, got \(angle)°")
    }

    @Test func aFeaturelessPhotoHasNothingToLevel() {
        let flat = CIImage(color: CIColor(red: 0.5, green: 0.6, blue: 0.7)).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(HorizonDetector.edgeAngle(flat) == nil)
    }
}

/// RAW-54: a preset crop fills the photo's height (or width), so it already touches two edges.
@Suite("Crop overlay dragging")
@MainActor
struct CropOverlayDragTests {
    private struct Setup {
        let window: NSWindow
        let overlay: CropOverlayView
        var crops: [PhotoAdjustments.Crop] = []
    }

    /// A 6000 × 4000 photo shown at 600 × 400 points, with a crop of `aspect`.
    private func overlay(aspect: CropAspect, rect: CGRect? = nil) -> (NSWindow, CropOverlayView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let overlay = CropOverlayView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        window.contentView = overlay
        let size = CGSize(width: 6000, height: 4000)
        overlay.frameRect = CGRect(x: 50, y: 50, width: 600, height: 400)
        overlay.imageSize = size
        var crop = PhotoAdjustments.Crop()
        crop.aspect = aspect
        crop.isAspectLocked = aspect != .custom
        crop.rect = rect ?? CropGeometry.largestRect(ratio: aspect.landscapeRatio(imageSize: size), portrait: false, angle: 0, imageSize: size)
        overlay.crop = crop
        overlay.onChange = { [weak overlay] crop, _ in overlay?.crop = crop }
        return (window, overlay)
    }

    private func drag(_ overlay: CropOverlayView, in window: NSWindow, from start: CGPoint, to end: CGPoint) {
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        overlay.mouseDown(with: event(.leftMouseDown, start))
        for step in 1...4 {
            let t = CGFloat(step) / 4
            overlay.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)))
        }
        overlay.mouseUp(with: event(.leftMouseUp, end))
    }

    @Test(arguments: [CropAspect.ratio(width: 1, height: 1), .ratio(width: 5, height: 4), .ratio(width: 7, height: 5), .ratio(width: 16, height: 9)])
    func aPresetCropMovesAlongTheEdgesItTouches(aspect: CropAspect) throws {
        let (window, overlay) = overlay(aspect: aspect)
        let start = overlay.crop.rect
        let center = CGPoint(x: overlay.cropRectInView.midX, y: overlay.cropRectInView.midY)
        // A slightly diagonal drag, as a hand makes: the vertical part can't happen, the horizontal part must.
        drag(overlay, in: window, from: center, to: CGPoint(x: center.x - 30, y: center.y + 12))
        let moved = overlay.crop.rect
        if start.height >= 0.999 {
            #expect(moved.minX < start.minX - 0.01, "moved left: \(start) → \(moved)")
            #expect(moved.minY == 0 && moved.height == start.height)
        } else {
            #expect(moved.minY > start.minY + 0.01, "moved up: \(start) → \(moved)")
            #expect(moved.minX == 0 && moved.width == start.width)
        }
        #expect(moved.size == start.size, "moving doesn't resize")
    }

    @Test func aMoveStopsExactlyAtTheEdge() throws {
        let (window, overlay) = overlay(aspect: .ratio(width: 1, height: 1))
        let center = CGPoint(x: overlay.cropRectInView.midX, y: overlay.cropRectInView.midY)
        drag(overlay, in: window, from: center, to: CGPoint(x: center.x - 500, y: center.y - 40))
        #expect(overlay.crop.rect.minX == 0 && overlay.crop.rect.minY == 0)
    }

    @Test func aFreeCropTouchingAnEdgeStillResizesTheOtherWay() throws {
        // Custom, touching the bottom edge: drag the bottom-right corner right and down.
        let (window, overlay) = overlay(aspect: .custom, rect: CGRect(x: 0.2, y: 0, width: 0.4, height: 0.5))
        let corner = CGPoint(x: overlay.cropRectInView.maxX, y: overlay.cropRectInView.minY)
        drag(overlay, in: window, from: corner, to: CGPoint(x: corner.x + 60, y: corner.y - 30))
        #expect(overlay.crop.rect.maxX > 0.69, "the right side followed: \(overlay.crop.rect)")
        #expect(abs(overlay.crop.rect.minY) < 0.001)
    }

    @Test func aCustomCropAwayFromTheEdgesMovesFreely() throws {
        let (window, overlay) = overlay(aspect: .custom, rect: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4))
        let center = CGPoint(x: overlay.cropRectInView.midX, y: overlay.cropRectInView.midY)
        drag(overlay, in: window, from: center, to: CGPoint(x: center.x + 60, y: center.y + 40))
        #expect(abs(overlay.crop.rect.minX - 0.3) < 0.001 && abs(overlay.crop.rect.minY - 0.3) < 0.001)
    }
}
