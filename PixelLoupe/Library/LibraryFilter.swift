import CoreData

/// Everything that determines which photos the Library grid shows and in what order.
nonisolated struct LibraryFilter: Equatable, Sendable {
    enum Scope: Equatable, Sendable {
        case allPhotos
        /// A folder and all of its subfolders.
        case folder(path: String)
        /// The photos of the catalog's most recent import (see `Photo.latestImportID(in:)`).
        case previousImport(id: UUID)
        /// A collection, smart collection or collection set, with what it contains.
        case collection(id: UUID, content: CollectionContent)
        /// Photos whose Lightroom settings weren't fully imported for a reason (the import report's
        /// "Show Photos"), or for any reason when `nil`.
        case importDifference(reason: String?)
        /// The photos of a publish service, in any state (RAW-179): the grid groups them into New,
        /// Modified, Published and Deleted.
        case publishService(id: UUID)
        /// An album in a publish service (RAW-185): a regular album's photos, or a smart album's matches
        /// (`rules`). Shown grouped like its service's photos.
        case publishAlbum(id: UUID, serviceID: UUID, rules: SmartCollectionRules?)

        /// The publish service shown, or the one whose album is shown.
        var publishServiceID: UUID? {
            switch self {
            case .publishService(let id): id
            case .publishAlbum(_, let serviceID, _): serviceID
            default: nil
            }
        }

        var publishAlbumID: UUID? {
            if case .publishAlbum(let id, _, _) = self { id } else { nil }
        }

        /// The collection whose own photos are shown (not a smart collection or a set).
        var membersCollectionID: UUID? {
            if case .collection(let id, .members(_)) = self { id } else { nil }
        }

        var collectionID: UUID? {
            if case .collection(let id, _) = self { id } else { nil }
        }
    }

    enum RatingComparison: String, CaseIterable, Codable, Sendable {
        case atLeast, exactly, atMost

        var symbol: String {
            switch self {
            case .atLeast: "≥"
            case .exactly: "="
            case .atMost: "≤"
            }
        }
    }

    /// The Library Filter bar's modes (Lightroom's Text, Attribute and Metadata). Each active mode's
    /// criteria narrow the photos further; a mode that's off keeps its criteria but doesn't filter.
    enum Mode: String, CaseIterable, Codable, Sendable {
        case text, attribute, metadata

        var title: String {
            switch self {
            case .text: "Text"
            case .attribute: "Attribute"
            case .metadata: "Metadata"
            }
        }
    }

    /// The Attribute mode's criteria, in Lightroom's groups: flag, edit, rating, color label, kind
    /// and stack. A photo matches a group if it matches any of the group's choices, and must match
    /// every group that has choices.
    struct Attributes: Equatable, Codable, Sendable {
        enum EditStatus: String, CaseIterable, Codable, Sendable {
            case edited, unedited

            var title: String {
                switch self {
                case .edited: "Edited"
                case .unedited: "Unedited"
                }
            }
        }

        enum Kind: String, CaseIterable, Codable, Sendable {
            /// A photo that isn't a virtual copy or a video (Lightroom's Master Photos).
            case original
            case virtualCopy
            case video

            var title: String {
                switch self {
                case .original: "Originals"
                case .virtualCopy: "Virtual Copies"
                case .video: "Videos"
                }
            }
        }

        enum StackStatus: String, CaseIterable, Codable, Sendable {
            case stacked, unstacked

            var title: String {
                switch self {
                case .stacked: "Stacked"
                case .unstacked: "Not Stacked"
                }
            }
        }

        /// 1–5, or `nil` for no rating filter.
        var rating: Int?
        var ratingComparison: RatingComparison = .atLeast
        /// Photos with any of these flags are shown. Empty means no flag filter.
        var flags: Set<PhotoFlag> = []
        /// Edited photos (with Develop settings), unedited ones, or (empty) either.
        var editStatus: Set<EditStatus> = []
        /// Photos with any of these color labels are shown (`.none` for photos with no label at all).
        /// With `otherLabel`, so are photos with a label that has no color here (a custom Lightroom
        /// label). Neither set means no label filter.
        var colorLabels: Set<ColorLabel> = []
        var otherLabel = false
        /// Photos of any of these kinds are shown. Empty means no kind filter.
        var kinds: Set<Kind> = []
        /// Photos in a stack, photos in none, or (empty) either.
        var stackStatus: Set<StackStatus> = []

        init(
            rating: Int? = nil, ratingComparison: RatingComparison = .atLeast, flags: Set<PhotoFlag> = [],
            editStatus: Set<EditStatus> = [], colorLabels: Set<ColorLabel> = [], otherLabel: Bool = false,
            kinds: Set<Kind> = [], stackStatus: Set<StackStatus> = []
        ) {
            self.rating = rating
            self.ratingComparison = ratingComparison
            self.flags = flags
            self.editStatus = editStatus
            self.colorLabels = colorLabels
            self.otherLabel = otherLabel
            self.kinds = kinds
            self.stackStatus = stackStatus
        }

        init(from decoder: Decoder) throws {
            // Groups added later are missing from filters saved before them.
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rating = try container.decodeIfPresent(Int.self, forKey: .rating)
            ratingComparison = try container.decodeIfPresent(RatingComparison.self, forKey: .ratingComparison) ?? .atLeast
            flags = try container.decodeIfPresent(Set<PhotoFlag>.self, forKey: .flags) ?? []
            editStatus = try container.decodeIfPresent(Set<EditStatus>.self, forKey: .editStatus) ?? []
            colorLabels = try container.decodeIfPresent(Set<ColorLabel>.self, forKey: .colorLabels) ?? []
            otherLabel = try container.decodeIfPresent(Bool.self, forKey: .otherLabel) ?? false
            kinds = try container.decodeIfPresent(Set<Kind>.self, forKey: .kinds) ?? []
            stackStatus = try container.decodeIfPresent(Set<StackStatus>.self, forKey: .stackStatus) ?? []
        }

        var isEmpty: Bool {
            rating == nil && flags.isEmpty && editStatus.isEmpty && colorLabels.isEmpty && !otherLabel
                && kinds.isEmpty && stackStatus.isEmpty
        }

        fileprivate var predicates: [NSPredicate] {
            var predicates: [NSPredicate] = []
            if !flags.isEmpty {
                predicates.append(NSPredicate(format: "flag IN %@", flags.map { NSNumber(value: $0.rawValue) }))
            }
            if !editStatus.isEmpty {
                predicates.append(anyOf(EditStatus.allCases.filter(editStatus.contains).map {
                    switch $0 {
                    // The same test as the smart-collection rule "Has Adjustments".
                    case .edited: NSPredicate(format: "adjustmentsData != nil")
                    case .unedited: NSPredicate(format: "adjustmentsData == nil")
                    }
                }))
            }
            if let rating {
                let format = switch ratingComparison {
                case .atLeast: "rating >= %d"
                case .exactly: "rating == %d"
                case .atMost: "rating <= %d"
                }
                predicates.append(NSPredicate(format: format, rating))
            }
            if !colorLabels.isEmpty || otherLabel {
                var labels: [NSPredicate] = []
                let colors = colorLabels.subtracting([.none])
                if !colors.isEmpty {
                    labels.append(NSPredicate(format: "colorLabel IN %@", colors.map { NSNumber(value: $0.rawValue) }))
                }
                // A custom label has no color, so "no label" is no color and no label text.
                if colorLabels.contains(.none) {
                    labels.append(NSPredicate(format: "colorLabel == 0 AND labelText == nil"))
                }
                if otherLabel {
                    labels.append(NSPredicate(format: "colorLabel == 0 AND labelText != nil"))
                }
                predicates.append(anyOf(labels))
            }
            if !kinds.isEmpty {
                predicates.append(anyOf(Kind.allCases.filter(kinds.contains).map {
                    switch $0 {
                    case .original: NSPredicate(format: "master == nil AND isVideo == NO")
                    case .virtualCopy: NSPredicate(format: "master != nil")
                    case .video: NSPredicate(format: "isVideo == YES")
                    }
                }))
            }
            if !stackStatus.isEmpty {
                predicates.append(anyOf(StackStatus.allCases.filter(stackStatus.contains).map {
                    switch $0 {
                    case .stacked: NSPredicate(format: "stack != nil")
                    case .unstacked: NSPredicate(format: "stack == nil")
                    }
                }))
            }
            return predicates
        }

        private func anyOf(_ predicates: [NSPredicate]) -> NSPredicate {
            predicates.count == 1 ? predicates[0] : NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        }
    }

    /// The Text mode's criteria, as Lightroom's: which fields to search, how the words must match,
    /// and the words. A word written `!word` must not appear, `+word` must start a word and `word+`
    /// must end one, whatever the rule.
    struct TextSearch: Equatable, Codable, Sendable {
        enum Field: String, CaseIterable, Codable, Sendable {
            case anySearchable, fileName, copyName, title, caption, keywords, cameraAndLens, creatorAndCopyright

            var title: String {
                switch self {
                case .anySearchable: "Any Searchable Field"
                case .fileName: "Filename"
                case .copyName: "Copy Name"
                case .title: "Title"
                case .caption: "Caption"
                case .keywords: "Keywords"
                case .cameraAndLens: "Camera & Lens"
                case .creatorAndCopyright: "Creator & Copyright"
                }
            }

            /// The photo's text attributes the field searches.
            fileprivate var keyPaths: [String] {
                switch self {
                case .anySearchable:
                    ["fileName", "copyName", "titleText", "captionText", "creatorText", "copyrightText",
                     "cameraMake", "cameraModel", "lensModel", "labelText"]
                case .fileName: ["fileName"]
                case .copyName: ["copyName"]
                case .title: ["titleText"]
                case .caption: ["captionText"]
                case .keywords: []
                case .cameraAndLens: ["cameraMake", "cameraModel", "lensModel"]
                case .creatorAndCopyright: ["creatorText", "copyrightText"]
                }
            }

            /// Keywords match by their full path (so a parent's name finds what's below it) or a synonym.
            fileprivate var searchesKeywords: Bool { self == .anySearchable || self == .keywords }
        }

        enum Rule: String, CaseIterable, Codable, Sendable {
            /// Any of the words, anywhere.
            case contains
            /// All of the words, anywhere (part of a word counts).
            case containsAll
            /// All of the words, as whole words.
            case containsWords
            /// None of the words.
            case doesNotContain
            /// Each word starts a word.
            case startsWith
            /// Each word ends a word.
            case endsWith

            var title: String {
                switch self {
                case .contains: "Contains"
                case .containsAll: "Contains All"
                case .containsWords: "Contains Words"
                case .doesNotContain: "Doesn't Contain"
                case .startsWith: "Starts With"
                case .endsWith: "Ends With"
                }
            }
        }

        /// How one word must match.
        fileprivate enum Match: Equatable {
            case anywhere, wholeWord, startOfWord, endOfWord, absent
        }

        var field = Field.anySearchable
        var rule = Rule.containsAll
        var query = ""

        init(field: Field = .anySearchable, rule: Rule = .containsAll, query: String = "") {
            self.field = field
            self.rule = rule
            self.query = query
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            field = try container.decodeIfPresent(Field.self, forKey: .field) ?? .anySearchable
            rule = try container.decodeIfPresent(Rule.self, forKey: .rule) ?? .containsAll
            query = try container.decodeIfPresent(String.self, forKey: .query) ?? ""
        }

        var isEmpty: Bool { Self.words(in: query).isEmpty }

        /// The query's words with how each must match: Lightroom's `!word`, `+word` and `word+`
        /// override the rule. A bare `!` or `+` is no word.
        fileprivate func matches() -> [(word: String, match: Match)] {
            let ruleMatch: Match = switch rule {
            case .contains, .containsAll: .anywhere
            case .containsWords: .wholeWord
            case .doesNotContain: .absent
            case .startsWith: .startOfWord
            case .endsWith: .endOfWord
            }
            return Self.words(in: query).compactMap { word in
                if word.hasPrefix("!") { return Self.stripped(word.dropFirst()).map { ($0, .absent) } }
                if word.hasPrefix("+") { return Self.stripped(word.dropFirst()).map { ($0, .startOfWord) } }
                if word.hasSuffix("+") { return Self.stripped(word.dropLast()).map { ($0, .endOfWord) } }
                return (word, ruleMatch)
            }
        }

        private static func words(in query: String) -> [String] {
            query.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0 != "!" && $0 != "+" }
        }

        private static func stripped(_ word: Substring) -> String? {
            word.isEmpty ? nil : String(word)
        }

        fileprivate var predicates: [NSPredicate] {
            let matches = matches()
            guard !matches.isEmpty else { return [] }
            // Contains needs any of its plain words; every other word (and every word for the other
            // rules) must match on its own.
            if rule == .contains {
                let plain = matches.filter { $0.match == .anywhere }.map { predicate(for: $0.word, $0.match) }
                let others = matches.filter { $0.match != .anywhere }.map { predicate(for: $0.word, $0.match) }
                return (plain.isEmpty ? [] : [NSCompoundPredicate(orPredicateWithSubpredicates: plain)]) + others
            }
            return matches.map { predicate(for: $0.word, $0.match) }
        }

        /// The word matches (or, for `.absent`, doesn't appear in) any of the field's attributes.
        private func predicate(for word: String, _ match: Match) -> NSPredicate {
            if match == .absent {
                // Spelled out rather than NOT(…): SQLite can't negate ANY over keywords, and NOT of a
                // missing value (no lens) is unknown, which would leave the photo out.
                var predicates = field.keyPaths.map { NSPredicate(format: "\($0) == nil OR NOT (\($0) CONTAINS[cd] %@)", word) }
                if field.searchesKeywords {
                    predicates.append(NSPredicate(
                        format: "SUBQUERY(tags, $t, $t.pathKey CONTAINS[cd] %@ OR $t.synonymText CONTAINS[cd] %@).@count == 0", word, word
                    ))
                }
                return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            }
            let (comparison, value): (String, String) = switch match {
            case .anywhere, .absent: ("CONTAINS[cd]", word)
            // Word boundaries need a regular expression; (?is) is case-insensitive and lets . span lines.
            case .wholeWord: ("MATCHES", "(?is).*\\b\(NSRegularExpression.escapedPattern(for: word))\\b.*")
            case .startOfWord: ("MATCHES", "(?is).*\\b\(NSRegularExpression.escapedPattern(for: word)).*")
            case .endOfWord: ("MATCHES", "(?is).*\(NSRegularExpression.escapedPattern(for: word))\\b.*")
            }
            var predicates = field.keyPaths.map { NSPredicate(format: "\($0) \(comparison) %@", value) }
            if field.searchesKeywords {
                predicates.append(NSPredicate(format: "ANY tags.pathKey \(comparison) %@", value))
                predicates.append(NSPredicate(format: "ANY tags.synonymText \(comparison) %@", value))
            }
            return NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        }
    }

    /// The Metadata mode's criteria: Lightroom's columns, each listing one kind of metadata (Date,
    /// Camera, Keyword…) with the values the photos have. Values chosen in a column are OR'd, columns
    /// are AND'd, and each column lists only what the columns to its left leave (see
    /// ``MetadataColumn``).
    struct MetadataBrowser: Equatable, Codable, Sendable {
        struct Column: Equatable, Codable, Sendable {
            var kind: MetadataColumn
            /// The chosen values' keys (``MetadataColumn/predicate(forKey:)``); empty is "All".
            var selection: Set<String> = []
        }

        static let defaultColumns: [MetadataColumn] = [.date, .camera, .lens, .label]
        static let columnCountRange = 1...8

        var columns: [Column] = MetadataBrowser.defaultColumns.map { Column(kind: $0) }

        init(columns: [Column] = MetadataBrowser.defaultColumns.map { Column(kind: $0) }) {
            self.columns = columns
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let columns = try container.decodeIfPresent([Column].self, forKey: .columns) ?? []
            self.columns = columns.isEmpty ? Self.defaultColumns.map { Column(kind: $0) } : columns
        }

        var isEmpty: Bool { columns.allSatisfy(\.selection.isEmpty) }

        /// What the columns before `index` leave: the cascade's filter for that column.
        func predicates(before index: Int) -> [NSPredicate] {
            columns.prefix(index).compactMap(\.predicate)
        }

        fileprivate var predicates: [NSPredicate] { columns.compactMap(\.predicate) }

        /// Shows photos with these keywords (and those below them): selects them in the first Keyword
        /// column, adding one at the left if there's none, and resets the other columns to All.
        mutating func select(keywords: Set<String>) {
            for index in columns.indices { columns[index].selection = [] }
            if let index = columns.firstIndex(where: { $0.kind == .keyword }) {
                columns[index].selection = keywords
                return
            }
            if columns.count == Self.columnCountRange.upperBound { columns.removeFirst() }
            columns.insert(Column(kind: .keyword, selection: keywords), at: 0)
        }
    }

    /// What the Library Filter bar filters by, saved with the catalog: its modes and every mode's
    /// criteria (including those of modes that are off).
    struct Criteria: Equatable, Codable, Sendable {
        var modes: Set<Mode> = []
        var attributes = Attributes()
        var text = TextSearch()
        var metadata = MetadataBrowser()
    }

    var scope: Scope = .allPhotos {
        didSet { if scope != oldValue { cullReview = nil } }
    }
    /// The Assisted Culling panel's Review (Selects or Rejects; nil is All), on top of the bar's criteria. Not
    /// saved, and back to All when the source changes.
    var cullReview: CullingReview?
    /// The modes that filter. Setting a mode's criteria turns it on, so the filmstrip's filters and
    /// the keyword list's arrow work whatever the bar shows (as in Lightroom).
    var modes: Set<Mode> = []
    var attributes = Attributes() {
        didSet { if !attributes.isEmpty { modes.insert(.attribute) } }
    }
    var text = TextSearch() {
        didSet { if !text.isEmpty { modes.insert(.text) } }
    }
    var metadata = MetadataBrowser() {
        didSet { if !metadata.isEmpty { modes.insert(.metadata) } }
    }
    var sortKey: PhotoSortKey = .captureTime
    var ascending = true

    var criteria: Criteria {
        get { Criteria(modes: modes, attributes: attributes, text: text, metadata: metadata) }
        set {
            // Set the criteria before the modes, which the criteria's observers would otherwise turn on.
            attributes = newValue.attributes
            text = newValue.text
            metadata = newValue.metadata
            modes = newValue.modes
        }
    }

    /// Whether any active mode leaves photos out, so the grid may show fewer than its source has.
    var isFiltering: Bool { !criteriaPredicates.isEmpty }

    /// The photos of the source (folder, collection…) before the bar's criteria.
    var scopePredicate: NSPredicate {
        // Every photo in a publish service, stacked or not: each is published on its own.
        if case .publishService(let id) = scope {
            return NSPredicate(format: "ANY publications.service.id == %@", id as CVarArg)
        }
        if case .publishAlbum(let id, _, let rules) = scope {
            return PublishAlbum.predicate(id: id, rules: rules)
        }
        // Photos a collapsed stack hides.
        let hidden = NSPredicate(format: "isHiddenInStack == NO")
        let scoped: NSPredicate? = switch scope {
        case .allPhotos:
            nil
        case .folder(let path):
            NSPredicate(format: "folder.path == %@ OR folder.path BEGINSWITH %@", path, path + "/")
        case .previousImport(let id):
            NSPredicate(format: "importID == %@", id as CVarArg)
        case .collection(_, let content):
            content.predicate
        case .importDifference(let reason):
            LightroomImportReport.predicate(forReason: reason)
        case .publishService, .publishAlbum:
            nil
        }
        return scoped.map { NSCompoundPredicate(andPredicateWithSubpredicates: [hidden, $0]) } ?? hidden
    }

    /// What the Metadata columns count from: the source, the other active modes' criteria and the Review.
    var metadataBasePredicate: NSPredicate {
        let predicates = (modes.contains(.text) ? text.predicates : []) + (modes.contains(.attribute) ? attributes.predicates : [])
            + (cullReview.map { [$0.predicate] } ?? [])
        guard !predicates.isEmpty else { return scopePredicate }
        return NSCompoundPredicate(andPredicateWithSubpredicates: [scopePredicate] + predicates)
    }

    /// The active modes' criteria, Text then Attribute then Metadata, and the Review.
    private var criteriaPredicates: [NSPredicate] {
        (modes.contains(.text) ? text.predicates : [])
            + (modes.contains(.attribute) ? attributes.predicates : [])
            + (modes.contains(.metadata) ? metadata.predicates : [])
            + (cullReview.map { [$0.predicate] } ?? [])
    }

    var predicate: NSPredicate? {
        let predicates = criteriaPredicates
        guard !predicates.isEmpty else { return scopePredicate }
        return NSCompoundPredicate(andPredicateWithSubpredicates: [scopePredicate] + predicates)
    }

    var sortDescriptors: [NSSortDescriptor] {
        var descriptors = [primarySortDescriptor]
        // Stable tiebreakers so photos with equal keys don't shuffle between fetches.
        if sortKey != .captureTime {
            descriptors.append(NSSortDescriptor(key: #keyPath(Photo.captureDate), ascending: ascending))
        }
        if sortKey != .fileName {
            descriptors.append(NSSortDescriptor(
                key: #keyPath(Photo.fileName), ascending: ascending,
                selector: #selector(NSString.localizedStandardCompare(_:))
            ))
        }
        // A virtual copy follows its master.
        descriptors.append(NSSortDescriptor(key: "copyName", ascending: true))
        return descriptors
    }

    private var primarySortDescriptor: NSSortDescriptor {
        if sortKey.isStringKey {
            return NSSortDescriptor(
                key: sortKey.keyPath, ascending: ascending,
                selector: #selector(NSString.localizedStandardCompare(_:))
            )
        }
        return NSSortDescriptor(key: sortKey.keyPath, ascending: ascending)
    }
}
