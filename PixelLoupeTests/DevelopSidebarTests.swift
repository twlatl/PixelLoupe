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
        // Histogram, tool icons, the active tool's dot and the line, plus the seven tools' panels stacked in one place.
        #expect(sidebar.subviews.count == 11)
        #expect(sidebar.subviews.filter { !$0.isHidden }.count == 5, "the histogram, icons, dot, line and the Adjust panel")
    }

    @Test func toolIconsSitAboveTheActiveDot() throws {
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
        #expect(icons.map { $0.accessibilityIdentifier() } == ["developTool.adjust", "developTool.lighting", "developTool.crop", "developTool.mask", "developTool.remove", "developTool.retouch", "developTool.history"])
        let header = try #require(icons.first?.superview)
        let line = try #require(header.superview?.subviews.compactMap { $0 as? NSBox }.first)
        // Measured from the icons' alignment rects (their frames add padding around the symbols)
        // to the drawn line, centered in the separator box.
        let iconBottom = icons.map { $0.convert($0.bounds, to: nil).minY + $0.alignmentRectInsets.bottom }.min()!
        let lineTop = line.convert(line.bounds, to: nil).midY
        #expect(iconBottom > 0, "laid out")
        #expect(abs(iconBottom - lineTop - 17) < 1.5, "room for the dot, got \(iconBottom - lineTop)")
        // Flush left and right, the same space between each pair.
        let sidebar = try #require(header.superview)
        let frames = icons.map { header.convert($0.alignmentRect(forFrame: $0.frame), to: sidebar) }
        #expect(frames.first!.minX <= 16)
        #expect(sidebar.bounds.maxX - frames.last!.maxX <= 16, "History flush right")
        let gaps = zip(frames, frames.dropFirst()).map { $1.minX - $0.maxX }
        #expect(gaps.max()! - gaps.min()! < 1.5, "even: \(gaps)")
        // The dot sits under the active tool.
        let dot = try #require(sidebar.subviews.first { $0 is DevelopViewController.ToolDot })
        #expect(abs(dot.frame.midX - frames[0].midX) < 1, "under Adjust")

        // The histogram is above the icons.
        let histogram = try #require(window.contentView!.descendants.first { $0.accessibilityIdentifier() == "histogram" })
        #expect(histogram.convert(histogram.bounds, to: nil).minY > icons[0].convert(icons[0].bounds, to: nil).maxY)

        // The history icon shows History in place of the Adjust panel.
        func isShown(_ identifier: String) -> Bool {
            window.contentView!.descendants.first { $0.accessibilityIdentifier() == identifier }.map { !$0.isHiddenOrHasHiddenAncestor } ?? false
        }
        #expect(isShown("adjustPanel"))
        let historyIcon = try #require(icons.first { $0.accessibilityIdentifier() == "developTool.history" })
        historyIcon.performClick(nil)
        #expect(controller.state.developTool == .history)
        #expect(!isShown("adjustPanel"))
        #expect(historyIcon.accessibilityValue() as? String == "active")
        controller.state.developTool = .adjust
        window.layoutIfNeeded()
        let adjustPanel = try #require(window.contentView!.descendants.first { $0.accessibilityIdentifier() == "adjustPanel" })
        // The panel fills the sidebar below the tool icons' line, whatever the window's height (CI screens are small).
        let panelFrame = adjustPanel.convert(adjustPanel.bounds, to: nil)
        let sidebarFrame = sidebar.convert(sidebar.bounds, to: nil)
        #expect(abs(panelFrame.minY - sidebarFrame.minY) <= 1, "reaches the bottom of the sidebar: \(panelFrame) in \(sidebarFrame)")
        #expect(panelFrame.maxY <= lineTop + 1 && lineTop - panelFrame.maxY < 20, "starts just below the line: \(panelFrame.maxY) vs \(lineTop)")
        #expect(panelFrame.height > 100)
        #expect(!adjustPanel.hasAmbiguousLayout && !histogram.hasAmbiguousLayout)
        // The plot, the shooting settings and what the photo is drawn from.
        #expect(abs(histogram.frame.height - (HistogramView.plotHeight + 6 + 16 + 16)) < 0.5)
    }

    /// RAW-260: Profile is the Adjust panel's first section, Presets its second and Lens Corrections its last, the
    /// last two each a whole panel.
    @Test func presetsAndLensCorrectionsAreSectionsOfAdjust() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url)
        let controller = CatalogWindowController(store: store)
        defer { controller.close() }
        controller.showWindow(nil)
        controller.state.mode = .develop
        let window = try #require(controller.window)
        let adjustPanel = try #require(window.contentView!.descendants.first { $0.accessibilityIdentifier() == "adjustPanel" })
        // In the order the panel's stack shows them.
        let stack = try #require(adjustPanel.descendants.first { $0 is AdjustmentSectionView }?.superview as? NSStackView)
        let sections = stack.arrangedSubviews.compactMap { $0 as? AdjustmentSectionView }
        try #require(sections.count > 2)
        #expect(sections[0].title == "Profile")
        #expect(sections[1].title == "Presets")
        #expect(sections.last?.title == "Lens Corrections")
        let presets = try #require(window.contentView!.descendants.first { $0.accessibilityIdentifier() == "presetsPanel" })
        let lens = try #require(window.contentView!.descendants.first { $0.accessibilityIdentifier() == "lensPanel" })
        #expect(presets.isDescendant(of: sections[1]) && lens.isDescendant(of: sections.last!))
        // Neither has an on/off circle of its own.
        for section in [sections[1], sections.last!] {
            let toggle = section.descendants.first { $0.accessibilityIdentifier() == "toggle.\(section.title)" }
            #expect(toggle?.isHidden == true)
        }
    }
}
