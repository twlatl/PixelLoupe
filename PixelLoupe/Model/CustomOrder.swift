import Foundation

/// A collection's custom photo order (`PhotoCollection.customOrder`): the order Lightroom keeps for
/// a collection, and the one dragging photos in the grid changes.
nonisolated enum CustomOrder {
    /// `items` in the order of `order`. Items whose photo isn't listed come after, in the order given.
    static func sorted<T>(_ items: [(item: T, id: UUID)], by order: [UUID]) -> [T] {
        var position: [UUID: Int] = [:]
        for (index, id) in order.enumerated() where position[id] == nil { position[id] = index }
        return items.enumerated()
            .sorted { lhs, rhs in
                let left = position[lhs.element.id] ?? order.count + lhs.offset
                let right = position[rhs.element.id] ?? order.count + rhs.offset
                return left < right
            }
            .map(\.element.item)
    }

    /// `current` after moving the photos in `moving` (kept in their current order) to just before the
    /// photo at `index` of `current`, or to the end when `index` is `current.count`.
    static func moved(_ moving: [UUID], to index: Int, in current: [UUID]) -> [UUID] {
        let moved = Set(moving)
        let kept = current.filter { !moved.contains($0) }
        // The photos taken out from before the drop point shift it up.
        let removedBefore = current.prefix(max(0, min(index, current.count))).filter { moved.contains($0) }.count
        let insertion = max(0, min(index - removedBefore, kept.count))
        let inOrder = current.filter { moved.contains($0) }
        return Array(kept.prefix(insertion)) + inOrder + Array(kept.dropFirst(insertion))
    }
}
