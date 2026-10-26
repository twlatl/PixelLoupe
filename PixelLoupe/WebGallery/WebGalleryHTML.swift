import Foundation

/// The web gallery's HTML pages and stylesheet. The preview and the generated folder are written from
/// the same strings, so what the window shows is what the folder holds.
///
/// Each photo gets a square cell, fitted inside it at its own aspect ratio, with its caption
/// underneath, in a grid of up to `columns` across (fewer on a narrow screen).
nonisolated enum WebGalleryHTML {
    static let stylesheetName = "gallery.css"
    static let thumbnailFolder = "images/thumbs"

    /// Narrower than this (in CSS pixels), the grid shows at most two columns; narrower than
    /// `singleColumnWidth`, one.
    static let narrowWidth = 700
    static let singleColumnWidth = 400

    /// The file name of photo `index` (0-based) of `count`: "001.jpg", numbered so they sort in order
    /// and so original file names aren't published.
    static func imageName(index: Int, count: Int) -> String {
        let digits = max(3, String(max(count, 1)).count)
        let number = String(index + 1)
        return String(repeating: "0", count: max(0, digits - number.count)) + number + ".jpg"
    }

    /// The photo an image name names (the reverse of ``imageName(index:count:)``).
    static func index(ofImageNamed name: String) -> Int? {
        guard name.hasSuffix(".jpg"), let number = Int(name.dropLast(4)), number >= 1 else { return nil }
        return number - 1
    }

    // MARK: Pages

    /// Page `page` of the gallery. `sourceName` titles it when there's no headline.
    static func page(_ page: Int, photos: [ContactSheetPhoto], settings: WebGallerySettings, sourceName: String) -> String {
        let pages = WebGalleryPages(photoCount: photos.count, photosPerPage: settings.photosPerPage)
        let headline = settings.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = settings.description.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = headline.isEmpty ? sourceName : headline
        if pages.count > 1 { title += " (\(page + 1) of \(pages.count))" }
        let language = Locale.current.language.languageCode?.identifier ?? "en"

        var html = """
        <!DOCTYPE html>
        <html lang="\(escape(language))">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="PixelLoupe">
        <title>\(escape(title))</title>
        <link rel="stylesheet" href="\(stylesheetName)">
        </head>
        <body>

        """
        if !headline.isEmpty || !description.isEmpty {
            html += "<header>\n"
            if !headline.isEmpty { html += "<h1>\(escape(headline))</h1>\n" }
            if !description.isEmpty { html += "<p class=\"description\">\(escape(description))</p>\n" }
            html += "</header>\n"
        }

        var gridClasses = ["grid"]
        if settings.showsBorder { gridClasses.append("border") }
        if settings.showsShadow { gridClasses.append("shadow") }
        html += "<main class=\"\(gridClasses.joined(separator: " "))\">\n"
        for index in pages.photos(onPage: page) {
            html += cell(index, photo: photos[index], count: photos.count, settings: settings)
        }
        html += "</main>\n"
        html += navigation(page, pages: pages, showsNumbers: settings.showsPageNumbers)
        html += "</body>\n</html>\n"
        return html
    }

    private static func cell(_ index: Int, photo: ContactSheetPhoto, count: Int, settings: WebGallerySettings) -> String {
        let source = "\(thumbnailFolder)/\(imageName(index: index, count: count))"
        let caption = settings.showsCaption ? photo.caption(settings.captionField) : ""
        // The alt text describes the photo even when the caption shows something else; the file name
        // is published only when it's the caption.
        let alt = photo.title ?? photo.caption ?? "Photo \(index + 1)"
        // The size attributes give the browser the photo's shape before the image arrives, so the
        // grid doesn't jump as thumbnails load. Width / height of 0 means unknown: drawn landscape.
        let aspect = photo.aspect > 0 ? photo.aspect : 1.5
        let width = aspect >= 1 ? 800 : Int((800 * aspect).rounded())
        let height = aspect >= 1 ? Int((800 / aspect).rounded()) : 800
        var html = "<figure id=\"\(index + 1)\">\n"
        html += "<div class=\"cell\"><img class=\"\(aspect >= 1 ? "landscape" : "portrait")\" src=\"\(source)\" "
        html += "width=\"\(width)\" height=\"\(height)\" alt=\"\(escape(alt))\" loading=\"lazy\" decoding=\"async\"></div>\n"
        if settings.showsCaption {
            // An empty caption still takes its line, so the rows stay even.
            html += "<figcaption>\(caption.isEmpty ? "&nbsp;" : escape(caption))</figcaption>\n"
        }
        html += "</figure>\n"
        return html
    }

    /// "‹ Previous · 1 2 3 · Next ›" under the grid; nothing for a single page.
    private static func navigation(_ page: Int, pages: WebGalleryPages, showsNumbers: Bool) -> String {
        guard pages.count > 1 else { return "" }
        var items: [String] = []
        if page > 0 {
            items.append("<a rel=\"prev\" href=\"\(WebGalleryPages.fileName(ofPage: page - 1))\">‹ Previous</a>")
        } else {
            items.append("<span class=\"disabled\">‹ Previous</span>")
        }
        if showsNumbers {
            for link in pages.numberedLinks(around: page) {
                guard let link else {
                    items.append("<span class=\"gap\">…</span>")
                    continue
                }
                items.append(link == page
                    ? "<span aria-current=\"page\">\(link + 1)</span>"
                    : "<a href=\"\(WebGalleryPages.fileName(ofPage: link))\">\(link + 1)</a>")
            }
        }
        if page < pages.count - 1 {
            items.append("<a rel=\"next\" href=\"\(WebGalleryPages.fileName(ofPage: page + 1))\">Next ›</a>")
        } else {
            items.append("<span class=\"disabled\">Next ›</span>")
        }
        return "<nav class=\"pages\" aria-label=\"Pages\">\n\(items.joined(separator: "\n"))\n</nav>\n"
    }

    // MARK: Stylesheet

    static func stylesheet(settings: WebGallerySettings) -> String {
        let columns = min(max(settings.columns, WebGallerySettings.columnRange.lowerBound), WebGallerySettings.columnRange.upperBound)
        let border = ContactSheetLayout.borderFraction * 100
        return """
        :root {
          --text: \(css(settings.textColor));
          --background: \(css(settings.backgroundColor));
          --columns: \(columns);
        }
        @media (max-width: \(narrowWidth)px) { :root { --columns: \(min(columns, 2)); } }
        @media (max-width: \(singleColumnWidth)px) { :root { --columns: 1; } }

        * { box-sizing: border-box; }
        html { background: var(--background); color: var(--text); }
        body {
          margin: 0 auto;
          padding: 36px 24px;
          max-width: 1600px;
          font: 15px/1.4 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif;
        }
        a { color: inherit; }
        header { margin-bottom: 24px; }
        h1 { margin: 0 0 4px; font-size: 1.6em; font-weight: 600; }
        .description { margin: 0; white-space: pre-line; }

        .grid {
          display: grid;
          grid-template-columns: repeat(var(--columns), minmax(0, 1fr));
          gap: 16px;
        }
        figure { margin: 0; min-width: 0; }
        .cell {
          aspect-ratio: 1;
          display: flex;
          align-items: center;
          justify-content: center;
        }
        .cell img { display: block; object-fit: contain; }
        .cell img.landscape { width: 100%; height: auto; }
        .cell img.portrait { height: 100%; width: auto; }
        .border .cell img { padding: \(String(format: "%g", border))%; background: #fff; }
        .shadow .cell img { box-shadow: 0 2px 8px rgba(0, 0, 0, 0.35); }
        figcaption {
          margin-top: 4px;
          font-size: 0.75em;
          text-align: center;
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
        }

        .pages {
          display: flex;
          flex-wrap: wrap;
          justify-content: center;
          gap: 4px 12px;
          margin-top: 32px;
        }
        .pages a { text-decoration: none; }
        .pages a:hover { text-decoration: underline; }
        .pages [aria-current] { font-weight: 700; }
        .pages .disabled { opacity: 0.4; }

        """
    }

    // MARK: Helpers

    /// `value` with HTML's special characters escaped, for text and attribute values.
    static func escape(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// "#1a2b3c".
    static func css(_ color: WebGallerySettings.Color) -> String {
        func byte(_ component: Double) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(color.red), byte(color.green), byte(color.blue))
    }
}
