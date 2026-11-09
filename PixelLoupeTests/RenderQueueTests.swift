import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

/// RAW-256: full-size renders piled up on Swift's cooperative pool until nothing else could run, and
/// Develop never loaded its photo.
@Suite("Render queue")
struct RenderQueueTests {
    /// The hang, modelled: each render blocks its thread until something else gets to run, as the one
    /// holding the `CIContext` lock waited on Apple's RAW engine. Run from `@concurrent` functions, 40 of
    /// them took every thread in the pool and the probe (Develop's `loadSource`) never started; on the
    /// render queue they wait on one thread of their own.
    @Test(.timeLimit(.minutes(1))) func blockedRendersLeaveTheCooperativePoolFree() async {
        let queue = RenderQueue(label: "test.blocked")
        let started = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        let renders = (0..<40).map { _ in
            Task { try? await queue.run { started.signal(); _ = gate.wait(timeout: .now() + 20) } }
        }
        // Once one render is blocked, give the rest time to take whatever threads they're going to. (With the
        // pool full, even this sleep can't resume until a render lets go of its thread.)
        await Self.wait(for: started)
        let start = ContinuousClock.now
        try? await Task.sleep(for: .milliseconds(500))
        await Self.probe()
        let waited = ContinuousClock.now - start
        for _ in renders { gate.signal() }
        for render in renders { await render.value }
        #expect(waited < .seconds(5), "work on the cooperative pool ran while renders were blocked (waited \(waited))")
    }

    @concurrent
    private static func probe() async {}

    /// Latest wins: a job cancelled before its turn is dropped without running.
    @Test(.timeLimit(.minutes(1))) func cancelledJobsAreDroppedBeforeTheyStart() async throws {
        let queue = RenderQueue(label: "test.latest")
        let started = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        let first = Task { try await queue.run { started.signal(); _ = gate.wait(timeout: .now() + 20) } }
        await Self.wait(for: started)
        var later: [Task<Int, any Error>] = []
        for index in 0..<20 {
            later.last?.cancel()
            later.append(Task { try await queue.run { index } })
        }
        gate.signal()
        try await first.value
        #expect(try await later.last!.value == 19, "the latest job ran")
        for job in later.dropLast() {
            await #expect(throws: CancellationError.self) { try await job.value }
        }
        #expect(queue.completedCounts == RenderQueue.Counts(run: 2, dropped: 19))
    }

    @Test func aCancelledCallerDoesntWaitForTheQueue() async {
        let queue = RenderQueue(label: "test.cancelled")
        let job = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await queue.run { 1 }
        }
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(queue.completedCounts == RenderQueue.Counts(run: 0, dropped: 1))
    }

    @concurrent
    private static func wait(for semaphore: DispatchSemaphore) async {
        block(on: semaphore)
    }

    nonisolated private static func block(on semaphore: DispatchSemaphore) {
        _ = semaphore.wait(timeout: .now() + 20)
    }
}

@Suite("Full-size renders")
@MainActor
struct FullSizeRenderTests {
    private struct Catalog {
        let directory: TemporaryDirectory
        let store: CatalogStore
        let ids: [NSManagedObjectID]
    }

    /// `count` 1200 × 800 JPEGs, on disk.
    private func catalog(count: Int) throws -> Catalog {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        var photos: [Photo] = []
        for index in 0..<count {
            let photo = Photo(context: store.viewContext)
            photo.id = UUID()
            photo.fileName = "IMG_\(index).jpg"
            let url = directory.url.appending(path: photo.fileName)
            try Fixtures.writeJPEG(to: url, width: 1200, height: 800)
            photo.filePath = url.path(percentEncoded: false)
            photo.fileType = "JPG"
            photo.pixelWidth = 1200
            photo.pixelHeight = 800
            photo.orientation = 1
            photo.captureDate = Date(timeIntervalSince1970: Double(index))
            photo.importDate = Date()
            photo.editDate = Date()
            photos.append(photo)
        }
        try store.viewContext.save()
        return Catalog(directory: directory, store: store, ids: photos.map(\.objectID))
    }

    private func pump(_ seconds: Double = 0.05) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Arrowing through photos used to start a render for every one shown; now the ones passed over
    /// before their turn are never rendered, and the last one is.
    @Test(.timeLimit(.minutes(1))) func movingQuicklyThroughPhotosRendersOnlyTheLatest() async throws {
        let catalog = try catalog(count: 30)
        let queue = RenderQueue(label: "test.viewer")
        let viewer = PhotoViewer(store: catalog.store, inset: 0, renderQueue: queue)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = viewer
        defer { window.close() }
        window.layoutIfNeeded()
        for id in catalog.ids {
            viewer.show(id)
            window.layoutIfNeeded()
        }
        let start = Date()
        while viewer.renderedSize == 0, Date().timeIntervalSince(start) < 30 { await pump() }
        #expect(viewer.renderedSize > 0, "the last photo rendered")
        await pump(0.3)
        let counts = queue.completedCounts
        #expect(counts.run <= 2, "at most the one already rendering and the latest: \(counts)")
        #expect(counts.dropped >= catalog.ids.count - 2, "every other request was dropped: \(counts)")
    }

    /// The bug as Ted saw it: after moving through photos in the enlarged view, Develop still loads
    /// the selected one.
    @Test(.timeLimit(.minutes(2))) func developLoadsAfterMovingQuicklyThroughPhotos() async throws {
        let catalog = try catalog(count: 40)
        let controller = CatalogWindowController(store: catalog.store)
        controller.showWindow(nil)
        defer { controller.close() }
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: true)
        let state = controller.state
        state.selectedPhotoIDs = [try #require(state.photoOrder.first)]
        state.presentation = .loupe
        controller.window?.layoutIfNeeded()
        for id in state.photoOrder {
            state.selectedPhotoIDs = [id]
            controller.window?.layoutIfNeeded()
        }
        state.mode = .develop
        let develop = controller.rootViewController.main.develop
        let start = Date()
        while !develop.canAutoLight, Date().timeIntervalSince(start) < 60 { await pump(0.1) }
        #expect(develop.canAutoLight, "Develop loaded the photo")
    }
}
