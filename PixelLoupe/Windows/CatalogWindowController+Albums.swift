import AppKit
import UniformTypeIdentifiers

/// A Flickr service's albums in the catalog window (RAW-185): Create Album…, Create Smart Album… and Import
/// Smart Collection Settings… in the service's menu, and Edit, Rename, Delete and Show in Flickr in an album's.
extension CatalogWindowController {
    private func albumID(from sender: Any?) -> UUID? {
        (sender as? NSMenuItem)?.representedObject as? UUID
    }

    @objc func createPublishAlbum(_ sender: Any?) {
        presentAlbumDialog(.album, serviceID: albumID(from: sender))
    }

    @objc func createPublishSmartAlbum(_ sender: Any?) {
        presentAlbumDialog(.smart, serviceID: albumID(from: sender))
    }

    private func presentAlbumDialog(_ kind: PublishAlbum.Kind, serviceID: UUID?) {
        guard let window, window.attachedSheet == nil, let serviceID else { return }
        let selection = state.selectedPhotoIDs
        let dialog = CollectionDialog(kind: kind == .smart ? .smart : .collection, sets: [], parentID: nil,
                                      hasSelection: !selection.isEmpty, album: true)
        dialog.onFinish = { [weak self] result in
            guard let self, let result,
                  let album = PublishEditing(store: store).createAlbum(
                    kind, in: serviceID, named: result.name, description: result.description,
                    rules: kind == .smart ? result.rules : nil, photos: result.includeSelectedPhotos ? selection : []
                  ) else { return }
            if result.setAsTarget {
                store.viewState.targetCollectionID = album.id
                rootViewController.main.sidebar.reload()
            }
            album.scope.map { state.filter.scope = $0 }
        }
        window.contentViewController?.presentAsSheet(dialog)
        lastCollectionDialog = dialog
    }

    @objc func editPublishAlbum(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, let id = albumID(from: sender),
              let album = PublishAlbum.with(id: id, in: store.viewContext) else { return }
        let dialog = CollectionDialog(kind: album.kind == .smart ? .smart : .collection, sets: [], parentID: nil, hasSelection: false,
                                      name: album.name, rules: album.kind == .smart ? album.rules : nil,
                                      album: true, description: album.albumDescription)
        dialog.onFinish = { [weak self] result in
            guard let self, let result else { return }
            PublishEditing(store: store).updateAlbum(id, name: result.name, description: result.description,
                                                     rules: album.kind == .smart ? result.rules : nil)
            // A smart album's photos follow its new rules.
            if state.filter.scope.publishAlbumID == id, let scope = album.scope { state.filter.scope = scope }
        }
        window.contentViewController?.presentAsSheet(dialog)
        lastCollectionDialog = dialog
    }

    @objc func renamePublishAlbum(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, let id = albumID(from: sender),
              let album = PublishAlbum.with(id: id, in: store.viewContext) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename “\(album.name)”"
        let field = NSTextField(string: album.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            PublishEditing(store: store).renameAlbum(id, to: field.stringValue)
        }
    }

    @objc func deletePublishAlbum(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, let id = albumID(from: sender),
              let album = PublishAlbum.with(id: id, in: store.viewContext) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the album “\(album.name)”?"
        alert.informativeText = album.remoteID == nil
            ? "The photos stay in the service and in your catalog."
            : "It’s deleted on Flickr at the next Publish. Its photos stay on Flickr and in your catalog."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if state.filter.scope.publishAlbumID == id, let serviceID = album.service?.id {
                state.filter.scope = .publishService(id: serviceID)
            }
            PublishEditing(store: store).deleteAlbum(id)
        }
    }

    @objc func showPublishAlbumLocation(_ sender: Any?) {
        guard let id = albumID(from: sender) else { return }
        PublishAlbum.with(id: id, in: store.viewContext)?.location().map { _ = NSWorkspace.shared.open($0) }
    }

    /// Import Smart Collection Settings…: a smart album with the rules of a `.lrsmcol` file Lightroom exported.
    @objc func importSmartAlbumSettings(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, let serviceID = albumID(from: sender) else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a smart collection settings file exported from Lightroom."
        panel.allowedContentTypes = [UTType(filenameExtension: "lrsmcol") ?? .data]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try importSmartAlbum(from: url, into: serviceID)
            } catch {
                showError(error)
            }
        }
    }

    /// Makes a smart album from a `.lrsmcol` file, named after the file.
    @discardableResult
    func importSmartAlbum(from url: URL, into serviceID: UUID) throws -> PublishAlbum? {
        let translation = try LightroomSmartRules.translateSettingsFile(Data(contentsOf: url))
        let warning = translation.unmapped.isEmpty
            ? nil : "Not imported (PixelLoupe can't match these): " + translation.unmapped.joined(separator: "; ")
        let album = PublishEditing(store: store).createAlbum(
            .smart, in: serviceID, named: url.deletingPathExtension().lastPathComponent, description: "",
            rules: translation.rules, importWarning: warning
        )
        album?.scope.map { state.filter.scope = $0 }
        return album
    }

    /// Enabling for the album items; nil for other items.
    func validateAlbumItem(_ item: any NSValidatedUserInterfaceItem) -> Bool? {
        switch item.action {
        case #selector(createPublishAlbum(_:)), #selector(createPublishSmartAlbum(_:)), #selector(importSmartAlbumSettings(_:)):
            guard window?.attachedSheet == nil, let id = albumID(from: item) else { return false }
            return PublishService.with(id: id, in: store.viewContext)?.hasAlbums ?? false
        case #selector(editPublishAlbum(_:)), #selector(renamePublishAlbum(_:)), #selector(deletePublishAlbum(_:)):
            guard window?.attachedSheet == nil, let id = albumID(from: item) else { return false }
            return PublishAlbum.with(id: id, in: store.viewContext) != nil
        case #selector(showPublishAlbumLocation(_:)):
            guard let id = albumID(from: item) else { return false }
            return PublishAlbum.with(id: id, in: store.viewContext)?.location() != nil
        default:
            return nil
        }
    }
}
