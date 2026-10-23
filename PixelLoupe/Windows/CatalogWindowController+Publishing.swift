import AppKit

/// Window ▸ Publishing Manager… (RAW-178): the catalog's publish services, set up in their own window.
extension CatalogWindowController {
    @objc func showPublishingManager(_ sender: Any?) {
        if let publishingManager {
            publishingManager.showWindow(nil)
            return
        }
        let controller = PublishingManagerWindowController(model: PublishingManagerModel(context: store.viewContext))
        controller.onClose = { [weak self] in self?.publishingManager = nil }
        publishingManager = controller
        controller.showWindow(nil)
    }
}
