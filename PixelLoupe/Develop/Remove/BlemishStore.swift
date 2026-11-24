import CoreGraphics
import CoreImage
import Foundation
import Vision

/// The marks Blemish Removal can remove in a photo (RAW-306), found once and kept.
///
/// Kept like ``FaceStore``'s faces (see ADR 0003): in memory, and on disk in the app's caches, keyed by the file and
/// the geometry that moves pixels around the frame, plus ``BlemishDetector/version`` so a better detector looks again.
/// Nothing is written to the catalog. Renders off the main thread wait for them; Develop's preview doesn't, and redraws
/// on ``SubjectMatteStore/didFind``, which this posts too.
///
/// Faces are found by Vision on the same 1536-pixel frame as subjects and faces; each face's skin is then looked at
/// closely (about ``faceWidth`` pixels across the face), leaving out its eyes, brows, lips and nostrils. With no face,
/// the whole frame is looked at as skin, for close-ups and shoulders.
nonisolated final class BlemishStore: @unchecked Sendable {
    static let shared = BlemishStore(directory: defaultDirectory)

    static var defaultDirectory: URL {
        URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "PixelLoupe").appending(path: "Blemishes")
    }

    /// How many pixels across a face is looked at: enough for a pimple to be several pixels wide.
    static let faceWidth: CGFloat = 700
    /// The long edge a frame with no face is looked at.
    static let frameLongEdge: CGFloat = 1600

    let directory: URL
    private let detect: @Sendable (SubjectMatteStore.Request) -> [BlemishCandidate]?
    private let lock = NSLock()
    private var found: [String: [BlemishCandidate]] = [:]
    private var recent: [String] = []
    private var finding: [String: DispatchGroup] = [:]
    private static let memoryLimit = 24

    /// `detect` finds the marks in a request's photo, or returns nil when it couldn't look (which isn't kept, so it's
    /// tried again); Vision and ``BlemishDetector`` by default.
    init(directory: URL, detect: @escaping @Sendable (SubjectMatteStore.Request) -> [BlemishCandidate]? = BlemishStore.detectInPhoto) {
        self.directory = directory
        self.detect = detect
    }

    // MARK: - Asking

    /// The marks in `source`'s photo with `adjustments`' geometry. Waiting finds them now if it must (off the main thread);
    /// otherwise nil until they're found in the background.
    func candidates(for source: DevelopSource, adjustments: PhotoAdjustments, waiting: Bool) -> [BlemishCandidate]? {
        let request = SubjectMatteStore.Request(source: source, adjustments: adjustments)
        let key = Self.key(request)
        if let marks = remembered(key) { return marks }
        if waiting { return find(request) }
        Task.detached(priority: .userInitiated) { [self] in
            _ = find(request)
            await MainActor.run { NotificationCenter.default.post(name: SubjectMatteStore.didFind, object: self) }
        }
        return nil
    }

    /// The marks if they've been found already (doesn't wait, or start looking).
    func knownCandidates(for source: DevelopSource, adjustments: PhotoAdjustments) -> [BlemishCandidate]? {
        remembered(Self.key(SubjectMatteStore.Request(source: source, adjustments: adjustments)))
    }

    static func key(_ request: SubjectMatteStore.Request) -> String { request.key + "-blemishes-\(BlemishDetector.version)" }

    private func remembered(_ key: String) -> [BlemishCandidate]? {
        lock.withLock {
            guard let marks = found[key] else { return nil }
            recent.removeAll { $0 == key }
            recent.append(key)
            return marks
        }
    }

    private func remember(_ marks: [BlemishCandidate], for key: String) {
        lock.withLock {
            found[key] = marks
            recent.removeAll { $0 == key }
            recent.append(key)
            while recent.count > Self.memoryLimit { found[recent.removeFirst()] = nil }
        }
    }

    // MARK: - Finding

    /// Finds the marks (or reads them from disk), once however many renders ask at the same time.
    private func find(_ request: SubjectMatteStore.Request) -> [BlemishCandidate]? {
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
        if let marks = remembered(key) { return marks }
        if let marks = read(key) {
            remember(marks, for: key)
            return marks
        }
        guard let marks = detect(request) else { return nil }
        write(marks, for: key)
        remember(marks, for: key)
        return marks
    }

    /// A face Vision found, in unit coordinates of the frame (origin bottom-left), with what on it isn't skin.
    struct Face: Sendable {
        var bounds: CGRect
        /// Outlines to leave out, each with how far around it (a fraction of the face's width).
        var exclusions: [(points: [CGPoint], margin: CGFloat)]
    }

    /// Finds the faces, then the marks on each (or on the whole frame when there are none).
    @Sendable static func detectInPhoto(_ request: SubjectMatteStore.Request) -> [BlemishCandidate]? {
        let source = request.isSmartPreview ? DevelopSource(smartPreview: request.url) : DevelopSource(url: request.url)
        guard let source, let detection = SubjectMatteStore.detectionImage(for: request), let faces = findFaces(in: detection) else { return nil }
        let frame = source.frameSize(request.geometry)
        guard frame.width > 0, frame.height > 0 else { return nil }

        var candidates: [BlemishCandidate] = []
        func add(_ found: [BlemishCandidate]) {
            for candidate in found {
                // Faces' areas can overlap: keep one of a mark found twice.
                let duplicate = candidates.contains {
                    hypot(($0.center.x - candidate.center.x) * Double(frame.width), ($0.center.y - candidate.center.y) * Double(frame.height))
                        < max($0.radius, candidate.radius) * Double(max(frame.width, frame.height))
                }
                if !duplicate { candidates.append(candidate) }
            }
        }
        if faces.isEmpty {
            let scale = min(1, frameLongEdge / max(frame.width, frame.height))
            let longEdge = Double(max(frame.width, frame.height) * scale)
            let sizes = BlemishDetector.Sizes(minimum: max(1.5, longEdge * 0.0008), maximum: longEdge * 0.015)
            add(look(at: CGRect(x: 0, y: 0, width: 1, height: 1), scale: scale, face: nil, sizes: sizes, source: source, request: request, frame: frame))
        } else {
            for face in faces {
                let width = face.bounds.width * frame.width
                let scale = min(1, faceWidth / max(width, 1))
                // The face and some forehead (Vision's box stops at the brows) and jaw.
                let b = face.bounds
                let area = CGRect(x: b.minX - b.width * 0.1, y: b.minY - b.height * 0.1, width: b.width * 1.2, height: b.height * 1.45)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                let across = Double(width * scale)
                let sizes = BlemishDetector.Sizes(minimum: max(1.5, across * 0.004), maximum: across * 0.03)
                add(look(at: area, scale: scale, face: face, sizes: sizes, source: source, request: request, frame: frame))
            }
        }
        return candidates
    }

    /// Faces wide enough to retouch, with their landmarks; nil when Vision couldn't look.
    static func findFaces(in image: CGImage) -> [Face]? {
        let request = VNDetectFaceLandmarksRequest()
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return nil }
        let shortSide = Double(min(image.width, image.height))
        return (request.results ?? []).compactMap { observation in
            let box = observation.boundingBox
            guard box.width * Double(image.width) >= FaceStore.minimumFaceShare * shortSide else { return nil }
            func inFrame(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
                (region?.normalizedPoints ?? []).map { CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height) }
            }
            let landmarks = observation.landmarks
            var exclusions: [(points: [CGPoint], margin: CGFloat)] = []
            for eye in [landmarks?.leftEye, landmarks?.rightEye, landmarks?.leftEyebrow, landmarks?.rightEyebrow] {
                exclusions.append((inFrame(eye), 0.05))
            }
            exclusions.append((inFrame(landmarks?.outerLips), 0.03))
            // The nostrils: the bottom of the nose.
            let nose = inFrame(landmarks?.nose)
            if let lowest = nose.map(\.y).min() {
                exclusions.append((nose.filter { $0.y < lowest + box.height * 0.05 }, 0.015))
            }
            return Face(bounds: box, exclusions: exclusions.filter { $0.points.count >= 3 })
        }
    }

    /// The marks in `area` (unit coordinates) of the frame, looked at `scale` of full size.
    private static func look(
        at area: CGRect, scale: CGFloat, face: Face?, sizes: BlemishDetector.Sizes, source: DevelopSource,
        request: SubjectMatteStore.Request, frame: CGSize
    ) -> [BlemishCandidate] {
        let image = source.image(with: request.geometry, scale: scale)
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        let pixelArea = CGRect(x: extent.minX + area.minX * extent.width, y: extent.minY + area.minY * extent.height,
                               width: area.width * extent.width, height: area.height * extent.height).integral.intersection(extent)
        let width = Int(pixelArea.width), height = Int(pixelArea.height)
        guard width >= 16, height >= 16 else { return [] }
        // The area actually looked at, in unit coordinates.
        let unit = CGRect(x: (pixelArea.minX - extent.minX) / extent.width, y: (pixelArea.minY - extent.minY) / extent.height,
                          width: pixelArea.width / extent.width, height: pixelArea.height / extent.height)

        var rgba = [Float](repeating: 0, count: width * height * 4)
        PhotoRenderer.context.render(image, toBitmap: &rgba, rowBytes: width * 16, bounds: pixelArea, format: .RGBAf, colorSpace: space)
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for row in 0..<height {
            let from = (height - 1 - row) * width
            for column in 0..<width {
                for c in 0..<3 { rgb[(row * width + column) * 3 + c] = min(1, max(0, rgba[(from + column) * 4 + c])) }
            }
        }

        // Area pixels from unit coordinates.
        func local(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - unit.minX) / unit.width * CGFloat(width), y: (p.y - unit.minY) / unit.height * CGFloat(height))
        }
        var allowed: [Bool]?
        var reference: CGRect?
        if let face {
            let faceWidth = face.bounds.width / unit.width * CGFloat(width)
            allowed = excluding(face.exclusions.map { ($0.points.map(local), $0.margin * faceWidth) }, width: width, height: height)
            let origin = local(face.bounds.origin), corner = local(CGPoint(x: face.bounds.maxX, y: face.bounds.maxY))
            reference = CGRect(x: origin.x, y: origin.y, width: corner.x - origin.x, height: corner.y - origin.y)
                .insetBy(dx: (corner.x - origin.x) * 0.15, dy: (corner.y - origin.y) * 0.15)
        }

        let marks = BlemishDetector.find(in: .init(width: width, height: height, pixels: rgb), allowed: allowed, reference: reference, sizes: sizes)
        let longEdge = Double(max(frame.width, frame.height) * scale)
        return marks.map { mark in
            func toUnit(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: unit.minX + x / CGFloat(width) * unit.width, y: unit.minY + y / CGFloat(height) * unit.height)
            }
            let center = toUnit(mark.center.x, mark.center.y)
            let lower = toUnit(mark.box.minX, mark.box.minY), upper = toUnit(mark.box.maxX, mark.box.maxY)
            let box = CGRect(x: lower.x, y: lower.y, width: upper.x - lower.x, height: upper.y - lower.y)
            // The coverage's rows go from the bottom, as an ObjectMatte's do.
            let matte = PhotoAdjustments.ObjectMatte(box: box, width: mark.coverageWidth, height: mark.coverageHeight, coverage: mark.coverage)
            let radius = mark.radius / longEdge
            return BlemishCandidate(
                id: BlemishCandidate.id(center: center, radius: radius), center: .init(x: Double(center.x), y: Double(center.y)),
                radius: radius, matte: matte, blemish: mark.blemish, natural: mark.natural
            )
        }
    }

    /// Everywhere but the outlines (each grown by its margin, in pixels), rows from the bottom.
    static func excluding(_ outlines: [([CGPoint], CGFloat)], width: Int, height: Int) -> [Bool] {
        var allowed = [Bool](repeating: true, count: width * height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return allowed }
        context.setFillColor(gray: 1, alpha: 1)
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineJoin(.round)
        for (points, margin) in outlines where points.count >= 3 {
            let path = CGMutablePath()
            path.addLines(between: points)
            path.closeSubpath()
            context.setLineWidth(margin * 2)
            context.addPath(path)
            context.drawPath(using: .fillStroke)
        }
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return allowed }
        // The context's first row in memory is its top.
        for row in 0..<height {
            let from = (height - 1 - row) * width
            for column in 0..<width where data[from + column] > 127 { allowed[row * width + column] = false }
        }
        return allowed
    }

    // MARK: - Disk

    private func url(for key: String) -> URL { directory.appending(path: "\(key).json") }

    private func read(_ key: String) -> [BlemishCandidate]? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        return try? JSONDecoder().decode([BlemishCandidate].self, from: data)
    }

    private func write(_ marks: [BlemishCandidate], for key: String) {
        guard let data = try? JSONEncoder().encode(marks) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: key), options: .atomic)
    }
}
