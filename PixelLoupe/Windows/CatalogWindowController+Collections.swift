import AppKit
import CoreData

/// Library ▸ New Collection and friends, the sidebar's collection menus, Add to Collection and B.
extension CatalogWindowController {
    var collectionEditing: CollectionEditing { CollectionEditing(store: store) }

    /// The set a new collection goes in: the one the menu was for, or the set being shown.
    private func parentSet(for sender: Any?) -> UUID? {
        if let id = (sender as? NSMenuItem)?.representedObject as? UUID { return id }
        guard let id = state.filter.scope.collectionID, collectionEditing.collection(id)?.kind == .set else { return nil }
        return id
    }

    /// ⌘N
    @objc func newCollection(_ sender: Any?) {
        // In Develop ⌘N saves a snapshot (Lightroom's shortcut there).
        if state.mode == .develop {
            rootViewController.main.develop.createSnapshot()
            return
        }
        presentCollectionDialog(.collection, parentID: parentSet(for: sender))
    }

    @objc func newSmartCollection(_ sender: Any?) {
        presentCollectionDialog(.smart, parentID: parentSet(for: sender))
    }

    @objc func newCollectionSet(_ sender: Any?) {
        presentCollectionDialog(.set, parentID: parentSet(for: sender))
    }

    private func presentCollectionDialog(_ kind: PhotoCollection.Kind, parentID: UUID?) {
        guard let window, window.attachedSheet == nil else { return }
        let selection = state.selectedPhotoIDs
        let dialog = CollectionDialog(kind: kind, sets: collectionEditing.sets(), parentID: parentID, hasSelection: !selection.isEmpty)
        dialog.onFinish = { [weak self] result in
            guard let self, let result else { return }
            let collection = collectionEditing.create(
                kind, named: result.name, in: result.parentID,
                photos: result.includeSelectedPhotos ? selection : [],
                rules: kind == .smart ? result.rules : nil
            )
            if result.setAsTarget {
                store.viewState.targetCollectionID = collection.id
                rootViewController.main.sidebar.reload()
            }
            // Show what was made (collections and smart collections).
            if kind != .set { state.filter.scope = .collection(id: collection.id, content: collection.content) }
        }
        window.contentViewController?.presentAsSheet(dialog)
        lastCollectionDialog = dialog
    }

    @objc func editSmartCollection(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, let id = (sender as? NSMenuItem)?.representedObject as? UUID,
              let collection = collectionEditing.collection(id), collection.kind == .smart else { return }
        let dialog = CollectionDialog(
            kind: .smart, sets: collectionEditing.sets(excluding: id), parentID: collection.parent?.id, hasSelection: false,
            name: collection.name, rules: collection.rules
        )
        dialog.onFinish = { [weak self] result in
            guard let self, let result else { return }
            collectionEditing.update(id, name: result.name, parent: result.parentID, rules: result.rules)
        }
        window.contentViewController?.presentAsSheet(dialog)
        lastCollectionDialog = dialog
    }

    @objc func renameCollection(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, let id = (sender as? NSMenuItem)?.representedObject as? UUID,
              let collection = collectionEditing.collection(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename “\(collection.name)”"
        let field = NSTextField(string: collection.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.collectionEditing.rename(id, to: field.stringValue)
        }
    }

    @objc func deleteCollection(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, let id = (sender as? NSMenuItem)?.representedObject as? UUID,
              let collection = collectionEditing.collection(id) else { return }
        let alert = NSAlert()
        switch collection.kind {
        case .set:
            alert.messageText = "Delete the collection set “\(collection.name)”?"
            alert.informativeText = collection.children.isEmpty
                ? "The photos in its collections stay in your catalog."
                : "Its \(collection.children.count) collection\(collection.children.count == 1 ? "" : "s") will be deleted too. The photos stay in your catalog."
        case .collection, .smart:
            alert.messageText = "Delete the collection “\(collection.name)”?"
            alert.informativeText = "The photos stay in your catalog."
        }
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.collectionEditing.delete(id)
        }
    }

    /// Set as Target Collection (or clear it, choosing the target again).
    @objc func setTargetCollection(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID else { return }
        store.viewState.targetCollectionID = store.viewState.targetCollectionID == id ? nil : id
        rootViewController.main.sidebar.reload()   // it marks the target
    }

    /// Photo ▸ Add to Collection ▸ (a collection).
    @objc func addToCollection(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID else { return }
        collectionEditing.add(state.selectedPhotoIDs, to: id)
    }

    /// Removes the selected photos from the collection being shown.
    @objc func removeFromCollection(_ sender: Any?) {
        guard let id = state.filter.scope.collectionID else { return }
        collectionEditing.remove(state.selectedPhotoIDs, from: id)
    }

    /// B: adds the selected photos to the target collection, or removes them if they're all in it.
    @objc func addToTargetCollection(_ sender: Any?) {
        guard let id = store.viewState.targetCollectionID, collectionEditing.collection(id) != nil,
              !state.selectedPhotoIDs.isEmpty else {
            NSSound.beep()
            return
        }
        collectionEditing.toggle(state.selectedPhotoIDs, in: id)
    }

    /// Whether the collection being shown is a regular collection (photos can be removed from it).
    var isShowingCollection: Bool {
        state.filter.scope.collectionID.flatMap { collectionEditing.collection($0) }?.kind == .collection
    }

    /// The Add to Collection submenu: every collection, by path.
    func addToCollectionMenu() -> NSMenu {
        let menu = NSMenu(title: "Add to Collection")
        let collections = collectionEditing.collections()
        if collections.isEmpty {
            let none = NSMenuItem(title: "No Collections", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for collection in collections {
            let item = NSMenuItem(title: collection.path, action: #selector(addToCollection(_:)), keyEquivalent: "")
            item.representedObject = collection.id
            menu.addItem(item)
        }
        return menu
    }
}
