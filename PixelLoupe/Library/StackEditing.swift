import CoreData
import Foundation

/// Stacking commands (Photo ▸ Stacking), each one undoable step.
extension PhotoEditing {
    /// Groups the photos into one stack, top photo first (as given). Photos already in a stack leave
    /// it. Needs at least two photos. Returns whether a stack was made.
    @discardableResult
    func groupIntoStack(_ ids: [NSManagedObjectID]) -> Bool {
        let members = photos(ids)
        guard members.count >= 2 else { return false }
        let context = store.viewContext
        for photo in members { PhotoStack.remove(photo, in: context) }
        let stack = PhotoStack(context: context)
        stack.isCollapsed = true
        for photo in members { photo.stack = stack }
        stack.renumber(members)
        commit("Group into Stack")
        return true
    }

    /// Dissolves the stacks the photos belong to.
    func unstack(_ ids: [NSManagedObjectID]) {
        let stacks = Set(photos(ids).compactMap(\.stack))
        guard !stacks.isEmpty else { return }
        for stack in stacks { dissolve(stack) }
        commit(stacks.count == 1 ? "Unstack" : "Unstack Photos")
    }

    /// Collapses stacks that are open and opens those that are closed.
    func toggleCollapsed(_ ids: [NSManagedObjectID]) {
        let stacks = Set(photos(ids).compactMap(\.stack))
        guard !stacks.isEmpty else { return }
        for stack in stacks {
            stack.isCollapsed.toggle()
            stack.refreshHidden()
        }
        commit(stacks.allSatisfy(\.isCollapsed) ? "Collapse Stack" : "Expand Stack")
    }

    func setAllStacksCollapsed(_ collapsed: Bool) {
        let all = (try? store.viewContext.fetch(PhotoStack.fetchRequest())) ?? []
        let changing = all.filter { $0.isCollapsed != collapsed }
        guard !changing.isEmpty else { return }
        for stack in changing {
            stack.isCollapsed = collapsed
            stack.refreshHidden()
        }
        commit(collapsed ? "Collapse All Stacks" : "Expand All Stacks")
    }

    /// Makes the photo the top of its stack.
    func moveToTopOfStack(_ id: NSManagedObjectID) {
        guard let photo = photos([id]).first, let stack = photo.stack, photo.stackPosition != 1 else { return }
        stack.renumber([photo] + stack.orderedPhotos.filter { $0 !== photo })
        commit("Move to Top of Stack")
    }

    /// Takes the photos out of their stacks (a stack left with one photo dissolves).
    func removeFromStack(_ ids: [NSManagedObjectID]) {
        let members = photos(ids).filter { $0.stack != nil }
        guard !members.isEmpty else { return }
        for photo in members { PhotoStack.remove(photo, in: store.viewContext) }
        commit("Remove from Stack")
    }

    private func dissolve(_ stack: PhotoStack) {
        for photo in stack.photos {
            photo.stack = nil
            photo.stackPosition = 0
            photo.isHiddenInStack = false
        }
        store.viewContext.delete(stack)
    }

    private func commit(_ actionName: String) {
        store.viewContext.processPendingChanges()
        store.viewContext.undoManager?.setActionName(actionName)
        store.save()
    }
}
