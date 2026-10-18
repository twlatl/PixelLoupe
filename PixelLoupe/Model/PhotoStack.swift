import CoreData

/// A group of related photos (a burst, brackets, a photo and its edits) shown as one, under its top
/// photo, as Lightroom's stacks. A collapsed stack hides every photo but the top one; that is kept in
/// `Photo.isHiddenInStack` so the grid can leave them out with a plain predicate.
@objc(PhotoStack)
nonisolated final class PhotoStack: NSManagedObject {
    @NSManaged var isCollapsed: Bool
    @NSManaged var photos: Set<Photo>

    @nonobjc class func fetchRequest() -> NSFetchRequest<PhotoStack> {
        NSFetchRequest<PhotoStack>(entityName: "PhotoStack")
    }

    /// The photos in stack order: the top photo first.
    var orderedPhotos: [Photo] {
        photos.sorted { $0.stackPosition < $1.stackPosition }
    }

    var topPhoto: Photo? { photos.min { $0.stackPosition < $1.stackPosition } }

    /// Sets each photo's position (1 is the top) and whether it is hidden.
    func renumber(_ ordered: [Photo]) {
        for (index, photo) in ordered.enumerated() {
            let position = Int32(index + 1)
            if photo.stackPosition != position { photo.stackPosition = position }
        }
        refreshHidden()
    }

    /// Hides every photo but the top one while the stack is collapsed.
    func refreshHidden() {
        for photo in photos {
            let hidden = isCollapsed && photo.stackPosition != 1
            if photo.isHiddenInStack != hidden { photo.isHiddenInStack = hidden }
        }
    }

    /// Takes a photo out of its stack (leaving the stack alone if it still has two photos or more;
    /// dissolving it otherwise). Returns the stack if it was dissolved.
    @discardableResult
    static func remove(_ photo: Photo, in context: NSManagedObjectContext) -> PhotoStack? {
        guard let stack = photo.stack else { return nil }
        photo.stack = nil
        photo.stackPosition = 0
        photo.isHiddenInStack = false
        let rest = stack.orderedPhotos
        if rest.count < 2 {
            for other in rest {
                other.stack = nil
                other.stackPosition = 0
                other.isHiddenInStack = false
            }
            context.delete(stack)
            return stack
        }
        stack.renumber(rest)
        return nil
    }
}

nonisolated extension Photo {
    @NSManaged var stack: PhotoStack?
    /// 1 for the top photo of its stack, then 2, 3… (0 when not in a stack; model v10).
    @NSManaged var stackPosition: Int32
    /// Whether a collapsed stack is hiding this photo from the grid (model v10).
    @NSManaged var isHiddenInStack: Bool
}
