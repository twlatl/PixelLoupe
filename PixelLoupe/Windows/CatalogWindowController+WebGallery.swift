import AppKit

/// RAW-195: Window ▸ Web Gallery (⌃⌥⌘W) opens a web gallery of the photos a contact sheet would
/// show: the selected photos when several are selected, otherwise every photo in the grid. Videos
/// are left out.
extension CatalogWindowController {
    @objc func showWebGallery(_ sender: Any?) {
        guard let ids = contactSheetPhotoIDs else { return }
        let photos = ContactSheetPhoto.photos(ids, in: store)
        guard !photos.isEmpty else { return NSSound.beep() }
        let controller = WebGalleryWindowController(photos: photos, thumbnails: store.thumbnails, sourceName: contactSheetSourceName)
        controller.onClose = { [weak self, weak controller] in
            self?.webGalleryControllers.removeAll { $0 === controller }
        }
        webGalleryControllers.append(controller)
        controller.showWindow(nil)
    }
}
