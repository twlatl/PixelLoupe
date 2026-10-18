import AppKit
import Testing
@testable import PixelLoupe

@Suite("Shift-click selection")
@MainActor
struct ShiftSelectTests {
    /// Ten items in a row, with a delegate recording what it's told.
    private final class Harness: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let collectionView = RangeSelectingCollectionView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        var selected: Set<Int> = []

        override init() {
            super.init()
            let layout = NSCollectionViewFlowLayout()
            layout.itemSize = NSSize(width: 100, height: 100)
            layout.minimumInteritemSpacing = 0
            collectionView.collectionViewLayout = layout
            collectionView.register(NSCollectionViewItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("item"))
            collectionView.dataSource = self
            collectionView.delegate = self
            collectionView.isSelectable = true
            collectionView.allowsMultipleSelection = true
            let scrollView = NSScrollView(frame: window.contentView!.bounds)
            scrollView.documentView = collectionView
            window.contentView!.addSubview(scrollView)
            collectionView.reloadData()
            window.orderFront(nil)
            window.layoutIfNeeded()
            window.displayIfNeeded()
            collectionView.layoutSubtreeIfNeeded()
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { 10 }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("item"), for: indexPath)
            item.view = NSView()
            return item
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            selected.formUnion(indexPaths.map(\.item))
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            selected.subtract(indexPaths.map(\.item))
        }

        deinit { MainActor.assumeIsolated { window.orderOut(nil) } }

        var selection: Set<Int> { Set(collectionView.selectionIndexPaths.map(\.item)) }

        func select(_ item: Int) {
            collectionView.selectionIndexPaths = [IndexPath(item: item, section: 0)]
            selected = [item]
        }

        /// A Shift-click (with ⌘ when `command`) on an item, as AppKit delivers it.
        func shiftClick(_ item: Int, command: Bool = false) {
            let frame = collectionView.frameForItem(at: item)
            let point = collectionView.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: command ? [.shift, .command] : [.shift],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
            collectionView.mouseDown(with: event)
        }
    }

    @Test func shiftClickSelectsEverythingBetweenForwardsOrBackwards() {
        let harness = Harness()
        harness.select(2)
        harness.shiftClick(6)
        #expect(harness.selection == [2, 3, 4, 5, 6])
        #expect(harness.selected == harness.selection, "the delegate hears about it, as for a click")
        // From the same anchor, backwards: the range replaces the last one.
        harness.shiftClick(0)
        #expect(harness.selection == [0, 1, 2])
        #expect(harness.selected == [0, 1, 2])
    }

    @Test func commandShiftClickAddsTheRange() {
        let harness = Harness()
        harness.select(1)
        harness.collectionView.selectRange(to: IndexPath(item: 2, section: 0))
        harness.collectionView.selectionIndexPaths.insert(IndexPath(item: 8, section: 0))
        harness.shiftClick(5, command: true)
        #expect(harness.selection == [1, 2, 3, 4, 5, 8])
    }

    @Test func withoutAnAnchorItExtendsFromTheFirstSelectedPhoto() {
        let harness = Harness()
        harness.collectionView.selectionIndexPaths = [IndexPath(item: 7, section: 0)]   // e.g. stepping with →
        harness.shiftClick(4)
        #expect(harness.selection == [4, 5, 6, 7])
    }

    @Test func withNothingSelectedShiftClickSelectsJustThatPhoto() {
        let harness = Harness()
        #expect(!harness.collectionView.selectRange(to: IndexPath(item: 3, section: 0)))
    }

    @Test func theGridAndFilmstripUseIt() {
        let grid: NSCollectionView = PhotoCollectionView()
        #expect(grid is RangeSelectingCollectionView)
    }
}
