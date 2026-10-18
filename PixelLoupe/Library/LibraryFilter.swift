import CoreData

/// Everything that determines which photos the Library grid shows and in what order.
nonisolated struct LibraryFilter: Equatable, Sendable {
    enum Scope: Equatable, Sendable {
        case allPhotos
        /// A folder and all of its subfolders.
        case folder(path: String)
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

    enum RatingComparison: String, CaseIterable, Sendable {
        case atLeast, exactly, atMost

        var symbol: String {
            switch self {
            case .atLeast: "≥"
            case .exactly: "="
            case .atMost: "≤"
            }
        }
    }

    var scope: Scope = .allPhotos
    /// 1–5, or `nil` for no rating filter.
    var rating: Int?
    var ratingComparison: RatingComparison = .atLeast
    /// Photos with any of these flags are shown. Empty means no flag filter.
    var flags: Set<PhotoFlag> = []
    /// Photos with any of these color labels are shown (`.none` for unlabelled photos). Empty means
    /// no label filter.
    var colorLabels: Set<ColorLabel> = []
    /// Photos with any of these keywords, or a keyword below one, are shown. Each is a keyword's full
    /// path (`Places > Ireland`, which is just the name for a root keyword). Empty means no keyword filter.
    var tags: Set<String> = []
    /// Matched against camera make, model and lens.
    var searchText = ""
    var sortKey: PhotoSortKey = .captureTime
    var ascending = true

    var predicate: NSPredicate? {
        // Photos a collapsed stack hides.
        var predicates: [NSPredicate] = [NSPredicate(format: "isHiddenInStack == NO")]

        switch scope {
        case .allPhotos:
            break
        case .folder(let path):
            predicates.append(NSPredicate(
                format: "folder.path == %@ OR folder.path BEGINSWITH %@", path, path + "/"
            ))
        case .collection(_, let content):
            predicates.append(content.predicate)
        case .importDifference(let reason):
            predicates.append(LightroomImportReport.predicate(forReason: reason))
        }

        if let rating {
            let format = switch ratingComparison {
            case .atLeast: "rating >= %d"
            case .exactly: "rating == %d"
            case .atMost: "rating <= %d"
            }
            predicates.append(NSPredicate(format: format, rating))
        }

        if !flags.isEmpty {
            predicates.append(NSPredicate(format: "flag IN %@", flags.map { NSNumber(value: $0.rawValue) }))
        }

        if !colorLabels.isEmpty {
            predicates.append(NSPredicate(format: "colorLabel IN %@", colorLabels.map { NSNumber(value: $0.rawValue) }))
        }

        if !tags.isEmpty {
            // A keyword and everything below it: its own path, or a path that starts with it.
            predicates.append(NSCompoundPredicate(orPredicateWithSubpredicates: tags.sorted().flatMap { path in [
                NSPredicate(format: "ANY tags.pathKey ==[c] %@", path),
                NSPredicate(format: "ANY tags.pathKey BEGINSWITH[c] %@", path + Tag.pathSeparator),
            ] }))
        }

        // Every word must match at least one of the camera/lens fields.
        let words = searchText.split(whereSeparator: \.isWhitespace).map(String.init)
        for word in words {
            predicates.append(NSPredicate(
                format: "cameraMake CONTAINS[cd] %@ OR cameraModel CONTAINS[cd] %@ OR lensModel CONTAINS[cd] %@",
                word, word, word
            ))
        }

        switch predicates.count {
        case 0: return nil
        case 1: return predicates[0]
        default: return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }
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
