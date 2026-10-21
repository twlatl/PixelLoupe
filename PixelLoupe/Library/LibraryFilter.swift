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

    /// The Text mode's criteria.
    struct TextSearch: Equatable, Codable, Sendable {
        /// Matched against camera make, model and lens.
        var query = ""

        var isEmpty: Bool { query.allSatisfy(\.isWhitespace) }

        fileprivate var predicates: [NSPredicate] {
            // Every word must match at least one of the camera/lens fields.
            query.split(whereSeparator: \.isWhitespace).map(String.init).map { word in
                NSPredicate(
                    format: "cameraMake CONTAINS[cd] %@ OR cameraModel CONTAINS[cd] %@ OR lensModel CONTAINS[cd] %@",
                    word, word, word
                )
            }
        }
    }

    /// The Metadata mode's criteria.
    struct MetadataBrowser: Equatable, Codable, Sendable {
        /// Photos with any of these keywords, or a keyword below one, are shown. Each is a keyword's
        /// full path (`Places > Ireland`, which is just the name for a root keyword). Empty means no
        /// keyword filter.
        var tags: Set<String> = []

        var isEmpty: Bool { tags.isEmpty }

        fileprivate var predicates: [NSPredicate] {
            guard !tags.isEmpty else { return [] }
            // A keyword and everything below it: its own path, or a path that starts with it.
            return [NSCompoundPredicate(orPredicateWithSubpredicates: tags.sorted().flatMap { path in [
                NSPredicate(format: "ANY tags.pathKey ==[c] %@", path),
                NSPredicate(format: "ANY tags.pathKey BEGINSWITH[c] %@", path + Tag.pathSeparator),
            ] })]
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

    var scope: Scope = .allPhotos
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
        }
        return scoped.map { NSCompoundPredicate(andPredicateWithSubpredicates: [hidden, $0]) } ?? hidden
    }

    /// The active modes' criteria, Text then Attribute then Metadata.
    private var criteriaPredicates: [NSPredicate] {
        (modes.contains(.text) ? text.predicates : [])
            + (modes.contains(.attribute) ? attributes.predicates : [])
            + (modes.contains(.metadata) ? metadata.predicates : [])
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
