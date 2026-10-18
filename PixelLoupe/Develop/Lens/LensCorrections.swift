import Foundation

nonisolated extension PhotoAdjustments {
    /// Lens Corrections, like Lightroom's panel: Profile (a LensFun lens profile, or the camera's
    /// built-in one) and Manual (distortion, defringe and vignetting).
    struct LensCorrections: Equatable, Sendable {
        enum ProfileSetup: String, Codable, Sendable, CaseIterable {
            /// The profile matching the photo's camera and lens.
            case auto
            /// A profile picked from the Make, Model and Profile menus.
            case custom
        }

        // MARK: Profile

        var removeChromaticAberration = false
        /// Lateral chromatic aberration measured from the photo when Remove Chromatic Aberration was
        /// turned on (used when the profile has none).
        var chromaticAberration = RadialScale()
        var enableProfileCorrections = false
        var setup = ProfileSetup.auto
        /// The LensFun profile chosen for the photo, resolved for its focal length and aperture.
        /// Nil when there's none (or the camera's built-in profile is used).
        var profile: LensProfile?
        /// Lightroom's Amount sliders: 0…2, 1 being the profile as measured.
        var distortionAmount = 1.0
        var vignettingAmount = 1.0

        // MARK: Manual

        /// -1…1; positive corrects barrel distortion (pulls the edges in), negative pincushion.
        var manualDistortion = 0.0
        /// Scales the photo up so corrected edges never show empty space.
        var constrainCrop = false
        /// 0…1 (Lightroom's 0…20).
        var purpleAmount = 0.0
        /// Hue range on the purple slider, 0…1 (Lightroom's 0…100).
        var purpleHue = HueRange(lower: 0.3, upper: 0.7)
        var greenAmount = 0.0
        var greenHue = HueRange(lower: 0.4, upper: 0.6)
        /// -1…1; positive brightens the corners.
        var manualVignetting = 0.0
        /// 0…1: how far toward the center the vignetting reaches (lower reaches further).
        var vignettingMidpoint = 0.5

        struct RadialScale: Codable, Equatable, Sendable {
            /// How much larger (above 1) the red and blue channels are than green at the same radius.
            var red = 1.0
            var blue = 1.0

            var isIdentity: Bool { red == 1 && blue == 1 }
        }

        struct HueRange: Codable, Equatable, Sendable {
            var lower: Double
            var upper: Double
        }

        /// Whether a LensFun profile's corrections apply.
        var appliesProfile: Bool { enableProfileCorrections && profile != nil }

        var hasManualCorrections: Bool {
            manualDistortion != 0 || purpleAmount > 0 || greenAmount > 0 || manualVignetting != 0
        }

        var isDefault: Bool { self == LensCorrections() }
    }

    /// A LensFun calibration resolved for one photo: the lens's distortion, chromatic aberration and
    /// vignetting coefficients at the photo's focal length and aperture, so rendering (thumbnails
    /// included) never needs the database.
    struct LensProfile: Codable, Equatable, Sendable {
        var maker: String
        var model: String
        /// Which of the lens's calibrations, when it has several (by crop factor).
        var variant: String = ""

        /// Distortion as rd = ru · (a·ru³ + b·ru² + c·ru + d + e·ru⁴) (every LensFun model fits);
        /// empty when the profile has none.
        var distortion: [Double] = []
        /// Lateral chromatic aberration for red and blue as rd = ru · (b·ru² + c·ru + v); empty when none.
        var tcaRed: [Double] = []
        var tcaBlue: [Double] = []
        /// Vignetting as gain = 1 / (1 + k1·r² + k2·r⁴ + k3·r⁶); empty when none.
        var vignetting: [Double] = []

        /// The radius of 1 in the distortion and chromatic aberration models, as a fraction of half
        /// the photo's diagonal.
        var distortionUnit = 1.0
        /// The same for the vignetting model.
        var vignettingUnit = 1.0

        var title: String { "\(maker) \(model)" }
    }
}

nonisolated extension PhotoAdjustments.LensCorrections: Codable {
    private enum CodingKeys: String, CodingKey {
        case removeChromaticAberration, chromaticAberration, enableProfileCorrections, setup, profile
        case distortionAmount, vignettingAmount, manualDistortion, constrainCrop
        case purpleAmount, purpleHue, greenAmount, greenHue, manualVignetting, vignettingMidpoint
    }

    /// Settings missing from older saves decode as their defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func decode<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        self.init()
        removeChromaticAberration = try decode(.removeChromaticAberration, removeChromaticAberration)
        chromaticAberration = try decode(.chromaticAberration, chromaticAberration)
        enableProfileCorrections = try decode(.enableProfileCorrections, enableProfileCorrections)
        setup = try decode(.setup, setup)
        profile = try container.decodeIfPresent(PhotoAdjustments.LensProfile.self, forKey: .profile)
        distortionAmount = try decode(.distortionAmount, distortionAmount)
        vignettingAmount = try decode(.vignettingAmount, vignettingAmount)
        manualDistortion = try decode(.manualDistortion, manualDistortion)
        constrainCrop = try decode(.constrainCrop, constrainCrop)
        purpleAmount = try decode(.purpleAmount, purpleAmount)
        purpleHue = try decode(.purpleHue, purpleHue)
        greenAmount = try decode(.greenAmount, greenAmount)
        greenHue = try decode(.greenHue, greenHue)
        manualVignetting = try decode(.manualVignetting, manualVignetting)
        vignettingMidpoint = try decode(.vignettingMidpoint, vignettingMidpoint)
    }
}
