import AppKit
import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

/// Rim Light, from Pixegen's Filter ▸ Rim Light (RAW-203).
@Suite("Rim Light (RAW-203)")
struct RimLightTests {
    private typealias RimLight = PhotoAdjustments.RimLight

    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func pixel(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> [Float] {
        var data = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return Array(data.prefix(3))
    }

    /// One strong light from the right, no glow. Made once: each light has its own id.
    private let lit: RimLight = {
        var rimLight = RimLight()
        rimLight.isEnabled = true
        rimLight.lights = [RimLight.Light(angle: 0, strength: 1, width: 0.5)]
        rimLight.glow = 0
        return rimLight
    }()

    // MARK: Model

    @Test("Off with no lights by default, so unedited photos stay default and store nothing")
    func defaults() {
        #expect(RimLight() == RimLight())
        #expect(PhotoAdjustments().isDefault && PhotoAdjustments().encoded == nil)
        #expect(!RimLight().isActive)
        var on = RimLight()
        on.isEnabled = true
        #expect(!on.isActive, "on, but with no lights there's nothing to add")
        on.lights = [.init()]
        #expect(on.isActive)
        on.lights[0].strength = 0
        #expect(!on.isActive)
    }

    @Test("Saved settings round-trip; older ones without Rim Light, and missing fields, decode as defaults")
    func coding() throws {
        var adjustments = PhotoAdjustments()
        adjustments.rimLight = lit
        adjustments.rimLight.lights.append(adjustments.rimLight.nextLight)
        let data = try #require(adjustments.encoded)
        #expect(PhotoAdjustments(data: data) == adjustments)

        let old = try JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{"light":{"exposure":1}}"#.utf8))
        #expect(old.rimLight == RimLight() && old.light.exposure == 1)
        let partial = try JSONDecoder().decode(RimLight.self, from: Data(#"{"isEnabled":true,"lights":[{"angle":45}]}"#.utf8))
        #expect(partial.isEnabled && partial.glow == RimLight().glow)
        #expect(partial.lights.first?.angle == 45 && partial.lights.first?.strength == RimLight.Light().strength)
        let many = #"{"lights":[{},{},{},{},{}]}"#
        #expect(try JSONDecoder().decode(RimLight.self, from: Data(many.utf8)).lights.count == RimLight.maximumLights)
    }

    @Test("The next light comes from across the last one, cool and then white, as wide and choked")
    func nextLight() {
        var rimLight = RimLight()
        #expect(rimLight.nextLight.angle == 135)
        rimLight.lights = [RimLight.Light(angle: 135, width: 0.6, choke: 0.4)]
        let second = rimLight.nextLight
        #expect(second.angle == -45 && second.blue == 1 && second.red == 0.7 && second.width == 0.6 && second.choke == 0.4)
        rimLight.lights.append(second)
        let third = rimLight.nextLight
        #expect(third.angle == 135 && third.red == 1 && third.green == 1 && third.blue == 1)
    }

    // MARK: Copy, Sync and presets

    @Test("Copy and Sync Settings carry Rim Light as its own checkbox, checked by default")
    func developSetting() {
        var source = PhotoAdjustments()
        source.rimLight = lit
        #expect(DevelopSetting.apply([.rimLight], from: source, to: PhotoAdjustments()).rimLight == lit)
        #expect(DevelopSetting.apply([.vignette], from: source, to: PhotoAdjustments()).rimLight == RimLight())
        #expect(DevelopSetting.groups.contains { $0.title == "Rim Light" && $0.settings == [.rimLight] })
        #expect(DevelopSetting.defaultSelection.contains(.rimLight))
        #expect(DevelopSetting.rimLight.title == "Rim Light")
    }

    @Test("A preset carries Rim Light in PixelLoupe's own setting and applies it back")
    func preset() throws {
        var adjustments = PhotoAdjustments()
        adjustments.rimLight = lit
        let settings = PresetWriter.settings(for: adjustments, sections: [.rimLight])
        guard case .text(let text)? = settings[RimLightPreset.key] else { Issue.record("not written"); return }
        #expect(RimLightPreset.rimLight(text) == lit)
        #expect(PresetWriter.settings(for: adjustments, sections: [.effects])[RimLightPreset.key] == nil)

        let data = PresetWriter.xmp(name: "Rim", group: "User Presets", settings: settings)
        let preset = try #require(DevelopPreset.parse(data, url: URL(filePath: "/tmp/Rim.xmp"), defaultGroup: "User Presets"))
        #expect(PresetSection.sections(of: preset.settingKeys) == [.rimLight])
        var photo = PhotoAdjustments()
        photo.light.exposure = 0.5
        let applied = preset.applied(to: photo, isRaw: false)
        #expect(applied.rimLight == lit && applied.light.exposure == 0.5, "only Rim Light changes")
    }

    // MARK: Rendering

    /// A gray photo with a darker square subject in the middle, and its matte.
    private func scene() -> (photo: CIImage, matte: CIImage) {
        let extent = CGRect(x: 0, y: 0, width: 240, height: 160)
        let square = CGRect(x: 80, y: 40, width: 80, height: 80)
        let photo = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.08)).cropped(to: square)
            .composited(over: CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: extent))
        let matte = CIImage(color: .white).cropped(to: square).composited(over: CIImage(color: .black).cropped(to: extent))
        return (photo, matte)
    }

    @Test("A light from the right brightens the subject's right edge, not its left, and leaves the backdrop")
    func lightsTheEdgeFacingIt() {
        let (photo, matte) = scene()
        let result = RimLightRenderer.apply(lit, to: photo, subject: matte)
        let right = pixel(result, 157, 80), left = pixel(result, 82, 80), middle = pixel(result, 120, 80)
        let before = pixel(photo, 157, 80)
        #expect(right[0] > before[0] + 0.05, "the right edge is lit: \(right) from \(before)")
        #expect(abs(left[0] - before[0]) < 0.02, "the left edge faces away: \(left)")
        #expect(abs(middle[0] - before[0]) < 0.02, "the middle is past its reach: \(middle)")
        let far = pixel(result, 10, 10)
        #expect(abs(far[0] - 0.3) < 0.01, "the backdrop away from the subject is untouched: \(far)")
        #expect(result.extent == photo.extent)
    }

    @Test("The light takes its color: a warm light adds more red than blue")
    func color() {
        let (photo, matte) = scene()
        var warm = lit
        warm.lights[0].red = 1
        warm.lights[0].green = 0.5
        warm.lights[0].blue = 0.1
        let edge = pixel(RimLightRenderer.apply(warm, to: photo, subject: matte), 157, 80)
        #expect(edge[0] > edge[2] + 0.05, "\(edge)")
    }

    @Test("Off, with no subject, or at strength 0, the photo is unchanged")
    func identity() {
        let (photo, matte) = scene()
        var off = lit
        off.isEnabled = false
        #expect(RimLightRenderer.apply(off, to: photo, subject: matte) === photo)
        #expect(RimLightRenderer.apply(lit, to: photo, subject: nil) === photo)
        var dark = lit
        dark.lights[0].strength = 0
        #expect(RimLightRenderer.apply(dark, to: photo, subject: matte) === photo)
    }

    @Test("Highlights brighter than white stay as bright; they aren't clipped")
    func keepsHighlights() {
        let extent = CGRect(x: 0, y: 0, width: 240, height: 160)
        let square = CGRect(x: 80, y: 40, width: 80, height: 80)
        let photo = CIImage(color: CIColor(red: 2, green: 2, blue: 2, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!)
            .cropped(to: extent)
        let matte = CIImage(color: .white).cropped(to: square).composited(over: CIImage(color: .black).cropped(to: extent))
        let lit = RimLightRenderer.apply(lit, to: photo, subject: matte)
        #expect(pixel(lit, 157, 80)[0] >= 1.95, "\(pixel(lit, 157, 80))")
    }

    @Test("The refined matte keeps its size and stays within 0–1, following the photo it was found in")
    func refinedMatte() throws {
        let width = 60, height = 40
        // The matte covers the left half; the photo is bright on the left 24 columns only.
        var bytes = Data(count: width * height)
        for y in 0..<height { for x in 0..<width / 2 { bytes[y * width + x] = 255 } }
        let matte = SubjectMatteStore.Matte(width: width, height: height, bytes: bytes)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 24, height: height))
        let guide = try #require(context.makeImage())
        let refined = try #require(SubjectMatteStore.refined(matte, guide: guide))
        #expect(refined.width == width && refined.height == height && refined.bytes.count == width * height)
        let row = 20 * width
        #expect(refined.bytes[row + 5] > 230, "deep in the subject stays in it")
        #expect(refined.bytes[row + 55] < 25, "far outside stays out")
        #expect(refined.bytes[row + 27] < refined.bytes[row + 20], "pulled toward the photo's own edge, at 24")
    }

    @Test("A render off the main thread waits for the refined subject and lights it")
    func pipelineWaitsForTheSubject() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "IMG.jpg")
        try Fixtures.writeJPEG(to: url, width: 120, height: 80)
        // The subject is the left half.
        let store = SubjectMatteStore(directory: directory.url.appending(path: "Mattes")) { image in
            var bytes = Data(count: image.width * image.height)
            for y in 0..<image.height { for x in 0..<image.width / 2 { bytes[y * image.width + x] = 255 } }
            return SubjectMatteStore.Matte(width: image.width, height: image.height, bytes: bytes)
        }
        var adjustments = PhotoAdjustments()
        adjustments.rimLight = lit
        let values = await Task.detached { () -> (lit: Float, plain: Float)? in
            guard let source = DevelopSource(url: url) else { return nil }
            source.subjectMattes = store
            let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
            func sample(_ image: CIImage) -> Float {
                var data = [Float](repeating: 0, count: 4)
                // Just inside the subject's right edge, which faces the light.
                let x = image.extent.minX + image.extent.width * 0.48, y = image.extent.midY
                context.render(image, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                return data[0]
            }
            return (sample(source.image(with: adjustments, scale: 1)), sample(source.image(with: PhotoAdjustments(), scale: 1)))
        }.value
        let result = try #require(values)
        #expect(result.lit > result.plain + 0.03, "\(result)")
    }
}

/// The Rim Light panel's switch, lights and controls.
@MainActor
@Suite("Rim Light panel (RAW-203)")
struct RimLightPanelTests {
    private typealias RimLight = PhotoAdjustments.RimLight

    private func panel() -> (RimLightPanelViewController, Log) {
        let panel = RimLightPanelViewController()
        _ = panel.view
        panel.isEditingEnabled = true
        let log = Log()
        panel.onChange = { log.changes.append(($0, $1, $2)) }
        return (panel, log)
    }

    private final class Log {
        var changes: [(RimLight, Bool, String)] = []
    }

    private func find<View: NSView>(_ id: String, _ type: View.Type, in view: NSView) -> View? {
        if let view = view as? View, view.accessibilityIdentifier() == id { return view }
        return view.subviews.lazy.compactMap { self.find(id, type, in: $0) }.first
    }

    @Test("Turning it on adds a warm light at 135°; turning it off keeps the lights")
    func turningOn() throws {
        let (panel, log) = panel()
        let toggle = try #require(find("rimLightEnabled", NSSwitch.self, in: panel.view))
        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)
        let on = try #require(log.changes.last)
        #expect(on.0.isEnabled && on.0.lights.count == 1 && on.0.lights[0].angle == 135 && on.1 && on.2 == "Rim Light On")
        toggle.state = .off
        toggle.sendAction(toggle.action, to: toggle.target)
        #expect(log.changes.last?.0.isEnabled == false && log.changes.last?.0.lights.count == 1 && log.changes.last?.2 == "Rim Light Off")
    }

    @Test("Add Light adds up to three, across from the last; a light's controls change only it")
    func lights() throws {
        let (panel, log) = panel()
        var rimLight = RimLight()
        rimLight.isEnabled = true
        rimLight.lights = [.init()]
        panel.display(rimLight)
        let add = try #require(find("rimLightAdd", NSButton.self, in: panel.view))
        add.performClick(nil)
        #expect(panel.rimLight.lights.count == 2 && panel.rimLight.lights[1].angle == -45 && log.changes.last?.2 == "Add Light")
        add.performClick(nil)
        #expect(panel.rimLight.lights.count == 3 && add.isHidden, "three at most")

        let strength = try #require(find("slider.RimLight.2.Strength", AdjustmentSlider.self, in: panel.view))
        let row = try #require(strength.superview as? SliderRow)
        row.onChange?(0.9, true)
        #expect(panel.rimLight.lights[1].strength == 0.9 && panel.rimLight.lights[0].strength == 0.5)
        #expect(log.changes.last?.1 == true && log.changes.last?.2 == "Strength")

        let remove = try #require(find("rimLight.1.remove", NSButton.self, in: panel.view))
        remove.performClick(nil)
        #expect(panel.rimLight.lights.count == 2 && log.changes.last?.2 == "Remove Light" && !add.isHidden)
    }

    @Test("With Rim Light off, its controls are disabled; the panel says while the subject is being found")
    func states() throws {
        let (panel, _) = panel()
        var rimLight = RimLight()
        rimLight.lights = [.init()]
        panel.display(rimLight)
        let glow = try #require(find("slider.RimLight.Glow", AdjustmentSlider.self, in: panel.view))
        #expect(!glow.isEnabled)
        rimLight.isEnabled = true
        panel.display(rimLight)
        #expect(glow.isEnabled)
        panel.subjectStatus = .finding
        let status = try #require(find("rimLightStatus", NSTextField.self, in: panel.view))
        #expect(!status.isHidden && status.stringValue == "Finding the subject…")
        panel.subjectStatus = .found
        #expect(status.isHidden)
    }
}
