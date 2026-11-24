import CoreGraphics
import Foundation

nonisolated extension PhotoAdjustments {
    /// Remove's Blemish Removal (RAW-306): blemishes found on skin and filled the way Remove fills a spot.
    ///
    /// Only what the user chose is stored. The blemishes themselves are found again from the file and kept in the
    /// app's caches (``BlemishStore``), so the settings stay small and can be copied to other photos.
    struct BlemishRemoval: Codable, Equatable, Sendable {
        var isEnabled = false
        /// 0…1: higher removes more of what was found as blemishes.
        var blemishes = 0.5
        /// 0…1: higher also removes more of what looks like freckles, moles and birthmarks.
        var naturalMarks = 0.0
        /// Blemishes the user put back, by ``BlemishCandidate/id``.
        var excluded: Set<UInt64> = []

        var isActive: Bool { isEnabled }

        /// Whether `candidate` is removed at these settings.
        func removes(_ candidate: BlemishCandidate) -> Bool {
            !excluded.contains(candidate.id) && selects(candidate)
        }

        /// Whether the sliders choose `candidate`, whether or not the user put it back.
        func selects(_ candidate: BlemishCandidate) -> Bool {
            guard blemishes > 0 else { return false }
            guard candidate.blemish >= 1 - blemishes else { return false }
            return candidate.natural < 0.5 || candidate.natural <= naturalMarks
        }

        /// The Remove spots that fill what these settings remove.
        func spots(for candidates: [BlemishCandidate]) -> [Spot] {
            candidates.filter(removes).map(\.spot)
        }
    }
}

nonisolated extension PhotoAdjustments.BlemishRemoval {
    private enum CodingKeys: String, CodingKey { case isEnabled, blemishes, naturalMarks, excluded }

    /// Fields missing from saved settings decode as their defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        blemishes = try container.decodeIfPresent(Double.self, forKey: .blemishes) ?? blemishes
        naturalMarks = try container.decodeIfPresent(Double.self, forKey: .naturalMarks) ?? naturalMarks
        excluded = try container.decodeIfPresent(Set<UInt64>.self, forKey: .excluded) ?? excluded
    }
}

/// A mark found on skin that might be a blemish, in the frame's unit coordinates (origin bottom-left, as spots have).
nonisolated struct BlemishCandidate: Codable, Equatable, Sendable {
    /// Stable across finding it again: from where it is and how big, roughly.
    var id: UInt64
    var center: PhotoAdjustments.UnitPoint
    /// A fraction of the frame's long edge.
    var radius: Double
    /// What's covered: the mark and a little around it.
    var matte: PhotoAdjustments.ObjectMatte
    /// 0…1: how much it looks like a blemish (red, raised, uneven).
    var blemish: Double
    /// 0…1: how much it looks like a natural mark (brown, round, even).
    var natural: Double

    /// The Remove spot that fills it: patch fill (never generative), with a seed from its id so it always fills the same.
    var spot: PhotoAdjustments.Spot {
        var spot = PhotoAdjustments.Spot()
        spot.id = UUID(uuid: Self.uuid(id))
        spot.kind = .remove
        spot.area = PhotoAdjustments.RemoveArea(object: matte)
        spot.center = center
        spot.source = center
        spot.radius = radius
        spot.seed = id | 1
        return spot
    }

    private static func uuid(_ id: UInt64) -> uuid_t {
        let b = withUnsafeBytes(of: id.bigEndian, Array.init)
        return (0xB1, 0xE3, 0x15, 0x40, 0, 0, 0, 0, b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7])
    }

    /// An id from where the mark is and how big, quantized so finding it again on a slightly different render (a
    /// pixel off) usually gives the same one.
    static func id(center: CGPoint, radius: Double) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for value in [Int((center.x * 1000).rounded()), Int((center.y * 1000).rounded()), Int((log2(max(radius, 1e-5)) * 2).rounded())] {
            for byte in withUnsafeBytes(of: Int64(value).littleEndian, Array.init) {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
        }
        return hash
    }
}
