import AppKit
import CoreData

/// Keeps the photo a catalog opened with centred in a grid or filmstrip while the window settles (RAW-258), and
/// centres the one a source comes back with (RAW-259).
///
/// A catalog's window fills the screen and its sidebars take their remembered widths only after the grid and
/// filmstrip first lay out, and each change reflows them, so a single scroll on appearing is soon out of date.
/// While pinned, every resize of the scroll view centres the photo again, without animating, until the person
/// scrolls, the selection or source changes, or the settle time after the window appears is up.
final class RestoredSelectionPin: NSObject {
    enum Axis { case vertical, horizontal }

    /// How long after the window appears its layout is still treated as settling.
    static let settleTime: TimeInterval = 1

    private weak var collectionView: NSCollectionView?
    private let axis: Axis
    private let indexPath: (NSManagedObjectID) -> IndexPath?
    /// The photo being kept in view, until released.
    private(set) var photoID: NSManagedObjectID?
    private var isCentring = false
    /// Counts pins, so a release scheduled for an earlier one leaves a later one alone.
    private var generation = 0

    /// `indexPath` finds the photo's item in the collection view, which must be in a scroll view by now.
    init(collectionView: NSCollectionView, axis: Axis, indexPath: @escaping (NSManagedObjectID) -> IndexPath?) {
        self.collectionView = collectionView
        self.axis = axis
        self.indexPath = indexPath
        super.init()
    }

    /// Starts keeping `photoID` (the active photo the catalog opened with) centred.
    func pin(_ photoID: NSManagedObjectID?) {
        release()
        guard let photoID, let scrollView = collectionView?.enclosingScrollView else { return }
        self.photoID = photoID
        generation += 1
        let center = NotificationCenter.default
        scrollView.contentView.postsFrameChangedNotifications = true
        center.addObserver(self, selector: #selector(frameDidChange(_:)), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(userDidScroll(_:)), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        // In case the window never appears (or ``settle()`` isn't called).
        releaseLater(after: 10)
        centre()
    }

    /// Releases the pin once the window that appeared has had time to settle.
    func settle() {
        releaseLater(after: Self.settleTime)
    }

    private func releaseLater(after delay: TimeInterval) {
        guard photoID != nil else { return }
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            if self?.generation == generation { self?.release() }
        }
    }

    /// Stops keeping the photo in view; the grid scrolls only as the person or the selection moves it.
    func release() {
        guard photoID != nil else { return }
        photoID = nil
        NotificationCenter.default.removeObserver(self)
    }

    /// Centres the pinned photo now, as far as the ends of the list allow.
    func centre() {
        guard !isCentring, let photoID, let collectionView, let indexPath = indexPath(photoID),
              let clipView = collectionView.enclosingScrollView?.contentView else { return }
        isCentring = true
        defer { isCentring = false }
        // The reflow first, so the item's frame and the grid's height are the new ones.
        collectionView.layoutSubtreeIfNeeded()
        guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
        var bounds = clipView.bounds
        switch axis {
        case .vertical: bounds.origin.y = frame.midY - bounds.height / 2
        case .horizontal: bounds.origin.x = frame.midX - bounds.width / 2
        }
        let origin = clipView.constrainBoundsRect(bounds).origin
        guard origin != clipView.bounds.origin else { return }
        clipView.scroll(to: origin)
        collectionView.enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    @objc private func frameDidChange(_ notification: Notification) {
        centre()
        // And once the layout pass this resize is part of has finished.
        DispatchQueue.main.async { [weak self] in self?.centre() }
    }

    @objc private func userDidScroll(_ notification: Notification) {
        release()
    }
}
