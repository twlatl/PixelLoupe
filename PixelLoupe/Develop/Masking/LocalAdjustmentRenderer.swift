import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies masks' local adjustments: each is the photo adjusted by its sliders, blended in through
/// its mask. Gradients are analytic Core Image gradients and brushes are painted at the render's size
/// (`BrushRasterizer`), so a mask costs one blend and the adjustments it asks for; spatial ones (clarity,
/// texture, dehaze) run only when used.
nonisolated enum LocalAdjustmentRenderer {
    static func apply(_ masks: [PhotoAdjustments.LocalAdjustment], to image: CIImage) -> CIImage {
        var result = image
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return image }
        for mask in masks where mask.isActive {
            guard let selection = self.mask(for: mask, extent: extent) else { continue }
            let adjusted = adjust(result, with: mask.settings)
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
    static func mask(for adjustment: PhotoAdjustments.LocalAdjustment, extent: CGRect) -> CIImage? {
        var selection: CIImage?
        for component in adjustment.components {
            guard var shape = shape(component.shape, extent: extent) else { continue }
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

    private static func shape(_ shape: PhotoAdjustments.MaskShape, extent: CGRect) -> CIImage? {
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
        }
    }

    // MARK: - Adjusting

    /// `image` with a mask's sliders applied everywhere (the mask decides where it shows).
    static func adjust(_ image: CIImage, with settings: PhotoAdjustments.LocalSettings) -> CIImage {
        var result = image
        if settings.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = result
            filter.ev = Float(settings.exposure.clamped(to: -5...5))
            result = filter.outputImage ?? result
        }
        if settings.temperature != 0 || settings.tint != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = result
            // Warmer is a higher temperature, as in the white balance; positive tint is magenta.
            filter.neutral = CIVector(x: 6500 + settings.temperature * 2000, y: settings.tint * 150)
            filter.targetNeutral = CIVector(x: 6500, y: 0)
            result = filter.outputImage ?? result
        }

        // Tone and color through the same filters as the global sliders.
        var global = PhotoAdjustments()
        global.light.highlights = settings.highlights
        global.light.shadows = settings.shadows
        global.light.whites = settings.whites
        global.light.contrast = settings.contrast
        global.light.blackPoint = -settings.blacks
        global.presence.saturation = settings.saturation
        if global.light.highlights < 0 || global.light.shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = result
            filter.shadowAmount = Float(global.light.shadows.clamped(to: -1...1))
            filter.highlightAmount = Float((1 + min(global.light.highlights, 0)).clamped(to: 0...1))
            result = filter.outputImage ?? result
        }
        if let key = ColorLUT.key(for: global) {
            let filter = CIFilter.colorCubeWithColorSpace()
            filter.inputImage = result
            filter.cubeDimension = Float(ColorLUT.dimension)
            filter.cubeData = ColorLUT.cubeData(for: key)
            filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            result = filter.outputImage ?? result
        }

        var presence = PhotoAdjustments.Presence()
        presence.clarity = settings.clarity
        presence.texture = settings.texture
        presence.dehaze = settings.dehaze
        return PresenceRenderer.apply(presence, to: result, longEdge: max(image.extent.width, image.extent.height))
    }
}
