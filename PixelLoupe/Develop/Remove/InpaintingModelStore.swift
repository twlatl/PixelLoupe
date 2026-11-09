import CoreML
import CoreVideo
import Foundation

/// The on-device inpainting model Remove's Use Generative AI fills with (RAW-260). It isn't in the app: it's
/// downloaded the first time Use Generative AI is turned on, compiled, and kept in Application Support.
///
/// The model takes `image` (RGB, 512 × 512, sRGB) and `mask` (grayscale, 512 × 512, white where to fill) and
/// returns `output` (RGB, 512 × 512), as LaMa-style models converted to Core ML do. It always runs on the CPU
/// and GPU in full precision, never the Neural Engine, so a Mac always makes the same fill (ADR 0004).
///
/// Where it's downloaded from is the `PLInpaintingModelURL` key in the app's Info.plist (a zipped, compiled
/// `.mlmodelc` or an `.mlmodel`); without it, generative Remove isn't offered and spots use patch fill.
nonisolated final class InpaintingModelStore: GenerativeInpainting, @unchecked Sendable {
    static let shared = InpaintingModelStore()
    /// Posted on the main thread when the state changes (downloading progress, ready, failed).
    static let didChange = Notification.Name("PixelLoupe.InpaintingModelStore.didChange")

    enum State: Equatable, Sendable {
        /// No download location is configured.
        case unavailable
        case notDownloaded
        case downloading(progress: Double)
        case ready
        case failed(String)
    }

    static let side = 512
    private static let urlKey = "PLInpaintingModelURL"

    let downloadURL: URL?
    let directory: URL
    private let lock = NSLock()
    private var _state: State
    private var model: MLModel?
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    init(downloadURL: URL? = (Bundle.main.object(forInfoDictionaryKey: urlKey) as? String).flatMap(URL.init(string:)),
         directory: URL = URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "PixelLoupe").appending(path: "Models")) {
        self.downloadURL = downloadURL
        self.directory = directory
        _state = .unavailable
        _state = downloadURL == nil ? .unavailable : (FileManager.default.fileExists(atPath: compiledURL.path) ? .ready : .notDownloaded)
    }

    var compiledURL: URL { directory.appending(path: "Inpainting.mlmodelc") }

    var state: State { lock.withLock { _state } }

    private func setState(_ state: State) {
        lock.withLock { _state = state }
        Task { @MainActor in NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    var isAvailable: Bool { state == .ready }

    var identifier: String {
        let date = (try? FileManager.default.attributesOfItem(atPath: compiledURL.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "inpainting-\(Int(date))"
    }

    // MARK: - Downloading

    /// Starts downloading the model, unless it's there, downloading, or has nowhere to come from.
    func download() {
        guard let downloadURL else { return }
        switch state {
        case .ready, .downloading, .unavailable: return
        case .notDownloaded, .failed: break
        }
        setState(.downloading(progress: 0))
        let task = URLSession.shared.downloadTask(with: downloadURL) { [self] location, _, error in
            guard let location, error == nil else {
                setState(.failed(error?.localizedDescription ?? "The download failed."))
                return
            }
            do {
                try install(from: location, name: downloadURL.lastPathComponent)
                setState(.ready)
            } catch {
                setState(.failed(error.localizedDescription))
            }
        }
        observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            self?.setState(.downloading(progress: progress.fractionCompleted))
        }
        lock.withLock { self.task = task }
        task.resume()
    }

    /// Moves a downloaded model into place, unzipping and compiling it as needed.
    private func install(from location: URL, name: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let work = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }
        var model = work.appending(path: name)
        try fileManager.moveItem(at: location, to: model)
        if model.pathExtension == "zip" {
            let unzip = Process()
            unzip.executableURL = URL(filePath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", model.path, work.path]
            try unzip.run()
            unzip.waitUntilExit()
            guard let found = try fileManager.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                .first(where: { ["mlmodelc", "mlmodel", "mlpackage"].contains($0.pathExtension) }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            model = found
        }
        let compiled = model.pathExtension == "mlmodelc" ? model : try MLModel.compileModel(at: model)
        if fileManager.fileExists(atPath: compiledURL.path) { try fileManager.removeItem(at: compiledURL) }
        try fileManager.moveItem(at: compiled, to: compiledURL)
        lock.withLock { self.model = nil }
    }

    // MARK: - Filling

    private func loadedModel() -> MLModel? {
        lock.withLock {
            if let model { return model }
            let configuration = MLModelConfiguration()
            // The same compute units every time, so the same input gives the same fill (ADR 0004).
            configuration.computeUnits = .cpuAndGPU
            configuration.allowLowPrecisionAccumulationOnGPU = false
            model = try? MLModel(contentsOf: compiledURL, configuration: configuration)
            return model
        }
    }

    /// The image squeezed to 512 × 512 (with the seed choosing a mirror image and a slight zoom, so Refresh
    /// gives another fill), filled, and scaled back over the hole.
    func fill(_ image: PatchInpainter.Image, hole: [Bool], seed: UInt64) -> PatchInpainter.Image? {
        guard isAvailable, let model = loadedModel() else { return nil }
        let side = Self.side
        let mirrored = seed & 1 == 1
        let zoom = 1 + Double((seed >> 1) % 8) * 0.0125
        // Model pixel → image pixel (rows from the bottom in both).
        func sourcePoint(_ x: Int, _ y: Int) -> (Double, Double) {
            let u = (Double(x) + 0.5) / Double(side), v = (Double(y) + 0.5) / Double(side)
            let cu = 0.5 + (u - 0.5) / zoom, cv = 0.5 + (v - 0.5) / zoom
            return ((mirrored ? 1 - cu : cu) * Double(image.width) - 0.5, cv * Double(image.height) - 0.5)
        }
        guard let imageBuffer = Self.pixelBuffer(side, side, format: kCVPixelFormatType_32BGRA),
              let maskBuffer = Self.pixelBuffer(side, side, format: kCVPixelFormatType_OneComponent8) else { return nil }
        Self.write(imageBuffer) { base, rowBytes in
            for y in 0..<side {
                // Buffer rows are from the top.
                let row = base.advanced(by: (side - 1 - y) * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<side {
                    let (sx, sy) = sourcePoint(x, y)
                    let rgb = Self.sample(image, sx, sy)
                    row[x * 4] = Self.encode(rgb.2); row[x * 4 + 1] = Self.encode(rgb.1); row[x * 4 + 2] = Self.encode(rgb.0); row[x * 4 + 3] = 255
                }
            }
        }
        Self.write(maskBuffer) { base, rowBytes in
            for y in 0..<side {
                let row = base.advanced(by: (side - 1 - y) * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<side {
                    let (sx, sy) = sourcePoint(x, y)
                    // Any hole pixel nearby counts, so the hole is never shrunk by the resize.
                    var inHole = false
                    for dy in -1...1 where !inHole {
                        for dx in -1...1 {
                            let px = Int(sx.rounded()) + dx, py = Int(sy.rounded()) + dy
                            if px >= 0, px < image.width, py >= 0, py < image.height, hole[py * image.width + px] { inHole = true; break }
                        }
                    }
                    row[x] = inHole ? 255 : 0
                }
            }
        }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: imageBuffer), "mask": MLFeatureValue(pixelBuffer: maskBuffer),
        ]), let output = try? model.prediction(from: input), let result = output.featureValue(for: "output") else { return nil }

        // The model's image back over the hole.
        let read: (Int, Int) -> (Float, Float, Float)
        if let buffer = result.imageBufferValue {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let bytes = Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: rowBytes * side))
            let isBGRA = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA
            read = { x, y in
                let i = (side - 1 - y) * rowBytes + x * 4
                let r = bytes[i + (isBGRA ? 2 : 0)], g = bytes[i + 1], b = bytes[i + (isBGRA ? 0 : 2)]
                return (Self.decode(r), Self.decode(g), Self.decode(b))
            }
        } else if let array = result.multiArrayValue, array.count == 3 * side * side {
            // [1, 3, H, W] or [3, H, W], 0…1 (or 0…255), rows from the top.
            let values = (0..<array.count).map { array[$0].floatValue }
            let scale: Float = (values.max() ?? 1) > 1.5 ? 1 / 255 : 1
            read = { x, y in
                let i = (side - 1 - y) * side + x
                return (Self.linear(values[i] * scale), Self.linear(values[side * side + i] * scale), Self.linear(values[2 * side * side + i] * scale))
            }
        } else {
            return nil
        }
        var filled = image
        for y in 0..<image.height {
            for x in 0..<image.width where hole[y * image.width + x] {
                // Image pixel → model pixel.
                let u = (Double(x) + 0.5) / Double(image.width), v = (Double(y) + 0.5) / Double(image.height)
                let mu = mirrored ? 1 - u : u
                let mx = Int(((0.5 + (mu - 0.5) * zoom) * Double(side)).rounded(.down)), my = Int(((0.5 + (v - 0.5) * zoom) * Double(side)).rounded(.down))
                let rgb = read(min(side - 1, max(0, mx)), min(side - 1, max(0, my)))
                filled.pixels[(y * image.width + x) * 3] = rgb.0
                filled.pixels[(y * image.width + x) * 3 + 1] = rgb.1
                filled.pixels[(y * image.width + x) * 3 + 2] = rgb.2
            }
        }
        return filled
    }

    private static func sample(_ image: PatchInpainter.Image, _ x: Double, _ y: Double) -> (Float, Float, Float) {
        let px = min(image.width - 1, max(0, Int(x.rounded()))), py = min(image.height - 1, max(0, Int(y.rounded())))
        let i = (py * image.width + px) * 3
        return (image.pixels[i], image.pixels[i + 1], image.pixels[i + 2])
    }

    /// Linear light to an sRGB-encoded byte, and back.
    private static func encode(_ value: Float) -> UInt8 {
        let v = min(1, max(0, value))
        let e = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        return UInt8(min(255, max(0, e * 255 + 0.5)))
    }

    private static func decode(_ byte: UInt8) -> Float { linear(Float(byte) / 255) }

    private static func linear(_ e: Float) -> Float {
        let e = min(1, max(0, e))
        return e <= 0.04045 ? e / 12.92 : pow((e + 0.055) / 1.055, 2.4)
    }

    private static func pixelBuffer(_ width: Int, _ height: Int, format: OSType) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &buffer)
        return buffer
    }

    private static func write(_ buffer: CVPixelBuffer, _ body: (UnsafeMutableRawPointer, Int) -> Void) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        body(base, CVPixelBufferGetBytesPerRow(buffer))
    }
}
