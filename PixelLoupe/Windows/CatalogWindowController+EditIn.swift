import AppKit

/// Photo ▸ Edit In, as in Lightroom: Edit in the primary editor (⌘E), the additional editor
/// (⌥⌘E), an additional-editor preset, or Open in Other Application…. Raw photos go as a copy with
/// their PixelLoupe adjustments; for other images a sheet asks what to send. Copies are written in
/// the background with progress in the bottom bar, join the catalog (stacked with the original when
/// Stack With Original is on), and open in the editor. Saves there come back through
/// ``ExternalEditMonitor``.
extension CatalogWindowController {
    enum EditInTarget: Equatable {
        case primary, additional, preset(String), otherApplication
    }

    @objc func editInPrimary(_ sender: Any?) { editIn(.primary) }

    @objc func editInAdditional(_ sender: Any?) { editIn(.additional) }

    @objc func editInPreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        editIn(.preset(name))
    }

    @objc func openInOtherApplication(_ sender: Any?) { editIn(.otherApplication) }

    /// The editor a target uses (Open in Other Application starts from the additional editor's file
    /// options, with no app).
    func editorSettings(for target: EditInTarget) -> ExternalEditorSettings? {
        let preferences = ExternalEditingPreferences.shared
        switch target {
        case .primary: return preferences.primary
        case .additional: return preferences.additional
        case .preset(let name): return preferences.preset(named: name)?.settings
        case .otherApplication:
            var settings = preferences.additional
            settings.applicationPath = nil
            return settings
        }
    }

    /// The selected photos Edit In can send, in grid order.
    var editInPhotos: [Photo] {
        let order = state.photoOrder
        return editing.externalEditPhotos(state.selectedPhotoIDs)
            .sorted { (order.firstIndex(of: $0.objectID) ?? .max) < (order.firstIndex(of: $1.objectID) ?? .max) }
    }

    /// Whether an Edit In command can run now.
    func canEditIn(_ target: EditInTarget) -> Bool {
        guard editInTask == nil, window?.attachedSheet == nil,
              editing.photos(state.selectedPhotoIDs).contains(where: { !$0.isVideo }) else { return false }
        return target == .otherApplication || editorSettings(for: target)?.applicationPath != nil
    }

    func editIn(_ target: EditInTarget) {
        guard let window, canEditIn(target), let settings = editorSettings(for: target) else {
            NSSound.beep()
            return
        }
        let photos = editInPhotos
        if target != .otherApplication, !settings.applicationExists {
            askForMissingApplication(target, settings: settings)
            return
        }
        let ids = photos.map(\.objectID)
        guard target == .otherApplication || photos.contains(where: PhotoEditing.asksWhatToEdit) else {
            startEditIn(ids, choice: .copyWithAdjustments, editor: settings)
            return
        }
        let sheet = EditPhotoSheetController(model: EditPhotoSheetModel(
            settings: settings, choosesApplication: target == .otherApplication, photos: photos
        ))
        sheet.onFinish = { [weak self, weak sheet] model in
            guard let self, let sheet, let sheetWindow = sheet.window else { return }
            window.endSheet(sheetWindow)
            editInSheet = nil
            guard let model, model.settings.applicationPath != nil else { return }
            startEditIn(ids, choice: model.choice, editor: model.settings)
        }
        editInSheet = sheet
        window.beginSheet(sheet.window!)
    }

    /// The editor was moved or deleted: offer to choose it again, then carry on.
    private func askForMissingApplication(_ target: EditInTarget, settings: ExternalEditorSettings) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "“\(settings.applicationName ?? "The external editor")” can’t be found."
        alert.informativeText = "Choose the application to edit photos in. You can also change it in Settings ▸ External Editing."
        alert.addButton(withTitle: "Choose Application…")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            ExternalApplicationChooser.choose(current: nil, attachedTo: window) { [weak self] path in
                let preferences = ExternalEditingPreferences.shared
                switch target {
                case .primary: preferences.primary.applicationPath = path
                case .additional: preferences.additional.applicationPath = path
                case .preset(let name):
                    if let index = preferences.presets.firstIndex(where: { $0.name == name }) {
                        preferences.presets[index].settings.applicationPath = path
                    }
                case .otherApplication: break
                }
                // After the panel's sheet has gone.
                DispatchQueue.main.async { self?.editIn(target) }
            }
        }
    }

    /// Writes the copies, adds them to the catalog and opens everything in the editor.
    func startEditIn(_ ids: [NSManagedObjectID], choice: ExternalEditMode, editor: ExternalEditorSettings) {
        guard editInTask == nil, let applicationURL = editor.applicationURL else { return }
        let preferences = ExternalEditingPreferences.shared
        let settings = editor.exportSettings(naming: preferences.naming)
        let jobs = editing.externalEditJobs(ids, choice: choice, settings: settings)
        guard !jobs.isEmpty else { return }
        let stacks = preferences.stacksWithOriginal
        let collectionID = isShowingCollection ? state.filter.scope.collectionID : nil
        let thumbnails = store.thumbnails.directory
        let selectionAtStart = state.selectedPhotoIDs
        let state = state
        state.editInApplicationName = editor.applicationName ?? ""
        state.editInStatus = LibraryState.ImportStatus(completed: 0, total: jobs.filter(\.makesCopy).count)
        editInTask = Task { [weak self] in
            let result = await ExternalEditRunner.run(jobs, settings: settings, thumbnailDirectory: thumbnails) { completed, total in
                guard state.editInStatus != nil else { return }
                state.editInStatus = LibraryState.ImportStatus(completed: completed, total: total)
            }
            guard let self else {
                // The window closed: don't leave uncataloged copies behind.
                for output in result.outputs { try? FileManager.default.removeItem(at: output.job.url) }
                return
            }
            editInTask = nil
            state.editInStatus = nil
            let added = editing.addExternalEdits(result.outputs, stacksWithOriginal: stacks, collectionID: collectionID)
            // Lightroom selects the copies, unless the selection has moved on meanwhile.
            if !added.isEmpty, state.selectedPhotoIDs == selectionAtStart { state.selectedPhotoIDs = added }

            let written = Set(result.outputs.map(\.job.url))
            let urls = jobs.filter { !$0.makesCopy || written.contains($0.url) }.map(\.url)
            if !urls.isEmpty {
                store.externalEdits.track(urls)
                openInEditor(urls, applicationURL: applicationURL)
            }
            if !result.failures.isEmpty, let window {
                let alert = NSAlert()
                alert.messageText = "\(result.failures.count) photo\(result.failures.count == 1 ? "" : "s") couldn’t be prepared for editing."
                alert.informativeText = result.failures.prefix(10).joined(separator: "\n") + (result.failures.count > 10 ? "\n…" : "")
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    private func openInEditor(_ urls: [URL], applicationURL: URL) {
        Task { [weak self] in
            do {
                _ = try await NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                guard let window = self?.window else { return }
                let alert = NSAlert()
                alert.messageText = "“\(FileManager.default.displayName(atPath: applicationURL.path(percentEncoded: false)))” couldn’t open the photos."
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }
}
