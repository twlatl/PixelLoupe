import AppKit
import CoreData

/// Photo ▸ Photo Merge, as in Lightroom: HDR… (⌃H) and Panorama… (⌃M) show a sheet previewing the
/// merge of the selected photos with its options, then Merge runs it in the background with progress
/// (and Cancel) in the Library's bottom bar. Panorama with Previous Settings (⌃⇧M) merges straight
/// away. The merged DNG joins the catalog beside its sources.
extension CatalogWindowController {
    @objc func photoMergeHDR(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, mergeTask == nil else { return }
        let ids = selectedMergeIDs()
        let sources = editing.photoMergeSources(ids)
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

    @objc func photoMergePanorama(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, mergeTask == nil else { return }
        let ids = selectedMergeIDs()
        let sources = editing.photoMergeSources(ids)
        guard sources.count >= 2 else {
            NSSound.beep()
            return
        }
        let sheet = PanoramaMergeSheetController(sources: sources, options: PanoramaMergeOptions.load())
        sheet.onFinish = { [weak self, weak sheet] options in
            guard let self, let sheet, let sheetWindow = sheet.window else { return }
            window.endSheet(sheetWindow)
            mergeSheet = nil
            guard let options else { return }
            options.save()
            startPanoramaMerge(ids, options: options)
        }
        mergeSheet = sheet
        window.beginSheet(sheet.window!)
    }

    /// Lightroom's headless merge: the last settings, no preview.
    @objc func photoMergePanoramaWithPreviousSettings(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, mergeTask == nil else { return }
        let ids = selectedMergeIDs()
        guard editing.photoMergeSources(ids).count >= 2 else {
            NSSound.beep()
            return
        }
        startPanoramaMerge(ids, options: PanoramaMergeOptions.load())
    }

    @objc func cancelPhotoMerge(_ sender: Any?) {
        mergeTask?.cancel()
    }

    /// The selected photos to merge, in grid order (videos left out).
    private func selectedMergeIDs() -> [NSManagedObjectID] {
        let order = state.photoOrder
        return editing.photos(state.selectedPhotoIDs)
            .filter { !$0.isVideo }
            .map(\.objectID)
            .sorted { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
    }

    private func startHDRMerge(_ ids: [NSManagedObjectID], options: HDRMergeOptions) {
        let sources = editing.photoMergeSources(ids)
        startMerge(ids, kind: .hdr, createsStack: options.createsStack) { destination, thumbnails, progress in
            let output = try await HDRMergeRunner.run(
                sources: sources, options: options, destination: destination, thumbnailDirectory: thumbnails, progress: progress
            )
            return (output, nil)
        }
    }

    private func startPanoramaMerge(_ ids: [NSManagedObjectID], options: PanoramaMergeOptions) {
        let sources = editing.photoMergeSources(ids)
        startMerge(ids, kind: .panorama, createsStack: options.createsStack) { destination, thumbnails, progress in
            let result = try await PanoramaMergeRunner.run(
                sources: sources, options: options, destination: destination, thumbnailDirectory: thumbnails, progress: progress
            )
            let note = result.mergedCount < result.photoCount ? "\(result.mergedCount) of \(result.photoCount) photos merged" : nil
            return (result.output, note)
        }
    }

    /// Runs a merge in the background with progress and Cancel in the bottom bar, then adds the result
    /// to the catalog (and selects it). `run` writes the merged file and says what to note when done.
    private func startMerge(
        _ ids: [NSManagedObjectID], kind: PhotoMergeKind, createsStack: Bool,
        run: @escaping @Sendable (URL, URL, @escaping @Sendable (Double) -> Void) async throws -> (PhotoMergeOutput, String?)
    ) {
        guard mergeTask == nil, let destination = editing.mergeDestination(for: ids, kind: kind) else { return }
        let thumbnails = store.thumbnails.directory
        let selectionAtStart = state.selectedPhotoIDs
        let state = state
        state.mergeMessage = nil
        state.mergeKind = kind
        state.mergeStatus = LibraryState.ImportStatus(completed: 0, total: 100)
        mergeTask = Task { [weak self] in
            let result: Result<(PhotoMergeOutput, String?), Error>
            do {
                result = .success(try await run(destination, thumbnails) { fraction in
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
                if case .success(let output) = result { try? FileManager.default.removeItem(at: output.0.url) }
                return
            }
            mergeTask = nil
            state.mergeStatus = nil
            switch result {
            case .success(let (output, note)):
                // Written before Cancel arrived, so it joins the catalog rather than being left on disk.
                let id = editing.addMergedPhoto(output, sources: ids, createsStack: createsStack)
                // Lightroom selects the result, unless the selection has moved on meanwhile.
                if let id, state.selectedPhotoIDs == selectionAtStart { state.selectedPhotoIDs = [id] }
                if let note { showMergeNote(note) }
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

    /// Shows a note about the finished merge in the bottom bar for a few seconds.
    private func showMergeNote(_ note: String) {
        let state = state
        state.mergeMessage = note
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            if state.mergeMessage == note { state.mergeMessage = nil }
        }
    }
}
