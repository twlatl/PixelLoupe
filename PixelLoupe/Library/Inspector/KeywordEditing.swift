import CoreData

/// Creating, renaming, deleting and editing keywords, each saved as one named, undoable step.
struct KeywordEditing {
    let store: CatalogStore

    private var context: NSManagedObjectContext { store.viewContext }

    enum Failure: Error, Equatable, LocalizedError {
        case emptyName
        /// A sibling already has the name.
        case duplicate(String)

        var errorDescription: String? {
            switch self {
            case .emptyName: "A keyword needs a name."
            case .duplicate(let name): "There is already a keyword named “\(name)” in the same place."
            }
        }
    }

    /// A new keyword inside `parent` (or at the top level).
    @discardableResult
    func create(named text: String, in parent: Tag?) throws -> Tag {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Failure.emptyName }
        guard Tag.child(named: name, of: parent, in: context) == nil else { throw Failure.duplicate(name) }
        let tag = Tag.makeChild(named: name, of: parent, in: context)
        commit("Create Keyword")
        return tag
    }

    func rename(_ tag: Tag, to text: String) throws {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Failure.emptyName }
        if let sibling = Tag.child(named: name, of: tag.parent, in: context), sibling !== tag { throw Failure.duplicate(name) }
        tag.name = name
        tag.refreshPath()
        commit("Rename Keyword")
    }

    /// Deletes the keyword and the keywords inside it. Photos keep everything else.
    func delete(_ tag: Tag) {
        context.delete(tag)
        commit("Delete Keyword")
    }

    func update(_ tag: Tag, synonyms: [String], includeOnExport: Bool, includeParents: Bool, includeSynonyms: Bool, isPerson: Bool) {
        tag.synonyms = synonyms
        tag.includeOnExport = includeOnExport
        tag.includeParents = includeParents
        tag.includeSynonyms = includeSynonyms
        tag.isPerson = isPerson
        commit("Edit Keyword")
    }

    private func commit(_ actionName: String) {
        context.processPendingChanges()
        context.undoManager?.setActionName(actionName)
        store.save()
    }
}
