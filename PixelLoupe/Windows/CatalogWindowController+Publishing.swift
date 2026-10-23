import AppKit
import CoreData

/// Publish services in the catalog window: Window ▸ Publishing Manager… (RAW-178), and adding photos to
/// services, Publish, its progress and its results (RAW-179).
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

    /// A publish service's Edit Settings…: the Publishing Manager, with that service selected.
    @objc func editPublishService(_ sender: Any?) {
        guard let id = publishServiceID(from: sender) else { return }
        showPublishingManager(sender)
        publishingManager?.select(serviceID: id)
    }

    /// The service a menu item names, else the one the grid shows.
    private func publishServiceID(from sender: Any?) -> UUID? {
        (sender as? NSMenuItem)?.representedObject as? UUID ?? state.filter.scope.publishServiceID
    }

    // MARK: - Adding and removing photos

    /// Add to Publish Service ▸ (a service): the selected photos.
    @objc func addToPublishService(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID else { return }
        PublishEditing(store: store).add(state.selectedPhotoIDs, to: id)
    }

    /// Remove from Publish Service: the selected photos, from the service the grid shows.
    @objc func removeFromPublishService(_ sender: Any?) {
        guard let id = state.filter.scope.publishServiceID else { return }
        PublishEditing(store: store).remove(state.selectedPhotoIDs, from: id)
    }

    /// The Add to Publish Service submenu: every service.
    func addToPublishServiceMenu() -> NSMenu {
        let menu = NSMenu(title: "Add to Publish Service")
        for service in PublishService.all(in: store.viewContext) {
            let item = NSMenuItem(title: service.displayName, action: #selector(addToPublishService(_:)), keyEquivalent: "")
            item.representedObject = service.id
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - Publish

    /// Publishes a service: its new and modified photos, and (once confirmed) removes its deleted ones.
    @objc func publishNow(_ sender: Any?) {
        guard publishTask == nil, let id = publishServiceID(from: sender),
              let service = PublishService.with(id: id, in: store.viewContext) else { return }
        service.pruneUnpublishedOrphans()
        let removals = service.entries(in: .deleted).count { $0.remoteID != nil }
        guard removals > 0, let window else { return startPublish(service) }
        let alert = NSAlert()
        alert.messageText = removals == 1
            ? "Remove 1 photo from \(service.displayName)?"
            : "Remove \(removals.formatted()) photos from \(service.displayName)?"
        alert.informativeText = service.kind == .hardDrive
            ? "Their published files are moved to the Trash. The photos stay in your catalog."
            : "They’re deleted from \(service.kind.title), with their comments and favorites. The photos stay in your catalog."
        alert.addButton(withTitle: "Publish")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.startPublish(service) }
        }
    }

    @objc func cancelPublish(_ sender: Any?) {
        publishTask?.cancel()
    }

    private func startPublish(_ service: PublishService) {
        state.publishingServiceName = service.displayName
        state.publishStatus = LibraryState.ImportStatus(completed: 0, total: 0)
        publishTask = Task { [weak self] in
            guard let self else { return }
            let result = await PublishRun.run(service, store: store) { [weak self] completed, total in
                self?.state.publishStatus = LibraryState.ImportStatus(completed: completed, total: total)
            }
            publishTask = nil
            state.publishStatus = nil
            if !result.failures.isEmpty || result.stopReason != nil, let window {
                Self.publishSummary(result, service: service.displayName).beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    /// What went wrong in a Publish.
    static func publishSummary(_ result: PublishRun.Result, service: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if let reason = result.stopReason {
            alert.messageText = "Publishing to \(service) stopped."
            alert.informativeText = reason + (result.published > 0 ? "\n\n\(result.published.formatted()) published before it stopped." : "")
            return alert
        }
        let failed = result.failures.count
        alert.messageText = failed == 1 ? "1 photo couldn’t be published to \(service)." : "\(failed.formatted()) photos couldn’t be published to \(service)."
        let listed = result.failures.prefix(10).joined(separator: "\n")
        alert.informativeText = listed + (failed > 10 ? "\n…and \((failed - 10).formatted()) more." : "")
            + "\n\nThey’re marked in the grid, and the next Publish tries them again."
        return alert
    }

    /// Enabling for the publishing items; nil for other items.
    func validatePublishItem(_ item: any NSValidatedUserInterfaceItem) -> Bool? {
        switch item.action {
        case #selector(publishNow(_:)):
            guard publishTask == nil, let id = publishServiceID(from: item),
                  let service = PublishService.with(id: id, in: store.viewContext) else { return false }
            return PublishGroups(service: service, photoIDs: service.publishedPhotos.compactMap { $0.photo?.objectID },
                                 context: store.viewContext).hasWork
        case #selector(cancelPublish(_:)):
            return publishTask != nil
        case #selector(editPublishService(_:)):
            return publishServiceID(from: item) != nil
        case #selector(addToPublishService(_:)):
            return !state.selectedPhotoIDs.isEmpty
        case #selector(removeFromPublishService(_:)):
            return state.filter.scope.publishServiceID != nil && !state.selectedPhotoIDs.isEmpty
        default:
            return nil
        }
    }
}
