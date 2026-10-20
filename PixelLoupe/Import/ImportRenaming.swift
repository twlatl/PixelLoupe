import Foundation

/// File Renaming in the import window: how copied photos are named. Only copies are renamed; photos
/// added in place keep their names.
nonisolated struct ImportRenaming: Codable, Equatable, Sendable {
    enum Template: String, Codable, Sendable, CaseIterable {
        /// `2026-10-15-DSC00112` (the capture date).
        case dateFilename
        /// `DSC00112`, the file's own name (with Extensions applied).
        case filename
        /// `California Adventure-0001`
        case shootNameSequence
        /// `Custom-0001`
        case customTextSequence
        /// `Custom-DSC00112`
        case customTextFilename
        /// `2026-10-15-0001`
        case dateSequence

        var title: String {
            switch self {
            case .dateFilename: "Date - Filename"
            case .filename: "Filename"
            case .shootNameSequence: "Shoot Name - Sequence"
            case .customTextSequence: "Custom Text - Sequence"
            case .customTextFilename: "Custom Text - Filename"
            case .dateSequence: "Date - Sequence"
            }
        }

        var usesCustomText: Bool { self == .customTextSequence || self == .customTextFilename }
        var usesShootName: Bool { self == .shootNameSequence }
        var usesSequence: Bool { self == .shootNameSequence || self == .customTextSequence || self == .dateSequence }
    }

    enum ExtensionCase: String, Codable, Sendable, CaseIterable {
        case leave, lowercase, uppercase

        var title: String {
            switch self {
            case .leave: "Leave As-Is"
            case .lowercase: "lowercase"
            case .uppercase: "UPPERCASE"
            }
        }

        func apply(_ ext: String) -> String {
            switch self {
            case .leave: ext
            case .lowercase: ext.lowercased()
            case .uppercase: ext.uppercased()
            }
        }
    }

    var isOn = false
    var template = Template.dateFilename
    var customText = ""
    var shootName = ""
    /// Whether Shoot Name was typed, rather than following the destination's subfolder.
    var shootNameEdited = false
    var startNumber = 1
    var extensionCase = ExtensionCase.leave

    /// The new name for a file named `original`, taken on `date`, the `index`th renamed in this import
    /// (from 0). Characters that can't be in a file name are replaced.
    func name(for original: String, date: Date, index: Int, calendar: Calendar = .current) -> String {
        let base = (original as NSString).deletingPathExtension
        let ext = extensionCase.apply((original as NSString).pathExtension)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let sequence = String(format: "%04d", max(0, startNumber) + index)
        func text(_ value: String, fallback: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallback : trimmed
        }
        let stem: String = switch template {
        case .dateFilename: "\(day)-\(base)"
        case .filename: base
        case .shootNameSequence: "\(text(shootName, fallback: "Shoot"))-\(sequence)"
        case .customTextSequence: "\(text(customText, fallback: "Untitled"))-\(sequence)"
        case .customTextFilename: "\(text(customText, fallback: "Untitled"))-\(base)"
        case .dateSequence: "\(day)-\(sequence)"
        }
        let safe = stem.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return ext.isEmpty ? safe : "\(safe).\(ext)"
    }
}
