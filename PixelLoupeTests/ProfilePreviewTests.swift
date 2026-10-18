import AppKit
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Profile menu preview")
@MainActor
struct ProfilePreviewTests {
    @Test func highlightingAProfilePreviewsItWithoutApplying() throws {
        let directory = try TemporaryDirectory()
        let library = AdobeProfileLibrary(directory: directory.url)
        library.register(try #require(AdobeProfile.parse(ProfileFixtures.xmp(name: "B&W 11", group: "B&W", uuid: "UUID-B11", monochrome: true,
                                                                              lookTable: ProfileFixtures.lookTable(hueShift: 0)))))
        let panel = AdjustmentsPanelViewController()
        panel.profiles = library
        _ = panel.view
        panel.isEditingEnabled = true
        panel.cameraModel = "Nikon Z 9"
        var changes = 0
        var previews: [PhotoAdjustments?] = []
        panel.onChange = { _, _, _ in changes += 1 }
        panel.onPreview = { previews.append($0) }
        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        let popUp = try #require(allViews(panel.view).first { $0.accessibilityIdentifier() == "profilePopUp" } as? NSPopUpButton)
        let menu = try #require(popUp.menu)
        let delegate = try #require(menu.delegate)

        // Scrubbing the top level: PixelLoupe's looks.
        delegate.menuWillOpen?(menu)
        delegate.menu?(menu, willHighlight: menu.item(withTitle: "Vivid"))
        #expect(previews.last??.profile.kind == .vivid)

        // Into a group: an Adobe profile, black and white with it.
        let group = try #require(menu.items.first { $0.submenu?.title == "B&W" }?.submenu)
        #expect(group.delegate === delegate)
        delegate.menu?(menu, willHighlight: menu.items.first { $0.submenu === group })
        #expect(previews.count == 1, "a group's own row keeps the preview")
        delegate.menuWillOpen?(group)
        delegate.menu?(group, willHighlight: group.item(withTitle: "B&W 11"))
        let bw = try #require(previews.last ?? nil)
        #expect(bw.profile.adobeID == "UUID-B11" && bw.blackAndWhite.isEnabled)

        // Leaving the group keeps previewing; closing the menu ends it.
        delegate.menuDidClose?(group)
        #expect(previews.last ?? nil != nil)
        delegate.menuDidClose?(menu)
        #expect(previews.last! == nil)
        #expect(changes == 0, "nothing was applied")
    }
}
