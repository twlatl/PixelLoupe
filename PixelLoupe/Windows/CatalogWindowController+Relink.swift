import AppKit

/// Photo ▸ Locate Missing Photo…, and Find Missing Folder… in the Folders list's context menu.
extension CatalogWindowController {
    /// The first selected photo whose file can't be found.
    var missingSelectedPhoto: Photo? {
        state.selectedPhotoIDs
            .compactMap { try? store.viewContext.existingObject(with: $0) as? Photo }
            .first { store.availability.isMissing($0.id) }
    }

    /// Asks for the photo's file and points the photo at it.
    @objc func locateMissingPhoto(_ sender: Any?) {
        guard let photo = missingSelectedPhoto, let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.message = "Locate “\(photo.fileName)”"
        panel.prompt = "Locate"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let parent = photo.fileURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path(percentEncoded: false)) { panel.directoryURL = parent }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try FileRelinking.locate(photo, at: url, in: store)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    /// Context menu on a folder: asks where the folder is now, shows what would be relinked, then
    /// rewrites the paths of every photo under it.
    @objc func findMissingFolder(_ sender: Any?) {
        guard let oldPath = (sender as? NSMenuItem)?.representedObject as? String, let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose the new location of “\((oldPath as NSString).lastPathComponent)”"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let newPath = url.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
            confirmRelink(of: oldPath, to: newPath)
        }
    }

    private func confirmRelink(of oldPath: String, to newPath: String) {
        guard let window else { return }
        let context = store.newBackgroundContext()
        Task { [weak self] in
            let preview = await FileRelinking.preview(folder: oldPath, to: newPath, context: context)
            guard let self else { return }
            let name = (oldPath as NSString).lastPathComponent
            let alert = NSAlert()
            if preview.found == 0 {
                alert.messageText = preview.total == 0 ? "There are no photos to relink" : "None of the photos are there"
                alert.informativeText = preview.total == 0
                    ? "“\(name)” has no photos in this catalog."
                    : "None of the \(preview.total.formatted()) photos in “\(name)” were found in “\((newPath as NSString).lastPathComponent)”. Choose the folder that contains the same files."
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window) { _ in }
                return
            }
            alert.messageText = "Relink “\(name)”?"
            var detail = "\(preview.found.formatted()) of \(preview.total.formatted()) photos were found in “\(newPath)”."
            if preview.missing > 0 { detail += " \(preview.missing.formatted()) will stay missing." }
            if preview.sizeMismatches > 0 {
                detail += " \(preview.sizeMismatches.formatted()) have a different file size from the one in the catalog."
            }
            alert.informativeText = detail + " You can undo this."
            alert.addButton(withTitle: "Relink")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self else { return }
                relink(oldPath, to: newPath)
            }
        }
    }

    private func relink(_ oldPath: String, to newPath: String) {
        do {
            try FileRelinking.relinkFolder(oldPath, to: newPath, in: store)
            // Keep showing the folder if it was the one on screen.
            if case .folder(let path) = state.filter.scope, path == oldPath || path.hasPrefix(oldPath + "/") {
                state.filter.scope = .folder(path: newPath + String(path.dropFirst(oldPath.count)))
            }
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }
}
