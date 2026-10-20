import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws contact sheet pages with Core Graphics: into the preview at screen scale and into the PDF,
/// from the same ``ContactSheetLayout``, so what the window shows is what the PDF holds. Text is
/// drawn with Core Text, so it stays text (sharp and searchable) in the PDF.
nonisolated enum ContactSheetRenderer {
    /// The photo in one cell: its image when there is one (a placeholder with its file name is drawn
    /// otherwise) and its caption.
    struct Cell {
        var image: CGImage?
        var aspect: CGFloat
        var name: String
        var caption: String
    }

    /// Draws `page` with its bottom-left at the context's origin, one unit per point.
    static func drawPage(_ page: Int, layout: ContactSheetLayout, settings: ContactSheetSettings,
                         in context: CGContext, cell: (Int) -> Cell) {
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        context.interpolationQuality = .high
        let text = settings.textColor.cgColor

        context.setFillColor(settings.backgroundColor.cgColor)
        context.fill(CGRect(origin: .zero, size: layout.pageSize))

        if let rect = layout.headlineRect {
            drawLine(settings.headline.trimmingCharacters(in: .whitespacesAndNewlines),
                     font: ContactSheetLayout.font(size: ContactSheetLayout.headlineSize, bold: true),
                     color: text, in: rect, centered: false, truncation: .end, context: context)
        }
        if let rect = layout.descriptionRect {
            drawParagraph(settings.description.trimmingCharacters(in: .whitespacesAndNewlines),
                          font: ContactSheetLayout.font(size: ContactSheetLayout.descriptionSize, bold: false),
                          color: text, in: rect, context: context)
        }

        let captionFont = ContactSheetLayout.font(size: ContactSheetLayout.captionSize, bold: false)
        for (slot, index) in layout.photos(onPage: page).enumerated() {
            let frame = layout.cell(at: slot)
            let photo = cell(index)
            drawPhoto(photo, in: frame, settings: settings, context: context)
            if settings.showsCaption, !photo.caption.isEmpty {
                drawLine(photo.caption, font: captionFont, color: text, in: layout.captionRect(under: frame),
                         centered: true, truncation: .middle, context: context)
            }
        }

        if settings.showsPageNumbers {
            drawLine("\(page + 1) of \(layout.pageCount)",
                     font: ContactSheetLayout.font(size: ContactSheetLayout.pageNumberSize, bold: false),
                     color: text, in: layout.pageNumberRect, centered: true, truncation: .end, context: context)
        }
    }

    private static func drawPhoto(_ photo: Cell, in cell: CGRect, settings: ContactSheetSettings, context: CGContext) {
        let aspect = photo.image.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? photo.aspect
        let frame = ContactSheetLayout.imageFrame(aspect: aspect > 0 ? aspect : 1.5, in: cell)
        let border = settings.showsBorder ? (cell.width * ContactSheetLayout.borderFraction).rounded() : 0
        let imageRect = frame.insetBy(dx: border, dy: border)

        // The shadow falls from the photo's outer edge: the border when there is one, else the photo itself.
        context.saveGState()
        if settings.showsShadow {
            context.setShadow(offset: CGSize(width: 0, height: -cell.width * 0.012), blur: cell.width * 0.04,
                              color: CGColor(gray: 0, alpha: 0.45))
        }
        if border > 0 {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(frame)
            context.setShadow(offset: .zero, blur: 0, color: nil)
        }
        if let image = photo.image {
            context.draw(image, in: imageRect)
            context.restoreGState()
        } else {
            context.setFillColor(CGColor(gray: 0.82, alpha: 1))
            context.fill(imageRect)
            context.restoreGState()
            let font = ContactSheetLayout.font(size: ContactSheetLayout.captionSize, bold: false)
            let height = ContactSheetLayout.lineHeight(font)
            drawLine(photo.name, font: font, color: CGColor(gray: 0.4, alpha: 1),
                     in: CGRect(x: imageRect.minX + 4, y: imageRect.midY - height / 2, width: max(imageRect.width - 8, 1), height: height),
                     centered: true, truncation: .middle, context: context)
        }
    }

    // MARK: Text

    private static func attributed(_ text: String, font: CTFont, color: CGColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color,
        ])
    }

    /// One line in `rect`, vertically centered, shortened with "…" when it doesn't fit.
    private static func drawLine(_ text: String, font: CTFont, color: CGColor, in rect: CGRect, centered: Bool,
                                 truncation: CTLineTruncationType, context: CGContext) {
        guard !text.isEmpty else { return }
        var line = CTLineCreateWithAttributedString(attributed(text, font: font, color: color))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        if CTLineGetTypographicBounds(line, nil, nil, nil) > rect.width {
            let token = CTLineCreateWithAttributedString(attributed("…", font: font, color: color))
            if let truncated = CTLineCreateTruncatedLine(line, rect.width, truncation, token) { line = truncated }
        }
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let x = centered ? rect.midX - width / 2 : rect.minX
        context.textPosition = CGPoint(x: x, y: rect.midY - (ascent - descent) / 2)
        CTLineDraw(line, context)
    }

    /// Wrapped lines from the top of `rect`; lines that don't fit are left out.
    private static func drawParagraph(_ text: String, font: CTFont, color: CGColor, in rect: CGRect, context: CGContext) {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed(text, font: font, color: color))
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }
}

/// Writes a contact sheet as a PDF (Generate), rendering each photo with its edits at print
/// resolution off the main thread.
nonisolated enum ContactSheetPDF {
    /// The photos are rendered for this many pixels per inch of their cells.
    static let pixelsPerInch: CGFloat = 300

    enum WriteError: LocalizedError {
        case unwritable

        var errorDescription: String? { "The PDF couldn't be written." }
    }

    /// Writes the sheet to `url`, page by page. `progress` gets the fraction done on the main actor.
    /// Throws `CancellationError` when cancelled; nothing is left at `url` unless it succeeds.
    @concurrent
    static func write(_ photos: [ContactSheetPhoto], settings: ContactSheetSettings, to url: URL,
                      progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        let layout = ContactSheetLayout(settings: settings, photoCount: photos.count)
        var mediaBox = CGRect(origin: .zero, size: layout.pageSize)
        let headline = settings.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let info: [CFString: Any] = [
            kCGPDFContextTitle: headline.isEmpty ? url.deletingPathExtension().lastPathComponent : headline,
            kCGPDFContextCreator: "PixelLoupe",
        ]
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else { throw WriteError.unwritable }
        var finished = false
        defer {
            if !finished {
                context.closePDF()
                try? FileManager.default.removeItem(at: url)
            }
        }

        let maxPixels = layout.cellSize / 72 * pixelsPerInch
        for page in 0..<layout.pageCount {
            try Task.checkCancellation()
            let range = layout.photos(onPage: page)
            let images = await renderImages(Array(photos[range]), maxPixels: maxPixels)
            try Task.checkCancellation()
            context.beginPDFPage(nil)
            ContactSheetRenderer.drawPage(page, layout: layout, settings: settings, in: context) { index in
                let photo = photos[index]
                return ContactSheetRenderer.Cell(image: images[index - range.lowerBound]?.image, aspect: photo.aspect,
                                                 name: photo.fileName, caption: photo.caption(settings.captionField))
            }
            context.endPDFPage()
            let done = Double(page + 1) / Double(layout.pageCount)
            await progress(done)
        }
        context.closePDF()
        finished = true
    }

    /// Renders a page's photos a few at a time (as Export does), each as a JPEG so the PDF embeds
    /// compressed images rather than raw pixels. A photo that can't be read comes back nil.
    private static func renderImages(_ photos: [ContactSheetPhoto], maxPixels: CGFloat) async -> [PhotoRenderer.Rendered?] {
        let limit = max(1, min(3, ProcessInfo.processInfo.activeProcessorCount / 3))
        var results = [PhotoRenderer.Rendered?](repeating: nil, count: photos.count)
        await withTaskGroup(of: (Int, PhotoRenderer.Rendered?).self) { group in
            var next = 0
            func addNext() {
                guard next < photos.count else { return }
                let index = next, photo = photos[index]
                next += 1
                group.addTask {
                    guard !Task.isCancelled,
                          let rendered = await PhotoRenderer.render(photo.source, adjustments: photo.adjustments, maxPixels: maxPixels)
                    else { return (index, nil) }
                    return (index, jpeg(rendered) ?? rendered)
                }
            }
            for _ in 0..<limit { addNext() }
            for await (index, image) in group {
                results[index] = image
                addNext()
            }
        }
        return results
    }

    /// The image re-read from JPEG data, which Core Graphics embeds in a PDF as it is.
    private static func jpeg(_ rendered: PhotoRenderer.Rendered) -> PhotoRenderer.Rendered? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, rendered.image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(data, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return PhotoRenderer.Rendered(image: image)
    }
}
