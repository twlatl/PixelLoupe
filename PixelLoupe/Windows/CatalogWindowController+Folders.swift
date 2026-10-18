import AppKit
import SwiftUI

/// The Folders list's context menu (Lightroom's folder actions). Each menu item carries the folder's
/// path as its represented object.
extension CatalogWindowController {
    var folderEditing: FolderEditing { FolderEditing(store: store) }

    private func folderPath(_ sender: Any?) -> String? {
        (sender as? NSMenuItem)?.representedObject as? String
    }

    private func folderName(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// The sheet-free window the folder dialogs attach to.
    private var folderSheetWindow: NSWindow? {
        guard let window, window.attachedSheet == nil else { return nil }
        return window
    }

    /// Asks for a name in a sheet: Create Folder and Rename.
    private func askForFolderName(title: String, button: String, initial: String, completion: @escaping (String) -> Void) {
        guard let window = folderSheetWindow else { return }
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.setAccessibilityLabel("Folder name")
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            completion(field.stringValue)
        }
    }

    // MARK: - Create

    @objc func createFolderInside(_ sender: Any?) {
        guard let path = folderPath(sender) else { return }
        askForFolderName(title: "Create Folder Inside “\(folderName(path))”", button: "Create", initial: "untitled folder") { [weak self] name in
            guard let self else { return }
            do {
                let newPath = try folderEditing.createFolder(named: name, inside: path)
                rootViewController.main.sidebar.reload()
                state.filter.scope = .folder(path: newPath)
            } catch {
                showError(error)
            }
        }
    }

    @objc func createCollectionFromFolder(_ sender: Any?) {
        guard let path = folderPath(sender), let collection = folderEditing.createCollection(from: path) else { return }
        state.filter.scope = .collection(id: collection.id, content: collection.content)
    }

    @objc func createCollectionSetFromFolder(_ sender: Any?) {
        guard let path = folderPath(sender) else { return }
        folderEditing.createCollectionSet(from: path)
    }

    // MARK: - Favorites and labels

    @objc func toggleFolderFavorite(_ sender: Any?) {
        guard let path = folderPath(sender), let folder = folderEditing.folder(at: path) else { return }
        folderEditing.setFavorite(!folder.isFavorite, at: path)
    }

    /// Add Color Label to Folder ▸ (a label); the item's tag is the label.
    @objc func setFolderColorLabel(_ sender: NSMenuItem) {
        guard let path = folderPath(sender), let label = ColorLabel(rawValue: Int16(sender.tag)) else { return }
        folderEditing.setLabel(label, at: path)
    }

    // MARK: - Rename and Remove

    @objc func renameFolder(_ sender: Any?) {
        guard let path = folderPath(sender) else { return }
        askForFolderName(title: "Rename “\(folderName(path))”", button: "Rename", initial: folderName(path)) { [weak self] name in
            guard let self else { return }
            do {
                let newPath = try folderEditing.rename(path, to: name)
                followFolder(from: path, to: newPath)
            } catch {
                showError(error)
            }
        }
    }

    /// Keeps the renamed folder (or one inside it) on screen and expanded as it was.
    func followFolder(from oldPath: String, to newPath: String) {
        rootViewController.main.sidebar.renameExpandedFolders(from: oldPath, to: newPath)
        if case .folder(let shown) = state.filter.scope, shown == oldPath || shown.hasPrefix(oldPath + "/") {
            state.filter.scope = .folder(path: newPath + String(shown.dropFirst(oldPath.count)))
        }
    }

    @objc func removeFolder(_ sender: Any?) {
        guard let path = folderPath(sender), let window = folderSheetWindow else { return }
        let count = folderEditing.photoCount(in: path)
        let alert = NSAlert()
        alert.messageText = "Remove the folder “\(path)”? This folder contains \(count.formatted()) photo\(count == 1 ? "" : "s")."
        alert.informativeText = "If you continue, these photos will be removed from the PixelLoupe catalog but the folder and files will remain on disk."
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if case .folder(let shown) = state.filter.scope, shown == path || shown.hasPrefix(path + "/") {
                state.filter.scope = .allPhotos
            }
            folderEditing.remove(path)
        }
    }

    // MARK: - Parents

    @objc func hideFolderParent(_ sender: Any?) {
        guard let path = folderPath(sender) else { return }
        if case .folder(let shown) = state.filter.scope, shown == path { state.filter.scope = .allPhotos }
        folderEditing.hideParent(path)
    }

    @objc func showFolderParent(_ sender: Any?) {
        guard let path = folderPath(sender) else { return }
        folderEditing.showParent(path)
    }

    // MARK: - Synchronize

    @objc func synchronizeFolder(_ sender: Any?) {
        guard let path = folderPath(sender), let window = folderSheetWindow else { return }
        let model = SynchronizeFolderModel(folderName: folderName(path))
        let sheet = NSHostingController(rootView: SynchronizeFolderView(model: model))
        let planning = Task { [store] in
            let plan = await FolderSync.plan(folder: path, info: store.info, context: store.newBackgroundContext())
            if !Task.isCancelled { model.plan = plan }
        }
        model.onCancel = { [weak sheet] in
            planning.cancel()
            sheet?.dismiss(nil)
        }
        model.onShowMissing = { [weak self, weak sheet] in
            sheet?.dismiss(nil)
            guard let self, let missing = model.plan?.missing else { return }
            state.mode = .library
            state.presentation = .grid
            state.filter.scope = .folder(path: path)
            state.selectedPhotoIDs = missing
        }
        model.onSynchronize = { [weak self, weak sheet] model in
            sheet?.dismiss(nil)
            guard let self, let plan = model.plan else { return }
            synchronize(path, plan: plan, model: model)
        }
        window.contentViewController?.presentAsSheet(sheet)
        lastSynchronizeModel = model
    }

    private func synchronize(_ path: String, plan: FolderSync.Plan, model: SynchronizeFolderModel) {
        Task { [weak self] in
            guard let self else { return }
            let context = store.viewContext
            let updates = model.scansMetadata ? await FolderSync.readUpdates(plan.changed, in: context) : []
            // Removing and updating are one undo step.
            if (model.removesMissing && !plan.missing.isEmpty) || !updates.isEmpty {
                if model.removesMissing {
                    for id in plan.missing { if let photo = try? context.existingObject(with: id) { context.delete(photo) } }
                }
                FolderSync.apply(updates, in: context)
                context.undoManager?.setActionName("Synchronize Folder")
                store.save()
                store.availability.refresh()
            }

            guard model.importsNew, !plan.newFiles.isEmpty else { return }
            if model.showsImportDialog {
                showImportWindow(source: ImportWindowController.Source(urls: [URL(filePath: path, directoryHint: .isDirectory)]))
                importWindowController?.addInPlace()
            } else {
                let candidates = await ImportService.readCandidates(plan.newFiles)
                runImport(candidates, transfer: .add, destination: ImportSettings.defaults(for: store.info).destination)
            }
        }
    }

    // MARK: - Locations

    @objc func importToFolder(_ sender: Any?) {
        guard let path = folderPath(sender) else { return }
        showImportWindow(source: nil)
        importWindowController?.copyInto(URL(filePath: path, directoryHint: .isDirectory))
    }

    @objc func exportFolderAsCatalog(_ sender: Any?) {
        guard let path = folderPath(sender), let window = folderSheetWindow else { return }
        let panel = NSSavePanel()
        panel.title = "Export as Catalog"
        panel.nameFieldLabel = "Save As:"
        panel.nameFieldStringValue = folderName(path)
        panel.prompt = "Export Catalog"
        panel.canCreateDirectories = true
        let accessory = ExportCatalogAccessory(photoCount: folderEditing.photoCount(in: path))
        panel.accessoryView = accessory
        panel.isExtensionHidden = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let options = accessory.options
            Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await CatalogExporter.export(folder: path, from: store, to: url, options: options)
                    reportCatalogExport(result)
                } catch {
                    showError(error)
                }
            }
        }
    }

    private func reportCatalogExport(_ result: CatalogExporter.Result) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Exported \(result.photoCount.formatted()) photo\(result.photoCount == 1 ? "" : "s") as a catalog"
        alert.informativeText = result.failures.isEmpty
            ? "“\(result.catalogURL.lastPathComponent)” is ready to open."
            : "These files couldn’t be copied: " + result.failures.prefix(10).joined(separator: ", ")
                + (result.failures.count > 10 ? " and \(result.failures.count - 10) more." : ".")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            NSWorkspace.shared.activateFileViewerSelecting([result.catalogURL])
        }
    }

    @objc func showFolderInFinder(_ sender: Any?) {
        guard let path = folderPath(sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path, directoryHint: .isDirectory)])
    }

    /// Shows the folder in the Finder with its Get Info window open (Apple Events: macOS asks once
    /// whether PixelLoupe may control the Finder).
    @objc func getFolderInfo(_ sender: Any?) {
        guard let path = folderPath(sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path, directoryHint: .isDirectory)])
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
            tell application "Finder"
                activate
                open information window of (POSIX file "\(escaped)" as alias)
            end tell
            """
        Task.detached {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    /// Enables the folder menu's items; nil for other items.
    func validateFolderItem(_ item: any NSValidatedUserInterfaceItem) -> Bool? {
        guard let action = item.action else { return nil }
        let path = (item as? NSMenuItem)?.representedObject as? String
        switch action {
        case #selector(hideFolderParent(_:)):
            return path.map(folderEditing.canHideParent) ?? false
        case #selector(showFolderParent(_:)):
            return path.map(folderEditing.canShowParent) ?? false
        case #selector(createFolderInside(_:)), #selector(renameFolder(_:)), #selector(synchronizeFolder(_:)),
             #selector(showFolderInFinder(_:)), #selector(getFolderInfo(_:)):
            // These need the folder on disk.
            guard let path, window?.attachedSheet == nil || action == #selector(showFolderInFinder(_:)) else { return false }
            return !store.availability.isOffline(folderPath: path)
        case #selector(importToFolder(_:)):
            guard let path else { return false }
            return importTask == nil && !store.availability.isOffline(folderPath: path)
        case #selector(createCollectionFromFolder(_:)), #selector(createCollectionSetFromFolder(_:)),
             #selector(toggleFolderFavorite(_:)), #selector(setFolderColorLabel(_:)), #selector(removeFolder(_:)),
             #selector(exportFolderAsCatalog(_:)):
            return path != nil && window?.attachedSheet == nil
        default:
            return nil
        }
    }
}
