import AppKit

/// Lightroom's zoom, as the Navigator shows it: a *fit* choice (Fit or Fill) and a *zoom* choice (1:1, or
/// a ratio from the Navigator's menu). Clicking the photo, or Z, switches between the two.
nonisolated struct PhotoZoom: Equatable, Sendable {
    enum Fit: String, CaseIterable, Sendable {
        /// The whole photo, as large as fits.
        case fit
        /// The view filled, cropping the photo's longer side.
        case fill

        var title: String { rawValue.uppercased() }
    }

    var fit = Fit.fit
    /// What clicking zooms to: 1:1, or the last ratio chosen from the menu.
    var ratio = ZoomRatio.oneToOne
    /// The ratio the menu shows (Lightroom starts at 3:1).
    var menuRatio = ZoomRatio.threeToOne
    var isZoomed = false
    /// The point of the photo at the center of the view while zoomed, in unit photo coordinates (origin
    /// bottom-left).
    var center = CGPoint(x: 0.5, y: 0.5)

    /// Z or a click: zoom to `ratio` (centered on `point` if given), or back to the fit choice.
    mutating func toggle(at point: CGPoint? = nil) {
        isZoomed.toggle()
        if isZoomed, let point { center = point }
    }

    /// The zoom to show, as display pixels per photo pixel, for a photo of `imageSize` pixels in a view of
    /// `paneSize` display pixels.
    func scale(imageSize: CGSize, paneSize: CGSize) -> Double {
        guard imageSize.width > 0, imageSize.height > 0, paneSize.width > 0, paneSize.height > 0 else { return 1 }
        if isZoomed { return ratio.scale }
        let horizontal = paneSize.width / imageSize.width, vertical = paneSize.height / imageSize.height
        return Double(fit == .fit ? min(horizontal, vertical) : max(horizontal, vertical))
    }
}

/// The Navigator's zoom ratios: display pixels per photo pixel, written as Lightroom does ("1:4" is a
/// quarter size, "3:1" three times).
nonisolated enum ZoomRatio: String, CaseIterable, Sendable {
    case oneToSixteen = "1:16", oneToEight = "1:8", oneToFour = "1:4", oneToThree = "1:3", oneToTwo = "1:2"
    case oneToOne = "1:1"
    case twoToOne = "2:1", threeToOne = "3:1", fourToOne = "4:1", eightToOne = "8:1", elevenToOne = "11:1"

    var title: String { rawValue }

    var scale: Double {
        let parts = rawValue.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : 1
    }

    /// The ratios in the Navigator's menu (1:1 has a button of its own).
    static let menu: [ZoomRatio] = allCases.filter { $0 != .oneToOne }
}
