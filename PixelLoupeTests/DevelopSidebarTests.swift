import AppKit
import Testing
@testable import PixelLoupe

@Suite("Develop sidebar")
struct DevelopSidebarTests {
    /// Regression: the Mask, Spot Removal and History panels drew over Adjust the first time Develop
    /// opened, until another tool was chosen and Adjust chosen again.
    @Test func onlyTheCurrentToolsPanelShowsWhenDevelopOpens() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url)
        let controller = CatalogWindowController(store: store)
        defer { controller.close() }
        controller.showWindow(nil)
        controller.state.mode = .develop
        let sidebar = try #require(controller.rootViewController.main.develop.sidebarView)
        // Histogram, tool icons and their line, plus the seven tools' panels stacked in one place.
        #expect(sidebar.subviews.count == 10)
        #expect(sidebar.subviews.filter { !$0.isHidden }.count == 4, "the histogram, icons, line and the Adjust panel")
    }

    @Test func toolIconsSitAbove10ptOfSpace() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url)
        let controller = CatalogWindowController(store: store)
        defer { controller.close() }
        controller.showWindow(nil)
        controller.state.mode = .develop
        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: true)
        window.layoutIfNeeded()

        let icons = window.contentView!.descendants.compactMap { $0 as? NSButton }
            .filter { $0.accessibilityIdentifier().hasPrefix("developTool.") }
        #expect(icons.map { $0.accessibilityIdentifier() } == ["developTool.adjust", "developTool.presets", "developTool.crop", "developTool.lens", "developTool.mask", "developTool.retouch", "developTool.history"])
        let header = try #require(icons.first?.superview)
        let line = try #require(header.superview?.subviews.compactMap { $0 as? NSBox }.first)
        // Measured from the icons' alignment rects (their frames add padding around the symbols)
        // to the drawn line, centered in the separator box.
        let iconBottom = icons.map { $0.convert($0.bounds, to: nil).minY + $0.alignmentRectInsets.bottom }.min()!
        let lineTop = line.convert(line.bounds, to: nil).midY
        #expect(iconBottom > 0, "laid out")
        #expect(abs(iconBottom - lineTop - 10) < 1.5, "10pt gap, got \(iconBottom - lineTop)")
        // Flush left: the first icon starts at the sidebar's leading inset.
        let sidebar = try #require(header.superview)
        #expect(icons.map { $0.convert($0.bounds, to: sidebar).minX }.min()! <= 16)

        // The histogram is above the icons.
        let histogram = try #require(window.contentView!.descendants.first { $0.accessibilityIdentifier() == "histogram" })
        #expect(histogram.convert(histogram.bounds, to: nil).minY > icons[0].convert(icons[0].bounds, to: nil).maxY)

        // The camera shows Lens Corrections in place of the Adjust panel.
        func isShown(_ identifier: String) -> Bool {
            window.contentView!.descendants.first { $0.accessibilityIdentifier() == identifier }.map { !$0.isHiddenOrHasHiddenAncestor } ?? false
        }
        #expect(isShown("adjustPanel") && !isShown("lensPanel"))
        let lensIcon = try #require(icons.first { $0.accessibilityIdentifier() == "developTool.lens" })
        lensIcon.performClick(nil)
        #expect(controller.state.developTool == .lens)
        #expect(isShown("lensPanel") && !isShown("adjustPanel"))
        #expect(lensIcon.accessibilityValue() as? String == "active")
        window.layoutIfNeeded()
        let lensPanel = try #require(window.contentView!.descendants.first { $0.accessibilityIdentifier() == "lensPanel" })
        // The panel fills the sidebar below the tool icons' line, whatever the window's height (CI screens are small).
        let panelFrame = lensPanel.convert(lensPanel.bounds, to: nil)
        let sidebarFrame = sidebar.convert(sidebar.bounds, to: nil)
        #expect(abs(panelFrame.minY - sidebarFrame.minY) <= 1, "reaches the bottom of the sidebar: \(panelFrame) in \(sidebarFrame)")
        #expect(panelFrame.maxY <= lineTop + 1 && lineTop - panelFrame.maxY < 20, "starts just below the line: \(panelFrame.maxY) vs \(lineTop)")
        #expect(panelFrame.height > 100)
        #expect(!lensPanel.hasAmbiguousLayout && !histogram.hasAmbiguousLayout)
        // The plot, the shooting settings and what the photo is drawn from.
        #expect(abs(histogram.frame.height - (HistogramView.plotHeight + 6 + 16 + 16)) < 0.5)
    }
}
