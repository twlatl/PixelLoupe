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

    @Test("Without people, while off, or for the face effects with no faces, the photo is untouched")
    func untouched() {
        let (photo, matte) = scene()
        #expect(pixel(PortraitLightingRenderer.apply(lighting(.stage), to: photo, people: nil), 10, 10)[0] == 0.5)
        var off = lighting(.stage)
        off.isEnabled = false
        #expect(pixel(PortraitLightingRenderer.apply(off, to: photo, people: matte), 10, 10)[0] == 0.5)
        #expect(pixel(PortraitLightingRenderer.apply(lighting(.studio), to: photo, people: matte), 10, 10)[0] == 0.5)
    }

    // MARK: Studio and Contour (RAW-215)

    /// A gray photo with a person (the matte's square) and a face in the top of them.
    private func faceScene(turn: Double = 0) -> (photo: CIImage, matte: CIImage, face: FaceStore.Face) {
        let extent = CGRect(x: 0, y: 0, width: 240, height: 160)
        let square = CGRect(x: 80, y: 20, width: 80, height: 120)
        let photo = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: extent)
        let matte = CIImage(color: .white).cropped(to: square).composited(over: CIImage(color: .black).cropped(to: extent))
        let bounds = CGRect(x: 100.0 / 240, y: 70.0 / 160, width: 40.0 / 240, height: 50.0 / 160)
        return (photo, matte, FaceStore.Face(bounds: bounds, center: CGPoint(x: bounds.midX, y: bounds.midY), turn: turn, roll: 0))
    }

    @Test("Studio brightens the face, and nothing outside the person")
    func studio() {
        let (photo, matte, face) = faceScene()
        let result = PortraitLightingRenderer.apply(lighting(.studio), to: photo, people: matte, faces: [face])
        let before = pixel(photo, 120, 100)[0]
        #expect(pixel(result, 120, 100)[0] > before + 0.02, "the face is lit: \(pixel(result, 120, 100)) from \(before)")
        #expect(abs(pixel(result, 60, 100)[0] - before) < 0.001, "beside the person is untouched")
        #expect(abs(pixel(result, 120, 25)[0] - before) < 0.005, "the light stays near the face")
        let softer = PortraitLightingRenderer.apply(lighting(.studio, intensity: 0.3), to: photo, people: matte, faces: [face])
        #expect(pixel(softer, 120, 100)[0] < pixel(result, 120, 100)[0])
        #expect(result.extent == photo.extent)
    }

    @Test("Contour lights a face looking at the camera from the camera's left, and a turned face on the side it turns to")
    func contour() {
        func sides(turn: Double) -> (left: Float, right: Float) {
            let (photo, matte, face) = faceScene(turn: turn)
            let result = PortraitLightingRenderer.apply(lighting(.contour), to: photo, people: matte, faces: [face])
            return (pixel(result, 106, 95)[0], pixel(result, 134, 95)[0])
        }
        let frontal = sides(turn: 0)
        #expect(frontal.left > frontal.right + 0.03, "\(frontal)")
        #expect(frontal.right < 0.2, "the far side is in shadow: \(frontal)")
        let slight = sides(turn: 0.05)
        #expect(slight.left > slight.right, "under ~10° still counts as facing the camera: \(slight)")
        let toRight = sides(turn: 0.3), toLeft = sides(turn: -0.3)
        #expect(toRight.right > toRight.left + 0.03, "\(toRight)")
        #expect(toLeft.left > toLeft.right + 0.03, "\(toLeft)")
    }

    @Test("Someone with no face found is lit from a stand-in at the top of them")
    func standIn() throws {
        // A person 4 wide in the middle columns of an 8 × 10 matte, from the third row down.
        var bytes = Data(count: 80)
        for row in 2..<10 { for x in 2..<6 { bytes[row * 8 + x] = 255 } }
        let face = try #require(PortraitLightingRenderer.standIn(for: SubjectMatteStore.Matte(width: 8, height: 10, bytes: bytes)))
        #expect(abs(face.bounds.midX - 0.5) < 0.001 && abs(face.bounds.width - 0.25) < 0.001)
        #expect(abs(face.bounds.maxY - 0.8) < 0.001, "at the top of the person: \(face.bounds)")
        #expect(face.turn == 0 && face.roll == 0)
        #expect(PortraitLightingRenderer.standIn(for: .noSubject) == nil)
    }

    @Test("A face's turn comes from where its nose sits, and its tilt from its eyes")
    func faceFromLandmarks() {
        let bounds = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let frontal = FaceStore.face(bounds: bounds, aspect: 1, all: [CGPoint(x: 0.5, y: 0.5)], nose: [CGPoint(x: 0.5, y: 0.48)],
                                     leftEye: [CGPoint(x: 0.45, y: 0.55)], rightEye: [CGPoint(x: 0.55, y: 0.55)])
        #expect(abs(frontal.turn) < 0.001 && abs(frontal.roll) < 0.001 && frontal.center == CGPoint(x: 0.5, y: 0.5))
        let turned = FaceStore.face(bounds: bounds, aspect: 1, all: [], nose: [CGPoint(x: 0.56, y: 0.48)],
                                    leftEye: [CGPoint(x: 0.55, y: 0.6)], rightEye: [CGPoint(x: 0.45, y: 0.5)])
        #expect(abs(turned.turn - 0.6) < 0.001, "nose toward the frame's right")
        #expect(abs(turned.roll - .pi / 4) < 0.001, "tilted counterclockwise")
        #expect(turned.center == CGPoint(x: 0.5, y: 0.5), "no landmarks: the middle of the face")
    }

    @Test("Faces are found once, kept on disk, and found again only when the geometry changes")
    func faceStore() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "IMG.jpg")
        try Fixtures.writeJPEG(to: url, width: 300, height: 200)
        let source = try #require(DevelopSource(url: url))
        let face = FaceStore.Face(bounds: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3), center: CGPoint(x: 0.5, y: 0.55), turn: 0.2, roll: 0.1)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let store = FaceStore(directory: directory.url.appending(path: "Faces")) { _ in
            calls.withLock { $0 += 1 }
            return [face]
        }
        var adjustments = PhotoAdjustments()
        #expect(store.faces(for: source, adjustments: adjustments, waiting: true) == [face])
        adjustments.light.exposure = 1
        _ = store.faces(for: source, adjustments: adjustments, waiting: true)
        #expect(calls.withLock { $0 } == 1)
        let reread = FaceStore(directory: store.directory) { _ in nil }
        #expect(reread.faces(for: source, adjustments: adjustments, waiting: true) == [face])
        adjustments.orientation.quarterTurns = 1
        _ = store.faces(for: source, adjustments: adjustments, waiting: true)
        #expect(calls.withLock { $0 } == 2)
    }

    @Test("A Studio render off the main thread waits for the faces and lights them; Stage doesn't look for faces")
    func pipelineWaitsForFaces() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "IMG.jpg")
        try Fixtures.writeJPEG(to: url, width: 120, height: 80)
        let people = SubjectMatteStore(directory: directory.url.appending(path: "Mattes"), detect: { _ in nil }, detectPeople: { image in
            SubjectMatteStore.Matte(width: image.width, height: image.height, bytes: Data(repeating: 255, count: image.width * image.height))
        })
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let faces = FaceStore(directory: directory.url.appending(path: "Faces")) { _ in
            calls.withLock { $0 += 1 }
            let bounds = CGRect(x: 0.4, y: 0.35, width: 0.2, height: 0.3)
            return [FaceStore.Face(bounds: bounds, center: CGPoint(x: bounds.midX, y: bounds.midY), turn: 0, roll: 0)]
        }
        var studio = PhotoAdjustments(), stage = PhotoAdjustments()
        studio.portraitLighting = lighting(.studio)
        stage.portraitLighting = lighting(.stage, intensity: 0.5)
        let values = await Task.detached { () -> (lit: Float, plain: Float)? in
            guard let source = DevelopSource(url: url) else { return nil }
            source.subjectMattes = people
            source.faces = faces
            let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
            func sample(_ image: CIImage) -> Float {
                var data = [Float](repeating: 0, count: 4)
                context.render(image, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1),
                               format: .RGBAf, colorSpace: nil)
                return data[0]
            }
            _ = source.image(with: stage, scale: 1)
            return (sample(source.image(with: studio, scale: 1)), sample(source.image(with: PhotoAdjustments(), scale: 1)))
        }.value
        let result = try #require(values)
        #expect(result.lit > result.plain + 0.01, "\(result)")
        #expect(calls.withLock { $0 } == 1, "found once, for Studio only")
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
