import AppKit
import CoreData

/// RAW-103: Window ▸ Contact Sheet (⌃⌥⌘C) opens a contact sheet of the current photos, chosen as
/// Impromptu Slideshow chooses them: the selected photos when several are selected, otherwise every
/// photo in the grid. Videos are left out.
extension CatalogWindowController {
    @objc func showContactSheet(_ sender: Any?) {
        guard let ids = contactSheetPhotoIDs else { return }
        let photos = ContactSheetPhoto.photos(ids, in: store)
        guard !photos.isEmpty else { return NSSound.beep() }
        let controller = ContactSheetWindowController(photos: photos, thumbnails: store.thumbnails, sourceName: contactSheetSourceName)
        controller.onClose = { [weak self, weak controller] in
            self?.contactSheetControllers.removeAll { $0 === controller }
        }
        contactSheetControllers.append(controller)
        controller.showWindow(nil)
    }

    /// The photos a contact sheet would show (videos included; they're left out when it opens).
    var contactSheetPhotoIDs: [NSManagedObjectID]? {
        SlideshowPlaylist.make(selection: state.selectedPhotoIDs, order: state.photoOrder)?.photos
    }

    /// The grid's source, as the sidebar names it.
    var contactSheetSourceName: String {
        switch state.filter.scope {
        case .allPhotos: "All Photographs"
        case .previousImport: "Previous Import"
        case .folder(let path): (path as NSString).lastPathComponent
        case .collection(let id, _): PhotoCollection.with(id: id, in: store.viewContext)?.name ?? "Collection"
        case .importDifference(let reason): LightroomImportReport.title(forReason: reason)
        case .publishService(let id): PublishService.with(id: id, in: store.viewContext)?.displayName ?? "Publish Service"
        case .publishAlbum(let id, _, _): PublishAlbum.with(id: id, in: store.viewContext)?.name ?? "Album"
        }
    }

    /// Enabling for Contact Sheet and Web Gallery, which show the same photos; nil for other items.
    func validateContactSheetItem(_ item: any NSValidatedUserInterfaceItem) -> Bool? {
        guard item.action == #selector(showContactSheet(_:)) || item.action == #selector(showWebGallery(_:)) else { return nil }
        guard let ids = contactSheetPhotoIDs else { return false }
        // Usually the first photo answers it, so this stays quick for a large grid.
        let context = store.viewContext
        return ids.contains { (try? context.existingObject(with: $0) as? Photo)?.isVideo == false }
    }
}
