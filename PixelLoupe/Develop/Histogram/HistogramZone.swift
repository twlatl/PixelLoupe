import CoreImage
import Foundation

/// The five regions of the histogram that can be dragged, like Lightroom's. Dragging right always
/// brightens that part of the tonal range.
///
/// PixelLoupe's Light section has no Blacks or Whites sliders, so those zones drive the closest
/// controls: Light ▸ Black Point and Levels ▸ Input White.
nonisolated enum HistogramZone: Int, CaseIterable, Sendable {
    case blacks, shadows, exposure, highlights, whites

    /// Where each zone starts, as a fraction of the histogram's width (it ends where the next starts).
    static let boundaries: [Double] = [0, 0.12, 0.37, 0.63, 0.88, 1]

    static func at(fraction: Double) -> HistogramZone {
        let index = boundaries.dropFirst().firstIndex { fraction < $0 }.map { $0 - 1 } ?? HistogramZone.allCases.count - 1
        return HistogramZone(rawValue: index.clamped(to: 0...(HistogramZone.allCases.count - 1)))!
    }

    var range: ClosedRange<Double> { Self.boundaries[rawValue]...Self.boundaries[rawValue + 1] }

    var title: String {
        switch self {
        case .blacks: "Black Point"
        case .shadows: "Shadows"
        case .exposure: "Exposure"
        case .highlights: "Highlights"
        case .whites: "White Point"
        }
    }

    /// The undo action name, matching the panel's.
    var actionName: String {
        switch self {
        case .whites: "Adjust Levels"
        default: "Adjust Light"
        }
    }

    /// The control's value, oriented so that higher is brighter.
    func value(in adjustments: PhotoAdjustments) -> Double {
        switch self {
        case .blacks: -adjustments.light.blackPoint
        case .shadows: adjustments.light.shadows
        case .exposure: adjustments.light.exposure
        case .highlights: adjustments.light.highlights
        case .whites: 1 - adjustments.levels.inputWhite
        }
    }

    /// The value shown while hovering or dragging, formatted like the panel's slider.
    func displayValue(in adjustments: PhotoAdjustments) -> String {
        switch self {
        case .whites: SliderRow.unsigned(adjustments.levels.inputWhite)
        case .blacks: SliderRow.signed(adjustments.light.blackPoint)
        default: SliderRow.signed(value(in: adjustments))
        }
    }

    /// How far the value moves for a drag across the whole histogram.
    private var span: Double {
        switch self {
        case .exposure: 3
        case .whites: 0.5
        default: 1.5
        }
    }

    /// `adjustments` after dragging `distance` (a fraction of the histogram's width; positive is
    /// right) from where the drag started. Turns the affected section on.
    func applying(_ distance: Double, to adjustments: PhotoAdjustments) -> PhotoAdjustments {
        var result = adjustments
        let value = (self.value(in: adjustments) + distance * span)
        func rounded(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        switch self {
        case .blacks:
            result.light.blackPoint = rounded(-value.clamped(to: -1...1))
            result.light.isEnabled = true
        case .shadows:
            result.light.shadows = rounded(value.clamped(to: -1...1))
            result.light.isEnabled = true
        case .exposure:
            result.light.exposure = rounded(value.clamped(to: -5...5))
            result.light.isEnabled = true
        case .highlights:
            result.light.highlights = rounded(value.clamped(to: -1...1))
            result.light.isEnabled = true
        case .whites:
            let lowest = min(1, adjustments.levels.inputBlack + 0.05)
            result.levels.inputWhite = rounded((1 - value).clamped(to: lowest...1))
            result.levels.isEnabled = true
        }
        return result
    }
}

/// Paints clipped shadows blue and clipped highlights red over the preview (Lightroom's J).
nonisolated enum ClippingOverlay {
    static func apply(to image: CIImage, shadows: Bool, highlights: Bool) -> CIImage {
        guard shadows || highlights,
              let encoded = image.matchedFromWorkingSpace(to: CGColorSpace(name: CGColorSpace.displayP3)!)
        else { return image }
        var result = image
        if highlights {
            // 1 where any channel is at white (the histogram's last bin).
            result = paint(result, color: CIColor(red: 1, green: 0.1, blue: 0.1),
                           where: mask(encoded, scale: 256, bias: -255).applyingFilter("CIMaximumComponent"))
        }
        if shadows {
            // 1 where any channel is at black (the first bin).
            result = paint(result, color: CIColor(red: 0.15, green: 0.35, blue: 1),
                           where: mask(encoded, scale: -256, bias: 1).applyingFilter("CIMaximumComponent"))
        }
        return result
    }

    /// Each channel scaled and offset, clamped to 0…1.
    private static func mask(_ image: CIImage, scale: CGFloat, bias: CGFloat) -> CIImage {
        image
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
            ])
            .applyingFilter("CIColorClamp")
    }

    private static func paint(_ image: CIImage, color: CIColor, where mask: CIImage) -> CIImage {
        CIImage(color: color).cropped(to: image.extent).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask,
        ])
    }
}
