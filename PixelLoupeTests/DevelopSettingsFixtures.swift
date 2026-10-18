import Foundation

/// Develop settings text in the shape Lightroom Classic writes it (key order, nesting, the profile
/// "Look" block, legacy PV2010 keys next to the 2012 ones). Written by hand from the format, with
/// invented values: no one's photos or catalog are in the repository.
enum DevelopSettingsFixtures {
    struct Fixture {
        var name: String
        var processVersion: String?
        var whiteBalance: String?
        var text: String
    }

    /// A JPEG straight from import: every setting at its default.
    static let untouched = Fixture(name: "untouched JPEG", processVersion: "11.0", whiteBalance: "As Shot", text: """
        s = {
        AutoLateralCA = 0,
        AutoGrayscaleMix = true,
        Blacks2012 = 0,
        Brightness = 0,
        CameraProfile = "Embedded",
        CameraProfileDigest = "54650A341B5B5CCAE8442D0B43A9E2D1",
        ColorNoiseReduction = 0,
        Contrast = 0,
        Contrast2012 = 0,
        ConvertToGrayscale = false,
        DefringeGreenAmount = 0,
        DefringeGreenHueHi = 60,
        DefringeGreenHueLo = 40,
        DefringePurpleAmount = 0,
        DefringePurpleHueHi = 70,
        DefringePurpleHueLo = 30,
        Exposure = 0,
        Exposure2012 = 0,
        GrainSize = 25,
        Highlights2012 = 0,
        IncrementalTemperature = 0,
        IncrementalTint = 0,
        LensManualDistortionAmount = 0,
        LensProfileEnable = 0,
        LensProfileSetup = "LensDefaults",
        OverrideLookVignette = false,
        PerspectiveHorizontal = 0,
        PerspectiveRotate = 0,
        PerspectiveScale = 100,
        PerspectiveVertical = 0,
        PerspectiveX = 0,
        PerspectiveY = 0,
        ProcessVersion = "11.0",
        RedEyeInfo = {  },
        RetouchInfo = {  },
        Shadows = 0,
        Shadows2012 = 0,
        SharpenDetail = 25,
        SharpenEdgeMasking = 0,
        SharpenRadius = 1,
        ToneCurveName2012 = "Linear",
        ToneCurvePV2012 = { 0, 0, 255, 255, },
        ToneCurvePV2012Blue = { 0, 0, 255, 255, },
        ToneCurvePV2012Green = { 0, 0, 255, 255, },
        ToneCurvePV2012Red = { 0, 0, 255, 255, },
        UprightCenterMode = 0,
        UprightCenterNormX = 0.5,
        UprightCenterNormY = 0.5,
        UprightFocalLength35mm = 35,
        UprightFocalMode = 0,
        UprightFourSegmentsCount = 0,
        UprightPreview = false,
        UprightTransformCount = 6,
        UprightVersion = 151388160,
        Version = "15.0",
        WhiteBalance = "As Shot",
        Whites2012 = 0,
        }
        """)

    /// A RAW file as imported with Lightroom's default Adobe Color look and sharpening.
    static let rawDefaults = Fixture(name: "RAW at import defaults", processVersion: "11.0", whiteBalance: "As Shot", text: """
        s = {
        CameraProfile = "Adobe Standard",
        ColorNoiseReduction = 25,
        Exposure2012 = 0,
        IncrementalTemperature = 0,
        IncrementalTint = 0,
        Look = { Amount = 1,
        Group = { ["x-default"] = "Profiles" },
        Name = "Adobe Color",
        Parameters = { CameraProfile = "Adobe Standard",
        ConvertToGrayscale = false,
        ProcessVersion = "11.0",
        ToneCurveName2012 = "",
        ToneCurvePV2012 = { 0, 0, 22, 16, 40, 35, 127, 127, 224, 230, 240, 246, 255, 255, },
        ToneCurvePV2012Blue = { 0, 0, 255, 255, },
        ToneCurvePV2012Green = { 0, 0, 255, 255, },
        ToneCurvePV2012Red = { 0, 0, 255, 255, },
        Version = "15.0", },
        SupportsAmount = false,
        UUID = "B952C231111CD8E0ECC0DF3D4EB1E79B", },
        ProcessVersion = "11.0",
        Sharpness = 40,
        Temperature = 5300,
        Tint = 12,
        ToneCurvePV2012 = { 0, 0, 255, 255, },
        Version = "15.0",
        WhiteBalance = "As Shot",
        }
        """)

    /// A RAW file with a custom white balance and exposure.
    static let rawCustomWhiteBalance = Fixture(name: "RAW with custom white balance", processVersion: "11.0", whiteBalance: "Custom", text: """
        s = {
        Exposure2012 = 0.65,
        ProcessVersion = "11.0",
        Temperature = 4350,
        Tint = -8,
        Version = "15.0",
        WhiteBalance = "Custom",
        }
        """)

    /// A JPEG warmed up and edited in several panels.
    static let editedJPEG = Fixture(name: "edited JPEG", processVersion: "11.0", whiteBalance: "Custom", text: """
        s = {
        Blacks2012 = -12,
        Clarity2012 = 20,
        ColorGradeBlending = 50,
        ColorGradeGlobalHue = 0,
        ColorGradeHighlightHue = 40,
        ColorGradeHighlightLum = 0,
        ColorGradeHighlightSat = 18,
        Contrast2012 = 14,
        CropAngle = 1.09,
        CropBottom = 0.921875,
        CropConstrainAspectRatio = true,
        CropLeft = 0.127589,
        CropRight = 0.794255,
        CropTop = 0.078125,
        Dehaze = 8,
        Exposure2012 = -0.35,
        GrainAmount = 25,
        GrainSize = 25,
        HueAdjustmentBlue = 5,
        IncrementalTemperature = 14,
        IncrementalTint = -6,
        PostCropVignetteAmount = -20,
        ProcessVersion = "11.0",
        Saturation = 10,
        SaturationAdjustmentGreen = -20,
        Shadows2012 = 30,
        Texture = -8,
        Vibrance = 24,
        Version = "15.0",
        WhiteBalance = "Custom",
        }
        """)

    /// A photo with a masked adjustment, a spot removal and a lens profile.
    static let localEdits = Fixture(name: "masks, retouch and lens profile", processVersion: "11.0", whiteBalance: "As Shot", text: """
        s = {
        Exposure2012 = 0,
        LensProfileDigest = "59E78A35E0F6409AF308B231FCBB1234",
        LensProfileEnable = 1,
        LensProfileFilename = "Canon EOS M (Canon EF-M 18-55mm f35-56 IS STM) - RAW.lcp",
        LensProfileIsEmbedded = false,
        LensProfileName = "Adobe (Canon EF-M 18-55mm f/3.5-5.6 IS STM)",
        LensProfileSetup = "Auto",
        MaskGroupBasedCorrections = { { CorrectionActive = true,
        CorrectionName = "Mask 1",
        CorrectionAmount = 1,
        CorrectionMasks = { { MaskActive = true, MaskBlendMode = 0, MaskInverted = false, MaskSubType = 0, MaskSubCategoryID = 50004,
        What = "Mask/Image", }, },
        LocalExposure2012 = 0.4,
        What = "Correction",
        }, },
        ProcessVersion = "11.0",
        RetouchInfo = { { centerX = 0.618654, centerY = 0.4, radius = 0.02, sourceState = "sourceAutoComputed", },  },
        Version = "15.0",
        WhiteBalance = "As Shot",
        }
        """)

    /// A photo with HDR and glow settings from newer Lightroom versions.
    static let hdr = Fixture(name: "HDR photo", processVersion: "11.0", whiteBalance: "As Shot", text: """
        s = {
        AILook = {  },
        CurveRefineSaturation = 100,
        EnableDistractionRemoval = true,
        FilterList = {  },
        Glow = 0,
        GlowRange = 50,
        GlowSpread = 50,
        GlowStyle = 0,
        GlowWarmth = 0,
        HDREditMode = 1,
        HDRMaxValue = 2.3,
        LensBlur = {  },
        PointColors = {  },
        ProcessVersion = "11.0",
        SDRBlend = 0,
        SDRBrightness = 0,
        SDRClarity = 0,
        SDRContrast = 0,
        SDRHighlights = 0,
        SDRShadows = 0,
        SDRWhites = 0,
        Version = "15.0",
        WhiteBalance = "As Shot",
        }
        """)

    /// Settings from Lightroom 4 (process version 2010).
    static let processVersion2010 = Fixture(name: "process version 2010", processVersion: "5.0", whiteBalance: "As Shot", text: """
        s = {
        Brightness = 25,
        Contrast = 12,
        Exposure = 0.5,
        FillLight = 10,
        ProcessVersion = "5.0",
        Shadows = 15,
        ToneCurve = { 0, 0, 255, 255, },
        ToneCurveName = "Linear",
        Version = "7.0",
        WhiteBalance = "As Shot",
        }
        """)

    static let all: [Fixture] = [untouched, rawDefaults, rawCustomWhiteBalance, editedJPEG, localEdits, hdr, processVersion2010]
}
