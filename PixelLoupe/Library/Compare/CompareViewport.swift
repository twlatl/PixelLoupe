import CoreGraphics

/// Zoom and pan for one Compare pane.
///
/// `zoom` is relative to the original's actual pixels (1 = 100%: one photo pixel per display
/// pixel), matching the zoom slider. `center` is the point of the photo at the middle of the pane, in
/// unit coordinates (0…1, origin bottom-left).
nonisolated struct CompareViewport: Equatable {
    static let maxZoom = 4.0
    static let minZoom = 0.02

    var zoom: Double
    var center = CGPoint(x: 0.5, y: 0.5)

    /// Zoom that fits the whole photo in `paneSize` points.
    static func fitZoom(imageSize: CGSize, paneSize: CGSize, backingScale: CGFloat) -> Double {
        guard imageSize.width > 0, imageSize.height > 0, paneSize.width > 0, paneSize.height > 0 else { return 1 }
        let scale = min(paneSize.width * backingScale / imageSize.width, paneSize.height * backingScale / imageSize.height)
        return Double(scale).clamped(to: minZoom...maxZoom)
    }

    /// Where the whole photo is drawn, in pane points. Smaller than the pane when zoomed out.
    func imageRect(imageSize: CGSize, paneBounds: CGRect, backingScale: CGFloat) -> CGRect {
        let size = CGSize(
            width: imageSize.width * CGFloat(zoom) / backingScale,
            height: imageSize.height * CGFloat(zoom) / backingScale
        )
        var origin = CGPoint(x: paneBounds.midX - center.x * size.width, y: paneBounds.midY - center.y * size.height)
        // A dimension that fits in the pane is always centered.
        if size.width <= paneBounds.width { origin.x = paneBounds.midX - size.width / 2 }
        if size.height <= paneBounds.height { origin.y = paneBounds.midY - size.height / 2 }
        return CGRect(origin: origin, size: size)
    }

    /// Moves the photo by `delta` points (drag direction), keeping the pane covered where possible.
    mutating func pan(by delta: CGVector, imageSize: CGSize, paneBounds: CGRect, backingScale: CGFloat) {
        let rect = imageRect(imageSize: imageSize, paneBounds: paneBounds, backingScale: backingScale)
        guard rect.width > 0, rect.height > 0 else { return }
        center.x -= delta.dx / rect.width
        center.y -= delta.dy / rect.height
        clampCenter(imageSize: imageSize, paneBounds: paneBounds, backingScale: backingScale)
    }

    /// Keeps the pane's edges inside the photo when it's larger than the pane.
    mutating func clampCenter(imageSize: CGSize, paneBounds: CGRect, backingScale: CGFloat) {
        let width = imageSize.width * CGFloat(zoom) / backingScale
        let height = imageSize.height * CGFloat(zoom) / backingScale
        func clamp(_ value: CGFloat, content: CGFloat, pane: CGFloat) -> CGFloat {
            guard content > pane else { return 0.5 }
            let half = pane / 2 / content
            return value.clamped(to: half...(1 - half))
        }
        center = CGPoint(
            x: clamp(center.x, content: width, pane: paneBounds.width),
            y: clamp(center.y, content: height, pane: paneBounds.height)
        )
    }

    /// The part of the photo visible in the pane, in full-resolution photo pixels.
    func visibleImageRegion(imageSize: CGSize, paneBounds: CGRect, backingScale: CGFloat) -> CGRect {
        let rect = imageRect(imageSize: imageSize, paneBounds: paneBounds, backingScale: backingScale)
        let visible = rect.intersection(paneBounds)
        guard !visible.isNull, rect.width > 0, rect.height > 0 else { return .zero }
        return CGRect(
            x: (visible.minX - rect.minX) / rect.width * imageSize.width,
            y: (visible.minY - rect.minY) / rect.height * imageSize.height,
            width: visible.width / rect.width * imageSize.width,
            height: visible.height / rect.height * imageSize.height
        )
    }

    /// Slider position (0…1) for a zoom, on a logarithmic scale so small zooms get room too.
    static func sliderValue(forZoom zoom: Double, fit: Double) -> Double {
        let low = log(max(min(fit, 1), minZoom)), high = log(maxZoom)
        return ((log(zoom) - low) / (high - low)).clamped(to: 0...1)
    }

    static func zoom(forSliderValue value: Double, fit: Double) -> Double {
        let low = log(max(min(fit, 1), minZoom)), high = log(maxZoom)
        return exp(low + value.clamped(to: 0...1) * (high - low))
    }
}

/// Which photos are compared: the first two selected, or the selected photo and the next one.
nonisolated enum ComparePair {
    static func make<ID: Equatable>(selection: [ID], order: [ID]) -> (select: ID, candidate: ID)? {
        if selection.count >= 2 { return (selection[0], selection[1]) }
        guard let select = selection.first, let index = order.firstIndex(of: select) else { return nil }
        if order.indices.contains(index + 1) { return (select, order[index + 1]) }
        if index > 0 { return (select, order[index - 1]) }
        return nil
    }

    /// The next (or previous) candidate in grid order, skipping the Select photo.
    static func step<ID: Equatable>(candidate: ID, select: ID, by offset: Int, order: [ID]) -> ID? {
        guard var index = order.firstIndex(of: candidate) else { return nil }
        repeat {
            index += offset
            guard order.indices.contains(index) else { return nil }
        } while order[index] == select
        return order[index]
    }
}
