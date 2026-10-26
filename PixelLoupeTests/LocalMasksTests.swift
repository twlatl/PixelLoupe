import AppKit
import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Local adjustments: linear and radial masks")
struct LocalMasksTests {
    private typealias Local = PhotoAdjustments.LocalAdjustment
    private typealias Component = PhotoAdjustments.MaskComponent

    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let extent = CGRect(x: 0, y: 0, width: 200, height: 100)

    private func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> [Float] {
        var data = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return data
    }

    private func gray(_ level: Double = 0.4) -> CIImage {
        CIImage(color: CIColor(red: level, green: level, blue: level)).cropped(to: extent)
    }

    private func linear(from zero: (Double, Double), to full: (Double, Double), mode: Component.Mode = .add, inverted: Bool = false) -> Component {
        .init(shape: .linear(.init(zero: .init(x: zero.0, y: zero.1), full: .init(x: full.0, y: full.1))), mode: mode, isInverted: inverted)
    }

    private func radial(center: (Double, Double) = (0.5, 0.5), radius: (Double, Double) = (0.25, 0.4), angle: Double = 0, feather: Double = 0.5,
                        mode: Component.Mode = .add, inverted: Bool = false) -> Component {
        .init(shape: .radial(.init(center: .init(x: center.0, y: center.1), radiusX: radius.0, radiusY: radius.1, angle: angle, feather: feather)),
              mode: mode, isInverted: inverted)
    }

    private func local(_ components: [Component], exposure: Double = 1, amount: Double = 1) -> Local {
        var local = Local()
        local.components = components
        local.settings.exposure = exposure
        local.amount = amount
        return local
    }

    private func maskValue(_ mask: Local, _ x: Int, _ y: Int) -> Float {
        pixel(LocalAdjustmentRenderer.mask(for: mask, extent: extent)!, x, y)[0]
    }

    // MARK: Model

    @Test("Masks are inactive until they have a shape and a slider; decoding is tolerant")
    func model() throws {
        #expect(!Local().isActive)
        #expect(!local([linear(from: (0, 1), to: (0, 0))], exposure: 0).isActive)
        #expect(local([linear(from: (0, 1), to: (0, 0))]).isActive)
        var off = local([linear(from: (0, 1), to: (0, 0))])
        off.isEnabled = false
        #expect(!off.isActive)
        var adjustments = PhotoAdjustments()
        adjustments.masks = [local([linear(from: (0.5, 1), to: (0.5, 0.2)), radial(mode: .subtract, inverted: true)], exposure: -0.7)]
        let data = try #require(adjustments.encoded)
        #expect(PhotoAdjustments(data: data) == adjustments)
        let old = try JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{"light":{"exposure":0.2}}"#.utf8))
        #expect(old.masks.isEmpty)
        let partial = try JSONDecoder().decode(Local.self, from: Data(#"{"name":"Sky"}"#.utf8))
        #expect(partial.name == "Sky" && partial.amount == 1 && partial.components.isEmpty)
    }

    // MARK: Mask rendering

    @Test("A linear gradient is nothing at its start, full at its end, and ramps between")
    func linearMask() {
        // Zero at the bottom (y = 0), full at the top (y = 1) of the frame.
        let mask = local([linear(from: (0.5, 0), to: (0.5, 1))])
        #expect(maskValue(mask, 100, 1) < 0.05)
        #expect(abs(maskValue(mask, 100, 50) - 0.5) < 0.03)
        #expect(maskValue(mask, 100, 98) > 0.95)
        // Beyond the ends it holds.
        let short = local([linear(from: (0.5, 0.4), to: (0.5, 0.6))])
        #expect(maskValue(short, 100, 5) < 0.01 && maskValue(short, 100, 95) > 0.99)
        // A degenerate gradient makes no mask.
        #expect(LocalAdjustmentRenderer.mask(for: local([linear(from: (0.5, 0.5), to: (0.5, 0.5))]), extent: extent) == nil)
    }

    @Test("A radial gradient is full inside, fades over its feather and is nothing outside")
    func radialMask() {
        // Center (100, 50), radii 50 × 40 px; a feather of 0.5 starts fading at half the radius.
        let mask = local([radial(feather: 0.5)])
        #expect(maskValue(mask, 100, 50) > 0.99)
        #expect(maskValue(mask, 100 + 20, 50) > 0.99, "inside the core")
        let edge = maskValue(mask, 100 + 38, 50)
        #expect(edge > 0.1 && edge < 0.9, "in the fade: \(edge)")
        #expect(maskValue(mask, 100 + 60, 50) < 0.01 && maskValue(mask, 100, 50 + 45) < 0.01, "outside")
        // The ellipse is taller than wide: 25 px up is still well inside, 45 px across is in the fade.
        #expect(maskValue(mask, 100, 50 + 25) > 0.5 && maskValue(mask, 100 + 45, 50) < 0.5)
        // Feather 0 is a hard edge.
        let hard = local([radial(feather: 0)])
        #expect(maskValue(hard, 100 + 45, 50) > 0.99 && maskValue(hard, 100 + 55, 50) < 0.01)
    }

    @Test("Turning an ellipse moves its long side")
    func radialAngle() {
        let long = local([radial(radius: (0.4, 0.1), angle: 90, feather: 0)])
        // 80 × 10 px of radius turned a quarter: now tall instead of wide.
        #expect(maskValue(long, 100, 50 + 60) < 0.01 || maskValue(long, 100, 50 + 35) > 0.99)
        #expect(maskValue(long, 100 + 60, 50) < 0.01)
    }

    @Test("Components add, subtract and intersect; invert flips; amount scales")
    func combining() {
        let left = linear(from: (0.52, 0.5), to: (0.48, 0.5), mode: .add)        // full on the left half
        let bottom = linear(from: (0.5, 0.52), to: (0.5, 0.48), mode: .add)      // full on the bottom half
        let sum = local([left, bottom])
        #expect(maskValue(sum, 20, 20) > 0.99 && maskValue(sum, 180, 20) > 0.99 && maskValue(sum, 20, 80) > 0.99)
        #expect(maskValue(sum, 180, 80) < 0.01, "neither")
        var both = bottom
        both.mode = .intersect
        let intersection = local([left, both])
        #expect(maskValue(intersection, 20, 20) > 0.99 && maskValue(intersection, 180, 20) < 0.01 && maskValue(intersection, 20, 80) < 0.01)
        var without = bottom
        without.mode = .subtract
        let difference = local([left, without])
        #expect(maskValue(difference, 20, 80) > 0.99 && maskValue(difference, 20, 20) < 0.01)
        // Inverted: the right half.
        var flipped = left
        flipped.isInverted = true
        #expect(maskValue(local([flipped]), 180, 50) > 0.99 && maskValue(local([flipped]), 20, 50) < 0.01)
        // Amount.
        #expect(abs(maskValue(local([left], amount: 0.4), 20, 50) - 0.4) < 0.01)
    }

    // MARK: Applying

    @Test("A mask brightens only where it is")
    func appliesWhereMasked() {
        let bright = LocalAdjustmentRenderer.apply([local([linear(from: (0.5, 0.1), to: (0.5, 0.9), inverted: false)], exposure: 1)], to: gray(0.25))
        let bottom = pixel(bright, 100, 3)[0], top = pixel(bright, 100, 96)[0]
        #expect(abs(bottom - 0.25) < 0.01, "untouched where the mask is nothing")
        #expect(top > 0.45, "a stop brighter where it is full: \(top)")
        // Darker with negative exposure, and the amount tones it down.
        let dark = LocalAdjustmentRenderer.apply([local([linear(from: (0.5, 0.1), to: (0.5, 0.9))], exposure: -1)], to: gray(0.5))
        #expect(pixel(dark, 100, 96)[0] < 0.35)
        let half = LocalAdjustmentRenderer.apply([local([linear(from: (0.5, 0.1), to: (0.5, 0.9))], exposure: 1, amount: 0.5)], to: gray(0.25))
        #expect(pixel(half, 100, 96)[0] < top && pixel(half, 100, 96)[0] > 0.25)
        // No masks: the image comes back.
        let image = gray()
        #expect(LocalAdjustmentRenderer.apply([], to: image) == image)
        var disabled = local([linear(from: (0.5, 0), to: (0.5, 1))])
        disabled.isEnabled = false
        #expect(LocalAdjustmentRenderer.apply([disabled], to: image) == image)
    }

    @Test("Each local slider changes the image the way its global one does")
    func localSliders() {
        let base = CIImage(color: CIColor(red: 0.6, green: 0.45, blue: 0.3)).cropped(to: extent)
        func change(_ configure: (inout PhotoAdjustments.LocalSettings) -> Void) -> [Float] {
            var settings = PhotoAdjustments.LocalSettings()
            configure(&settings)
            return pixel(LocalAdjustmentRenderer.adjust(base, with: settings), 100, 50)
        }
        let plain = pixel(base, 100, 50)
        #expect(change { $0.exposure = 1 }[0] > plain[0])
        #expect(change { $0.saturation = -1 }.prefix(3).max()! - change { $0.saturation = -1 }.prefix(3).min()! < 0.02)
        #expect(change { $0.temperature = 1 }[0] > plain[0] && change { $0.temperature = 1 }[2] < plain[2], "warmer")
        #expect(change { $0.tint = 1 }[1] < plain[1], "magenta lowers green")
        #expect(change { $0.contrast = 1 }[0] > plain[0], "above the middle gets lighter")
        #expect(change { $0.shadows = 1 }.count == 4)
        #expect(change { $0.whites = 1 }[0] >= plain[0])
    }

    @Test("Masks apply in the full pipeline, before the crop moves the frame")
    func pipeline() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "a.jpg")
        try Fixtures.writeJPEG(to: url, width: 200, height: 150)
        let source = try #require(DevelopSource(url: url))
        var plain = PhotoAdjustments()
        plain.crop.rect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        var masked = plain
        masked.masks = [local([linear(from: (0.5, 0.5), to: (0.5, 1))], exposure: -3)]
        let a = source.image(with: plain, scale: 1), b = source.image(with: masked, scale: 1)
        #expect(a.extent == b.extent)
        // The mask's far end (the top of the frame) is cropped away, so the top of the crop is only
        // partly darkened and the bottom of the crop (at the mask's start) is untouched.
        #expect(pixel(b, Int(b.extent.midX), 2)[0] == pixel(a, Int(a.extent.midX), 2)[0])
        #expect(pixel(b, Int(b.extent.midX), Int(b.extent.height) - 3)[0] < pixel(a, Int(a.extent.midX), Int(a.extent.height) - 3)[0])
    }

    // MARK: Lightroom

    private func map(_ text: String) throws -> (PhotoAdjustments, [LightroomDevelopMapper.Difference]) {
        var adjustments = PhotoAdjustments()
        let differences = LightroomDevelopMapper.apply(
            .init(settings: try #require(try LuaTableParser.parse(text).table), processVersion: "11.0", whiteBalance: nil, isRaw: true),
            to: &adjustments)
        return (adjustments, differences)
    }

    @Test("A legacy graduated filter imports with its y axis flipped")
    func importsGradient() throws {
        let (adjustments, differences) = try map("""
            { GradientBasedCorrections = { { CorrectionActive = true, CorrectionAmount = 0.8, CorrectionName = "Sky",
              CorrectionMasks = { { What = "Mask/Gradient", ZeroX = 0.5, ZeroY = 0.6, FullX = 0.5, FullY = 0.1 }, },
              LocalExposure2012 = -0.9, LocalContrast2012 = 25, LocalTemperature = -30, LocalSaturation = 10 }, }, }
            """)
        #expect(differences.isEmpty)
        let mask = try #require(adjustments.masks.first)
        #expect(mask.name == "Sky" && mask.amount == 0.8 && mask.isEnabled)
        #expect(mask.components == [.init(shape: .linear(.init(zero: .init(x: 0.5, y: 0.4), full: .init(x: 0.5, y: 0.9))))])
        #expect(mask.settings.exposure == -0.9 && mask.settings.contrast == 0.25 && mask.settings.temperature == -0.3 && mask.settings.saturation == 0.1)
    }

    @Test("A radial filter imports as an ellipse; the older one acts outside unless flipped")
    func importsRadial() throws {
        let legacy = try map("""
            { CircularGradientBasedCorrections = { { CorrectionAmount = 1, CorrectionMasks = { { What = "Mask/CircularGradient",
              Top = 0.2, Left = 0.3, Bottom = 0.6, Right = 0.7, Angle = 30, Feather = 80, Flipped = false }, }, LocalShadows2012 = 40 }, }, }
            """).0.masks[0]
        guard case .radial(let ellipse) = legacy.components[0].shape else { Issue.record("not radial"); return }
        #expect(abs(ellipse.center.x - 0.5) < 1e-9 && abs(ellipse.center.y - 0.6) < 1e-9)
        #expect(abs(ellipse.radiusX - 0.2) < 1e-9 && abs(ellipse.radiusY - 0.2) < 1e-9 && ellipse.angle == -30 && abs(ellipse.feather - 0.8) < 1e-9)
        #expect(legacy.components[0].isInverted, "not flipped: the effect is outside")
        let flipped = try map("""
            { CircularGradientBasedCorrections = { { CorrectionMasks = { { What = "Mask/CircularGradient",
              Top = 0.2, Left = 0.3, Bottom = 0.6, Right = 0.7, Flipped = true }, }, LocalShadows2012 = 40 }, }, }
            """).0.masks[0]
        #expect(!flipped.components[0].isInverted)
        // In the newer masking, the effect is inside unless the mask is inverted.
        let modern = try map("""
            { MaskGroupBasedCorrections = { { CorrectionMasks = { { What = "Mask/CircularGradient", MaskInverted = true,
              Top = 0.2, Left = 0.3, Bottom = 0.6, Right = 0.7 }, }, LocalShadows2012 = 40 }, }, }
            """).0.masks[0]
        #expect(modern.components[0].isInverted)
    }

    @Test("Several masks in a correction combine by blend mode")
    func importsBlendModes() throws {
        let mask = try map("""
            { MaskGroupBasedCorrections = { { CorrectionMasks = {
                { What = "Mask/Gradient", ZeroX = 0.5, ZeroY = 1, FullX = 0.5, FullY = 0, MaskBlendMode = 0 },
                { What = "Mask/CircularGradient", Top = 0.4, Left = 0.4, Bottom = 0.6, Right = 0.6, MaskBlendMode = 1 },
                { What = "Mask/Gradient", ZeroX = 0, ZeroY = 0.5, FullX = 1, FullY = 0.5, MaskBlendMode = 2, MaskInverted = true }, },
              LocalExposure2012 = 0.5 }, }, }
            """).0.masks[0]
        #expect(mask.components.map(\.mode) == [.add, .subtract, .intersect])
        #expect(mask.components[2].isInverted)
    }

    @Test("Brush, AI and range masks are reported, and a correction with one is not half-imported")
    func unsupportedMasks() throws {
        let brush = try map(#"{ PaintBasedCorrections = { { CorrectionMasks = { { What = "Mask/Paint" }, }, LocalExposure2012 = 1 }, }, }"#)
        #expect(brush.0.masks.isEmpty && brush.1 == [LightroomDevelopMapper.brushMasks])
        let mixed = try map("""
            { MaskGroupBasedCorrections = {
                { CorrectionMasks = { { What = "Mask/Gradient", ZeroX = 0.5, ZeroY = 1, FullX = 0.5, FullY = 0 }, { What = "Mask/Image", MaskSubCategoryID = 50004 }, }, LocalExposure2012 = 1 },
                { CorrectionMasks = { { What = "Mask/Gradient", ZeroX = 0.5, ZeroY = 1, FullX = 0.5, FullY = 0 }, }, LocalExposure2012 = 0.5 },
                { CorrectionMasks = { { What = "Mask/RangeMask" }, }, LocalExposure2012 = 0.5 }, }, }
            """)
        #expect(mixed.0.masks.count == 1 && mixed.0.masks[0].settings.exposure == 0.5)
        #expect(Set(mixed.1.map(\.key)) == ["masks-ai", "masks-range"])
        // Local settings PixelLoupe lacks are noted, and a correction with only those is skipped.
        let sharpen = try map("""
            { GradientBasedCorrections = { { CorrectionMasks = { { What = "Mask/Gradient", ZeroX = 0.5, ZeroY = 1, FullX = 0.5, FullY = 0 }, },
              LocalSharpness = 40 }, }, }
            """)
        #expect(sharpen.0.masks.isEmpty && sharpen.1 == [LightroomDevelopMapper.localSettings])
    }
}

@Suite("Mask handles and shortcuts")
struct MaskHandleTests {
    private let frame = CGSize(width: 400, height: 200)

    @Test("The linear gradient's lines are grabbed at their ends and the band moves as a whole")
    func linearHandles() {
        let gradient = PhotoAdjustments.LinearGradient(zero: .init(x: 0.5, y: 0.3), full: .init(x: 0.5, y: 0.8))
        // Pixels: zero line at y = 60, full line at y = 160.
        #expect(MaskGeometry.linearHandle(at: CGPoint(x: 50, y: 62), gradient: gradient, frame: frame, tolerance: 10) == .zero)
        #expect(MaskGeometry.linearHandle(at: CGPoint(x: 350, y: 158), gradient: gradient, frame: frame, tolerance: 10) == .full)
        #expect(MaskGeometry.linearHandle(at: CGPoint(x: 200, y: 110), gradient: gradient, frame: frame, tolerance: 10) == .move)
        #expect(MaskGeometry.linearHandle(at: CGPoint(x: 200, y: 10), gradient: gradient, frame: frame, tolerance: 10) == nil)
        // Dragging a line changes one end; the band moves both.
        let fuller = MaskGeometry.dragLinear(.full, gradient: gradient, by: CGPoint(x: 0, y: -20), frame: frame)
        #expect(fuller.zero == gradient.zero && abs(fuller.full.y - 0.7) < 1e-9)
        let moved = MaskGeometry.dragLinear(.move, gradient: gradient, by: CGPoint(x: 40, y: 20), frame: frame)
        #expect(abs(moved.zero.x - 0.6) < 1e-9 && abs(moved.zero.y - 0.4) < 1e-9 && abs(moved.full.y - 0.9) < 1e-9)
        // The drawn lines are perpendicular to the gradient and span the frame.
        let lines = MaskGeometry.lines(of: gradient, frame: frame)
        #expect(abs(lines.zero.0.y - 60) < 1e-6 && abs(lines.zero.1.y - 60) < 1e-6 && abs(lines.zero.0.x - lines.zero.1.x) > frame.width)
    }

    @Test("The ellipse's handles resize, move and turn it")
    func radialHandles() {
        let ellipse = PhotoAdjustments.RadialGradient(center: .init(x: 0.5, y: 0.5), radiusX: 0.25, radiusY: 0.25, angle: 0, feather: 0.5)
        // Pixels: center (200, 100), radii 100 × 50.
        #expect(MaskGeometry.position(of: .right, in: ellipse, frame: frame) == CGPoint(x: 300, y: 100))
        #expect(MaskGeometry.position(of: .top, in: ellipse, frame: frame) == CGPoint(x: 200, y: 150))
        #expect(MaskGeometry.radialHandle(at: CGPoint(x: 302, y: 98), ellipse: ellipse, frame: frame, tolerance: 10) == .right)
        #expect(MaskGeometry.radialHandle(at: CGPoint(x: 230, y: 110), ellipse: ellipse, frame: frame, tolerance: 10) == .center, "inside moves it")
        #expect(MaskGeometry.radialHandle(at: CGPoint(x: 20, y: 20), ellipse: ellipse, frame: frame, tolerance: 10) == nil)
        let wider = MaskGeometry.dragRadial(.right, ellipse: ellipse, to: CGPoint(x: 340, y: 100), from: CGPoint(x: 300, y: 100), frame: frame)
        #expect(abs(wider.radiusX - 0.35) < 1e-9 && wider.radiusY == ellipse.radiusY)
        let taller = MaskGeometry.dragRadial(.bottom, ellipse: ellipse, to: CGPoint(x: 200, y: 20), from: .zero, frame: frame)
        #expect(abs(taller.radiusY - 0.4) < 1e-9)
        let moved = MaskGeometry.dragRadial(.center, ellipse: ellipse, to: CGPoint(x: 240, y: 120), from: CGPoint(x: 200, y: 100), frame: frame)
        #expect(abs(moved.center.x - 0.6) < 1e-9 && abs(moved.center.y - 0.6) < 1e-9)
        let turned = MaskGeometry.dragRadial(.rotate, ellipse: ellipse, to: CGPoint(x: 200, y: 200), from: .zero, frame: frame)
        #expect(abs(turned.angle - 90) < 1e-9)
        // A turned ellipse has its handles turned with it.
        var tilted = ellipse
        tilted.angle = 90
        let right = MaskGeometry.position(of: .right, in: tilted, frame: frame)
        #expect(abs(right.x - 200) < 1e-6 && abs(right.y - 200) < 1e-6)
    }

    @MainActor
    @Test("The overlay drags a linear gradient's line and reports each step")
    func overlayDrag() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 220), styleMask: [.borderless], backing: .buffered, defer: false)
        let overlay = MaskOverlayView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
        window.contentView?.addSubview(overlay)
        overlay.frameRect = CGRect(x: 10, y: 10, width: 400, height: 200)
        var mask = PhotoAdjustments.LocalAdjustment()
        mask.components = [.init(shape: .linear(.init(zero: .init(x: 0.5, y: 0.3), full: .init(x: 0.5, y: 0.8))))]
        mask.settings.exposure = 1
        overlay.adjustment = mask
        var steps: [(PhotoAdjustments.LocalAdjustment, Bool)] = []
        overlay.onChange = { adjustment, isFinal, action in
            steps.append((adjustment, isFinal))
            #expect(action == "Move Mask")
        }
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // The full line is at frame y = 160, which is view y = 170.
        overlay.mouseDown(with: event(.leftMouseDown, 150, 170))
        overlay.mouseDragged(with: event(.leftMouseDragged, 150, 150))
        overlay.mouseUp(with: event(.leftMouseUp, 150, 150))
        guard case .linear(let moved)? = steps.last?.0.components.first?.shape else { Issue.record("no change"); return }
        #expect(abs(moved.full.y - 0.7) < 1e-6 && moved.zero == PhotoAdjustments.UnitPoint(x: 0.5, y: 0.3))
        #expect(steps.last?.1 == true && steps.first?.1 == false)
    }

    private func radialMask(_ name: String, center: (Double, Double) = (0.5, 0.5), radius: (Double, Double) = (0.25, 0.4)) -> PhotoAdjustments.LocalAdjustment {
        var mask = PhotoAdjustments.LocalAdjustment()
        mask.name = name
        mask.components = [.init(shape: .radial(.init(center: .init(x: center.0, y: center.1), radiusX: radius.0, radiusY: radius.1, angle: 0, feather: 0.5)))]
        mask.settings.exposure = -0.5
        return mask
    }

    @MainActor
    private func subview<View: NSView>(_ identifier: String, of type: View.Type, in view: NSView) -> View? {
        if let view = view as? View, view.accessibilityIdentifier() == identifier { return view }
        return view.subviews.lazy.compactMap { self.subview(identifier, of: type, in: $0) }.first
    }

    @MainActor
    @Test("A slider edit after moving a mask on the preview keeps the move (RAW-136)")
    func sliderKeepsMovedMask() throws {
        let panel = MaskPanelViewController()
        let mask = radialMask("Radial Gradient 1")
        panel.display(masks: [mask])
        var moved = mask
        moved.components = radialMask("", center: (0.2, 0.7), radius: (0.1, 0.15)).components
        panel.update(masks: [moved])

        var sent: [PhotoAdjustments.LocalAdjustment] = []
        panel.onChange = { masks, _, _ in sent = masks }
        let exposure = try #require(subview("slider.Mask.Exposure", of: SliderRow.self, in: panel.view))
        exposure.onChange?(2, true)
        #expect(sent.first?.components == moved.components)
        #expect(sent.first?.settings.exposure == 2)
    }

    @MainActor
    @Test("Each mask's row has a button that deletes it and leaves the selection alone")
    func rowDeleteButton() throws {
        let panel = MaskPanelViewController()
        let first = radialMask("Radial Gradient 1"), second = radialMask("Radial Gradient 2", center: (0.3, 0.3))
        panel.display(masks: [first, second], selecting: first.id)

        var sent: [PhotoAdjustments.LocalAdjustment]?
        panel.onChange = { masks, isFinal, action in
            sent = masks
            #expect(isFinal && action == "Delete Mask")
        }
        let table = try #require(subview("maskList", of: NSTableView.self, in: panel.view))
        let row = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        let delete = try #require(subview("deleteMask.1", of: NSButton.self, in: row))
        #expect(delete.accessibilityLabel() == "Delete Radial Gradient 2")
        delete.performClick(nil)
        #expect(sent?.map(\.id) == [first.id])
        #expect(panel.selectedID == first.id)
    }

    @MainActor
    @Test("The row's delete button shows at the right edge of the mask list")
    func rowDeleteButtonIsVisible() throws {
        let panel = MaskPanelViewController()
        // The panel is first laid out wider than it ends up, as when the Develop sidebar settles on its width.
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = panel.view
        panel.display(masks: [radialMask("Radial Gradient 1")])
        window.layoutIfNeeded()
        window.setContentSize(NSSize(width: 340, height: 700))
        window.layoutIfNeeded()

        let table = try #require(subview("maskList", of: NSTableView.self, in: panel.view))
        let row = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: false))
        let delete = try #require(subview("deleteMask.0", of: NSButton.self, in: row))
        let list = try #require(table.enclosingScrollView)
        let frame = delete.convert(delete.bounds, to: list)
        #expect(!frame.isEmpty)
        #expect(list.bounds.contains(frame), "button \(frame) list \(list.bounds) table \(table.frame) column \(table.tableColumns[0].width)")
        #expect(frame.maxX > list.bounds.maxX - 30)
        #expect(subview("deleteMask", of: NSButton.self, in: panel.view) == nil)
    }

    @MainActor
    @Test("The selected mask's header names its type and has an Invert switch at the right, above Amount (RAW-190)")
    func headerInvertSwitch() throws {
        let panel = MaskPanelViewController()
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = panel.view
        var mask = radialMask("Radial Gradient 1")
        mask.components.append(.init(shape: .linear(MaskGeometry.defaultLinear()), mode: .subtract))
        panel.display(masks: [mask])
        window.layoutIfNeeded()

        let kind = try #require(subview("maskKind", of: NSTextField.self, in: panel.view))
        #expect(kind.stringValue == "Radial Gradient")
        let invert = try #require(subview("maskInvert", of: NSSwitch.self, in: panel.view))
        #expect(invert.state == .off)
        #expect(invert.accessibilityLabel() == "Invert")

        // On the header's right, level with the type, and above the sliders.
        let amount = try #require(subview("slider.Mask.Amount", of: SliderRow.self, in: panel.view))
        let switchFrame = invert.convert(invert.bounds, to: panel.view), kindFrame = kind.convert(kind.bounds, to: panel.view)
        let amountFrame = amount.convert(amount.bounds, to: panel.view)
        #expect(switchFrame.minX > kindFrame.maxX)
        #expect(abs(switchFrame.midY - kindFrame.midY) < 6)
        #expect(abs(switchFrame.maxX - amountFrame.maxX) < 2, "switch \(switchFrame) amount \(amountFrame)")
        #expect(panel.view.isFlipped ? switchFrame.maxY <= amountFrame.minY : switchFrame.minY >= amountFrame.maxY)

        var sent: [PhotoAdjustments.LocalAdjustment]?
        panel.onChange = { masks, isFinal, action in
            sent = masks
            #expect(isFinal && action == "Invert Mask")
        }
        invert.performClick(nil)
        #expect(sent?.first?.components.map(\.isInverted) == [true, true], "every shape flips")

        // Showing an inverted mask turns the switch on.
        panel.display(masks: try #require(sent))
        #expect(invert.state == .on)
    }

    @Test("M, ⇧M, O and ⇧W are masking shortcuts; plain W stays the white balance selector")
    func shortcuts() throws {
        func command(_ character: String, shift: Bool = false) -> KeyCommand? {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: 0, context: nil,
                characters: shift ? character.uppercased() : character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)
            return event.flatMap(KeyCommand.init(event:))
        }
        #expect(command("m") == .linearMask && command("m", shift: true) == .radialMask)
        #expect(command("o") == .maskOverlay && command("w", shift: true) == .maskingTool && command("w") == .whiteBalanceTool)
        #expect(command("s", shift: true) == .moveToTopOfStack && command("x", shift: true) == nil)
    }
}
