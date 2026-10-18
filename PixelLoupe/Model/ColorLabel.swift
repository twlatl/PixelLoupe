import AppKit

/// Lightroom's color labels: five colors in the default label set, shown on cells and used to filter
/// and sort. Stored as `Photo.colorLabel`.
nonisolated enum ColorLabel: Int16, CaseIterable, Sendable {
    case none = 0
    case red, yellow, green, blue, purple

    /// The five colors, without "none".
    static var colors: [ColorLabel] { allCases.filter { $0 != .none } }

    var title: String {
        switch self {
        case .none: "None"
        case .red: "Red"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        }
    }

    /// The digit key that toggles the label, as in Lightroom (purple has none).
    var shortcut: String? {
        switch self {
        case .red: "6"
        case .yellow: "7"
        case .green: "8"
        case .blue: "9"
        default: nil
        }
    }

    /// How smart-collection rules store the label.
    var ruleValue: String { title.lowercased() }

    /// The label for a name as Lightroom stores it (`Red`), ignoring case and spaces.
    init?(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let match = Self.allCases.first(where: { $0 != .none && $0.title.lowercased() == trimmed }) else { return nil }
        self = match
    }

    init?(ruleValue: String) {
        guard let match = Self.allCases.first(where: { $0.ruleValue == ruleValue }) else { return nil }
        self = match
    }

    /// Lightroom-like colors that read on both the light and dark matte.
    var color: NSColor {
        switch self {
        case .none: .clear
        case .red: .systemRed
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        }
    }
}

nonisolated extension Photo {
    /// The photo's color label. A photo imported from Lightroom with a custom label name keeps that
    /// name in `labelText` and has no color.
    var label: ColorLabel {
        get { ColorLabel(rawValue: colorLabel) ?? .none }
        set {
            colorLabel = newValue.rawValue
            if newValue != .none { labelText = nil }
        }
    }
}
