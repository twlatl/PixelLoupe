import CoreData

/// A keyword attached to photos, either user-assigned or read from embedded IPTC/XMP metadata.
///
/// Keywords form a tree, as in Lightroom (`Places > Ireland > Dublin`). A name is unique among its
/// siblings, not globally, so two branches can each have a "Dublin". `pathKey` holds the keyword's
/// full path in one string, which lets a predicate match a keyword and everything below it.
@objc(Tag)
nonisolated final class Tag: NSManagedObject {
    @NSManaged var name: String
    /// The keyword's names from the root, joined by ``pathSeparator``. Kept in step by `refreshPath()`.
    @NSManaged var pathKey: String
    /// Other words that mean this keyword (one per line), searched along with the name.
    @NSManaged var synonymText: String?
    @NSManaged var includeOnExport: Bool
    /// Whether exporting a photo with this keyword also writes its parent keywords.
    @NSManaged var includeParents: Bool
    /// Whether exporting a photo with this keyword also writes its synonyms.
    @NSManaged var includeSynonyms: Bool
    /// A keyword naming a person (Lightroom's People).
    @NSManaged var isPerson: Bool
    @NSManaged var parent: Tag?
    @NSManaged var children: Set<Tag>
    @NSManaged var photos: Set<Photo>
    /// For a person keyword, the faces named with it (model v13).
    @NSManaged var faceRegions: Set<FaceRegion>

    @nonobjc class func fetchRequest() -> NSFetchRequest<Tag> {
        NSFetchRequest<Tag>(entityName: "Tag")
    }

    /// Between the names of a keyword's path in `pathKey` and in what people see and type.
    static let pathSeparator = " > "

    // MARK: - Paths

    /// The names from the root keyword down to this one.
    var pathComponents: [String] {
        var names = [name]
        var current = parent
        while let tag = current {
            names.insert(tag.name, at: 0)
            current = tag.parent
        }
        return names
    }

    /// `Places > Ireland > Dublin`.
    var displayPath: String { pathComponents.joined(separator: Self.pathSeparator) }

    var synonyms: [String] {
        get { (synonymText ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        set { synonymText = newValue.isEmpty ? nil : newValue.joined(separator: "\n") }
    }

    /// Keeps `pathKey` right even for a keyword made with just a name and a parent.
    override func willSave() {
        super.willSave()
        // (Stores opened with an older model, as migration tests do, have no paths yet.)
        guard !isDeleted, entity.relationshipsByName["parent"] != nil else { return }
        let path = displayPath
        if primitiveValue(forKey: "pathKey") as? String != path { setPrimitiveValue(path, forKey: "pathKey") }
    }

    /// Recomputes `pathKey` for this keyword and everything below it, after a rename or a move.
    func refreshPath() {
        let path = displayPath
        if pathKey != path { pathKey = path }
        for child in children { child.refreshPath() }
    }

    /// Splits typed text such as `Places > Ireland | Dublin` into names. A single name gives one component.
    static func parsePath(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == ">" || $0 == "|" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Finding and creating

    /// The child of `parent` (or the root keyword when `parent` is nil) named `name`, ignoring case.
    static func child(named name: String, of parent: Tag?, in context: NSManagedObjectContext) -> Tag? {
        let request = fetchRequest()
        request.predicate = parent.map { NSPredicate(format: "parent == %@ AND name ==[c] %@", $0, name) }
            ?? NSPredicate(format: "parent == nil AND name ==[c] %@", name)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    /// Makes a keyword under `parent`, or returns the sibling that already has the name.
    @discardableResult
    static func makeChild(named name: String, of parent: Tag?, in context: NSManagedObjectContext) -> Tag {
        if let existing = child(named: name, of: parent, in: context) { return existing }
        let tag = Tag(context: context)
        tag.name = name
        tag.parent = parent
        tag.refreshPath()
        return tag
    }

    /// The keyword at `path` (names from the root), creating it and any missing parents.
    static func findOrCreate(path: [String], in context: NSManagedObjectContext) -> Tag? {
        var current: Tag?
        for name in path {
            current = makeChild(named: name, of: current, in: context)
        }
        return current
    }

    /// Every keyword named `name` (ignoring case), wherever it sits in the tree.
    static func tags(named name: String, in context: NSManagedObjectContext) -> [Tag] {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "name ==[c] %@", name)
        request.sortDescriptors = [NSSortDescriptor(key: "pathKey", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    /// What typing `text` in the Keywords field means.
    enum Resolution {
        /// The keyword to use (it may have just been made).
        case tag(Tag)
        /// A plain name that several keywords share: the user has to pick one.
        case ambiguous([Tag])
    }

    /// A path (`A > B > C`) finds or creates that path. A plain name uses the one keyword with that
    /// name, anywhere in the tree; makes a root keyword if there is none; and is ambiguous when
    /// several keywords have it.
    static func resolve(_ text: String, in context: NSManagedObjectContext) -> Resolution? {
        let components = parsePath(text)
        guard !components.isEmpty else { return nil }
        if components.count > 1 {
            return findOrCreate(path: components, in: context).map(Resolution.tag)
        }
        let matches = tags(named: components[0], in: context)
        switch matches.count {
        case 0: return .tag(makeChild(named: components[0], of: nil, in: context))
        case 1: return .tag(matches[0])
        default: return .ambiguous(matches)
        }
    }

    /// The root-level keyword named `name` (case-insensitive), made if needed. A plain name that is
    /// already a keyword deeper in the tree uses that one when it is the only one.
    static func findOrCreate(named name: String, in context: NSManagedObjectContext) -> Tag {
        if case .tag(let tag)? = resolve(name, in: context) { return tag }
        // Ambiguous: prefer the root-level one, else the first by path.
        let matches = tags(named: name, in: context)
        return matches.first { $0.parent == nil } ?? matches[0]
    }

    /// Fills in `pathKey` for keywords from before keywords had a tree (all root level), so
    /// existing catalogs keep working after the model changes.
    static func backfillPathKeys(in context: NSManagedObjectContext) {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "pathKey == ''")
        guard let stale = try? context.fetch(request), !stale.isEmpty else { return }
        for tag in stale { tag.refreshPath() }
        try? context.save()
    }

    // MARK: - Export

    /// The keywords to write for a photo's tags: each tag, its parents and synonyms where the
    /// keyword says so, leaving out keywords marked not to export. Sorted, without repeats.
    static func exportNames(for tags: Set<Tag>) -> [String] {
        var names = Set<String>()
        for tag in tags where tag.includeOnExport {
            names.insert(tag.name)
            if tag.includeSynonyms { names.formUnion(tag.synonyms) }
            if tag.includeParents {
                var ancestor = tag.parent
                while let parent = ancestor {
                    if parent.includeOnExport { names.insert(parent.name) }
                    ancestor = parent.parent
                }
            }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Lightroom's separator in `lr:hierarchicalSubject` paths.
    static let hierarchySeparator = "|"

    /// Each exported keyword's path from the top of the tree, "Places|Ireland|Dublin", for
    /// `lr:hierarchicalSubject`: the keywords marked to export, whichever of their parents are. Sorted,
    /// without repeats.
    static func exportPaths(for tags: Set<Tag>) -> [String] {
        let paths = Set(tags.filter(\.includeOnExport).map { $0.pathComponents.joined(separator: hierarchySeparator) })
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
