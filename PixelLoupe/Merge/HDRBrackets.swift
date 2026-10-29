import Foundation

/// Photo Merge ▸ HDR Panorama's bracket sets: the photos split into runs taken one after another with
/// the same exposures, as Lightroom finds them. Each set is one position of the panorama.
///
/// Sets are matched by exposure compensation (EXIF Exposure Bias), which a camera's auto bracketing
/// records exactly. Shutter speed doesn't repeat from set to set: each position meters its own base
/// exposure, and the darkest frames can all hit the fastest shutter speed (two frames of a 7-shot
/// set at 1/4000 s). Without compensation, or when it doesn't split them, the sets are matched by
/// exposure (shutter speed, aperture and ISO) instead, from each set's darkest photo.
nonisolated enum HDRBrackets {
    /// The most photos a bracket set can have.
    static let largestSet = 9
    /// Compensations this close (EV) are the same step of the bracket.
    static let biasTolerance = 0.1
    /// Exposure offsets this close (EV) are the same step, when sets are matched by exposure.
    static let exposureTolerance = 0.2

    /// The bracket sets, in capture order (each darkest first by its compensation or exposure), or nil
    /// when the photos aren't sets of the same bracket: Lightroom then offers a plain panorama instead.
    static func sets(_ sources: [PhotoMergeSource]) -> [[PhotoMergeSource]]? {
        let photos = sources.sorted {
            ($0.captureDate ?? .distantFuture, $0.name) < ($1.captureDate ?? .distantFuture, $1.name)
        }
        guard photos.count >= 4 else { return nil }
        // Compensation first; exposure when it's missing or doesn't split them (brackets shot in manual
        // exposure can record no compensation).
        var ways: [(steps: [Double], tolerance: Double)] = []
        if photos.allSatisfy({ $0.exposureBias != nil }) {
            ways.append((photos.map { $0.exposureBias ?? 0 }, biasTolerance))
        }
        if photos.allSatisfy({ $0.exposureTime > 0 && $0.aperture > 0 && $0.iso > 0 }) {
            ways.append((photos.map { log2($0.exposureTime * Double($0.iso) / ($0.aperture * $0.aperture)) }, exposureTolerance))
        }
        for way in ways {
            for size in 2...min(largestSet, photos.count / 2) where photos.count % size == 0 {
                if let sets = split(photos, steps: way.steps, size: size, tolerance: way.tolerance) { return sets }
            }
        }
        return nil
    }

    /// The photos as sets of `size`, if every set's steps (from its darkest) are the first set's and
    /// none repeats within a set.
    private static func split(_ photos: [PhotoMergeSource], steps: [Double], size: Int, tolerance: Double) -> [[PhotoMergeSource]]? {
        var pattern: [Double]?
        var sets: [[PhotoMergeSource]] = []
        for start in stride(from: 0, to: photos.count, by: size) {
            let range = start..<(start + size)
            let set = Array(steps[range])
            let darkest = set.min() ?? 0
            let offsets = set.map { $0 - darkest }
            let sorted = offsets.sorted()
            guard zip(sorted, sorted.dropFirst()).allSatisfy({ $1 - $0 > tolerance }) else { return nil }
            if let pattern {
                guard zip(pattern, offsets).allSatisfy({ abs($0 - $1) <= tolerance }) else { return nil }
            } else {
                pattern = offsets
            }
            sets.append(range.sorted { steps[$0] < steps[$1] }.map { photos[$0] })
        }
        return sets
    }
}
