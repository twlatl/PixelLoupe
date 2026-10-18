import AppKit

/// A watermark, as set up in the Watermark Editor (Lightroom's layout and ranges). Positions and
/// sizes are relative to the photo, so the same watermark suits any photo or export size.
nonisolated struct WatermarkSettings: Codable, Equatable, Sendable {
    enum Style: String, Codable, Sendable {
        case text, graphic
    }

    enum Alignment: String, Codable, Sendable, CaseIterable {
        case left, center, right
    }

    enum Size: String, Codable, Sendable {
        /// `proportionalSize` percent of the photo's width.
        case proportional
        /// As large as fits inside the photo.
        case fit
        /// As large as covers the photo's width or height, whichever is larger.
        case fill
    }

    /// Where the watermark sits: a corner, an edge's middle or the center.
    enum Anchor: String, Codable, Sendable, CaseIterable {
        case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

        /// 0 (left/bottom), 0.5 or 1 (right/top), in unit coordinates with the origin bottom-left.
        var unitPosition: CGPoint {
            switch self {
            case .topLeft: CGPoint(x: 0, y: 1)
            case .top: CGPoint(x: 0.5, y: 1)
            case .topRight: CGPoint(x: 1, y: 1)
            case .left: CGPoint(x: 0, y: 0.5)
            case .center: CGPoint(x: 0.5, y: 0.5)
            case .right: CGPoint(x: 1, y: 0.5)
            case .bottomLeft: CGPoint(x: 0, y: 0)
            case .bottom: CGPoint(x: 0.5, y: 0)
            case .bottomRight: CGPoint(x: 1, y: 0)
            }
        }
    }

    struct Color: Codable, Equatable, Sendable {
        var red = 1.0, green = 1.0, blue = 1.0, alpha = 1.0

        static let white = Color()

        init(red: Double = 1, green: Double = 1, blue: Double = 1, alpha: Double = 1) {
            (self.red, self.green, self.blue, self.alpha) = (red, green, blue, alpha)
        }

        init(_ color: NSColor) {
            let srgb = color.usingColorSpace(.sRGB) ?? .white
            self.init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: srgb.alphaComponent)
        }

        var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
        var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    }

    struct Shadow: Codable, Equatable, Sendable {
        var isEnabled = true
        /// 0…100.
        var opacity = 80.0
        /// Distance from the text, 0…100 (percent of a tenth of the text's height).
        var offset = 10.0
        /// Blur, 0…100 (percent of a tenth of the text's height).
        var radius = 20.0
        /// Direction the shadow falls, −180…180 degrees; −90 is straight down.
        var angle = -90.0
    }

    var style = Style.text

    // Text
    var text = WatermarkSettings.defaultText
    var fontFamily = WatermarkSettings.defaultFontFamily
    var fontFace = "Regular"
    var alignment = Alignment.left
    var color = Color.white
    var shadow = Shadow()

    // Graphic: a PNG or JPEG in the watermark presets folder's Images (see WatermarkPresets).
    var imageName: String?

    // Effects
    /// 0…100.
    var opacity = 100.0
    var size = Size.proportional
    /// 1…100 percent of the photo's width.
    var proportionalSize = 10.0
    /// From the anchored edges, 0…50 percent of the photo's width and height.
    var horizontalInset = 0.0
    var verticalInset = 0.0
    var anchor = Anchor.bottomLeft
    /// Quarter turns counterclockwise, 0…3.
    var quarterTurns = 0

    static let defaultFontFamily = "Helvetica Neue"

    /// Just "©": the name is the photographer's to add (the Mac account's name isn't filled in).
    static let defaultText = "©"

    init() {}

    // Tolerant decoding: missing keys keep their defaults, so presets survive new options.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WatermarkSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        style = value(.style, defaults.style)
        text = value(.text, defaults.text)
        fontFamily = value(.fontFamily, defaults.fontFamily)
        fontFace = value(.fontFace, defaults.fontFace)
        alignment = value(.alignment, defaults.alignment)
        color = value(.color, defaults.color)
        shadow = value(.shadow, defaults.shadow)
        imageName = try? container.decodeIfPresent(String.self, forKey: .imageName)
        opacity = value(.opacity, defaults.opacity)
        size = value(.size, defaults.size)
        proportionalSize = value(.proportionalSize, defaults.proportionalSize)
        horizontalInset = value(.horizontalInset, defaults.horizontalInset)
        verticalInset = value(.verticalInset, defaults.verticalInset)
        anchor = value(.anchor, defaults.anchor)
        quarterTurns = value(.quarterTurns, defaults.quarterTurns)
    }

    /// The font for `fontFamily` and `fontFace` at `size` (Core Text, so any thread can render).
    /// A missing family falls back to the system's closest match.
    func font(size: CGFloat) -> CTFont {
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: fontFamily,
            kCTFontStyleNameAttribute: fontFace,
        ] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }
}

/// A saved watermark.
nonisolated struct WatermarkPreset: Codable, Equatable, Sendable {
    var name: String
    var settings: WatermarkSettings
}
