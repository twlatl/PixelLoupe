import Foundation

/// Lightroom's orientation codes and how they relate to a file's EXIF orientation.
///
/// Lightroom stores a photo's orientation as a two-letter code that **already includes** the user's
/// rotations. PixelLoupe keeps the file's own EXIF orientation in `Photo.orientation` and the user's
/// rotation and flips in `PhotoAdjustments.orientation`, so the import derives the second from the
/// first and Lightroom's code (see ``adjustment(lightroom:file:)``).
nonisolated enum LightroomOrientation {
    /// The EXIF orientation (1–8) for a Lightroom code, or `nil` for an unknown code.
    ///
    /// The upright and rotated forms were confirmed against files in a real catalog (`BC` is 6 and
    /// `DA` is 8). The mirrored forms follow Lightroom's documented order and are unconfirmed.
    static func exif(forCode code: String?) -> Int? {
        switch code {
        case "AB": 1
        case "BA": 2
        case "CD": 3
        case "DC": 4
        case "AD": 5
        case "BC": 6
        case "CB": 7
        case "DA": 8
        default: nil
        }
    }

    // Each EXIF orientation is a mirror (about the vertical axis, applied first) followed by a
    // counterclockwise turn: `rotate(turns) ∘ mirror`.
    private typealias Transform = (mirrored: Bool, turns: Int)

    private static func transform(forExif orientation: Int) -> Transform {
        switch orientation {
        case 2: (true, 0)
        case 3: (false, 2)
        case 4: (true, 2)
        case 5: (true, 1)
        case 6: (false, 3)
        case 7: (true, 3)
        case 8: (false, 1)
        default: (false, 0)
        }
    }

    /// `a` after `b` (apply `b` first). A mirror reverses the direction of a turn that follows it.
    private static func compose(_ a: Transform, after b: Transform) -> Transform {
        let turns = a.turns + (a.mirrored ? -b.turns : b.turns)
        return (a.mirrored != b.mirrored, ((turns % 4) + 4) % 4)
    }

    private static func inverse(_ t: Transform) -> Transform {
        // A mirror with a turn is its own inverse; a plain turn inverts by turning back.
        t.mirrored ? t : (false, (4 - t.turns) % 4)
    }

    /// The rotation and flip to apply on top of a file whose EXIF orientation is `file` to reach
    /// Lightroom's `lightroom` orientation (both EXIF numbers). The identity if they agree.
    static func adjustment(lightroom: Int, file: Int) -> PhotoAdjustments.Orientation {
        let result = compose(transform(forExif: lightroom), after: inverse(transform(forExif: file)))
        return PhotoAdjustments.Orientation(quarterTurns: result.turns, isMirrored: result.mirrored)
    }
}
