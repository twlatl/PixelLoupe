import CoreData

/// A folder on disk containing photos in the catalog. Folders form a tree mirroring the file system.
@objc(Folder)
nonisolated final class Folder: NSManagedObject {
    @NSManaged var name: String
    @NSManaged var path: String
    @NSManaged var parent: Folder?
    @NSManaged var children: Set<Folder>
    @NSManaged var photos: Set<Photo>
    /// Marked with a star in the Folders list (model v14).
    @NSManaged var isFavorite: Bool
    /// The folder's color label (model v14): see ``ColorLabel``. 0 is none.
    @NSManaged var colorLabel: Int16

    @nonobjc class func fetchRequest() -> NSFetchRequest<Folder> {
        NSFetchRequest<Folder>(entityName: "Folder")
    }

    var label: ColorLabel {
        get { ColorLabel(rawValue: colorLabel) ?? .none }
        set { colorLabel = newValue.rawValue }
    }

    var sortedChildren: [Folder] {
        children.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
