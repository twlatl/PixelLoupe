import Foundation
import Synchronization

/// Runs blocking Core Image and RAW work one job at a time on its own dispatch queue, off Swift's
/// cooperative pool (RAW-256).
///
/// `createCGImage` blocks its thread for the whole render, and Apple's RAW engine waits on work of
/// its own while it does. Run from `@concurrent` functions, a handful of renders queued up on the
/// shared `CIContext` filled every thread of the pool: nothing else `async` could run, Develop
/// included, and the renders themselves stopped making progress. A serial dispatch queue keeps
/// them to one thread at a time, and the caller's task only suspends while it waits.
///
/// A job whose task is cancelled before its turn comes is dropped without running, so a viewer
/// that cancels its previous render whenever it asks for a new one only ever has the latest one
/// waiting (latest wins).
nonisolated final class RenderQueue: Sendable {
    /// Full-size renders of one photo for viewing (the enlarged view, full screen, the slideshow).
    static let fullSize = RenderQueue(label: "net.pixegen.PixelLoupe.render.full-size")
    /// Thumbnails redrawn after edits. Separate from ``fullSize`` so pasting settings to many photos
    /// doesn't keep the photo on screen waiting.
    static let thumbnails = RenderQueue(label: "net.pixegen.PixelLoupe.render.thumbnails", qos: .utility)

    private let queue: DispatchQueue
    private let counts = Mutex(Counts())

    /// How many jobs have run and how many were dropped, for tests.
    struct Counts: Equatable {
        var run = 0
        var dropped = 0
    }

    var completedCounts: Counts { counts.withLock { $0 } }

    init(label: String, qos: DispatchQoS = .userInitiated) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    /// Runs `work` on the queue once the jobs ahead of it are done and returns what it returns.
    /// Throws `CancellationError`, without running it, if the calling task is cancelled first.
    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async throws(CancellationError) -> T {
        guard !Task.isCancelled else {
            counts.withLock { $0.dropped += 1 }
            throw CancellationError()
        }
        let cancelled = Flag()
        let result: Outcome<T> = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<T>, Never>) in
                queue.async { [self] in
                    guard !cancelled.isSet else {
                        counts.withLock { $0.dropped += 1 }
                        continuation.resume(returning: .dropped)
                        return
                    }
                    let value = work()
                    counts.withLock { $0.run += 1 }
                    continuation.resume(returning: .ran(value))
                }
            }
        } onCancel: {
            cancelled.set()
        }
        guard case .ran(let value) = result else { throw CancellationError() }
        return value
    }

    private enum Outcome<T: Sendable>: Sendable {
        case ran(T)
        case dropped
    }

    private final class Flag: Sendable {
        private let value = Mutex(false)
        var isSet: Bool { value.withLock { $0 } }
        func set() { value.withLock { $0 = true } }
    }
}
