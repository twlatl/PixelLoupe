import AppKit

/// RAW-75: the secondary window on another display, shown and switched from the toolbar's display
/// button and Window ▸ Secondary Display.
extension CatalogWindowController {
    private var secondarySettings: SecondaryDisplaySettings { .shared }

    /// More than one display is connected (the display toolbar button shows only then).
    var hasSecondaryDisplay: Bool { NSScreen.screens.count > 1 }

    /// The display the secondary window belongs on (Settings ▸ Displays), or nil with one display.
    var secondaryTargetScreen: NSScreen? {
        SecondaryDisplay.target(
            among: DisplayInfo.connected(),
            preferred: secondarySettings.preferredDisplayID,
            mainWindowDisplay: window?.screen?.displayUUID
        ).flatMap { NSScreen.with(displayUUID: $0.id) }
    }

    func showSecondaryWindow(fullScreen: Bool) {
        guard let screen = secondaryTargetScreen else { return }
        let controller = secondaryWindowController ?? makeSecondaryWindowController()
        secondaryWindowController = controller
        controller.present(on: screen, fullScreen: fullScreen)
        secondarySettings.isShown = true
    }

    private func makeSecondaryWindowController() -> SecondaryWindowController {
        let controller = SecondaryWindowController(store: store, main: state, view: secondarySettings.view)
        controller.actionTarget = self
        controller.onUserClose = { [weak self] in
            self?.secondaryWindowController = nil
            SecondaryDisplaySettings.shared.isShown = false
        }
        controller.onFullScreenChange = { SecondaryDisplaySettings.shared.isFullScreen = $0 }
        controller.onViewChange = { SecondaryDisplaySettings.shared.view = $0 }
        return controller
    }

    func hideSecondaryWindow() {
        secondaryWindowController?.closeQuietly()
        secondaryWindowController = nil
        secondarySettings.isShown = false
    }

    /// Reopens the secondary window if it was showing when the app last closed it.
    func restoreSecondaryWindow() {
        guard secondarySettings.isShown, secondaryWindowController == nil else { return }
        showSecondaryWindow(fullScreen: secondarySettings.isFullScreen)
    }

    /// Displays were connected, disconnected or rearranged: the toolbar button follows, the window
    /// closes when its display goes away (and comes back with it), or moves to the chosen display.
    @objc func screenParametersDidChange(_ notification: Notification) {
        updateDisplayToolbarItem()
        guard let controller = secondaryWindowController else {
            restoreSecondaryWindow()
            return
        }
        if let screen = secondaryTargetScreen {
            controller.move(to: screen)
        } else {
            controller.closeQuietly()
            secondaryWindowController = nil
        }
    }

    /// Settings ▸ Displays picked another display.
    @objc func secondaryDisplaySettingsDidChange(_ notification: Notification) {
        if let controller = secondaryWindowController, let screen = secondaryTargetScreen {
            controller.move(to: screen)
        }
    }

    func updateDisplayToolbarItem() {
        displayToolbarItem?.isHidden = !hasSecondaryDisplay
    }

    /// Switches the secondary window's view, opening the window if it's hidden. Choosing Loupe –
    /// Locked again unlocks (back to Loupe – Normal), as ⇧⌘Return does in Lightroom.
    func setSecondaryView(_ view: SecondaryView) {
        var view = view
        if view == .lockedLoupe, secondaryWindowController?.view == .lockedLoupe { view = .loupe }
        if let secondaryWindowController {
            secondaryWindowController.view = view
            // Compare falls back when there's nothing to compare.
            secondarySettings.view = secondaryWindowController.view
        } else {
            secondarySettings.view = view
            showSecondaryWindow(fullScreen: secondarySettings.isFullScreen)
        }
    }

    // MARK: - Menu actions

    @objc func toggleSecondaryWindow(_ sender: Any?) {
        if secondaryWindowController != nil {
            hideSecondaryWindow()
        } else {
            showSecondaryWindow(fullScreen: secondarySettings.isFullScreen)
        }
    }

    @objc func toggleSecondaryFullScreen(_ sender: Any?) {
        if let secondaryWindowController {
            secondaryWindowController.setFullScreen(!secondaryWindowController.isFullScreen)
        } else {
            secondarySettings.isFullScreen = true
            showSecondaryWindow(fullScreen: true)
        }
    }

    @objc func toggleSecondaryPreview(_ sender: Any?) {
        guard let secondaryWindowController else { return }
        secondaryWindowController.setPreviewShown(!secondaryWindowController.isShowingPreview, on: window?.screen)
    }

    @objc func showSecondaryView(_ sender: NSMenuItem) {
        guard let view = (sender.representedObject as? String).flatMap(SecondaryView.init(rawValue:)) else { return }
        setSecondaryView(view)
    }

    /// Checkmarks and enabling for the Secondary Window menu items; nil for other items.
    func validateSecondaryDisplayItem(_ item: any NSValidatedUserInterfaceItem) -> Bool? {
        let menuItem = item as? NSMenuItem
        switch item.action {
        case #selector(toggleSecondaryWindow(_:)):
            menuItem?.state = secondaryWindowController != nil ? .on : .off
            return hasSecondaryDisplay || secondaryWindowController != nil
        case #selector(toggleSecondaryFullScreen(_:)):
            menuItem?.state = secondaryWindowController?.isFullScreen == true ? .on : .off
            return hasSecondaryDisplay
        case #selector(toggleSecondaryPreview(_:)):
            menuItem?.state = secondaryWindowController?.isShowingPreview == true ? .on : .off
            return secondaryWindowController?.isFullScreen == true
        case #selector(showSecondaryView(_:)):
            // Shown with ⇧G / ⇧E / ⇧C; disabled while typing so the key reaches the text field.
            let typing = (NSApp.keyWindow?.firstResponder as? NSText)?.isEditable ?? false
            let view = (menuItem?.representedObject as? String).flatMap(SecondaryView.init(rawValue:))
            menuItem?.state = view == (secondaryWindowController?.view ?? secondarySettings.view) ? .on : .off
            if view == .compare {
                let canCompare = secondaryWindowController?.canCompare
                    ?? (ComparePair.make(selection: state.selectedPhotoIDs, order: state.photoOrder) != nil)
                return !typing && hasSecondaryDisplay && canCompare
            }
            return !typing && hasSecondaryDisplay
        default:
            return nil
        }
    }
}
