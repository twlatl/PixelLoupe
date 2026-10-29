import AppKit
import CoreImage
import Foundation
import os
import Testing
@testable import PixelLoupe

@Suite("Portrait Lighting (RAW-214)")
struct PortraitLightingTests {
    private typealias PortraitLighting = PhotoAdjustments.PortraitLighting

    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func pixel(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> [Float] {
        var data = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return Array(data.prefix(3))
    }

    private func lighting(_ effect: PortraitLighting.Effect, intensity: Double = 1) -> PortraitLighting {
        PortraitLighting(isEnabled: true, effect: effect, intensity: intensity)
    }

    // MARK: Model

    @Test("Off by default, so unedited photos stay default; Stage Mono still applies at Intensity 0")
    func defaults() {
        #expect(PortraitLighting() == PortraitLighting(isEnabled: false, effect: .studio, intensity: 1))
        #expect(PhotoAdjustments().isDefault && PhotoAdjustments().encoded == nil)
        #expect(!PortraitLighting().isActive)
        #expect(lighting(.stage).isActive)
        #expect(!lighting(.stage, intensity: 0).isActive)
        #expect(lighting(.stageMono, intensity: 0).isActive)
        #expect(PortraitLighting.Effect.allCases.map(\.title) == ["Studio", "Contour", "Stage", "Stage Mono"])
    }

    @Test("Saved settings round-trip; older ones, missing fields and unknown effects decode as defaults")
    func coding() throws {
        var adjustments = PhotoAdjustments()
        adjustments.portraitLighting = lighting(.stageMono, intensity: 0.4)
        let data = try #require(adjustments.encoded)
        #expect(PhotoAdjustments(data: data) == adjustments)

        let old = try JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{"light":{"exposure":1}}"#.utf8))
        #expect(old.portraitLighting == PortraitLighting() && old.light.exposure == 1)
        let partial = try JSONDecoder().decode(PortraitLighting.self, from: Data(#"{"isEnabled":true,"effect":"stage"}"#.utf8))
        #expect(partial == lighting(.stage))
        let unknown = try JSONDecoder().decode(PortraitLighting.self, from: Data(#"{"effect":"highKeyMono","intensity":0.5}"#.utf8))
        #expect(unknown.effect == .studio && unknown.intensity == 0.5)
    }

    // MARK: Copy, Sync and presets

    @Test("Copy and Sync Settings carry Portrait Lighting, switch and all, as its own checkbox")
    func developSetting() {
        var source = PhotoAdjustments()
        source.portraitLighting = lighting(.stage, intensity: 0.7)
        #expect(DevelopSetting.apply([.portraitLighting], from: source, to: PhotoAdjustments()).portraitLighting == source.portraitLighting)
        #expect(DevelopSetting.apply([.rimLight], from: source, to: PhotoAdjustments()).portraitLighting == PortraitLighting())
        var target = PhotoAdjustments()
        target.portraitLighting = lighting(.contour)
        #expect(!DevelopSetting.apply([.portraitLighting], from: PhotoAdjustments(), to: target).portraitLighting.isEnabled,
                "pasting it off turns it off")
        let titles = DevelopSetting.groups.map(\.title)
        #expect(titles.firstIndex(of: "Portrait Lighting").map { $0 + 1 } == titles.firstIndex(of: "Rim Light"))
        #expect(DevelopSetting.defaultSelection.contains(.portraitLighting))
    }

    @Test("A preset carries Portrait Lighting in PixelLoupe's own setting and applies it back")
    func preset() throws {
        var adjustments = PhotoAdjustments()
        adjustments.portraitLighting = lighting(.stageMono, intensity: 0.6)
        let settings = PresetWriter.settings(for: adjustments, sections: [.portraitLighting])
        guard case .text(let text)? = settings[PortraitLightingPreset.key] else { Issue.record("not written"); return }
        #expect(PortraitLightingPreset.portraitLighting(text) == adjustments.portraitLighting)
        #expect(PresetWriter.settings(for: adjustments, sections: [.rimLight])[PortraitLightingPreset.key] == nil)

        let data = PresetWriter.xmp(name: "Stage", group: "User Presets", settings: settings)
        let preset = try #require(DevelopPreset.parse(data, url: URL(filePath: "/tmp/Stage.xmp"), defaultGroup: "User Presets"))
        #expect(PresetSection.sections(of: preset.settingKeys) == [.portraitLighting])
        var photo = PhotoAdjustments()
        photo.light.exposure = 0.5
        let applied = preset.applied(to: photo, isRaw: false)
        #expect(applied.portraitLighting == adjustments.portraitLighting && applied.light.exposure == 0.5)
    }

    // MARK: Rendering

    /// A reddish photo with a person (the matte's white square) in the middle.
    private func scene() -> (photo: CIImage, matte: CIImage) {
        let extent = CGRect(x: 0, y: 0, width: 240, height: 160)
        let square = CGRect(x: 80, y: 40, width: 80, height: 80)
        let photo = CIImage(color: CIColor(red: 0.5, green: 0.2, blue: 0.1)).cropped(to: extent)
        let matte = CIImage(color: .white).cropped(to: square).composited(over: CIImage(color: .black).cropped(to: extent))
        return (photo, matte)
    }

    @Test("Stage puts the person on black, Intensity taking the background from the photo to black")
    func stage() {
        let (photo, matte) = scene()
        let full = PortraitLightingRenderer.apply(lighting(.stage), to: photo, people: matte)
        #expect(pixel(full, 10, 10).allSatisfy { $0 < 0.001 }, "black behind: \(pixel(full, 10, 10))")
        let person = pixel(full, 120, 80)
        #expect(abs(person[0] - 0.5) < 0.01 && abs(person[1] - 0.2) < 0.01, "the person is untouched: \(person)")

        let half = PortraitLightingRenderer.apply(lighting(.stage, intensity: 0.5), to: photo, people: matte)
        let behind = pixel(half, 10, 10)[0]
        #expect(behind > 0.05 && behind < 0.45, "half way to black: \(behind)")
        #expect(full.extent == photo.extent)
    }

    @Test("Stage Mono makes the person gray on black, even at Intensity 0")
    func stageMono() {
        let (photo, matte) = scene()
        let result = PortraitLightingRenderer.apply(lighting(.stageMono, intensity: 0), to: photo, people: matte)
        let person = pixel(result, 120, 80)
        #expect(abs(person[0] - person[1]) < 0.01 && abs(person[1] - person[2]) < 0.01, "gray: \(person)")
        #expect(abs(pixel(result, 10, 10)[0] - 0.5) < 0.01, "the background stays at Intensity 0")
    }

    @Test("Without people, while off, or for the face effects (RAW-215), the photo is untouched")
    func untouched() {
        let (photo, matte) = scene()
        #expect(pixel(PortraitLightingRenderer.apply(lighting(.stage), to: photo, people: nil), 10, 10)[0] == 0.5)
        var off = lighting(.stage)
        off.isEnabled = false
        #expect(pixel(PortraitLightingRenderer.apply(off, to: photo, people: matte), 10, 10)[0] == 0.5)
        #expect(pixel(PortraitLightingRenderer.apply(lighting(.studio), to: photo, people: matte), 10, 10)[0] == 0.5)
    }

    @Test("A render off the main thread waits for the people and puts them on black")
    func pipelineWaitsForPeople() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "IMG.jpg")
        try Fixtures.writeJPEG(to: url, width: 120, height: 80)
        // The person is the left half; the subject detector must not be asked.
        let subjectCalls = OSAllocatedUnfairLock(initialState: 0)
        let store = SubjectMatteStore(directory: directory.url.appending(path: "Mattes"), detect: { _ in
            subjectCalls.withLock { $0 += 1 }
            return nil
        }, detectPeople: { image in
            var bytes = Data(count: image.width * image.height)
            for y in 0..<image.height { for x in 0..<image.width / 2 { bytes[y * image.width + x] = 255 } }
            return SubjectMatteStore.Matte(width: image.width, height: image.height, bytes: bytes)
        })
        var adjustments = PhotoAdjustments()
        adjustments.portraitLighting = lighting(.stage)
        let values = await Task.detached { () -> (person: Float, behind: Float, plain: Float)? in
            guard let source = DevelopSource(url: url) else { return nil }
            source.subjectMattes = store
            let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
            func sample(_ image: CIImage, _ fx: Double) -> Float {
                var data = [Float](repeating: 0, count: 4)
                let x = image.extent.minX + image.extent.width * fx, y = image.extent.midY
                context.render(image, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                return max(data[0], data[1], data[2])
            }
            let staged = source.image(with: adjustments, scale: 1)
            return (sample(staged, 0.2), sample(staged, 0.8), sample(source.image(with: PhotoAdjustments(), scale: 1), 0.8))
        }.value
        let result = try #require(values)
        #expect(result.behind < 0.01 && result.plain > 0.05, "\(result)")
        #expect(result.person > 0.05, "\(result)")
        #expect(subjectCalls.withLock { $0 } == 0)
    }
}
