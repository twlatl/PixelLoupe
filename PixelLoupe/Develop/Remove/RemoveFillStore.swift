import CoreImage
import CryptoKit
import Foundation
import simd

/// The pixels Remove spots are filled with (RAW-260, ADR 0004).
///
/// A spot stores only its area and a seed; its fill is made from them, once, and kept: in memory, and on disk
/// in the app's caches, never in the catalog. Both engines give the same pixels for the same seed, so losing
/// the cache only costs the time to fill again.
///
/// A fill is made at a fixed working resolution (the spot's box, with room around it for context, at most
/// ``workingLongEdge`` pixels across) so every view (preview, thumbnail, export) scales the same fill. It is made
/// on the frame decoded with neutral RAW settings (only the geometry, and the spots before it, applied), and keeps
/// the average color of a ring around the hole: a render compares that with the same ring in what it's drawing
/// over and scales the fill to match, so changing White Balance or Exposure doesn't fill again.
///
/// Rendering off the main thread waits for a fill; Develop's preview draws on the main thread, so it asks
/// without waiting: the fill is made in the background and `didFill` is posted when it's ready.
nonisolated final class RemoveFillStore: @unchecked Sendable {
    /// Posted on the main thread when a fill has been made.
    static let didFill = Notification.Name("PixelLoupe.RemoveFillStore.didFill")

    static let shared = RemoveFillStore(directory: defaultDirectory)

    static var defaultDirectory: URL {
        URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "PixelLoupe").appending(path: "RemoveFills")
    }

    /// The longest side, in pixels, a fill is made at.
    static let workingLongEdge: CGFloat = 1024
    /// Bump when either engine's output changes: old fills are then made again (see ADR 0004).
    static let version = 1

    /// A fill: the spot's box with the hole filled, the coverage it's blended with, and the ring around the
    /// hole its colors are matched by. Immutable once made, so it can be handed between threads.
    struct Fill: @unchecked Sendable {
        /// Where it goes, in unit coordinates of the frame.
        var box: CGRect
        var width: Int
        var height: Int
        /// RGBA half floats in the working color space, rows from the top.
        var patch: Data
        /// Blend coverage and ring, 8-bit, rows from the top.
        var mask: Data
        var ring: Data
        /// The neutral frame's average color over the ring, and the share of the box the ring covers.
        var ringMean: SIMD3<Float>
        var ringFraction: Float

        let patchImage: CIImage
        let maskImage: CIImage
        let ringImage: CIImage

        init(box: CGRect, width: Int, height: Int, patch: Data, mask: Data, ring: Data, ringMean: SIMD3<Float>, ringFraction: Float) {
            self.box = box
            self.width = width
            self.height = height
            self.patch = patch
            self.mask = mask
            self.ring = ring
            self.ringMean = ringMean
            self.ringFraction = ringFraction
            let size = CGSize(width: width, height: height)
            patchImage = CIImage(bitmapData: patch, bytesPerRow: width * 8, size: size, format: .RGBAh, colorSpace: nil)
            maskImage = CIImage(bitmapData: mask, bytesPerRow: width, size: size, format: .L8, colorSpace: nil)
            ringImage = CIImage(bitmapData: ring, bytesPerRow: width, size: size, format: .L8, colorSpace: nil)
        }
    }

    let directory: URL
    /// Fills with the generative model, when it's there (``InpaintingModelStore``).
    var generative: (any GenerativeInpainting)? = InpaintingModelStore.shared
    private let lock = NSLock()
    private var fills: [String: Fill] = [:]
    private var recent: [String] = []
    private var making: [String: DispatchGroup] = [:]
    private static let memoryLimit = 32

    init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Asking

    /// The fill for `adjustments.spots[index]` on `source`'s photo. Waiting makes it now if it must (off the main
    /// thread); otherwise nil until it's made in the background.
    func fill(for source: DevelopSource, adjustments: PhotoAdjustments, spotIndex index: Int, waiting: Bool) -> Fill? {
        guard adjustments.spots.indices.contains(index), adjustments.spots[index].isFilled else { return nil }
        let request = Request(source: source, adjustments: adjustments, index: index, generative: generativeEngine)
        if let fill = remembered(request.key) { return fill }
        if waiting { return make(request) }
        Task.detached(priority: .userInitiated) { [self] in
            _ = make(request)
            await MainActor.run { NotificationCenter.default.post(name: Self.didFill, object: self) }
        }
        return nil
    }

    /// Whether the spot's fill is ready (doesn't wait, or start making it).
    func isReady(for source: DevelopSource, adjustments: PhotoAdjustments, spotIndex index: Int) -> Bool {
        guard adjustments.spots.indices.contains(index), adjustments.spots[index].isFilled else { return true }
        return remembered(Request(source: source, adjustments: adjustments, index: index, generative: generativeEngine).key) != nil
    }

    /// The generative model's identity when it can be used, so a fill made before it downloaded is made again with it.
    private var generativeEngine: String? {
        guard let generative, generative.isAvailable else { return nil }
        return generative.identifier
    }

    private func remembered(_ key: String) -> Fill? {
        lock.withLock {
            guard let fill = fills[key] else { return nil }
            recent.removeAll { $0 == key }
            recent.append(key)
            return fill
        }
    }

    private func remember(_ fill: Fill, for key: String) {
        lock.withLock {
            fills[key] = fill
            recent.removeAll { $0 == key }
            recent.append(key)
            while recent.count > Self.memoryLimit { fills[recent.removeFirst()] = nil }
        }
    }

    // MARK: - Making

    /// What a fill follows from: the file, the geometry, the spots before it (it's made on top of them), and the
    /// spot's area, seed and engine.
    struct Request: Sendable {
        var url: URL
        var isSmartPreview: Bool
        var geometry: PhotoAdjustments
        var preceding: [PhotoAdjustments.Spot]
        var spot: PhotoAdjustments.Spot
        /// The generative model used, or nil for patch fill.
        var engine: String?

        init(source: DevelopSource, adjustments: PhotoAdjustments, index: Int, generative: String?) {
            url = source.url
            isSmartPreview = source.isSmartPreview
            var geometry = PhotoAdjustments()
            geometry.lens = adjustments.lens
            geometry.orientation = adjustments.orientation
            geometry.transform = adjustments.transform
            self.geometry = geometry
            preceding = Array(adjustments.spots[..<index])
            spot = adjustments.spots[index]
            engine = spot.usesGenerativeAI ? generative : nil
        }

        var key: String {
            struct Identity: Encodable {
                var version = RemoveFillStore.version
                var path: String
                var isSmartPreview: Bool
                var lens: PhotoAdjustments.LensCorrections
                var orientation: PhotoAdjustments.Orientation
                var transform: PhotoAdjustments.Transform
                var preceding: [PhotoAdjustments.Spot]
                var area: PhotoAdjustments.RemoveArea?
                var seed: UInt64
                var engine: String
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let identity = Identity(path: url.path(percentEncoded: false), isSmartPreview: isSmartPreview, lens: geometry.lens,
                                    orientation: geometry.orientation, transform: geometry.transform, preceding: preceding,
                                    area: spot.area, seed: spot.seed, engine: engine ?? "patch")
            let data = (try? encoder.encode(identity)) ?? Data(url.path(percentEncoded: false).utf8)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Makes the fill (or reads it from disk), once however many renders ask at the same time.
    func make(_ request: Request) -> Fill? {
        let key = request.key
        let (group, isMaking) = lock.withLock { () -> (DispatchGroup, Bool) in
            if let group = making[key] { return (group, false) }
            let group = DispatchGroup()
            group.enter()
            making[key] = group
            return (group, true)
        }
        guard isMaking else {
            group.wait()
            return remembered(key)
        }
        defer {
            lock.withLock { making[key] = nil }
            group.leave()
        }
        if let fill = remembered(key) { return fill }
        if let fill = read(key) {
            remember(fill, for: key)
            return fill
        }
        guard let source = request.isSmartPreview ? DevelopSource(smartPreview: request.url) : DevelopSource(url: request.url),
              let fill = makeFill(request, source: source) else { return nil }
        write(fill, for: key)
        remember(fill, for: key)
        return fill
    }

    private func makeFill(_ request: Request, source: DevelopSource) -> Fill? {
        guard let area = request.spot.area else { return nil }
        let frameSize = source.frameSize(request.geometry)
        let aspect = Double(frameSize.width / max(frameSize.height, 1))
        guard let painted = area.bounds(aspect: aspect) else { return nil }
        let unitBox = Self.box(around: painted, frameSize: frameSize)
        guard !unitBox.isEmpty else { return nil }
        let scale = min(1, Self.workingLongEdge / max(unitBox.width * frameSize.width, unitBox.height * frameSize.height, 1))

        // The neutral frame with the spots before this one.
        var neutral = request.geometry
        neutral.spots = request.preceding
        var frame = source.frameImage(with: request.geometry, scale: scale)
        if !request.preceding.isEmpty {
            frame = RetouchRenderer.apply(spots: request.preceding, redEyes: [], to: frame) { [self] index in
                fill(for: source, adjustments: neutral, spotIndex: index, waiting: true)
            }
        }
        let extent = frame.extent
        guard !extent.isEmpty, !extent.isInfinite else { return nil }
        let pixelBox = CGRect(x: extent.minX + unitBox.minX * extent.width, y: extent.minY + unitBox.minY * extent.height,
                              width: unitBox.width * extent.width, height: unitBox.height * extent.height).integral.intersection(extent)
        let width = Int(pixelBox.width), height = Int(pixelBox.height)
        guard width >= 8, height >= 8 else { return nil }
        // The box actually filled, in unit coordinates.
        let box = CGRect(x: (pixelBox.minX - extent.minX) / extent.width, y: (pixelBox.minY - extent.minY) / extent.height,
                         width: pixelBox.width / extent.width, height: pixelBox.height / extent.height)

        var rgba = [Float](repeating: 0, count: width * height * 4)
        PhotoRenderer.context.render(frame, toBitmap: &rgba, rowBytes: width * 16, bounds: pixelBox, format: .RGBAf, colorSpace: nil)
        // To rows from the bottom, as the coverage and the inpainter have them.
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for row in 0..<height {
            let from = (height - 1 - row) * width
            for column in 0..<width {
                for c in 0..<3 { rgb[(row * width + column) * 3 + c] = rgba[(from + column) * 4 + c] }
            }
        }

        let coverage = RemoveAreaRaster.coverage(of: area, box: box, frameSize: extent.size, width: width, height: height)
        let hole = Self.dilate(coverage.map { $0 > 0.05 }, width: width, height: height, by: 2)
        guard hole.contains(true) else { return nil }

        let input = PatchInpainter.Image(width: width, height: height, pixels: rgb)
        let filled: PatchInpainter.Image
        if request.engine != nil, let generative, let made = generative.fill(input, hole: hole, seed: request.spot.seed) {
            filled = made
        } else {
            filled = PatchInpainter.fill(input, hole: hole, seed: request.spot.seed)
        }

        // The ring around the hole the render matches colors by.
        let ringWidth = max(4, Int(Double(max(width, height)) * 0.03))
        let grown = Self.dilate(hole, width: width, height: height, by: ringWidth)
        var ringSum = SIMD3<Float>(repeating: 0), ringCount = 0
        var ring = [UInt8](repeating: 0, count: width * height)
        for i in hole.indices where grown[i] && !hole[i] {
            ringSum += SIMD3(rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2])
            ringCount += 1
            ring[i] = 255
        }
        guard ringCount > 0 else { return nil }

        // Blended over the hole with a soft edge.
        let soft = Self.blur(hole.map { $0 ? Float(1) : 0 }, width: width, height: height, passes: 2)
        var patch = [Float16](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            for c in 0..<3 { patch[i * 4 + c] = Float16(filled.pixels[i * 3 + c]) }
            patch[i * 4 + 3] = 1
        }
        return Fill(
            box: box, width: width, height: height,
            patch: Self.topDown(patch.withUnsafeBytes { Data($0) }, rowBytes: width * 8, height: height),
            mask: Self.topDown(Data(soft.map { UInt8(min(255, max(0, $0 * 255 + 0.5))) }), rowBytes: width, height: height),
            ring: Self.topDown(Data(ring), rowBytes: width, height: height),
            ringMean: ringSum / Float(ringCount), ringFraction: Float(ringCount) / Float(width * height)
        )
    }

    /// The box a fill is made over: the painted box with room around it for the patches to come from.
    static func box(around painted: CGRect, frameSize: CGSize) -> CGRect {
        let pixels = CGSize(width: painted.width * frameSize.width, height: painted.height * frameSize.height)
        let margin = max(max(pixels.width, pixels.height) * 0.75, 32)
        return painted.insetBy(dx: -margin / max(frameSize.width, 1), dy: -margin / max(frameSize.height, 1))
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Rows from the bottom turned into rows from the top (or back).
    private static func topDown(_ data: Data, rowBytes: Int, height: Int) -> Data {
        var result = Data(count: data.count)
        result.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                for row in 0..<height {
                    let from = input.baseAddress! + (height - 1 - row) * rowBytes
                    (out.baseAddress! + row * rowBytes).copyMemory(from: from, byteCount: rowBytes)
                }
            }
        }
        return result
    }

    /// `mask` grown by `radius` pixels (a square).
    static func dilate(_ mask: [Bool], width: Int, height: Int, by radius: Int) -> [Bool] {
        guard radius > 0 else { return mask }
        // Separable: rows, then columns, each with a running count of set pixels in the window.
        var rows = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            var count = 0
            for x in 0..<min(width, radius) where mask[y * width + x] { count += 1 }
            for x in 0..<width {
                if x + radius < width, mask[y * width + x + radius] { count += 1 }
                if x - radius - 1 >= 0, mask[y * width + x - radius - 1] { count -= 1 }
                rows[y * width + x] = count > 0
            }
        }
        var result = [Bool](repeating: false, count: mask.count)
        for x in 0..<width {
            var count = 0
            for y in 0..<min(height, radius) where rows[y * width + x] { count += 1 }
            for y in 0..<height {
                if y + radius < height, rows[(y + radius) * width + x] { count += 1 }
                if y - radius - 1 >= 0, rows[(y - radius - 1) * width + x] { count -= 1 }
                result[y * width + x] = count > 0
            }
        }
        return result
    }

    /// A 3 × 3 box blur, `passes` times.
    private static func blur(_ values: [Float], width: Int, height: Int, passes: Int) -> [Float] {
        var current = values
        for _ in 0..<passes {
            var next = current
            for y in 0..<height {
                for x in 0..<width {
                    var sum: Float = 0, count: Float = 0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let nx = x + dx, ny = y + dy
                            guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                            sum += current[ny * width + nx]
                            count += 1
                        }
                    }
                    next[y * width + x] = sum / count
                }
            }
            current = next
        }
        return current
    }

    // MARK: - Disk

    /// A fill file, compressed (LZFSE): a header (format, the box, size, ring mean and share), then the patch,
    /// mask and ring.
    private func url(for key: String) -> URL { directory.appending(path: "\(key).fill") }

    private static let format: UInt32 = 1

    private func read(_ key: String) -> Fill? {
        guard let compressed = try? Data(contentsOf: url(for: key)),
              let data = try? (compressed as NSData).decompressed(using: .lzfse) as Data else { return nil }
        var offset = 0
        func take<T>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            defer { offset += size }
            return data[offset..<offset + size].withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        }
        guard take(UInt32.self) == Self.format,
              let x = take(Double.self), let y = take(Double.self), let w = take(Double.self), let h = take(Double.self),
              let width = take(UInt32.self).map(Int.init), let height = take(UInt32.self).map(Int.init),
              let r = take(Float.self), let g = take(Float.self), let b = take(Float.self), let fraction = take(Float.self)
        else { return nil }
        let patchBytes = width * height * 8, maskBytes = width * height
        guard data.count == offset + patchBytes + maskBytes * 2 else { return nil }
        let patch = data.subdata(in: offset..<offset + patchBytes)
        let mask = data.subdata(in: offset + patchBytes..<offset + patchBytes + maskBytes)
        let ring = data.subdata(in: offset + patchBytes + maskBytes..<data.count)
        return Fill(box: CGRect(x: x, y: y, width: w, height: h), width: width, height: height, patch: patch, mask: mask, ring: ring,
                    ringMean: SIMD3(r, g, b), ringFraction: fraction)
    }

    private func write(_ fill: Fill, for key: String) {
        var data = Data()
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        put(Self.format)
        put(Double(fill.box.minX)); put(Double(fill.box.minY)); put(Double(fill.box.width)); put(Double(fill.box.height))
        put(UInt32(fill.width)); put(UInt32(fill.height))
        put(fill.ringMean.x); put(fill.ringMean.y); put(fill.ringMean.z); put(fill.ringFraction)
        data.append(fill.patch)
        data.append(fill.mask)
        data.append(fill.ring)
        guard let compressed = try? (data as NSData).compressed(using: .lzfse) as Data else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? compressed.write(to: url(for: key), options: .atomic)
    }
}

/// An on-device model that fills a hole in an image (Remove with Use Generative AI on).
nonisolated protocol GenerativeInpainting: AnyObject, Sendable {
    /// Whether the model has been downloaded and can run.
    var isAvailable: Bool { get }
    /// Names the model and its version, so fills made by another one are made again.
    var identifier: String { get }
    /// `image` with the hole filled, the same for the same seed; nil when it can't run.
    func fill(_ image: PatchInpainter.Image, hole: [Bool], seed: UInt64) -> PatchInpainter.Image?
}
