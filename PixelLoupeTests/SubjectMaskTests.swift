import AppKit
import CoreImage
import CoreVideo
import Foundation
import os
import Testing
@testable import PixelLoupe

@Suite("Subject and Background masks (RAW-192)")
struct SubjectMaskTests {
    private typealias Matte = SubjectMatteStore.Matte

    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let extent = CGRect(x: 0, y: 0, width: 200, height: 100)

    /// The left half white: a subject on the left of the frame.
    private static let leftHalf = Matte(width: 4, height: 2, bytes: Data([255, 255, 0, 0, 255, 255, 0, 0]))

    private func value(_ image: CIImage, _ x: Int, _ y: Int) -> Float {
        var data = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return data[0]
    }

    private func mask(_ shape: PhotoAdjustments.MaskShape, inverted: Bool = false) -> PhotoAdjustments.LocalAdjustment {
        var mask = PhotoAdjustments.LocalAdjustment()
        mask.components = [.init(shape: shape, isInverted: inverted)]
        mask.settings.exposure = 1
        return mask
    }

    // MARK: Rendering

    @Test("Subject selects what was found, Background everything else, and neither does anything before it's found")
    func subjectAndBackground() throws {
        let matte = try #require(Self.leftHalf.image)
        let sharp = PhotoAdjustments.SubjectSelection(feather: 0, edge: 0)
        let subject = try #require(LocalAdjustmentRenderer.mask(for: mask(.subject(sharp)), extent: extent, subject: matte))
        #expect(value(subject, 20, 50) > 0.99 && value(subject, 180, 50) < 0.01)
        let background = try #require(LocalAdjustmentRenderer.mask(for: mask(.background(sharp)), extent: extent, subject: matte))
        #expect(value(background, 20, 50) < 0.01 && value(background, 180, 50) > 0.99)
        let inverted = try #require(LocalAdjustmentRenderer.mask(for: mask(.subject(sharp), inverted: true), extent: extent, subject: matte))
        #expect(value(inverted, 180, 50) > 0.99)

        #expect(LocalAdjustmentRenderer.mask(for: mask(.subject(sharp)), extent: extent, subject: nil) == nil)
        let gray = CIImage(color: CIColor(red: 0.25, green: 0.25, blue: 0.25)).cropped(to: extent)
        #expect(abs(value(LocalAdjustmentRenderer.apply([mask(.subject(sharp))], to: gray), 20, 50) - 0.25) < 0.01)
        #expect(value(LocalAdjustmentRenderer.apply([mask(.subject(sharp))], to: gray, subject: matte), 20, 50) > 0.45)
    }

    @Test("Edge grows or shrinks the selection; Feather softens its edge")
    func edgeAndFeather() throws {
        // At the frame's own size, so the edge is crisp (a small matte stretched over it is softened).
        let bytes = (0..<100).flatMap { _ in [UInt8](repeating: 255, count: 100) + [UInt8](repeating: 0, count: 100) }
        let matte = try #require(Matte(width: 200, height: 100, bytes: Data(bytes)).image)
        // The subject's edge is at x = 100; 3% of the 200 px long edge is 6 px.
        func at(_ x: Int, _ selection: PhotoAdjustments.SubjectSelection) throws -> Float {
            value(try #require(LocalAdjustmentRenderer.mask(for: mask(.subject(selection)), extent: extent, subject: matte)), x, 50)
        }
        #expect(try at(103, .init(feather: 0, edge: 0)) < 0.01)
        #expect(try at(103, .init(feather: 0, edge: 1)) > 0.99, "grown past the edge")
        #expect(try at(96, .init(feather: 0, edge: -1)) < 0.01, "shrunk back from it")
        let soft = try at(101, .init(feather: 1, edge: 0))
        #expect(soft > 0.1 && soft < 0.9, "\(soft)")
    }

    // MARK: Finding and keeping

    /// A store in its own folder, with a detector that counts its calls.
    private func store(finding matte: Matte? = SubjectMaskTests.leftHalf) throws -> (SubjectMatteStore, OSAllocatedUnfairLock<Int>, TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let store = SubjectMatteStore(directory: directory.url.appending(path: "Mattes")) { _ in
            calls.withLock { $0 += 1 }
            return matte
        }
        return (store, calls, directory)
    }

    private func photo(in directory: TemporaryDirectory, name: String = "IMG.jpg") throws -> URL {
        let url = directory.url.appending(path: name)
        try Fixtures.writeJPEG(to: url, width: 300, height: 200)
        return url
    }

    @Test("The subject is found once, kept in memory and on disk, and found again only when the geometry changes")
    func findsOnceAndKeeps() throws {
        let (store, calls, directory) = try store()
        let source = try #require(DevelopSource(url: try photo(in: directory)))
        var adjustments = PhotoAdjustments()
        adjustments.masks = [mask(.subject(.init()))]

        let found = try #require(store.matte(for: source, adjustments: adjustments, waiting: true))
        #expect(found.width == 4 && found.hasSubject)
        #expect(store.status(for: source, adjustments: adjustments) == .found)
        adjustments.light.exposure = 2
        _ = store.matte(for: source, adjustments: adjustments, waiting: true)
        #expect(calls.withLock { $0 } == 1, "tone edits don't find it again")

        // Another store on the same folder (the next launch) reads it from disk.
        let relaunchCalls = OSAllocatedUnfairLock(initialState: 0)
        let reread = SubjectMatteStore(directory: store.directory) { _ in relaunchCalls.withLock { $0 += 1 }; return nil }
        #expect(try #require(reread.matte(for: source, adjustments: adjustments, waiting: true)).bytes == found.bytes)
        #expect(relaunchCalls.withLock { $0 } == 0)

        adjustments.orientation.quarterTurns = 1
        #expect(store.status(for: source, adjustments: adjustments) == .finding)
        _ = store.matte(for: source, adjustments: adjustments, waiting: true)
        #expect(calls.withLock { $0 } == 2, "turning the photo finds it again")

        // Another photo (pasted settings) has its own subject.
        let other = try #require(DevelopSource(url: try photo(in: directory, name: "Other.jpg")))
        _ = store.matte(for: other, adjustments: adjustments, waiting: true)
        #expect(calls.withLock { $0 } == 3)
    }

    @Test("Renders asking at once find the subject once")
    func findsOnceWhenAskedTogether() async throws {
        let (store, calls, directory) = try store()
        let url = try photo(in: directory)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    guard let source = DevelopSource(url: url) else { return }
                    _ = store.matte(for: source, adjustments: PhotoAdjustments(), waiting: true)
                }
            }
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @MainActor
    @Test("Without waiting, the subject is found in the background and announced; no subject is remembered too")
    func findsInTheBackground() async throws {
        let (store, _, directory) = try store(finding: .noSubject)
        let source = try #require(DevelopSource(url: try photo(in: directory)))
        let announced = OSAllocatedUnfairLock(initialState: false)
        let observer = NotificationCenter.default.addObserver(forName: SubjectMatteStore.didFind, object: store, queue: .main) { _ in
            announced.withLock { $0 = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        #expect(store.matte(for: source, adjustments: PhotoAdjustments(), waiting: false) == nil)
        let start = Date()
        while !announced.withLock({ $0 }), Date().timeIntervalSince(start) < 10 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(announced.withLock { $0 })
        #expect(store.status(for: source, adjustments: PhotoAdjustments()) == .noSubject)
    }

    @Test("A render off the main thread waits for the subject and applies the mask there")
    func pipelineWaitsOffTheMainThread() async throws {
        let (store, _, directory) = try store()
        let url = try photo(in: directory)
        var adjustments = PhotoAdjustments()
        adjustments.masks = [mask(.subject(.init(feather: 0, edge: 0)))]
        let plain = PhotoAdjustments()
        let values = await Task.detached { () -> (masked: (Float, Float), plain: (Float, Float))? in
            guard let source = DevelopSource(url: url) else { return nil }
            source.subjectMattes = store
            let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
            func sample(_ image: CIImage, _ fx: Double) -> Float {
                var data = [Float](repeating: 0, count: 4)
                let x = image.extent.minX + image.extent.width * fx, y = image.extent.midY
                context.render(image, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                return data[0]
            }
            let masked = source.image(with: adjustments, scale: 1), unmasked = source.image(with: plain, scale: 1)
            return ((sample(masked, 0.2), sample(masked, 0.8)), (sample(unmasked, 0.2), sample(unmasked, 0.8)))
        }.value
        let result = try #require(values)
        #expect(result.masked.0 > result.plain.0 + 0.05, "brighter on the subject: \(result)")
        #expect(abs(result.masked.1 - result.plain.1) < 0.01, "untouched off it: \(result)")
    }

    @Test("Vision's mask is read as gray, rows from the top; a featureless image has no subject")
    func visionMask() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 3, 2, kCVPixelFormatType_OneComponent32Float, nil, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pixels)), rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        for (y, row) in [[1.0, 0.5, 0], [0, 0, 2]].enumerated() {
            let pointer = (base + y * rowBytes).assumingMemoryBound(to: Float.self)
            for (x, value) in row.enumerated() { pointer[x] = Float(value) }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let matte = try #require(SubjectMatteStore.matte(from: pixels))
        #expect(Array(matte.bytes) == [255, 128, 0, 0, 0, 255])

        let gray = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                             bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        gray.setFillColor(gray: 0.5, alpha: 1)
        gray.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let found = SubjectMatteStore.detectWithVision(gray.makeImage()!)
        #expect(found?.hasSubject != true, "nothing to find in flat gray")
    }

    @Test("Subject masks save their edge settings and say they need the subject")
    func model() throws {
        var adjustments = PhotoAdjustments()
        adjustments.masks = [mask(.subject(.init(feather: 0.4, edge: -0.3))), mask(.background(.init())), mask(.radial(MaskGeometry.defaultRadial()))]
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: JSONEncoder().encode(adjustments))
        #expect(decoded.masks == adjustments.masks)
        #expect(decoded.masks.map(\.usesSubject) == [true, true, false])
        #expect(decoded.masks.map(\.isEmpty) == [false, false, false])
    }

    // MARK: Panel and menu

    @MainActor
    @Test("The Subject and Background buttons add them; Feather and Edge show once the subject is found and edit the mask")
    func panel() throws {
        let panel = MaskPanelViewController()
        var added: [MaskPanelViewController.MaskKind] = []
        panel.onAdd = { added.append($0) }
        let subject = mask(.subject(.init()))
        panel.display(masks: [subject])
        try #require(subview("addSubjectMask", of: NSButton.self, in: panel.view)).performClick(nil)
        try #require(subview("addBackgroundMask", of: NSButton.self, in: panel.view)).performClick(nil)
        #expect(added == [.subject, .background])

        let controls = try #require(subview("subjectControls", of: NSStackView.self, in: panel.view))
        let status = try #require(subview("subjectStatus", of: NSTextField.self, in: controls))
        let feather = try #require(subview("slider.Subject.Feather", of: SliderRow.self, in: controls))
        #expect(!controls.isHidden && status.stringValue == "Finding the subject…" && !status.isHidden)
        panel.subjectStatus = .noSubject
        #expect(status.stringValue == "No subject found" && feather.isHidden)
        panel.subjectStatus = .found
        #expect(status.isHidden && !feather.isHidden)
        #expect(try #require(subview("maskKind", of: NSTextField.self, in: panel.view)).stringValue == "Subject")

        var sent: (PhotoAdjustments.LocalAdjustment, String)?
        panel.onChange = { masks, isFinal, action in if isFinal { sent = (masks[0], action) } }
        feather.onChange?(0.6, true)
        #expect(sent?.0.components.first?.shape == .subject(.init(feather: 0.6, edge: 0)))
        #expect(sent?.1 == "Mask Feather")

        var radial = PhotoAdjustments.LocalAdjustment()
        radial.components = [.init(shape: .radial(MaskGeometry.defaultRadial()))]
        panel.display(masks: [radial])
        #expect(controls.isHidden)
    }

    @MainActor
    @Test("View has Select Subject and Select Background, with no keys (Lightroom has none)")
    func menu() throws {
        let view = try #require(MainMenu.make().items.first { $0.title == "View" }?.submenu)
        for (title, action) in [("Select Subject", #selector(PixelLoupeActions.addSubjectMask(_:))),
                                ("Select Background", #selector(PixelLoupeActions.addBackgroundMask(_:)))] {
            let item = try #require(view.items.first { $0.action == action })
            #expect(item.title == title && item.keyEquivalent.isEmpty)
        }
    }

    private func subview<View: NSView>(_ identifier: String, of type: View.Type, in view: NSView) -> View? {
        if let view = view as? View, view.accessibilityIdentifier() == identifier { return view }
        return view.subviews.lazy.compactMap { self.subview(identifier, of: type, in: $0) }.first
    }
}
