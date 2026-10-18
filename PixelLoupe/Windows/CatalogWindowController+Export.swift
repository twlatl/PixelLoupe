import AppKit

/// File ▸ Export… (⇧⌘E), Export with Previous (⌥⇧⌘E) and Export with Preset, as in Lightroom.
/// Exports run in the background with progress (and Cancel) in the Library's bottom bar.
extension CatalogWindowController {
    private var selectedExportItems: [ExportItem] {
        // Videos aren't exported (there is nothing to render).
        state.selectedPhotoIDs.compactMap { id in
            (try? store.viewContext.existingObject(with: id) as? Photo).flatMap { $0.isVideo ? nil : ExportItem($0) }
        }
    }

    /// ⇧⌘E: the Export dialog for the selected photos.
    @objc func exportPhotos(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, exportTask == nil else { return }
        let items = selectedExportItems
        guard !items.isEmpty else { return }
        let dialog = ExportDialogController(items: items, settings: ExportPresets.shared.previous ?? ExportSettings())
        // Cancel (nil) discards changes; Done keeps them; Export keeps them and exports.
        dialog.onFinish = { [weak self, weak dialog] settings, shouldExport in
            guard let self, let dialog, let sheet = dialog.window else { return }
            window.endSheet(sheet)
            lastExportDialog = nil
            guard let settings else { return }
            ExportPresets.shared.previous = settings
            if shouldExport { startExport(items, settings: settings) }
        }
        lastExportDialog = dialog
        window.beginSheet(dialog.window!)
    }

    /// ⌥⇧⌘E: exports the selection with the last export's settings, without the dialog.
    @objc func exportWithPrevious(_ sender: Any?) {
        guard let settings = ExportPresets.shared.previous else {
            exportPhotos(sender)
            return
        }
        startExport(selectedExportItems, settings: settings)
    }

    /// File ▸ Export with Preset ▸ (a preset).
    @objc func exportWithPreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let preset = ExportPresets.shared.preset(named: name) else { return }
        ExportPresets.shared.previous = preset.settings
        startExport(selectedExportItems, settings: preset.settings)
    }

    @objc func cancelExport(_ sender: Any?) {
        exportTask?.cancel()
    }

    /// Picks the folder (asking when the settings say to), settles existing files, then exports.
    func startExport(_ items: [ExportItem], settings: ExportSettings) {
        guard exportTask == nil, !items.isEmpty, let window else { return }
        chooseFolder(for: settings) { [weak self] folder in
            guard let self else { return }
            let plan = ExportPlan(items: items, settings: settings, folder: folder)
            let conflicts = plan.conflicts
            guard settings.existingFiles == .ask, !conflicts.isEmpty else {
                run(plan.resolving(settings.existingFiles), settings: settings)
                return
            }
            let alert = NSAlert()
            alert.messageText = conflicts.count == 1
                ? "“\(conflicts[0].url.lastPathComponent)” already exists in the export folder."
                : "\(conflicts.count) of the files already exist in the export folder."
            alert.informativeText = "What should be done with the exported photos?"
            alert.addButton(withTitle: "Use Unique Names")
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Skip")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                let rule: ExportSettings.ExistingFiles? = switch response {
                case .alertFirstButtonReturn: .uniqueName
                case .alertSecondButtonReturn: .overwrite
                case .alertThirdButtonReturn: .skip
                default: nil
                }
                if let rule { self?.run(plan.resolving(rule), settings: settings) }
            }
        }
    }

    /// The export folder: the settings' folder, each original's (nil), or one chosen now.
    private func chooseFolder(for settings: ExportSettings, then completion: @escaping (URL?) -> Void) {
        switch settings.destination {
        case .sameFolderAsOriginal:
            completion(nil)
        case .specificFolder:
            completion(URL(filePath: settings.folderPath, directoryHint: .isDirectory))
        case .chooseLater:
            guard let window else { return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Export"
            panel.message = "Choose a folder for the exported photos."
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { completion(url) }
            }
        }
    }

    private func run(_ plan: ExportPlan, settings: ExportSettings) {
        guard !plan.entries.isEmpty else { return }
        let watermark = settings.watermarks && settings.format != .original
            ? WatermarkPresets.shared.preset(named: settings.watermarkName).map {
                PhotoExporter.Watermark(settings: $0.settings, imageURL: $0.settings.imageName.map(WatermarkPresets.shared.imageURL(named:)))
            }
            : nil
        state.exportStatus = LibraryState.ImportStatus(completed: 0, total: plan.entries.count)
        exportTask = Task { [weak self] in
            let result = await PhotoExporter.run(plan, settings: settings, watermark: watermark) { completed, total in
                self?.state.exportStatus = LibraryState.ImportStatus(completed: completed, total: total)
            }
            guard let self else { return }
            exportTask = nil
            state.exportStatus = nil
            finish(result, settings: settings)
        }
    }

    private func finish(_ result: PhotoExporter.Result, settings: ExportSettings) {
        if !result.exported.isEmpty {
            switch settings.afterExport {
            case .nothing:
                break
            case .showInFinder:
                NSWorkspace.shared.activateFileViewerSelecting(result.exported)
            case .openInApplication:
                if let path = settings.applicationPath {
                    NSWorkspace.shared.open(result.exported, withApplicationAt: URL(filePath: path), configuration: NSWorkspace.OpenConfiguration())
                }
            }
        }
        guard !result.failures.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = "\(result.failures.count) photo\(result.failures.count == 1 ? "" : "s") could not be exported."
        alert.informativeText = result.failures.prefix(10).joined(separator: "\n") + (result.failures.count > 10 ? "\n…" : "")
        alert.beginSheetModal(for: window)
    }
}
