import AppKit

/// Photo ▸ Photo Merge ▸ HDR… (⌃H), as in Lightroom: a sheet previews the merge of the selected
/// exposures with its options, then Merge runs it in the background with progress (and Cancel) in the
/// Library's bottom bar. The merged DNG joins the catalog beside its sources.
extension CatalogWindowController {
    @objc func photoMergeHDR(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, mergeTask == nil else { return }
        let order = state.photoOrder
        let ids = editing.photos(state.selectedPhotoIDs)
            .filter { !$0.isVideo }
            .map(\.objectID)
            .sorted { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
        let sources = editing.hdrMergeSources(ids)
        guard sources.count >= 2 else {
            NSSound.beep()
            return
        }
        let sheet = HDRMergeSheetController(sources: sources, options: HDRMergeOptions.load())
        sheet.onFinish = { [weak self, weak sheet] options in
            guard let self, let sheet, let sheetWindow = sheet.window else { return }
            window.endSheet(sheetWindow)
            mergeSheet = nil
            guard let options else { return }
            options.save()
            startHDRMerge(ids, options: options)
        }
        mergeSheet = sheet
        window.beginSheet(sheet.window!)
    }

    @objc func cancelPhotoMerge(_ sender: Any?) {
        mergeTask?.cancel()
    }

    private func startHDRMerge(_ ids: [NSManagedObjectID], options: HDRMergeOptions) {
        guard mergeTask == nil, let destination = editing.hdrDestination(for: ids) else { return }
        let sources = editing.hdrMergeSources(ids)
        let thumbnails = store.thumbnails.directory
        let selectionAtStart = state.selectedPhotoIDs
        let state = state
        state.mergeStatus = LibraryState.ImportStatus(completed: 0, total: 100)
        mergeTask = Task { [weak self] in
            let result: Result<HDRMergeOutput, Error>
            do {
                result = .success(try await HDRMergeRunner.run(
                    sources: sources, options: options, destination: destination, thumbnailDirectory: thumbnails
                ) { fraction in
                    Task { @MainActor in
                        // Not after it has finished.
                        guard state.mergeStatus != nil else { return }
                        state.mergeStatus = LibraryState.ImportStatus(completed: Int(fraction * 100), total: 100)
                    }
                })
            } catch {
                result = .failure(error)
            }
            guard let self else {
                // The window closed after the file was written: don't leave it behind uncataloged.
                if case .success(let output) = result { try? FileManager.default.removeItem(at: output.url) }
                return
            }
            mergeTask = nil
            state.mergeStatus = nil
            switch result {
            case .success(let output):
                // Written before Cancel arrived, so it joins the catalog rather than being left on disk.
                let id = editing.addMergedHDR(output, sources: ids, createsStack: options.createsStack)
                // Lightroom selects the result, unless the selection has moved on meanwhile.
                if let id, state.selectedPhotoIDs == selectionAtStart { state.selectedPhotoIDs = [id] }
            case .failure(let error) where error is CancellationError:
                break
            case .failure(let error):
                guard let window else { return }
                let alert = NSAlert()
                alert.messageText = "The photos couldn’t be merged."
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }
}
