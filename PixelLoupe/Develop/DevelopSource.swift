import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// A decoded photo that can be re-rendered with any `PhotoAdjustments`.
///
/// RAW files go through Apple's RAW engine (`CIRAWFilter`), which handles exposure, white
/// balance, noise reduction and sharpening at the demosaic stage for the best quality. Other
/// formats get the Core Image equivalents. The rest of the pipeline is shared.
///
/// Not thread-safe: use one instance per thread or task.
nonisolated final class DevelopSource {
    let url: URL
    let isRaw: Bool
    /// Size of the full-resolution image, after orientation.
    let nativeSize: CGSize

    private let rawFilter: CIRAWFilter?
    private let rawDefaults: RawDefaults?
    private let baseImage: CIImage?
    private var scaledBase: (scale: CGFloat, image: CIImage)?
    private var redEyeFilters: (scale: CGFloat, filters: [CIFilter])?

    private struct RawDefaults {
        var neutralTemperature: Float
        var neutralTint: Float
        var luminanceNoiseReduction: Float
        var colorNoiseReduction: Float
        var sharpness: Float
        var detail: Float
        /// Whether the RAW engine applies the camera's built-in lens profile unless asked to.
        var lensCorrection: Bool
    }

    init?(url: URL) {
        self.url = url
        if SupportedImageTypes.isRaw(url), let raw = CIRAWFilter(imageURL: url), let output = raw.outputImage {
            isRaw = true
            rawFilter = raw
            rawDefaults = RawDefaults(
                neutralTemperature: raw.neutralTemperature,
                neutralTint: raw.neutralTint,
                luminanceNoiseReduction: raw.luminanceNoiseReductionAmount,
                colorNoiseReduction: raw.colorNoiseReductionAmount,
                sharpness: raw.sharpnessAmount,
                detail: raw.detailAmount,
                lensCorrection: raw.isLensCorrectionSupported && raw.isLensCorrectionEnabled
            )
            baseImage = nil
            nativeSize = output.extent.size
        } else if let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
            isRaw = false
            rawFilter = nil
            rawDefaults = nil
            baseImage = image
            nativeSize = image.extent.size
        } else {
            return nil
        }
    }

    /// White balance the camera recorded. Non-RAW images are treated as already neutral (6500 K).
    var asShotWhiteBalance: (temperature: Double, tint: Double) {
        guard let rawDefaults else { return (6500, 0) }
        return (Double(rawDefaults.neutralTemperature), Double(rawDefaults.neutralTint))
    }

    /// Whether the file carries the camera's own lens profile (many mirrorless RAW formats), which
    /// Lens Corrections uses instead of a LensFun profile, as Lightroom does.
    var hasBuiltInLensProfile: Bool { rawFilter?.isLensCorrectionSupported ?? false }

    /// Whether the built-in lens profile is applied: when Enable Profile Corrections is on, and
    /// always for cameras whose RAW files apply it by default.
    func isBuiltInLensProfileApplied(_ adjustments: PhotoAdjustments) -> Bool {
        hasBuiltInLensProfile && (adjustments.lens.enableProfileCorrections || rawDefaults?.lensCorrection == true)
    }

    /// Scale that fits the image's long edge in `pixels` (never upscales).
    func scale(toFit pixels: CGFloat) -> CGFloat {
        min(1, pixels / max(nativeSize.width, nativeSize.height, 1))
    }

    /// Full-resolution size of the photo's frame after Rotate/Flip (before cropping).
    func frameSize(_ adjustments: PhotoAdjustments) -> CGSize {
        adjustments.orientation.swapsDimensions ? CGSize(width: nativeSize.height, height: nativeSize.width) : nativeSize
    }

    /// Full-resolution size as shown: rotated or flipped, then cropped (straightening doesn't
    /// change the frame's size).
    func croppedSize(_ adjustments: PhotoAdjustments) -> CGSize {
        let frame = frameSize(adjustments)
        return CGSize(width: frame.width * adjustments.crop.rect.width, height: frame.height * adjustments.crop.rect.height)
    }

    /// Scale at which the photo *as shown* (oriented and cropped) fits `pixels` on its long edge
    /// (never upscales), so a cropped photo still renders at the size it's shown.
    func scale(toFit pixels: CGFloat, adjustments: PhotoAdjustments) -> CGFloat {
        let size = croppedSize(adjustments)
        return min(1, pixels / max(size.width, size.height, 1))
    }

    /// Applies Photo ▸ Rotate/Flip: mirror horizontally, then quarter turns counterclockwise. The
    /// result starts at the origin.
    static func orient(_ image: CIImage, _ orientation: PhotoAdjustments.Orientation) -> CIImage {
        guard !orientation.isIdentity, !image.extent.isInfinite else { return image }
        var result = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if orientation.isMirrored {
            result = result.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -result.extent.width, y: 0))
        }
        if orientation.quarterTurns != 0 {
            result = result.transformed(by: CGAffineTransform(rotationAngle: CGFloat(orientation.quarterTurns) * .pi / 2))
        }
        // Snap to whole pixels at the origin (rotation leaves tiny floating-point offsets).
        let extent = result.extent
        return result.transformed(by: CGAffineTransform(translationX: -extent.minX.rounded(), y: -extent.minY.rounded()))
    }

    /// Renders the photo at `scale` (1 = full resolution) with `adjustments` applied.
    func image(with adjustments: PhotoAdjustments, scale: CGFloat, geometry: CropRendering = .cropped) -> CIImage {
        let corrected = LensCorrector.apply(
            adjustments.lens, to: baseImage(with: adjustments, scale: scale),
            builtInApplied: isBuiltInLensProfileApplied(adjustments)
        )
        let oriented = Self.orient(corrected, adjustments.orientation)
        // Perspective correction works on the photo as shown, so after orientation and before the crop.
        let base = TransformRenderer.apply(adjustments.transform, to: oriented)
        return AdjustmentPipeline.apply(adjustments, to: base, source: self, scale: scale, geometry: geometry)
    }

    /// The decoded image before Lens Corrections and the shared pipeline: RAW decoding settings
    /// applied for RAW files, a downscaled original otherwise.
    func baseImage(with adjustments: PhotoAdjustments, scale: CGFloat) -> CIImage {
        if let rawFilter, let rawDefaults {
            rawFilter.scaleFactor = Float(scale)

            let light = adjustments.light
            rawFilter.exposure = light.isEnabled ? Float(light.exposure) : 0

            let whiteBalance = adjustments.whiteBalance
            rawFilter.neutralTemperature = whiteBalance.isActive
                ? Float(whiteBalance.temperature ?? Double(rawDefaults.neutralTemperature))
                : rawDefaults.neutralTemperature
            rawFilter.neutralTint = whiteBalance.isActive
                ? Float(whiteBalance.tint ?? Double(rawDefaults.neutralTint))
                : rawDefaults.neutralTint

            let noise = adjustments.noiseReduction
            if rawFilter.isLuminanceNoiseReductionSupported {
                rawFilter.luminanceNoiseReductionAmount = noise.isActive && noise.amount > 0
                    ? Float(noise.amount) : rawDefaults.luminanceNoiseReduction
            }
            if rawFilter.isColorNoiseReductionSupported {
                rawFilter.colorNoiseReductionAmount = noise.isActive && noise.color > 0
                    ? Float(noise.color) : rawDefaults.colorNoiseReduction
            }

            let sharpen = adjustments.sharpen
            // Active sharpening is done by the pipeline (it has Radius, Detail and Masking), so the
            // engine's own is switched off then to avoid sharpening twice.
            if rawFilter.isSharpnessSupported {
                rawFilter.sharpnessAmount = sharpen.isActive ? 0 : rawDefaults.sharpness
            }
            if rawFilter.isDetailSupported {
                rawFilter.detailAmount = sharpen.isActive ? 0 : rawDefaults.detail
            }
            if rawFilter.isLensCorrectionSupported {
                rawFilter.isLensCorrectionEnabled = isBuiltInLensProfileApplied(adjustments)
            }

            if let output = rawFilter.outputImage { return output }
        }
        return scaledBaseImage(scale: scale)
    }

    private func scaledBaseImage(scale: CGFloat) -> CIImage {
        guard let baseImage else { return CIImage.empty() }
        if let scaledBase, abs(scaledBase.scale - scale) < 0.001 { return scaledBase.image }
        let image: CIImage
        if scale >= 0.999 {
            image = baseImage
        } else {
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = baseImage.transformed(
                by: CGAffineTransform(translationX: -baseImage.extent.minX, y: -baseImage.extent.minY)
            )
            filter.scale = Float(scale)
            filter.aspectRatio = 1
            image = filter.outputImage ?? baseImage
        }
        scaledBase = (scale, image)
        return image
    }

    /// Red-eye correction filters, detected once per scale (face detection is expensive).
    func redEyeCorrections(for image: CIImage, scale: CGFloat) -> [CIFilter] {
        if let redEyeFilters, abs(redEyeFilters.scale - scale) < 0.001 { return redEyeFilters.filters }
        let filters = image.autoAdjustmentFilters(options: [.enhance: false, .redEye: true])
        redEyeFilters = (scale, filters)
        return filters
    }
}

/// The adjustments applied after decoding, in a fixed order.
nonisolated enum AdjustmentPipeline {
    static func apply(
        _ adjustments: PhotoAdjustments, to base: CIImage, source: DevelopSource, scale: CGFloat,
        geometry: CropRendering = .cropped
    ) -> CIImage {
        var extent = base.extent
        guard !extent.isEmpty, !extent.isInfinite else { return base }
        // An Adobe profile's own settings render with it, out of sight of the sliders.
        let adjustments = AdobeProfileLook.withProfileSettings(adjustments)
        var image = RetouchRenderer.apply(spots: adjustments.spots, redEyes: adjustments.redEyes, to: base)

        if adjustments.redEye.isActive {
            for filter in source.redEyeCorrections(for: base, scale: scale) {
                filter.setValue(image, forKey: kCIInputImageKey)
                image = filter.outputImage ?? image
            }
        }

        if !source.isRaw {
            let light = adjustments.light
            if light.isEnabled, light.exposure != 0 {
                let filter = CIFilter.exposureAdjust()
                filter.inputImage = image
                filter.ev = Float(light.exposure)
                image = filter.outputImage ?? image
            }
            let whiteBalance = adjustments.whiteBalance
            if whiteBalance.isActive {
                let filter = CIFilter.temperatureAndTint()
                filter.inputImage = image
                // The temperature is the light the photo was lit by, as for RAW files: higher is warmer.
                filter.neutral = CIVector(x: whiteBalance.temperature ?? 6500, y: whiteBalance.tint ?? 0)
                filter.targetNeutral = CIVector(x: 6500, y: 0)
                image = filter.outputImage ?? image
            }
            let noise = adjustments.noiseReduction
            if noise.isActive {
                let filter = CIFilter.noiseReduction()
                filter.inputImage = image
                filter.noiseLevel = Float(0.005 + max(noise.amount, noise.color) * 0.06)
                filter.sharpness = Float(noise.detail * 0.8)
                image = filter.outputImage ?? image
            }
        }

        let light = adjustments.light
        if light.isEnabled, light.brilliance != 0 || light.highlights < 0 || light.shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            filter.shadowAmount = Float((light.shadows + 0.5 * light.brilliance).clamped(to: -1...1))
            filter.highlightAmount = Float((1 + min(light.highlights, 0) - 0.3 * max(light.brilliance, 0)).clamped(to: 0...1))
            image = filter.outputImage ?? image
        }

        // An Adobe profile: its look under everything that follows (curves, color, black and white).
        let profile = adjustments.profile
        if profile.isEnabled, profile.amount != 0, let id = profile.adobeID {
            for cube in AdobeProfileLibrary.shared.cubes(id: id, amount: profile.amount) {
                let filter = CIFilter.colorCubeWithColorSpace()
                filter.inputImage = image
                filter.cubeDimension = Float(cube.dimension)
                filter.cubeData = cube.data
                filter.colorSpace = CGColorSpace(name: cube.colorSpaceName as CFString)
                image = filter.outputImage ?? image
            }
        }

        if let key = ColorLUT.key(for: adjustments) {
            let filter = CIFilter.colorCubeWithColorSpace()
            filter.inputImage = image
            filter.cubeDimension = Float(ColorLUT.dimension)
            filter.cubeData = ColorLUT.cubeData(for: key)
            filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            image = filter.outputImage ?? image
        }

        let longEdge = max(extent.width, extent.height)

        image = PresenceRenderer.apply(adjustments.presence, to: image, longEdge: longEdge)

        if adjustments.definition.isActive {
            let filter = CIFilter.unsharpMask()
            filter.inputImage = image
            filter.radius = Float(longEdge * 0.012)
            filter.intensity = Float(adjustments.definition.intensity * 0.9)
            image = filter.outputImage ?? image
        }

        image = SharpenRenderer.apply(adjustments.sharpen, to: image, scale: scale)

        // Masks work on the whole frame, so before the crop moves it.
        image = LocalAdjustmentRenderer.apply(adjustments.masks, to: image)

        // Straighten and crop before the vignette and grain, so they follow the crop (Lightroom's
        // post-crop vignette).
        image = CropRenderer.apply(adjustments.crop, to: image, frame: extent, rendering: geometry)
        extent = image.extent

        image = VignetteRenderer.apply(adjustments.vignette, to: image)

        let effects = adjustments.effects
        if effects.isActive, effects.grain > 0, let grain = grainLayer(effects, extent: extent, scale: scale) {
            image = grain.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        }

        return image.cropped(to: extent)
    }

    /// Film grain: neutral gray noise centered on 50% gray, for an Overlay blend (which leaves the
    /// image unchanged where the layer is 50% gray). Size is in pixels of the full-resolution
    /// photo, so the grain looks the same in a fitted preview and at 100%; roughness softens it;
    /// the seed moves the noise so each photo has its own pattern, the same every time.
    static func grainLayer(_ effects: PhotoAdjustments.Effects, extent: CGRect, scale: CGFloat) -> CIImage? {
        guard let noise = CIFilter.randomGenerator().outputImage else { return nil }
        let fullSize = 1 + effects.grainSize.clamped(to: 0...1) * 3
        let grainSize = max(fullSize * scale, 1)
        let noiseExtent = CGRect(x: 0, y: 0, width: extent.width / grainSize + 2, height: extent.height / grainSize + 2)
        // Each seed reads a different part of the (endless) random field.
        let seed = effects.grainSeed
        let shifted = noise.transformed(by: CGAffineTransform(translationX: CGFloat((seed &* 7919) % 4096), y: CGFloat((seed &* 104_729) % 4096)))
        // The generator's alpha is random too. Make it opaque first, or the color matrix (which
        // un-premultiplies) divides by near-zero alpha and the noise overwhelms the photo.
        var opaque = shifted.cropped(to: noiseExtent).settingAlphaOne(in: noiseExtent)
        let softness = 1 - effects.grainRoughness.clamped(to: 0...1)
        if softness > 0.05 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = opaque.clampedToExtent()
            blur.radius = Float(softness * 1.2)
            opaque = blur.outputImage?.cropped(to: noiseExtent) ?? opaque
        }
        // Blurring lowers the noise's contrast; make it up so Amount means the same at any roughness.
        let strength = CGFloat(effects.grain.clamped(to: 0...1)) * 0.5 * (1 + softness * 1.5)
        let gray = opaque.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: strength, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: strength, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0.5 - strength / 2, y: 0.5 - strength / 2, z: 0.5 - strength / 2, w: 0),
        ])
        return gray
            .transformed(by: CGAffineTransform(scaleX: grainSize, y: grainSize))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    /// Suggested Light settings: exposure to bring average brightness to middle gray, plus the
    /// shadow/highlight balance Core Image's auto-enhance recommends. `region` (a unit rectangle,
    /// origin bottom left) limits what's measured.
    static func autoLight(for source: DevelopSource, current: PhotoAdjustments, context: CIContext, region: CGRect? = nil) -> PhotoAdjustments.Light {
        var neutral = current
        neutral.light = PhotoAdjustments.Light()
        let scale = source.scale(toFit: 512)
        let image = AutoDevelop.cropped(source.baseImage(with: neutral, scale: scale), to: region)

        var light = PhotoAdjustments.Light()
        if let averageFilter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent),
        ]), let average = averageFilter.outputImage {
            var pixel = [Float](repeating: 0, count: 4)
            context.render(
                average, toBitmap: &pixel, rowBytes: 16,
                bounds: average.extent, format: .RGBAf, colorSpace: nil
            )
            let luminance = Double(0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2])
            if luminance > 0.0001 {
                light.exposure = (log2(0.18 / luminance) * 20).rounded() / 20
                light.exposure = light.exposure.clamped(to: -2...2)
            }
        }
        for filter in image.autoAdjustmentFilters(options: [.enhance: true, .redEye: false])
        where filter.name == "CIHighlightShadowAdjust" {
            if let shadows = filter.value(forKey: "inputShadowAmount") as? Double {
                light.shadows = (shadows * 100).rounded() / 100
            }
            if let highlights = filter.value(forKey: "inputHighlightAmount") as? Double {
                light.highlights = ((highlights - 1) * 100).rounded() / 100
            }
        }
        return light
    }
}

/// What an Adobe profile adds to the photo's own settings when it renders.
nonisolated enum AdobeProfileLook {
    /// `adjustments` plus the profile's hidden settings, at the profile's amount: sliders add to the
    /// photo's; curves, color wheels and the vignette apply where the photo has none of its own.
    static func withProfileSettings(_ adjustments: PhotoAdjustments, library: AdobeProfileLibrary = .shared) -> PhotoAdjustments {
        let profile = adjustments.profile
        guard profile.isEnabled, profile.amount != 0, let id = profile.adobeID, let hidden = library.hiddenSettings(id: id),
              hidden != PhotoAdjustments() else { return adjustments }
        let k = profile.amount
        var result = adjustments
        result.light.exposure += hidden.light.exposure * k
        result.light.contrast += hidden.light.contrast * k
        result.light.highlights += hidden.light.highlights * k
        result.light.shadows += hidden.light.shadows * k
        result.light.whites += hidden.light.whites * k
        result.light.blackPoint += hidden.light.blackPoint * k
        result.presence.texture += hidden.presence.texture * k
        result.presence.clarity += hidden.presence.clarity * k
        result.presence.dehaze += hidden.presence.dehaze * k
        result.presence.vibrance += hidden.presence.vibrance * k
        result.presence.saturation += hidden.presence.saturation * k
        if result.curves.rgb.isIdentity { result.curves.rgb = hidden.curves.rgb }
        if result.curves.red.isIdentity { result.curves.red = hidden.curves.red }
        if result.curves.green.isIdentity { result.curves.green = hidden.curves.green }
        if result.curves.blue.isIdentity { result.curves.blue = hidden.curves.blue }
        if result.curves.parametric.isIdentity { result.curves.parametric = hidden.curves.parametric }
        let none = PhotoAdjustments.ColorWheel()
        if result.color.shadows == none { result.color.shadows = hidden.color.shadows }
        if result.color.midtones == none { result.color.midtones = hidden.color.midtones }
        if result.color.highlights == none { result.color.highlights = hidden.color.highlights }
        if result.color.global == none { result.color.global = hidden.color.global }
        if result.color.balance == 0 { result.color.balance = hidden.color.balance }
        for range in PhotoAdjustments.SelectiveColorRange.allCases {
            result.selectiveColor[range].hue += hidden.selectiveColor[range].hue * k
            result.selectiveColor[range].saturation += hidden.selectiveColor[range].saturation * k
            result.selectiveColor[range].luminance += hidden.selectiveColor[range].luminance * k
        }
        if !result.vignette.isActive, hidden.vignette.isActive { result.vignette = hidden.vignette }
        return result
    }
}
