import Foundation

/// How a web gallery (Window ▸ Web Gallery) is laid out. The layout choices are remembered between
/// galleries; the headline and description belong to one gallery and start empty.
nonisolated struct WebGallerySettings: Codable, Equatable, Sendable {
    typealias Color = WatermarkSettings.Color
    typealias CaptionField = ContactSheetSettings.CaptionField

    /// The Photos per Page choices: each divides evenly by 2, 3, 4, 6, 8 and 12 columns, so a full
    /// page usually ends in a whole row.
    static let photosPerPageChoices = [24, 48, 96, 192]
    /// The Image Size slider's range, in columns across a wide window (more columns, smaller photos).
    static let columnRange = ContactSheetSettings.columnRange
    /// The JPEG Quality slider's range and step, in percent.
    static let qualityRange = 10.0...100.0
    static let qualityStep = 5.0

    // Not remembered (see CodingKeys).
    var headline = ""
    var description = ""

    var textColor = Color(red: 0, green: 0, blue: 0)
    var backgroundColor = Color.white
    var columns = 4
    var showsBorder = false
    var showsShadow = false
    var showsCaption = false
    var captionField = CaptionField.fileName
    var showsPageNumbers = true
    var photosPerPage = 48
    /// The generated images' JPEG quality, in percent (both sizes; the preview ignores it).
    var jpegQuality = 85.0
    /// The watermark preset drawn on the large images; nil for none. The preview ignores it.
    var watermarkName: String?
    /// The address the header's email link writes to; none when empty.
    var email = ""
    /// Inserted as typed at the end of every page's `<head>` and `<body>` (analytics, fonts, a footer).
    /// The preview leaves them out.
    var headHTML = ""
    var bodyHTML = ""

    init() {}

    private enum CodingKeys: String, CodingKey {
        case textColor, backgroundColor, columns, showsBorder, showsShadow, showsCaption, captionField
        case showsPageNumbers, photosPerPage, jpegQuality, watermarkName, email, headHTML, bodyHTML
    }

    // Tolerant decoding: missing or unknown values keep their defaults, so saved settings survive new options.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WebGallerySettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        textColor = value(.textColor, defaults.textColor)
        backgroundColor = value(.backgroundColor, defaults.backgroundColor)
        columns = min(max(value(.columns, defaults.columns), Self.columnRange.lowerBound), Self.columnRange.upperBound)
        showsBorder = value(.showsBorder, defaults.showsBorder)
        showsShadow = value(.showsShadow, defaults.showsShadow)
        showsCaption = value(.showsCaption, defaults.showsCaption)
        captionField = value(.captionField, defaults.captionField)
        showsPageNumbers = value(.showsPageNumbers, defaults.showsPageNumbers)
        let perPage = value(.photosPerPage, defaults.photosPerPage)
        photosPerPage = Self.photosPerPageChoices.contains(perPage) ? perPage : defaults.photosPerPage
        jpegQuality = Self.clampedQuality(value(.jpegQuality, defaults.jpegQuality))
        watermarkName = value(.watermarkName, defaults.watermarkName)
        email = value(.email, defaults.email)
        headHTML = value(.headHTML, defaults.headHTML)
        bodyHTML = value(.bodyHTML, defaults.bodyHTML)
    }

    /// `quality` in the slider's range, on its steps.
    static func clampedQuality(_ quality: Double) -> Double {
        let stepped = (quality / qualityStep).rounded() * qualityStep
        return min(max(stepped, qualityRange.lowerBound), qualityRange.upperBound)
    }

    private static let defaultsKey = "WebGallerySettings"

    /// The settings last used, with an empty headline and description.
    static func remembered(in defaults: UserDefaults = Defaults.store) -> WebGallerySettings {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(WebGallerySettings.self, from: $0) }
            ?? WebGallerySettings()
    }

    func remember(in defaults: UserDefaults = Defaults.store) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// How a web gallery's photos fall into pages, and what each page's file is called.
nonisolated struct WebGalleryPages: Equatable, Sendable {
    let photoCount: Int
    let photosPerPage: Int

    init(photoCount: Int, photosPerPage: Int) {
        self.photoCount = photoCount
        self.photosPerPage = max(photosPerPage, 1)
    }

    /// At least one, so a gallery without photos is still a page.
    var count: Int { max(1, (photoCount + photosPerPage - 1) / photosPerPage) }

    func photos(onPage page: Int) -> Range<Int> {
        let start = min(page * photosPerPage, photoCount)
        return start..<min(start + photosPerPage, photoCount)
    }

    /// `index.html` for the first page, then `page-2.html`, `page-3.html`, …
    static func fileName(ofPage page: Int) -> String {
        page == 0 ? "index.html" : "page-\(page + 1).html"
    }

    /// The page a file name names (the reverse of ``fileName(ofPage:)``), or nil for any other file.
    static func page(named fileName: String) -> Int? {
        if fileName == "index.html" { return 0 }
        guard fileName.hasPrefix("page-"), fileName.hasSuffix(".html"),
              let number = Int(fileName.dropFirst(5).dropLast(5)), number >= 2 else { return nil }
        return number - 1
    }

    /// "48 photos per page · 3 pages".
    var summary: String {
        "\(photosPerPage) photos per page · \(count) page\(count == 1 ? "" : "s")"
    }

    /// The page numbers the navigation links to, around `current`: the first and last pages, and two
    /// either side of the current one, with nil where a run of pages is left out ("1 … 4 5 6 7 8 … 20").
    func numberedLinks(around current: Int) -> [Int?] {
        let shown = Set([0, count - 1] + Array(max(0, current - 2)...min(count - 1, current + 2)))
        var links: [Int?] = []
        for page in shown.sorted() {
            if let last = links.last, let last, page > last + 1 {
                // A gap of one page shows the page rather than an ellipsis that hides only it.
                links.append(page == last + 2 ? last + 1 : nil)
            }
            links.append(page)
        }
        return links
    }
}
