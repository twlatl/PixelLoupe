import AppKit
import SwiftUI

extension CatalogWindowController {
    /// PixelLoupe ▸ Catalog Settings… (⌥⌘,): the open catalog's settings, in a sheet on its window.
    func showCatalogSettings() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        // Already showing, or another sheet is up: leave it be.
        guard window.attachedSheet == nil, let content = window.contentViewController else { return }
        var sheet: NSViewController?
        let hosting = NSHostingController(rootView: CatalogSettingsView(store: store) { sheet?.dismiss(nil) })
        hosting.sizingOptions = [.preferredContentSize]
        hosting.title = "Catalog Settings"
        sheet = hosting
        content.presentAsSheet(hosting)
    }
}
