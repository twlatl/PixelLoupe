import CoreGraphics

/// Where Survey puts its photos: equal cells in rows, with the number of columns that shows the
/// photos largest. A short last row is centered, as in Lightroom.
nonisolated enum SurveyLayout {
    /// Cells for `count` photos in `bounds` (origin top-left, y down). `aspectRatio` is the photos'
    /// typical width ÷ height; `captionHeight` is kept under each photo for its name and rating.
    static func cells(count: Int, in bounds: CGRect, aspectRatio: CGFloat, spacing: CGFloat, captionHeight: CGFloat) -> [CGRect] {
        guard count > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        let columns = bestColumnCount(count: count, size: bounds.size, aspectRatio: aspectRatio,
                                      spacing: spacing, captionHeight: captionHeight)
        let rows = (count + columns - 1) / columns
        let cell = cellSize(columns: columns, rows: rows, size: bounds.size, spacing: spacing)
        return (0..<count).map { index in
            let row = index / columns
            let column = index % columns
            let inRow = row == rows - 1 ? count - row * columns : columns
            let rowWidth = CGFloat(inRow) * cell.width + CGFloat(inRow - 1) * spacing
            let x = bounds.minX + (bounds.width - rowWidth) / 2 + CGFloat(column) * (cell.width + spacing)
            let y = bounds.minY + CGFloat(row) * (cell.height + spacing)
            return CGRect(x: x, y: y, width: cell.width, height: cell.height)
        }
    }

    /// The column count whose cells fit the photos largest.
    static func bestColumnCount(count: Int, size: CGSize, aspectRatio: CGFloat, spacing: CGFloat, captionHeight: CGFloat) -> Int {
        let aspect = aspectRatio > 0 ? aspectRatio : 1.5
        var best = (columns: 1, area: -CGFloat.infinity)
        for columns in 1...max(count, 1) {
            let rows = (count + columns - 1) / columns
            let cell = cellSize(columns: columns, rows: rows, size: size, spacing: spacing)
            let photo = fitted(aspect: aspect, in: CGSize(width: cell.width, height: max(cell.height - captionHeight, 0)))
            let area = photo.width * photo.height
            if area > best.area { best = (columns, area) }
        }
        return best.columns
    }

    /// The largest size with `aspect` that fits in `size`.
    static func fitted(aspect: CGFloat, in size: CGSize) -> CGSize {
        guard aspect > 0, size.width > 0, size.height > 0 else { return .zero }
        return size.width / size.height > aspect
            ? CGSize(width: size.height * aspect, height: size.height)
            : CGSize(width: size.width, height: size.width / aspect)
    }

    private static func cellSize(columns: Int, rows: Int, size: CGSize, spacing: CGFloat) -> CGSize {
        CGSize(
            width: max((size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns), 0),
            height: max((size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows), 0)
        )
    }
}
