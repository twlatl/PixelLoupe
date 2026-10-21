import Foundation

/// A saved Library Filter: its modes and their criteria, under a name (Lightroom's filter presets).
nonisolated struct FilterPreset: Equatable, Codable, Sendable {
    var name: String
    var criteria: LibraryFilter.Criteria

    /// Lightroom's built-in presets, always offered and never changed.
    static let builtIn: [FilterPreset] = {
        var flagged = LibraryFilter.Criteria()
        flagged.modes = [.attribute]
        flagged.attributes.flags = [.picked]
        var rated = LibraryFilter.Criteria()
        rated.modes = [.attribute]
        rated.attributes.rating = 1
        var defaultColumns = LibraryFilter.Criteria()
        defaultColumns.modes = [.metadata]
        var exposure = LibraryFilter.Criteria()
        exposure.modes = [.metadata]
        exposure.metadata = .init(columns: [.focalLength, .shutterSpeed, .aperture, .iso].map { .init(kind: $0) })
        return [
            FilterPreset(name: "Filters Off", criteria: .init()),
            FilterPreset(name: "Default Columns", criteria: defaultColumns),
            FilterPreset(name: "Exposure Info", criteria: exposure),
            FilterPreset(name: "Flagged", criteria: flagged),
            FilterPreset(name: "Rated", criteria: rated),
        ]
    }()
}

nonisolated extension LibraryFilter.Criteria {
    /// Whether the two filter the same way: the same modes, each with the same criteria. What a mode
    /// that's off was set to doesn't count.
    func filtersLike(_ other: Self) -> Bool {
        modes == other.modes
            && (!modes.contains(.text) || text == other.text)
            && (!modes.contains(.attribute) || attributes == other.attributes)
            && (!modes.contains(.metadata) || metadata == other.metadata)
    }
}

nonisolated extension LibraryFilter {
    /// Applies a preset: its modes, and its criteria for those modes. Modes it leaves off keep what
    /// they were set to, as any mode that's turned off does.
    mutating func apply(_ preset: FilterPreset) {
        var criteria = self.criteria
        criteria.modes = preset.criteria.modes
        if preset.criteria.modes.contains(.text) { criteria.text = preset.criteria.text }
        if preset.criteria.modes.contains(.attribute) { criteria.attributes = preset.criteria.attributes }
        if preset.criteria.modes.contains(.metadata) { criteria.metadata = preset.criteria.metadata }
        self.criteria = criteria
    }
}

/// The user's own filter presets, shared by every catalog (as Lightroom's are) and kept in the app's
/// preferences. Changes are announced so each window's filter bar shows them.
final class FilterPresets {
    static let shared = FilterPresets(defaults: Defaults.store)
    static let didChangeNotification = Notification.Name("FilterPresetsDidChange")
    private static let key = "LibraryFilterPresets"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// In the order they were saved.
    private(set) var custom: [FilterPreset] {
        get {
            guard let data = defaults.data(forKey: Self.key) else { return [] }
            return (try? JSONDecoder().decode([FilterPreset].self, from: data)) ?? []
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.key)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// The preset that filters like `criteria` (custom ones first), for the bar to show its name.
    func preset(matching criteria: LibraryFilter.Criteria) -> FilterPreset? {
        (custom + FilterPreset.builtIn).first { $0.criteria.filtersLike(criteria) }
    }

    /// Whether `name` is taken by a built-in preset, which can't be replaced.
    func isBuiltIn(_ name: String) -> Bool {
        FilterPreset.builtIn.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Saves the criteria under `name`, replacing a custom preset of that name.
    func save(_ criteria: LibraryFilter.Criteria, as name: String) {
        var presets = custom
        let preset = FilterPreset(name: name, criteria: criteria)
        if let index = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        custom = presets
    }

    func rename(_ name: String, to newName: String) {
        var presets = custom.filter { $0.name.caseInsensitiveCompare(newName) != .orderedSame || $0.name == name }
        guard let index = presets.firstIndex(where: { $0.name == name }) else { return }
        presets[index].name = newName
        custom = presets
    }

    func delete(_ name: String) {
        custom.removeAll { $0.name == name }
    }
}
