import AppKit
import Testing
@testable import PixelLoupe

@Suite("New Catalog sheet")
struct NewCatalogSheetTests {
    private func controls(in view: NSView) -> [NSView] {
        view.subviews.flatMap { subview -> [NSView] in
            (subview is NSControl ? [subview] : []) + controls(in: subview)
        }
    }

    /// Every control fits inside the sheet with its margins, rather than being clipped.
    @Test func formFitsInsideTheSheet() throws {
        let controller = NewCatalogWindowController { _ in }
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()

        #expect(content.bounds.width == NewCatalogWindowController.width)
        let inset = content.bounds.insetBy(dx: 19, dy: 19)
        let all = controls(in: content).filter { !$0.isHidden }
        #expect(all.count >= 8)
        for control in all {
            let frame = control.convert(control.bounds, to: content)
            #expect(inset.contains(frame), "\(type(of: control)) at \(frame) is outside \(inset)")
        }

        // No wasted space on the left: the labels column is only as wide as its longest label.
        let labels = content.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSTextField }
            .filter { !$0.isEditable && $0.stringValue.hasSuffix(":") }
        let leftmost = try #require(labels.map { $0.convert($0.bounds, to: content).minX }.min())
        #expect(leftmost <= 26, "labels start at the left margin, not \(leftmost)")
    }
}
