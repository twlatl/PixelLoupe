import CoreImage

/// Composites the magnified photo into the lens of the Develop preview.
nonisolated enum LoupeRenderer {
    /// Scale to render the photo at for `zoom`: full resolution from 100% up, reduced below.
    static func renderScale(forZoom zoom: Double) -> CGFloat {
        CGFloat(min(zoom, 1))
    }

    /// The magnified photo for `request`, in drawable pixels, clipped to the lens and placed over
    /// `output`. `photo` is the adjusted photo rendered at `photoScale` of full resolution
    /// (normally `renderScale(forZoom:)`; lower while the full-resolution decoder is loading).
    static func composite(
        _ request: LoupeRenderRequest,
        photo: CIImage,
        photoScale: CGFloat,
        over output: CIImage,
        geometry: PreviewGeometry,
        matte: CIColor
    ) -> CIImage {
        let b = geometry.backingScale
        let renderScale = photoScale
        let magnification = CGFloat(request.zoom) / renderScale
        let focus = geometry.imagePoint(forViewPoint: request.focus)
        let lensCenter = CGPoint(x: request.lensCenter.x * b, y: request.lensCenter.y * b)
        let radius = request.coverRadius * b

        // Put the focus point (in rendered pixels) at the lens center, magnified. At 200% and
        // above, show crisp pixels rather than smoothing them.
        var magnified = photo.transformed(by: CGAffineTransform(
            translationX: -focus.x * renderScale, y: -focus.y * renderScale
        ))
        if magnification >= 2 { magnified = magnified.samplingNearest() }
        magnified = magnified
            .transformed(by: CGAffineTransform(scaleX: magnification, y: magnification))
            .transformed(by: CGAffineTransform(translationX: lensCenter.x, y: lensCenter.y))

        let lensBounds = CGRect(x: lensCenter.x - radius, y: lensCenter.y - radius, width: radius * 2, height: radius * 2)
        let content = magnified.composited(over: CIImage(color: matte)).cropped(to: lensBounds)
        let mask = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: lensCenter.x, y: lensCenter.y),
            "inputRadius0": radius - 1,
            "inputRadius1": radius,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.black,
        ])?.outputImage?.cropped(to: lensBounds.insetBy(dx: -2, dy: -2))
        guard let mask else { return output }
        return content
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: output, kCIInputMaskImageKey: mask,
            ])
            .cropped(to: output.extent)
    }

    /// The 8-bit sRGB color of the photo pixel under `request.focus`, or nil outside the photo.
    static func colorValue(
        at request: LoupeRenderRequest, photo: CIImage, photoScale: CGFloat, geometry: PreviewGeometry, context: CIContext
    ) -> (r: Int, g: Int, b: Int)? {
        let renderScale = photoScale
        let focus = geometry.imagePoint(forViewPoint: request.focus)
        let pixel = CGRect(
            x: (focus.x * renderScale).rounded(.down), y: (focus.y * renderScale).rounded(.down), width: 1, height: 1
        )
        guard photo.extent.contains(pixel), let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(photo, toBitmap: &bytes, rowBytes: 4, bounds: pixel, format: .RGBA8, colorSpace: sRGB)
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }
}
