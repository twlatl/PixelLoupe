import AppKit

/// RAW-90: slideshows of the current photos, on the main window's display (Window ▸ Impromptu
/// Slideshow, ⌘Return, as in Lightroom) or on the secondary display (the Secondary Window menu's
/// Slideshow, ⌥⇧⌘Return), where it plays while you keep working in the main window.
extension CatalogWindowController {
    /// Starts a slideshow, or stops the one playing there.
    @objc func impromptuSlideshow(_ sender: Any?) {
        if let slideshowController {
            slideshowController.stop()
        } else if let screen = window?.screen ?? NSScreen.main {
            slideshowController = startSlideshow(on: screen, secondary: false)
        }
    }

    @objc func toggleSecondarySlideshow(_ sender: Any?) {
        if let secondarySlideshowController {
            secondarySlideshowController.stop()
        } else if let screen = secondaryWindowController?.window?.screen ?? secondaryTargetScreen {
            secondarySlideshowController = startSlideshow(on: screen, secondary: true)
        }
    }

    /// The photos a slideshow would play: the selected ones, or the whole grid.
    var slideshowPlaylist: (photos: [NSManagedObjectID], start: Int)? {
        SlideshowPlaylist.make(selection: state.selectedPhotoIDs, order: state.photoOrder)
    }

    private func startSlideshow(on screen: NSScreen, secondary: Bool) -> SlideshowController? {
        guard let playlist = slideshowPlaylist else { return nil }
        let controller = SlideshowController(store: store, photos: playlist.photos, start: playlist.start,
                                             screen: screen, secondary: secondary)
        controller.onStop = { [weak self, weak controller] in
            guard let self, let controller else { return }
            if slideshowController === controller {
                slideshowController = nil
                window?.makeKeyAndOrderFront(nil)
            }
            if secondarySlideshowController === controller { secondarySlideshowController = nil }
        }
        controller.start()
        return controller
    }

    /// Titles and enabling for the slideshow items; nil for other items.
    func validateSlideshowItem(_ item: any NSValidatedUserInterfaceItem) -> Bool? {
        let menuItem = item as? NSMenuItem
        switch item.action {
        case #selector(impromptuSlideshow(_:)):
            menuItem?.title = slideshowController != nil ? "Stop Slideshow" : "Impromptu Slideshow"
            return slideshowController != nil || slideshowPlaylist != nil
        case #selector(toggleSecondarySlideshow(_:)):
            menuItem?.title = secondarySlideshowController != nil ? "Stop Slideshow" : "Slideshow"
            return secondarySlideshowController != nil || (hasSecondaryDisplay && slideshowPlaylist != nil)
        default:
            return nil
        }
    }
}
