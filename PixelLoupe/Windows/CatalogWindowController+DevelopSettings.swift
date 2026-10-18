import AppKit
import CoreData
import SwiftUI

/// The Library grid's Develop Settings submenu (Lightroom's): Reset, Copy / Paste / Sync Settings,
/// Delete All Empty Masks, Auto White Balance, Auto Settings and Convert to Black & White.
extension CatalogWindowController {
    /// Changes the photos' Develop settings as one undoable step, recording each change in the
    /// photo's history (with its Original first) as Develop does. Photos `change` leaves alone are
    /// untouched.
    func changeDevelopSettings(
        _ ids: [NSManagedObjectID], actionName: String, historyName: String? = nil,
        _ change: (Photo, PhotoAdjustments) -> PhotoAdjustments
    ) {
        editing.edit(ids, actionName: actionName) { photo in
            let before = photo.adjustments
            let after = change(photo, before)
            guard after != before else { return }
            if photo.historySteps.isEmpty { DevelopHistory.record(before, name: "Original", for: photo) }
            DevelopHistory.record(after, name: historyName ?? actionName, for: photo)
            photo.adjustments = after
        }
    }

    // MARK: - Copy and Sync

    /// Develop Settings ▸ Copy Settings…: asks which settings, then copies them for Paste Settings.
    @objc func copySettingsChoosing(_ sender: Any?) {
        guard let photo = editing.photos(state.selectedPhotoIDs).first else { return }
        let adjustments = photo.adjustments
        let name = photo.fileName
        presentDevelopSettingsDialog(.copy) { settings in
            SettingsClipboard.content = .settings(adjustments, from: name, only: settings)
        }
    }

    /// The photo Sync Settings copies from: the one the menu was opened on, else the first selected.
    private func syncSource(_ sender: Any?) -> NSManagedObjectID? {
        if let id = (sender as? NSMenuItem)?.representedObject as? NSManagedObjectID, state.selectedPhotoIDs.contains(id) { return id }
        return state.selectedPhotoIDs.first
    }

    /// Develop Settings ▸ Sync Settings… (two or more photos selected): asks which settings, then
    /// copies them from the active photo to the other selected photos.
    @objc func syncDevelopSettings(_ sender: Any?) {
        guard state.selectedPhotoIDs.count >= 2, let sourceID = syncSource(sender) else { return }
        let targets = state.selectedPhotoIDs.filter { $0 != sourceID }
        presentDevelopSettingsDialog(.sync(photoCount: targets.count)) { [weak self] settings in
            self?.syncDevelopSettings(settings, from: sourceID, to: targets)
        }
    }

    func syncDevelopSettings(_ settings: Set<DevelopSetting>, from sourceID: NSManagedObjectID, to targets: [NSManagedObjectID]) {
        guard let source = editing.photos([sourceID]).first else { return }
        let copied = source.adjustments
        changeDevelopSettings(targets, actionName: "Sync Settings") { _, before in
            DevelopSetting.apply(settings, from: copied, to: before)
        }
    }

    private func presentDevelopSettingsDialog(_ purpose: DevelopSettingsDialogModel.Purpose, completion: @escaping (Set<DevelopSetting>) -> Void) {
        guard let window, window.attachedSheet == nil else { return }
        let model = DevelopSettingsDialogModel(purpose: purpose)
        let sheet = NSHostingController(rootView: DevelopSettingsDialogView(model: model))
        model.onFinish = { [weak sheet] settings in
            sheet?.dismiss(nil)
            if let settings { completion(settings) }
        }
        window.contentViewController?.presentAsSheet(sheet)
        lastDevelopSettingsDialog = model
    }

    // MARK: - One-step changes

    @objc func deleteEmptyMasks(_ sender: Any?) {
        changeDevelopSettings(state.selectedPhotoIDs, actionName: "Delete All Empty Masks") { _, before in
            var after = before
            after.deleteEmptyMasks()
            return after
        }
    }

    @objc func convertToBlackAndWhite(_ sender: Any?) {
        changeDevelopSettings(state.selectedPhotoIDs, actionName: "Convert to Black & White") { _, before in
            var after = before
            after.blackAndWhite = PhotoAdjustments.autoBlackAndWhite
            return after
        }
    }

    /// Whether any selected photo has a mask with nothing in it.
    var selectionHasEmptyMasks: Bool {
        editing.photos(state.selectedPhotoIDs).contains { $0.adjustments.hasEmptyMasks }
    }

    // MARK: - Auto

    @objc func autoWhiteBalanceSelected(_ sender: Any?) {
        applyAuto(actionName: "Auto White Balance") { url, adjustments in
            guard let whiteBalance = await AutoDevelop.whiteBalance(for: url, adjustments: adjustments) else { return nil }
            var after = adjustments
            after.whiteBalance = whiteBalance
            return after
        }
    }

    @objc func autoSettingsSelected(_ sender: Any?) {
        applyAuto(actionName: "Auto Settings") { url, adjustments in
            await AutoDevelop.settings(for: url, adjustments: adjustments)
        }
    }

    /// Works out each selected photo's new settings off the main thread, then applies them all as
    /// one undoable step. Photos whose files can't be read are left as they are (with a beep).
    private func applyAuto(
        actionName: String, _ estimate: @escaping @Sendable (URL, PhotoAdjustments) async -> PhotoAdjustments?
    ) {
        let inputs = editing.photos(state.selectedPhotoIDs).map { ($0.objectID, $0.fileURL, $0.adjustments) }
        guard !inputs.isEmpty else { return }
        autoDevelopTask = Task { [weak self] in
            var results: [NSManagedObjectID: PhotoAdjustments] = [:]
            for (id, url, adjustments) in inputs {
                if Task.isCancelled { return }
                if let after = await estimate(url, adjustments) { results[id] = after }
            }
            guard let self else { return }
            autoDevelopTask = nil
            if results.count < inputs.count { NSSound.beep() }
            changeDevelopSettings(Array(results.keys), actionName: actionName) { photo, before in
                results[photo.objectID] ?? before
            }
        }
    }

    /// Enables the Develop Settings items; nil for other items.
    func validateDevelopSettingsItem(_ item: any NSValidatedUserInterfaceItem) -> Bool? {
        let selected = state.selectedPhotoIDs
        switch item.action {
        case #selector(copySettingsChoosing(_:)):
            return selected.count >= 1 && window?.attachedSheet == nil
        case #selector(syncDevelopSettings(_:)):
            return selected.count >= 2 && window?.attachedSheet == nil
        case #selector(deleteEmptyMasks(_:)):
            return selectionHasEmptyMasks
        case #selector(convertToBlackAndWhite(_:)):
            return !selected.isEmpty
        case #selector(autoWhiteBalanceSelected(_:)), #selector(autoSettingsSelected(_:)):
            return !selected.isEmpty && autoDevelopTask == nil
        default:
            return nil
        }
    }

    /// The Develop Settings submenu.
    func developSettingsMenu(clickedPhoto: NSManagedObjectID?) -> NSMenu {
        let menu = NSMenu(title: "Develop Settings")
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.representedObject = clickedPhoto
            menu.addItem(item)
        }
        add("Reset", #selector(PixelLoupeActions.revertToOriginal(_:)))
        add("Copy Settings…", #selector(PixelLoupeActions.copySettingsChoosing(_:)))
        add("Paste Settings", #selector(PixelLoupeActions.pasteSettings(_:)))
        add("Sync Settings…", #selector(PixelLoupeActions.syncDevelopSettings(_:)))
        menu.addItem(.separator())
        add("Delete All Empty Masks", #selector(PixelLoupeActions.deleteEmptyMasks(_:)))
        menu.addItem(.separator())
        add("Auto White Balance", #selector(PixelLoupeActions.autoWhiteBalanceSelected(_:)))
        add("Auto Settings", #selector(PixelLoupeActions.autoSettingsSelected(_:)))
        add("Convert to Black & White", #selector(PixelLoupeActions.convertToBlackAndWhite(_:)))
        return menu
    }
}
