import Foundation

/// A named set of metadata fields filled in on photos, as in Lightroom: chosen in the import window
/// (Apply During Import ▸ Metadata) or the Library's Metadata panel. Only the checked fields are
/// applied; a checked field left empty clears that field on the photo, and an unchecked one is left
/// as the photo has it.
nonisolated struct MetadataPreset: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    /// The checked fields and their values, by `MetadataField.ID`.
    var fields: [String: String] = [:]

    init(id: UUID = UUID(), name: String, fields: [MetadataField.ID: String] = [:]) {
        self.id = id
        self.name = name
        self.fields = Dictionary(uniqueKeysWithValues: fields.map { ($0.key.rawValue, $0.value) })
    }

    /// The field's value if it's checked.
    subscript(field: MetadataField.ID) -> String? {
        get { fields[field.rawValue] }
        set { fields[field.rawValue] = newValue }
    }

    func isChecked(_ field: MetadataField.ID) -> Bool { fields[field.rawValue] != nil }

    /// Sets the checked fields on `photo`.
    func apply(to photo: Photo) {
        var metadata = photo.metadata
        for (key, value) in fields {
            guard let id = MetadataField.ID(rawValue: key) else { continue }
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if id == .label {
                photo.colorLabel = (ColorLabel.allCases.first { $0.title == value } ?? .none).rawValue
            } else {
                metadata[id] = value
            }
        }
        photo.metadata = metadata
    }

    // MARK: Fields

    /// The fields a preset can hold, in sections as in Lightroom's preset editor: the ones PixelLoupe
    /// can store and show in the Metadata panel.
    struct Section: Sendable, Identifiable {
        var title: String
        var fields: [(id: MetadataField.ID, label: String)]
        var id: String { title }
    }

    static let sections: [Section] = [
        section("Basic Info", .copyName, .label, .caption),
        section("Camera Info", .userComment, .gps, .altitude, .direction),
        section("IPTC Content", .headline, .iptcSubjectCode, .descriptionWriter, .category, .otherCategories),
        section("IPTC Copyright", .copyright, .copyrightStatus, .rightsUsageTerms, .copyrightInfoURL),
        Section(title: "IPTC Creator", fields: [
            (.creator, "Creator"), (.creatorAddress, "Creator Address"), (.creatorCity, "Creator City"),
            (.creatorState, "Creator State / Province"), (.creatorPostalCode, "Creator Postal Code"),
            (.creatorCountry, "Creator Country"), (.creatorPhone, "Creator Phone"), (.creatorEmail, "Creator E-Mail"),
            (.creatorWebsite, "Creator Website"), (.creatorJobTitle, "Creator Job Title"),
        ]),
        Section(title: "IPTC Image", fields: [
            (.dateCreated, "Date Created"), (.intellectualGenre, "Intellectual Genre"), (.scene, "IPTC Scene Code"),
            (.sublocation, "Sublocation"), (.city, "City"), (.state, "State / Province"), (.country, "Country / Region"),
            (.isoCountryCode, "ISO Country Code"),
        ]),
        section("IPTC Status", .title, .jobIdentifier, .instructions, .creditLine, .source),
        Section(title: "IPTC Extension Administrative", fields: [
            (.supplierImageID, "Supplier Image ID"), (.maxAvailHeight, "Max Avail Height"),
            (.maxAvailWidth, "Max Avail Width"), (.sourceType, "Digital Source Type"),
        ]),
        Section(title: "IPTC Extension Description", fields: [
            (.personShown, "Person Shown in the Image"), (.nameOfOrgShown, "Name of Organization Shown"),
            (.codeOfOrgShown, "Code of Organization Shown"), (.event, "Event"),
        ]),
        Section(title: "IPTC Extension Models", fields: [
            (.additionalModelInfo, "Additional Information"), (.modelAge, "Age"),
            (.minorAgeDisclosure, "Minor Model Age Disclosure"), (.modelReleaseStatus, "Release Status"),
            (.modelReleaseID, "Release Id"),
        ]),
        Section(title: "IPTC Extension Rights", fields: [(.propertyReleaseID, "Property Release Id")]),
        section("Three Dimensional Projection", .projection),
        section("Video", .audioChannelType, .audioSampleType, .videoAlphaMode, .album, .alternateTapeName,
                .cameraModel, .cameraAngle, .cameraMove, .client, .comment, .composer, .director,
                .directorOfPhotography, .videoArtist, .videoScene, .engineer, .genre, .good, .instrument,
                .logComment, .projectName, .releaseDate, .shotDate, .dayOfShoot, .shotLocation, .shotName,
                .speakerPlacement, .tapeName),
    ]

    private static func section(_ title: String, _ ids: MetadataField.ID...) -> Section {
        Section(title: title, fields: ids.map { ($0, MetadataField.field($0).label) })
    }

    // MARK: Storage

    /// The presets, in the order they were made. Presets saved before RAW-88 (the import window's,
    /// and the Library's under the same key in another form) are read once and kept.
    static func all(in defaults: UserDefaults = Defaults.store) -> [MetadataPreset] {
        if let data = defaults.data(forKey: storageKey) {
            return (try? JSONDecoder().decode([MetadataPreset].self, from: data)) ?? []
        }
        let presets = legacy(in: defaults)
        if !presets.isEmpty { save(presets, in: defaults) }
        return presets
    }

    static func save(_ presets: [MetadataPreset], in defaults: UserDefaults = Defaults.store) {
        defaults.set(try? JSONEncoder().encode(presets), forKey: storageKey)
    }

    static let storageKey = "MetadataPresetList"
    static let legacyKey = "MetadataPresets"

    /// The import window's presets (a list of creator, copyright, title and caption, where an empty
    /// field was left alone), or the Library's (names and their filled-in fields).
    private static func legacy(in defaults: UserDefaults) -> [MetadataPreset] {
        struct ImportPreset: Decodable {
            var id: UUID
            var name: String
            var creator = "", copyright = "", title = "", caption = ""
        }
        if let data = defaults.data(forKey: legacyKey),
           let old = try? JSONDecoder().decode([ImportPreset].self, from: data) {
            return old.map { old in
                let values: [MetadataField.ID: String] = [
                    .creator: old.creator, .copyright: old.copyright, .title: old.title, .caption: old.caption,
                ]
                return MetadataPreset(id: old.id, name: old.name, fields: values.filter {
                    !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })
            }
        }
        if let library = defaults.dictionary(forKey: legacyKey) as? [String: [String: String]] {
            return library.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
                var preset = MetadataPreset(name: name)
                preset.fields = library[name]!.filter { MetadataField.ID(rawValue: $0.key) != nil }
                return preset
            }
        }
        return []
    }
}
