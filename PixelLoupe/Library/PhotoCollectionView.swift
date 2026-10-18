import AppKit

protocol PhotoCollectionViewDelegate: AnyObject {
    func collectionView(_ collectionView: PhotoCollectionView, menuForItemAt indexPath: IndexPath) -> NSMenu?
    func collectionView(_ collectionView: PhotoCollectionView, didDoubleClickItemAt indexPath: IndexPath)
}

/// A collection view where Shift-click selects every item between the last item clicked (the
/// anchor) and the clicked one, in either direction, as in Lightroom and Finder; ⌘⇧-click adds
/// that range to the selection. (AppKit's own Shift-click adds just the one item, like ⌘-click.)
class RangeSelectingCollectionView: NSCollectionView {
    /// The item range selections extend from: the last item clicked without Shift.
    private(set) var selectionAnchor: IndexPath?

    /// Called as the pointer moves onto another item (nil off the items), for the secondary
    /// window's Loupe – Live. Pointer tracking is only set up while this is set.
    var onHover: ((IndexPath?) -> Void)? {
        didSet { updateTrackingAreas() }
    }
    private var hoverTracking: NSTrackingArea?
    private var hoveredIndexPath: IndexPath?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        hoverTracking = nil
        guard onHover != nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hover(indexPathForItem(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover(nil)
    }

    private func hover(_ indexPath: IndexPath?) {
        guard indexPath != hoveredIndexPath else { return }
        hoveredIndexPath = indexPath
        onHover?(indexPath)
    }

    override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.shift), event.clickCount == 1, allowsMultipleSelection,
           let clicked = indexPath(at: event), selectRange(to: clicked, adding: modifiers.contains(.command)) {
            return
        }
        super.mouseDown(with: event)
        if !modifiers.contains(.shift), let clicked = indexPath(at: event) {
            selectionAnchor = clicked
        }
    }

    /// Selects from the anchor to `target` (replacing the selection, or `adding` to it), telling the
    /// delegate as a click would. Returns false when there's nothing to extend from.
    @discardableResult
    func selectRange(to target: IndexPath, adding: Bool = false) -> Bool {
        // The anchor counts while it's still selected; otherwise extend from the first selected item.
        let anchor = selectionAnchor.flatMap { selectionIndexPaths.contains($0) ? $0 : nil } ?? selectionIndexPaths.min()
        guard let anchor, anchor.section == target.section else { return false }
        let range = Set((min(anchor.item, target.item)...max(anchor.item, target.item)).map {
            IndexPath(item: $0, section: target.section)
        })
        let new = adding ? selectionIndexPaths.union(range) : range
        let removed = selectionIndexPaths.subtracting(new), added = new.subtracting(selectionIndexPaths)
        selectionIndexPaths = new
        selectionAnchor = anchor
        if !removed.isEmpty { delegate?.collectionView?(self, didDeselectItemsAt: removed) }
        if !added.isEmpty { delegate?.collectionView?(self, didSelectItemsAt: added) }
        return true
    }

    fileprivate func indexPath(at event: NSEvent) -> IndexPath? {
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point) { return indexPath }
        // Also from the layout, which knows items whose views haven't been made yet.
        return collectionViewLayout?.layoutAttributesForElements(in: NSRect(origin: point, size: NSSize(width: 1, height: 1)))
            .first { $0.representedElementCategory == .item && $0.frame.contains(point) }?.indexPath
    }
}

/// Adds right-click menus and double-click to the grid. Single-key shortcuts are handled for the
/// whole window by `CatalogWindowController` (see `KeyCommand`).
final class PhotoCollectionView: RangeSelectingCollectionView {
    weak var photoDelegate: PhotoCollectionViewDelegate?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let indexPath = indexPath(at: event) {
            photoDelegate?.collectionView(self, didDoubleClickItemAt: indexPath)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let indexPath = indexPath(at: event) else { return nil }
        return photoDelegate?.collectionView(self, menuForItemAt: indexPath)
    }
}
