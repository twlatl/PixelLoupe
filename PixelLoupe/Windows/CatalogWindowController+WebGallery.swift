import AppKit

/// RAW-195: Window ▸ Web Gallery (⌃⌥⌘W) opens a web gallery of the photos a contact sheet would
/// show: the selected photos when several are selected, otherwise every photo in the grid. Videos
/// are left out.
extension CatalogWindowController {
    @objc func showWebGallery(_ sender: Any?) {
        guard let ids = contactSheetPhotoIDs else { return }
        let photos = ContactSheetPhoto.photos(ids, in: store)
        guard !photos.isEmpty else { return NSSound.beep() }
        // What Export needs to render each photo for Generate, taken now as the photos are.
        var exportItems: [UUID: ExportItem] = [:]
        for id in ids {
            guard let photo = try? store.viewContext.existingObject(with: id) as? Photo, !photo.isVideo else { continue }
            exportItems[photo.id] = ExportItem(photo, smartPreview: store.smartPreviews.file(for: photo))
        }
        let controller = WebGalleryWindowController(photos: photos, exportItems: exportItems, thumbnails: store.thumbnails,
                                                    sourceName: contactSheetSourceName)
        controller.onClose = { [weak self, weak controller] in
            self?.webGalleryControllers.removeAll { $0 === controller }
        }
        webGalleryControllers.append(controller)
        controller.showWindow(nil)
    }
}
