import CoreGraphics
import Foundation

/// How a contact sheet (Window ▸ Contact Sheet) is laid out. The layout choices are remembered
/// between sheets; the headline and description belong to one sheet and start empty.
nonisolated struct ContactSheetSettings: Codable, Equatable, Sendable {
    typealias Color = WatermarkSettings.Color

    enum PageSize: String, Codable, Sendable, CaseIterable {
        case letter, a4, tabloid, a3

        var title: String {
            switch self {
            case .letter: "US Letter"
            case .a4: "A4"
            case .tabloid: "Tabloid"
            case .a3: "A3"
            }
        }

        /// Portrait size in points (1/72 inch).
        var size: CGSize {
            switch self {
            case .letter: CGSize(width: 612, height: 792)
            case .a4: CGSize(width: 595.28, height: 841.89)
            case .tabloid: CGSize(width: 792, height: 1224)
            case .a3: CGSize(width: 841.89, height: 1190.55)
            }
        }

        /// US Letter in the countries that use it, A4 elsewhere.
        static func standard(for locale: Locale = .current) -> PageSize {
            let letterRegions: Set = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "GT", "CR", "PR"]
            return locale.region.map { letterRegions.contains($0.identifier) } == true ? .letter : .a4
        }
    }

    enum Orientation: String, Codable, Sendable, CaseIterable {
        case portrait, landscape
    }

    /// The metadata shown under each photo.
    enum CaptionField: String, Codable, Sendable, CaseIterable {
        case fileName, title, caption, captureDate, captureDateTime, camera, lens, exposure, rating, creator, copyright

        var title: String {
            switch self {
            case .fileName: "Filename"
            case .title: "Title"
            case .caption: "Caption"
            case .captureDate: "Capture Date"
            case .captureDateTime: "Capture Date & Time"
            case .camera: "Camera"
            case .lens: "Lens"
            case .exposure: "Exposure"
            case .rating: "Rating"
            case .creator: "Creator"
            case .copyright: "Copyright"
            }
        }
    }

    /// The image size slider's range, in columns across the page (more columns, smaller photos).
    static let columnRange = 1...10

    // Not remembered (see CodingKeys).
    var headline = ""
    var description = ""

    /// Black on white by default: the colors are the printed page's, the same in Dark Mode.
    var textColor = Color(red: 0, green: 0, blue: 0)
    var backgroundColor = Color.white
    var columns = 4
    var showsBorder = false
    var showsShadow = false
    var showsCaption = false
    var captionField = CaptionField.fileName
    var showsPageNumbers = true
    var pageSize = PageSize.standard()
    var orientation = Orientation.portrait

    init() {}

    private enum CodingKeys: String, CodingKey {
        case textColor, backgroundColor, columns, showsBorder, showsShadow, showsCaption, captionField
        case showsPageNumbers, pageSize, orientation
    }

    // Tolerant decoding: missing or unknown values keep their defaults, so saved settings survive new options.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ContactSheetSettings()
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
        pageSize = value(.pageSize, defaults.pageSize)
        orientation = value(.orientation, defaults.orientation)
    }

    /// The page in points, turned for the orientation.
    var pageDimensions: CGSize {
        let size = pageSize.size
        return orientation == .portrait ? size : CGSize(width: size.height, height: size.width)
    }

    private static let defaultsKey = "ContactSheetSettings"

    /// The settings last used, with an empty headline and description.
    static func remembered(in defaults: UserDefaults = Defaults.store) -> ContactSheetSettings {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(ContactSheetSettings.self, from: $0) }
            ?? ContactSheetSettings()
    }

    func remember(in defaults: UserDefaults = Defaults.store) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
