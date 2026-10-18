import AppKit
import CoreImage
import CoreText

/// Draws watermarks onto photos: for the Watermark Editor's preview and for export. Sizes and
/// insets are relative to the photo, so a preview and a full-size export look the same.
nonisolated enum WatermarkRenderer {
    /// The watermark drawn at its final size, and where it goes (in the photo's coordinates,
    /// origin bottom-left). `nil` when there's nothing to draw (no text, or no image).
    struct Placement {
        let image: CIImage
        /// The text or graphic's bounds, without the room drawn around it for the shadow.
        let frame: CGRect
    }

    /// The photo with the watermark composited over it.
    static func apply(_ settings: WatermarkSettings, imageURL: URL?, to photo: CIImage) -> CIImage {
        guard let placement = placement(settings, imageURL: imageURL, photoSize: photo.extent.size) else { return photo }
        let moved = placement.image.transformed(by: CGAffineTransform(translationX: photo.extent.minX, y: photo.extent.minY))
        return moved.composited(over: photo).cropped(to: photo.extent)
    }

    static func placement(_ settings: WatermarkSettings, imageURL: URL?, photoSize: CGSize) -> Placement? {
        guard photoSize.width > 0, photoSize.height > 0, let content = Content(settings, imageURL: imageURL) else { return nil }
        let turns = ((settings.quarterTurns % 4) + 4) % 4
        let natural = turns % 2 == 0 ? content.naturalSize : CGSize(width: content.naturalSize.height, height: content.naturalSize.width)
        guard natural.width > 0, natural.height > 0 else { return nil }

        let insetX = photoSize.width * settings.horizontalInset.clamped(to: 0...50) / 100
        let insetY = photoSize.height * settings.verticalInset.clamped(to: 0...50) / 100
        let scale: CGFloat = switch settings.size {
        case .proportional:
            photoSize.width * settings.proportionalSize.clamped(to: 1...100) / 100 / natural.width
        case .fit:
            min((photoSize.width - 2 * insetX) / natural.width, (photoSize.height - 2 * insetY) / natural.height)
        case .fill:
            max(photoSize.width / natural.width, photoSize.height / natural.height)
        }
        guard scale > 0, let drawn = content.draw(scale: scale, settings: settings) else { return nil }

        // Turn the drawing (padding included) about its own origin, then put the content's
        // bounds where the anchor and insets say.
        var image = CIImage(cgImage: drawn.image)
        if turns > 0 {
            image = image.transformed(by: CGAffineTransform(rotationAngle: CGFloat(turns) * .pi / 2))
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        let contentRect = rotated(drawn.contentRect, in: drawn.size, turns: turns)
        let size = contentRect.size
        let anchor = settings.anchor.unitPosition
        func origin(_ unit: CGFloat, photo: CGFloat, length: CGFloat, inset: CGFloat) -> CGFloat {
            let position = unit * (photo - length)
            return unit == 0 ? position + inset : unit == 1 ? position - inset : position
        }
        let frame = CGRect(
            x: origin(anchor.x, photo: photoSize.width, length: size.width, inset: insetX),
            y: origin(anchor.y, photo: photoSize.height, length: size.height, inset: insetY),
            width: size.width, height: size.height
        )
        image = image.transformed(by: CGAffineTransform(translationX: frame.minX - contentRect.minX, y: frame.minY - contentRect.minY))
        return Placement(image: image, frame: frame)
    }

    /// `rect` (in a drawing of `size`) after turning the drawing `turns` quarter turns
    /// counterclockwise and moving it back to the origin.
    private static func rotated(_ rect: CGRect, in size: CGSize, turns: Int) -> CGRect {
        switch turns {
        case 1: CGRect(x: size.height - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        case 2: CGRect(x: size.width - rect.maxX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
        case 3: CGRect(x: rect.minY, y: size.width - rect.maxX, width: rect.height, height: rect.width)
        default: rect
        }
    }

    // MARK: - Content

    /// Text or a graphic, measured at a reference size and drawn at any scale.
    private enum Content {
        case text(NSAttributedString)
        case graphic(CGImage)

        /// Text is measured at 100 pt and scaled from there.
        static let referenceSize: CGFloat = 100

        init?(_ settings: WatermarkSettings, imageURL: URL?) {
            switch settings.style {
            case .text:
                guard !settings.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                self = .text(Self.attributedText(settings, size: Self.referenceSize))
            case .graphic:
                guard let imageURL, let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
                self = .graphic(image)
            }
        }

        var naturalSize: CGSize {
            switch self {
            case .text(let string): Self.textSize(string)
            case .graphic(let image): CGSize(width: image.width, height: image.height)
            }
        }

        struct Drawing {
            let image: CGImage
            let size: CGSize
            /// The text or graphic within the drawing (the rest is room for the shadow).
            let contentRect: CGRect
        }

        func draw(scale: CGFloat, settings: WatermarkSettings) -> Drawing? {
            switch self {
            case .text:
                let fontSize = Self.referenceSize * scale
                let string = Self.attributedText(settings, size: fontSize)
                let textSize = Self.textSize(string)
                // Shadow distances are relative to the text's size: 100 is a tenth of its height.
                let unit = fontSize / 10
                let shadow = settings.shadow
                let offset = shadow.isEnabled ? unit * shadow.offset.clamped(to: 0...100) / 100 : 0
                let blur = shadow.isEnabled ? unit * shadow.radius.clamped(to: 0...100) / 100 : 0
                let padding = ceil(offset + blur * 2)
                let size = CGSize(width: ceil(textSize.width + 2 * padding), height: ceil(textSize.height + 2 * padding))
                guard let context = Self.context(size) else { return nil }
                let contentRect = CGRect(x: padding, y: padding, width: textSize.width, height: textSize.height)
                context.setAlpha(settings.opacity.clamped(to: 0...100) / 100)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                if shadow.isEnabled {
                    let angle = shadow.angle * .pi / 180
                    context.setShadow(
                        offset: CGSize(width: cos(angle) * offset, height: sin(angle) * offset),
                        blur: blur,
                        color: CGColor(gray: 0, alpha: shadow.opacity.clamped(to: 0...100) / 100)
                    )
                }
                let framesetter = CTFramesetterCreateWithAttributedString(string)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: contentRect, transform: nil), nil)
                CTFrameDraw(frame, context)
                context.endTransparencyLayer()
                return context.makeImage().map { Drawing(image: $0, size: size, contentRect: contentRect) }

            case .graphic(let image):
                let size = CGSize(width: max(1, (CGFloat(image.width) * scale).rounded()),
                                  height: max(1, (CGFloat(image.height) * scale).rounded()))
                guard let context = Self.context(size) else { return nil }
                context.interpolationQuality = .high
                context.setAlpha(settings.opacity.clamped(to: 0...100) / 100)
                context.draw(image, in: CGRect(origin: .zero, size: size))
                return context.makeImage().map { Drawing(image: $0, size: size, contentRect: CGRect(origin: .zero, size: size)) }
            }
        }

        static func attributedText(_ settings: WatermarkSettings, size: CGFloat) -> NSAttributedString {
            var alignment: CTTextAlignment = switch settings.alignment {
            case .left: .left
            case .center: .center
            case .right: .right
            }
            let paragraph = withUnsafeBytes(of: &alignment) { bytes in
                var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: bytes.count, value: bytes.baseAddress!)
                return CTParagraphStyleCreate(&setting, 1)
            }
            return NSAttributedString(string: settings.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): settings.font(size: size),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): settings.color.cgColor,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            ])
        }

        static func textSize(_ string: NSAttributedString) -> CGSize {
            let framesetter = CTFramesetterCreateWithAttributedString(string)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(), nil, CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), nil
            )
            return CGSize(width: ceil(size.width), height: ceil(size.height))
        }

        static func context(_ size: CGSize) -> CGContext? {
            guard size.width >= 1, size.height >= 1, size.width < 32_768, size.height < 32_768 else { return nil }
            return CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }
    }
}
