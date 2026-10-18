import AppKit
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Develop panel controls")
@MainActor
struct DevelopControlActionTests {
    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    /// Regression: `#selector(ActionTarget.perform(_:))` resolved to `NSObject.perform(_:)`
    /// (`performSelector:`), so the Profile pop-up (and every other control wired this way) never ran
    /// its closure and choosing a profile did nothing.
    @Test func profilePopUpChangesTheProfile() throws {
        let panel = AdjustmentsPanelViewController()
        _ = panel.view
        panel.isEditingEnabled = true
        var changes: [PhotoAdjustments] = []
        panel.onChange = { adjustments, _, _ in changes.append(adjustments) }
        let popUp = try #require(allViews(panel.view).first { $0.accessibilityIdentifier() == "profilePopUp" } as? NSPopUpButton)
        let vivid = try #require(popUp.itemTitles.firstIndex(of: "Vivid"))
        popUp.selectItem(at: vivid)
        _ = popUp.target?.perform(popUp.action, with: popUp)

        let result = try #require(changes.last)
        #expect(result.profile.kind == .vivid && result.profile.isActive)
        #expect(ColorLUT.key(for: result)?.profile?.kind == .vivid, "and it reaches the color table the renderer uses")
        #expect(panel.adjustments.profile.kind == .vivid)
    }

    @Test func everyActionTargetControlCallsItsHandler() throws {
        let panel = AdjustmentsPanelViewController()
        _ = panel.view
        let controls = allViews(panel.view).compactMap { $0 as? NSControl }.filter { $0.target is ActionTarget }
        #expect(controls.count >= 5, "found the controls that use ActionTarget")
        for control in controls {
            #expect(control.action == #selector(ActionTarget.fire(_:)), "\(control.accessibilityIdentifier())")
        }
    }
}
