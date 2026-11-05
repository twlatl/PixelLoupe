import AppKit

/// Library ▸ Previews: building and discarding Standard previews (see ``StandardPreviewStore``) and Smart Previews
/// (see ``SmartPreviewStore``) of the selected photos.
extension CatalogWindowController {
    /// Builds them, and their Develop-rendered thumbnails, in the background for the selected RAW photos; progress
    /// shows under the grid.
    @objc func buildStandardPreviews(_ sender: Any?) {
        store.standardPreviewBuilder.build(editing.photos(state.selectedPhotoIDs))
    }

    /// Asks first, like Discard Smart Previews; they can be built again at any time.
    @objc func discardStandardPreviews(_ sender: Any?) {
        let photos = editing.photos(state.selectedPhotoIDs).filter { store.standardPreviews.contains($0.id) }
        guard let first = photos.first, let window else { return }
        let alert = NSAlert()
        alert.messageText = photos.count == 1
            ? "Discard the Standard preview of “\(first.fileName)”?"
            : "Discard the Standard previews of \(photos.count.formatted()) photos?"
        alert.informativeText = "The originals and their edits aren’t affected. You can build them again with Library ▸ Previews ▸ Build Standard Previews."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.standardPreviews.discard(photos.map(\.id))
        }
    }

    /// Builds them in the background; progress shows under the grid.
    @objc func buildSmartPreviews(_ sender: Any?) {
        store.smartPreviewBuilder.build(editing.photos(state.selectedPhotoIDs))
    }

    /// Asks first: a photo whose original is missing can't be edited without its Smart Preview.
    @objc func discardSmartPreviews(_ sender: Any?) {
        let photos = editing.photos(state.selectedPhotoIDs).filter(store.smartPreviews.contains)
        guard let first = photos.first, let window else { return }
        let alert = NSAlert()
        alert.messageText = photos.count == 1
            ? "Discard the Smart Preview of “\(first.fileName)”?"
            : "Discard the Smart Previews of \(photos.count.formatted()) photos?"
        alert.informativeText = "The originals and their edits aren’t affected. While an original is missing, its photo can only be edited with a Smart Preview."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.smartPreviews.discard(photos)
        }
    }

    func validateSmartPreviewItem(_ item: any NSValidatedUserInterfaceItem) -> Bool? {
        switch item.action {
        case #selector(buildStandardPreviews(_:)):
            return editing.photos(state.selectedPhotoIDs).contains(where: StandardPreviewBuilder.isEligible)
        case #selector(discardStandardPreviews(_:)):
            return window?.attachedSheet == nil
                && editing.photos(state.selectedPhotoIDs).contains { store.standardPreviews.contains($0.id) }
        case #selector(buildSmartPreviews(_:)):
            return editing.photos(state.selectedPhotoIDs).contains { !$0.isVideo }
        case #selector(discardSmartPreviews(_:)):
            return window?.attachedSheet == nil && editing.photos(state.selectedPhotoIDs).contains(where: store.smartPreviews.contains)
        default:
            return nil
        }
    }
}
