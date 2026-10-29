import CoreGraphics
import Foundation
import Vision

/// Where the faces in a photo are and which way they're turned, for Portrait Lighting's Studio and Contour (RAW-215).
///
/// Kept like ``SubjectMatteStore``'s mattes (see ADR 0003): found once per photo on the same 1536-pixel frame (the photo
/// after Lens Corrections, Rotate/Flip and Transform), in memory and on disk in the app's caches, keyed by the file and
/// that geometry. Renders off the main thread wait for it; Develop's preview doesn't, and redraws on
/// ``SubjectMatteStore/didFind``, which this posts too.
nonisolated final class FaceStore: @unchecked Sendable {
    static let shared = FaceStore(directory: defaultDirectory)

    static var defaultDirectory: URL {
        URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "PixelLoupe").appending(path: "Faces")
    }

    /// Faces narrower than this share of the frame's short side are left out.
    static let minimumFaceShare = 0.03

    /// One face, in fractions of the frame with the origin at the bottom left (Vision's and Core Image's).
    struct Face: Codable, Equatable, Sendable {
        /// Around the face.
        var bounds: CGRect
        /// The middle of its features.
        var center: CGPoint
        /// Which way it's turned, from where its nose sits across it: about −1 (to the frame's left) to 1 (to its right),
        /// 0 facing the camera.
        var turn: Double
        /// How far it's tilted, radians counterclockwise in the frame (the line through its eyes).
        var roll: Double
    }

    let directory: URL
    private let detect: @Sendable (CGImage) -> [Face]?
    private let lock = NSLock()
    private var faces: [String: [Face]] = [:]
    /// Keys most recently used last, to keep memory to a few dozen photos.
    private var recent: [String] = []
    private var finding: [String: DispatchGroup] = [:]
    private static let memoryLimit = 24

    /// `detect` finds the faces in an image, or returns nil when it couldn't look (which isn't kept, so it's tried
    /// again); Vision's by default.
    init(directory: URL, detect: @escaping @Sendable (CGImage) -> [Face]? = FaceStore.detectWithVision) {
        self.directory = directory
        self.detect = detect
    }

    // MARK: - Asking

    /// The faces in `source`'s photo with `adjustments`' geometry. Waiting finds them now if it must (off the main
    /// thread); otherwise nil until they're found in the background.
    func faces(for source: DevelopSource, adjustments: PhotoAdjustments, waiting: Bool) -> [Face]? {
        let request = SubjectMatteStore.Request(source: source, adjustments: adjustments)
        let key = Self.key(request)
        if let found = remembered(key) { return found }
        if waiting { return find(request) }
        Task.detached(priority: .userInitiated) { [self] in
            _ = find(request)
            await MainActor.run { NotificationCenter.default.post(name: SubjectMatteStore.didFind, object: self) }
        }
        return nil
    }

    private static func key(_ request: SubjectMatteStore.Request) -> String { request.key + "-faces" }

    private func remembered(_ key: String) -> [Face]? {
        lock.withLock {
            guard let found = faces[key] else { return nil }
            recent.removeAll { $0 == key }
            recent.append(key)
            return found
        }
    }

    private func remember(_ found: [Face], for key: String) {
        lock.withLock {
            faces[key] = found
            recent.removeAll { $0 == key }
            recent.append(key)
            while recent.count > Self.memoryLimit { faces[recent.removeFirst()] = nil }
        }
    }

    // MARK: - Finding

    /// Finds the faces (or reads them from disk), once however many renders ask at the same time.
    private func find(_ request: SubjectMatteStore.Request) -> [Face]? {
        let key = Self.key(request)
        let (group, isFinding) = lock.withLock { () -> (DispatchGroup, Bool) in
            if let group = finding[key] { return (group, false) }
            let group = DispatchGroup()
            group.enter()
            finding[key] = group
            return (group, true)
        }
        guard isFinding else {
            group.wait()
            return remembered(key)
        }
        defer {
            lock.withLock { finding[key] = nil }
            group.leave()
        }
        if let found = remembered(key) { return found }
        if let found = read(key) {
            remember(found, for: key)
            return found
        }
        guard let image = SubjectMatteStore.detectionImage(for: request), let found = detect(image) else { return nil }
        write(found, for: key)
        remember(found, for: key)
        return found
    }

    /// Vision's faces and their landmarks, the ones wide enough to light.
    @Sendable static func detectWithVision(_ image: CGImage) -> [Face]? {
        let request = VNDetectFaceLandmarksRequest()
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return nil }
        let shortSide = Double(min(image.width, image.height)), width = Double(image.width), height = Double(image.height)
        return (request.results ?? []).compactMap { observation in
            guard observation.boundingBox.width * width >= minimumFaceShare * shortSide else { return nil }
            let box = observation.boundingBox
            func inFrame(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
                (region?.normalizedPoints ?? []).map { CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height) }
            }
            return face(bounds: box, aspect: width / height, all: inFrame(observation.landmarks?.allPoints),
                        nose: inFrame(observation.landmarks?.nose), leftEye: inFrame(observation.landmarks?.leftEye),
                        rightEye: inFrame(observation.landmarks?.rightEye))
        }
    }

    /// A face from its landmarks in fractions of the frame (`aspect` is the frame's width over its height, to measure
    /// the eyes' tilt in pixels). Without landmarks it faces the camera, upright, from the middle of `bounds`.
    static func face(bounds: CGRect, aspect: Double, all: [CGPoint], nose: [CGPoint], leftEye: [CGPoint], rightEye: [CGPoint]) -> Face {
        func mean(_ points: [CGPoint]) -> CGPoint? {
            points.isEmpty ? nil : CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                                            y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        }
        let center = mean(all) ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let turn = mean(nose).map { min(1, max(-1, Double(($0.x - bounds.midX) / max(bounds.width / 2, 1e-6)))) } ?? 0
        var roll = 0.0
        if let a = mean(leftEye), let b = mean(rightEye) {
            let (left, right) = a.x <= b.x ? (a, b) : (b, a)
            roll = atan2(Double(right.y - left.y), Double(right.x - left.x) * aspect)
        }
        return Face(bounds: bounds, center: center, turn: turn, roll: roll)
    }

    // MARK: - Disk

    private func url(for key: String) -> URL { directory.appending(path: "\(key).json") }

    private func read(_ key: String) -> [Face]? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        return try? JSONDecoder().decode([Face].self, from: data)
    }

    private func write(_ found: [Face], for key: String) {
        guard let data = try? JSONEncoder().encode(found) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: key), options: .atomic)
    }
}
