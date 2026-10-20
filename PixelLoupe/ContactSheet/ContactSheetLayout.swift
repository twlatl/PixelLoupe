import CoreGraphics
import CoreText
import Foundation

/// Where everything goes on a contact sheet's pages, in points with the origin at the page's
/// bottom-left (PDF coordinates). The preview and the PDF both draw from it, so they always match.
///
/// Each photo gets a square cell, fitted inside it at its own aspect ratio, with its caption
/// underneath. The image size is set in whole columns, so a page never ends in a partial column;
/// as many rows as fit follow from it.
nonisolated struct ContactSheetLayout: Equatable, Sendable {
    static let margin: CGFloat = 36
    static let gutter: CGFloat = 12
    static let headlineSize: CGFloat = 20
    static let descriptionSize: CGFloat = 11
    static let captionSize: CGFloat = 8
    static let pageNumberSize: CGFloat = 9
    /// Between the headline and the description.
    static let headerSpacing: CGFloat = 4
    /// Between the headline (or description) and the photos.
    static let headerGap: CGFloat = 18
    /// Between a photo's cell and its caption.
    static let captionGap: CGFloat = 4
    /// The white border's width, as a fraction of the cell's edge.
    static let borderFraction: CGFloat = 0.03

    let pageSize: CGSize
    let photoCount: Int
    let columns: Int
    let rows: Int
    /// The edge of each photo's square cell.
    let cellSize: CGFloat
    /// The caption's line under each cell, or 0 without captions.
    let captionHeight: CGFloat
    let headlineRect: CGRect?
    let descriptionRect: CGRect?
    /// The top-left of the first cell, top-down from the page's top edge.
    private let gridOrigin: CGPoint

    init(settings: ContactSheetSettings, photoCount: Int) {
        let page = settings.pageDimensions
        let margin = Self.margin
        let width = page.width - 2 * margin
        pageSize = page
        self.photoCount = photoCount

        // The header, top-down.
        var top = margin
        let headline = settings.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        if headline.isEmpty {
            headlineRect = nil
        } else {
            let height = Self.lineHeight(Self.font(size: Self.headlineSize, bold: true))
            headlineRect = CGRect(x: margin, y: page.height - top - height, width: width, height: height)
            top += height
        }
        let description = settings.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.isEmpty {
            descriptionRect = nil
        } else {
            if headlineRect != nil { top += Self.headerSpacing }
            // At most a third of the page, so a long description can't push the photos off it.
            let height = Self.textHeight(description, font: Self.font(size: Self.descriptionSize, bold: false),
                                         width: width, maxHeight: (page.height - 2 * margin) / 3)
            descriptionRect = CGRect(x: margin, y: page.height - top - height, width: width, height: height)
            top += height
        }
        if headlineRect != nil || descriptionRect != nil { top += Self.headerGap }

        // The grid: whole columns across, as many rows as fit.
        let columns = min(max(settings.columns, ContactSheetSettings.columnRange.lowerBound), ContactSheetSettings.columnRange.upperBound)
        let gutter = Self.gutter
        let caption = settings.showsCaption ? Self.captionGap + Self.lineHeight(Self.font(size: Self.captionSize, bold: false)) : 0
        let available = max(page.height - top - margin, 1)
        var cell = (width - CGFloat(columns - 1) * gutter) / CGFloat(columns)
        var rows = Int(((available + gutter) / (cell + caption + gutter)).rounded(.down))
        if rows < 1 {
            // Too tall for one row (one or two columns on a landscape page): shrink to fit.
            rows = 1
            cell = max(available - caption, 1)
        }
        self.columns = columns
        self.rows = rows
        cellSize = cell
        captionHeight = caption
        let gridWidth = CGFloat(columns) * cell + CGFloat(columns - 1) * gutter
        gridOrigin = CGPoint(x: margin + (width - gridWidth) / 2, y: top)
    }

    var photosPerPage: Int { columns * rows }

    var pageCount: Int { max(1, (photoCount + photosPerPage - 1) / photosPerPage) }

    /// The photos (indices into the sheet's photos) on `page`.
    func photos(onPage page: Int) -> Range<Int> {
        let start = min(page * photosPerPage, photoCount)
        return start..<min(start + photosPerPage, photoCount)
    }

    /// The square cell of the `slot`th photo on a page, left to right then top to bottom.
    func cell(at slot: Int) -> CGRect {
        let column = slot % columns, row = slot / columns
        let x = gridOrigin.x + CGFloat(column) * (cellSize + Self.gutter)
        let top = gridOrigin.y + CGFloat(row) * (cellSize + captionHeight + Self.gutter)
        return CGRect(x: x, y: pageSize.height - top - cellSize, width: cellSize, height: cellSize)
    }

    /// The caption's line under `cell`.
    func captionRect(under cell: CGRect) -> CGRect {
        let height = captionHeight - Self.captionGap
        return CGRect(x: cell.minX, y: cell.minY - Self.captionGap - height, width: cell.width, height: height)
    }

    /// The page number's place: the bottom margin, across the page.
    var pageNumberRect: CGRect {
        CGRect(x: Self.margin, y: 0, width: pageSize.width - 2 * Self.margin, height: Self.margin)
    }

    /// "4 × 5 per page · 3 pages"
    var summary: String {
        "\(columns) × \(rows) per page · \(pageCount) page\(pageCount == 1 ? "" : "s")"
    }

    /// A photo `aspect` (width / height) times as wide as it is tall, as large as fits in `cell`, centered.
    static func imageFrame(aspect: CGFloat, in cell: CGRect) -> CGRect {
        guard aspect.isFinite, aspect > 0 else { return cell }
        let size = aspect >= 1
            ? CGSize(width: cell.width, height: cell.width / aspect)
            : CGSize(width: cell.height * aspect, height: cell.height)
        return CGRect(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2, width: size.width, height: size.height)
    }

    // MARK: Text

    /// The system font (Core Text, so any thread can lay out and draw).
    static func font(size: CGFloat, bold: Bool) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    static func lineHeight(_ font: CTFont) -> CGFloat {
        (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)).rounded(.up)
    }

    static func textHeight(_ text: String, font: CTFont, width: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, CGSize(width: width, height: maxHeight), nil
        )
        return min(size.height.rounded(.up), maxHeight)
    }
}
