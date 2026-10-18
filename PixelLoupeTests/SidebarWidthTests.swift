import AppKit
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Sidebar width")
@MainActor
struct SidebarWidthTests {
    /// The window's split view, with its own defaults so other tests' widths don't leak in.
    private func window(_ store: CatalogStore, defaults: UserDefaults, width: CGFloat = 1600) async throws -> (NSWindow, MainSplitViewController) {
        let split = MainSplitViewController(store: store, state: LibraryState(), defaults: defaults)
        split.isDraggingDivider = { false }
        let window = NSWindow(contentViewController: split)
        // Room for both sidebars at full width beside the Library's content.
        window.setContentSize(NSSize(width: width, height: 900))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        // The widths are set just after the first layout.
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        return (window, split)
    }

    @Test func theLeftSidebarOpensAsWideAsTheRightAndKeepsItsWidth() async throws {
        let suite = "SidebarWidthTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))

        let (first, split) = try await window(store, defaults: defaults)
        let views = split.splitView.arrangedSubviews
        #expect(abs(views[0].frame.width - views[2].frame.width) <= 2, "\(views[0].frame.width) vs \(views[2].frame.width)")

        // Narrower, as dragging the divider does; the next window opens at that width.
        split.isDraggingDivider = { true }
        split.splitView.setPosition(260, ofDividerAt: 0)
        split.splitView.layoutSubtreeIfNeeded()
        split.isDraggingDivider = { false }
        #expect(abs(views[0].frame.width - 260) <= 1)
        #expect(defaults.double(forKey: "LeftSidebarWidth") == Double(views[0].frame.width))
        first.close()
        let (second, reopened) = try await window(store, defaults: defaults)
        defer { second.close() }
        #expect(abs(reopened.splitView.arrangedSubviews[0].frame.width - 260) <= 1)
    }

    /// RAW-69 regressed: a window too narrow for both sidebars at full width squeezed the left one
    /// to its minimum, and that squeezed width was remembered as if the user had dragged it, so every
    /// later window opened with the narrow sidebar.
    @Test func squeezingTheSidebarDoesntChangeItsRememberedWidth() async throws {
        let suite = "SidebarWidthTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let (window, split) = try await self.window(store, defaults: defaults)
        defer { window.close() }
        let left = split.splitView.arrangedSubviews[0]
        let opened = left.frame.width

        window.setContentSize(NSSize(width: 1000, height: 900))
        window.layoutIfNeeded()
        #expect(left.frame.width < opened, "a narrow window squeezes the sidebar")
        window.setContentSize(NSSize(width: 1600, height: 900))
        window.layoutIfNeeded()
        #expect(defaults.object(forKey: "LeftSidebarWidth") == nil, "only a drag of the divider is remembered")

        // Opening in a window too narrow to give it its full width doesn't record the squeezed width.
        let (narrow, narrowSplit) = try await self.window(store, defaults: defaults, width: 1300)
        defer { narrow.close() }
        #expect(narrowSplit.splitView.arrangedSubviews[0].frame.width < split.sidebarWidth)
        #expect(defaults.object(forKey: "LeftSidebarWidth") == nil)
    }

    @Test func widthsSavedBeforeTheFixAreForgottenOnce() throws {
        let suite = "SidebarWidthTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(209.0, forKey: "LeftSidebarWidth")
        defaults.set(382.0, forKey: "RightSidebarWidth")
        MainSplitViewController.forgetWidthsRecordedBeforeDragOnly(in: defaults)
        #expect(defaults.object(forKey: "LeftSidebarWidth") == nil)
        #expect(defaults.object(forKey: "RightSidebarWidth") == nil)

        // A width dragged after that is kept.
        defaults.set(260.0, forKey: "LeftSidebarWidth")
        MainSplitViewController.forgetWidthsRecordedBeforeDragOnly(in: defaults)
        #expect(defaults.double(forKey: "LeftSidebarWidth") == 260)
    }
}
