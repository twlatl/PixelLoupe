import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies masks' local adjustments: each is the photo adjusted by its sliders, blended in through
/// its mask. Gradients are analytic Core Image gradients and brushes are painted at the render's size
/// (`BrushRasterizer`), so a mask costs one blend and the adjustments it asks for; spatial ones (clarity,
/// texture, dehaze) run only when used.
nonisolated enum LocalAdjustmentRenderer {
    /// `subject` is the photo's subject matte (``SubjectMatteStore``), when a mask needs it and it's been
    /// found; a Subject or Background shape adds nothing without it.
    static func apply(_ masks: [PhotoAdjustments.LocalAdjustment], to image: CIImage, subject: CIImage? = nil, scale: CGFloat = 1) -> CIImage {
        var result = image
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return image }
        for mask in masks where mask.isActive {
            guard let selection = self.mask(for: mask, extent: extent, subject: subject) else { continue }
            let adjusted = adjust(result, with: mask.settings, scale: scale)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = adjusted
            blend.backgroundImage = result
            blend.maskImage = selection
            result = blend.outputImage?.cropped(to: extent) ?? result
        }
        return result
    }

    // MARK: - Masks

    /// The mask as a gray image over `extent` (white where the adjustment applies in full), scaled by the amount.
    static func mask(for adjustment: PhotoAdjustments.LocalAdjustment, extent: CGRect, subject: CIImage? = nil) -> CIImage? {
        var selection: CIImage?
        for component in adjustment.components {
            guard var shape = shape(component.shape, extent: extent, subject: subject) else { continue }
            if component.isInverted { shape = invert(shape) }
            guard let current = selection else {
                // The first shape starts the mask (subtracting from nothing leaves nothing).
                selection = component.mode == .subtract ? black(extent) : shape
                continue
            }
            switch component.mode {
            case .add:
                selection = shape.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: current])
            case .subtract:
                selection = invert(shape).applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: current])
            case .intersect:
                selection = shape.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: current])
            }
        }
        guard var selection else { return nil }
        let amount = CGFloat(adjustment.amount.clamped(to: 0...1))
        if amount < 1 {
            selection = selection.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }
        return selection.cropped(to: extent)
    }

    private static func black(_ extent: CGRect) -> CIImage {
        CIImage(color: .black).cropped(to: extent)
    }

    private static func invert(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorInvert").cropped(to: image.extent)
    }

    private static func shape(_ shape: PhotoAdjustments.MaskShape, extent: CGRect, subject: CIImage?) -> CIImage? {
        func point(_ p: PhotoAdjustments.UnitPoint) -> CGPoint {
            CGPoint(x: extent.minX + CGFloat(p.x) * extent.width, y: extent.minY + CGFloat(p.y) * extent.height)
        }
        switch shape {
        case .linear(let gradient):
            let zero = point(gradient.zero), full = point(gradient.full)
            guard hypot(full.x - zero.x, full.y - zero.y) > 0.5 else { return nil }
            let filter = CIFilter.linearGradient()
            filter.point0 = zero
            filter.point1 = full
            filter.color0 = CIColor(red: 0, green: 0, blue: 0)
            filter.color1 = CIColor(red: 1, green: 1, blue: 1)
            return filter.outputImage?.cropped(to: extent)
        case .radial(let ellipse):
            let rx = CGFloat(ellipse.radiusX) * extent.width, ry = CGFloat(ellipse.radiusY) * extent.height
            guard rx >= 0.5, ry >= 0.5 else { return nil }
            // A circle of radius 1: white inside the feathered core, black past the edge.
            let filter = CIFilter.radialGradient()
            filter.center = .zero
            filter.radius0 = Float(1 - ellipse.feather.clamped(to: 0...1))
            filter.radius1 = 1
            filter.color0 = CIColor(red: 1, green: 1, blue: 1)
            filter.color1 = CIColor(red: 0, green: 0, blue: 0)
            guard let unit = filter.outputImage else { return nil }
            let center = point(ellipse.center)
            return unit
                .transformed(by: CGAffineTransform(scaleX: rx, y: ry))
                .transformed(by: CGAffineTransform(rotationAngle: CGFloat(ellipse.angle) * .pi / 180))
                .transformed(by: CGAffineTransform(translationX: center.x, y: center.y))
                .cropped(to: extent)
        case .brush(let brush):
            // Black when nothing is painted, so an inverted empty brush selects everything.
            return BrushRasterizer.image(for: brush, extent: extent)
        case .subject(let selection):
            return subject.map { refine(placed($0, in: extent), selection, extent: extent) }
        case .background(let selection):
            return subject.map { refine(invert(placed($0, in: extent)), selection, extent: extent) }
        }
    }

    /// The subject matte stretched over the frame (it was found on the same frame, smaller).
    private static func placed(_ matte: CIImage, in extent: CGRect) -> CIImage {
        let size = matte.extent
        guard size.width > 0, size.height > 0 else { return black(extent) }
        return matte
            .transformed(by: CGAffineTransform(translationX: -size.minX, y: -size.minY))
            .transformed(by: CGAffineTransform(scaleX: extent.width / size.width, y: extent.height / size.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    /// Edge grows (or shrinks) the selection by up to 3% of the long edge; Feather then softens it by up
    /// to 3%.
    static func refine(_ selection: CIImage, _ settings: PhotoAdjustments.SubjectSelection, extent: CGRect) -> CIImage {
        let longEdge = max(extent.width, extent.height)
        var result = selection
        let edge = settings.edge.clamped(to: -1...1)
        let reach = abs(edge) * 0.03 * longEdge
        if reach >= 0.5 {
            result = result.clampedToExtent()
                .applyingFilter(edge > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum", parameters: [kCIInputRadiusKey: reach])
                .cropped(to: extent)
        }
        let softness = settings.feather.clamped(to: 0...1) * 0.03 * longEdge
        if softness >= 0.5 {
            result = result.clampedToExtent().applyingGaussianBlur(sigma: softness / 2).cropped(to: extent)
        }
        return result
    }

    // MARK: - Adjusting

    /// `image` with a mask's sections applied everywhere (the mask decides where it shows): its exposure and
    /// white balance shift, then the photo's own tone and color stage (``AdjustmentPipeline/applyTone``) and
    /// grain, so a mask's sliders look just like the Develop panel's. `scale` is the render's (for grain size).
    static func adjust(_ image: CIImage, with settings: PhotoAdjustments.LocalSettings, scale: CGFloat = 1) -> CIImage {
        var result = image
        let light = settings.light
        if light.isEnabled, light.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = result
            filter.ev = Float(light.exposure.clamped(to: -5...5))
            result = filter.outputImage ?? result
        }
        if settings.isWhiteBalanceEnabled, settings.temperature != 0 || settings.tint != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = result
            // Warmer is a higher temperature, as in the white balance; positive tint is magenta.
            filter.neutral = CIVector(x: 6500 + settings.temperature * 2000, y: settings.tint * 150)
            filter.targetNeutral = CIVector(x: 6500, y: 0)
            result = filter.outputImage ?? result
        }

        let extent = image.extent
        result = AdjustmentPipeline.applyTone(settings.adjustments, to: result, longEdge: max(extent.width, extent.height), reducesNoise: true)

        let effects = settings.effects
        if effects.isActive, effects.grain > 0, !extent.isInfinite, let grain = AdjustmentPipeline.grainLayer(effects, extent: extent, scale: scale) {
            result = grain.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: result]).cropped(to: extent)
        }
        return result
    }
}
