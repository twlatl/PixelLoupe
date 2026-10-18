import Foundation

/// Finds the LensFun profile that stands in for the Adobe lens profile a Lightroom photo used.
///
/// Lightroom's profiles are Adobe LCP files, which PixelLoupe doesn't have. The lens named in the
/// profile (`Adobe (SIGMA 35mm F1.4 DG HSM A012)`, or `SONY (SIGMA 35mm …) - RAW.lcp`) or, failing
/// that, the lens in the photo's EXIF is matched by name and camera mount against LensFun.
nonisolated final class LightroomLensResolver: @unchecked Sendable {
    struct Query: Sendable {
        var cameraMake: String?
        var cameraModel: String?
        /// The lens named in the photo's metadata.
        var lensModel: String?
        /// `LensProfileName` and `LensProfileFilename` from the develop settings.
        var profileName: String?
        var profileFilename: String?
        var focalLength: Double?
        var aperture: Double?
    }

    private let database: @Sendable () -> LensFunDatabase
    private let lock = NSLock()
    private var matches: [String: LensFunDatabase.Lens?] = [:]

    init(database: @escaping @Sendable () -> LensFunDatabase = { LensFunDatabase.shared }) {
        self.database = database
    }

    /// The profile resolved for the photo's focal length and aperture, or `nil` when no LensFun lens matches.
    func profile(for query: Query) -> PhotoAdjustments.LensProfile? {
        let database = database()
        let camera = database.camera(make: query.cameraMake, model: query.cameraModel)
        for name in Self.candidateNames(query) {
            let key = [query.cameraMake, query.cameraModel, name].map { $0 ?? "" }.joined(separator: "|")
            let cached = lock.withLock { matches[key] }
            let lens: LensFunDatabase.Lens?
            if let cached {
                lens = cached
            } else {
                lens = database.match(make: query.cameraMake, model: query.cameraModel, lens: name)
                lock.withLock { matches[key] = .some(lens) }
            }
            if let lens {
                return LensFunDatabase.profile(
                    for: lens, cropFactor: camera?.cropFactor, focalLength: query.focalLength.flatMap { $0 > 0 ? $0 : nil },
                    aperture: query.aperture.flatMap { $0 > 0 ? $0 : nil }, distance: nil)
            }
        }
        return nil
    }

    /// Lens names to try, best first: the profile's, its filename's, the photo's own.
    static func candidateNames(_ query: Query) -> [String] {
        var names: [String] = []
        for source in [query.profileName, query.profileFilename] {
            guard let source, !source.isEmpty else { continue }
            names.append(contentsOf: lensNames(inProfile: source))
        }
        if let lens = query.lensModel, !lens.isEmpty { names.append(lens) }
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }

    /// The lens inside a profile name: the text in the outermost parentheses, else the name without an
    /// `Adobe`/maker prefix or `- RAW.lcp` suffix.
    static func lensNames(inProfile name: String) -> [String] {
        var text = name.trimmingCharacters(in: .whitespaces)
        for suffix in [".lcp", " - RAW", " - JPEG", " - DNG"] where text.lowercased().hasSuffix(suffix.lowercased()) {
            text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        for suffix in [" - RAW", " - JPEG", " - DNG"] where text.hasSuffix(suffix) { text = String(text.dropLast(suffix.count)) }
        if let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close {
            let inner = String(text[text.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            // "Canon EOS R5 (RF24-70mm F2.8 L IS USM)" style names put the lens inside; so do "Adobe (…)".
            return inner.isEmpty ? [text] : [inner, text]
        }
        return text.isEmpty ? [] : [text]
    }
}
