import AppKit
import Testing
@testable import PixelLoupe

@Suite("Lightroom Import Report window")
@MainActor
struct LightroomImportReportWindowTests {
    private func report() -> LightroomImportReport {
        let long = "Profile “Camera MONOCHROME+G FILTER” isn’t available: imported as Default"
        return LightroomImportReport(
            sourceName: "Work Photos.lrcat", lightroomVersion: "Lightroom Classic 15 (18.0.0)", importedAt: Date(), duration: 16,
            summary: LightroomCatalogSummary(),
            imported: [.init(title: "Photos", count: 9188)],
            groups: [.init(key: "short", title: "Masks", photoCount: 3), .init(key: "long", title: long, photoCount: 55)],
            warnings: [
                "3,647 photos use an Adobe Color or Standard profile: imported as PixelLoupe’s Default, which is close but not identical",
                "2 photos have no Lightroom preview. Thumbnails for those are made from the original photos in the background when the catalog is open.",
            ])
    }

    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + views(type, in: $0) }
    }

    @Test("Rows and warnings stay inside the margins and every line of a warning shows", arguments: [460.0, 560.0, 900.0])
    func fits(width: Double) throws {
        let controller = LightroomImportReportWindowController(report: report())
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: width, height: 320))
        window.layoutIfNeeded()
        let scroll = try #require(window.contentView.flatMap { views(NSScrollView.self, in: $0).first })
        let document = try #require(scroll.documentView)
        document.layoutSubtreeIfNeeded()
        let trailing = document.bounds.width - 20 + 0.5

        let buttons = views(NSButton.self, in: document).filter { $0.title == "Show Photos" }
        #expect(buttons.count == 2)
        for button in buttons {
            #expect(button.convert(button.bounds, to: document).maxX <= trailing)
        }
        // The buttons line up, however long their titles.
        #expect(Set(buttons.map { $0.convert($0.bounds, to: document).maxX.rounded() }).count == 1)

        let warnings = views(NSTextField.self, in: document).filter { $0.stringValue.hasPrefix("• ") }
        #expect(warnings.count == 2)
        for label in warnings {
            let frame = label.convert(label.bounds, to: document)
            // Constraints place a label's alignment rect, which is inset from its frame.
            #expect(document.convert(label.alignmentRect(forFrame: label.frame), from: label.superview).maxX <= trailing)
            let needed = try #require(label.cell).cellSize(forBounds: NSRect(x: 0, y: 0, width: frame.width, height: .greatestFiniteMagnitude)).height
            #expect(frame.height >= needed - 0.5, "\(label.stringValue) is cut off")
            #expect(frame.maxY <= document.bounds.height)
        }
    }
}
