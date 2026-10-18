import AppKit
import OSLog
import UniformTypeIdentifiers

// The catalog is used from one task at a time (see its documentation); it is handed between the
// summary task, the import task and the main actor, never used by two at once.
extension LightroomCatalog: @unchecked Sendable {}

/// Runs File ▸ Import Lightroom Catalog…: choose the `.lrcat`, read it (offering a snapshot if
/// Lightroom has it open), show what it holds, create the new catalog and import into it with
/// progress and Cancel, then hand the new catalog and the report to `completion`.
final class LightroomImportCoordinator {
    private let parentWindow: NSWindow?
    private let completion: (CatalogStore?, LightroomImportReport?) -> Void
    private let phases: [@Sendable () -> any LightroomImportPhase]

    private var sheet: LightroomImportSheetController?
    private var progressController: LightroomImportProgressController?
    private var summaryTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var catalog: LightroomCatalog?

    private static let logger = Logger(subsystem: "net.pixegen.PixelLoupe", category: "LightroomImport")

    /// `completion` is called once with the new catalog and its report, or with `nil`s if the
    /// import was cancelled or failed.
    init(
        parentWindow: NSWindow?,
        phases: [@Sendable () -> any LightroomImportPhase] = LightroomImporter.defaultPhases,
        completion: @escaping (CatalogStore?, LightroomImportReport?) -> Void
    ) {
        self.parentWindow = parentWindow
        self.phases = phases
        self.completion = completion
    }

    /// Where the open panel starts: `~/Pictures/Lightroom`, where Lightroom keeps catalogs by default.
    static var defaultDirectory: URL? {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        let lightroom = pictures?.appending(path: "Lightroom", directoryHint: .isDirectory)
        if let lightroom, FileManager.default.fileExists(atPath: lightroom.path(percentEncoded: false)) { return lightroom }
        return pictures
    }

    static let catalogType = UTType(filenameExtension: "lrcat") ?? .database

    /// Launch argument (`-PixelLoupeLightroomCatalog <path>`) that skips the open panel, used by UI tests.
    private static let testCatalogKey = "PixelLoupeLightroomCatalog"

    func start() {
        if let path = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[Self.testCatalogKey] as? String {
            open(URL(filePath: path), access: .direct)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Import Lightroom Catalog"
        panel.message = "Choose a Lightroom Classic catalog."
        panel.prompt = "Choose"
        panel.allowedContentTypes = [Self.catalogType]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.defaultDirectory
        guard panel.runModal() == .OK, let url = panel.url else {
            completion(nil, nil)
            return
        }
        open(url, access: .direct)
    }

    // MARK: - Reading the catalog

    @concurrent
    private static func openCatalog(_ url: URL, access: LightroomCatalogAccess) async throws -> LightroomCatalog {
        try LightroomCatalog(url: url, access: access)
    }

    @concurrent
    private static func readSummary(_ catalog: LightroomCatalog) async throws -> LightroomCatalogSummary {
        try catalog.summary()
    }

    @concurrent
    private static func countMissingFiles(_ catalog: LightroomCatalog) async throws -> Int {
        try catalog.countMissingFiles()
    }

    private func open(_ url: URL, access: LightroomCatalogAccess) {
        Task {
            do {
                let catalog = try await Self.openCatalog(url, access: access)
                self.catalog = catalog
                showSummary(of: catalog, from: url)
            } catch LightroomCatalogError.openInLightroom {
                offerSnapshot(of: url)
            } catch {
                report(error)
                completion(nil, nil)
            }
        }
    }

    private func offerSnapshot(of url: URL) {
        let alert = NSAlert()
        alert.messageText = "“\(url.lastPathComponent)” is open in Lightroom Classic"
        alert.informativeText = "Quit Lightroom Classic and try again, or import a snapshot: a copy of the catalog as "
            + "Lightroom has it right now. Lightroom’s own files are not changed."
        alert.addButton(withTitle: "Import Snapshot")
        alert.addButton(withTitle: "Cancel")
        let proceed = { [self] (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn {
                open(url, access: .snapshot)
            } else {
                completion(nil, nil)
            }
        }
        if let parentWindow {
            alert.beginSheetModal(for: parentWindow, completionHandler: proceed)
        } else {
            proceed(alert.runModal())
        }
    }

    private func showSummary(of catalog: LightroomCatalog, from url: URL) {
        let sheet = LightroomImportSheetController(sourceURL: url) { [weak self] request in
            guard let self else { return }
            self.sheet = nil
            if let request {
                self.beginImport(request, sourceURL: url)
            } else {
                self.abandon()
            }
        }
        self.sheet = sheet
        sheet.present(over: parentWindow)

        summaryTask = Task {
            do {
                var summary = try await Self.readSummary(catalog)
                sheet.show(summary)
                summary.missingFiles = try await Self.countMissingFiles(catalog)
                sheet.show(summary)
                self.summary = summary
            } catch is CancellationError {
            } catch {
                report(error)
            }
        }
    }

    private var summary: LightroomCatalogSummary?

    /// Stops the background summary so the catalog isn't read from two tasks.
    private func stopSummary() async {
        summaryTask?.cancel()
        await summaryTask?.value
        summaryTask = nil
    }

    private func abandon() {
        Task {
            await stopSummary()
            catalog?.close()
            catalog = nil
            completion(nil, nil)
        }
    }

    // MARK: - Importing

    private func beginImport(_ request: LightroomImportRequest, sourceURL: URL) {
        importTask = Task { [self] in
            await stopSummary()
            guard let catalog else { return }
            let store: CatalogStore
            do {
                store = try CatalogStore.create(at: request.packageURL, info: request.info)
            } catch {
                report(error)
                catalog.close()
                self.catalog = nil
                completion(nil, nil)
                return
            }

            var summary = self.summary
            if summary == nil { summary = try? catalog.summary() }
            let progress = LightroomImportProgressController(catalogName: sourceURL.deletingPathExtension().lastPathComponent)
            progress.onCancel = { [weak self] in self?.importTask?.cancel() }
            progressController = progress
            progress.present(over: parentWindow)

            do {
                let result = try await LightroomImporter.run(
                    catalog: catalog, sourceName: sourceURL.lastPathComponent, summary: summary ?? LightroomCatalogSummary(),
                    into: store.newBackgroundContext(), packageURL: request.packageURL,
                    phases: request.importsHistory ? phases + [{ LightroomHistoryPhase() }] : phases,
                    progress: { value in Task { @MainActor in progress.update(value) } })
                progress.dismiss()
                progressController = nil
                catalog.close()
                self.catalog = nil
                // Lightroom's own smart collections (Five Stars, Past Month…) came across, so PixelLoupe's
                // starter set would only duplicate them.
                store.viewState.createdDefaultCollections = true
                completion(store, result)
            } catch {
                progress.dismiss()
                progressController = nil
                store.closeAndDelete()
                catalog.close()
                self.catalog = nil
                if !(error is CancellationError) {
                    Self.logger.error("Lightroom import failed: \(error.localizedDescription, privacy: .public)")
                    report(error)
                }
                completion(nil, nil)
            }
        }
    }

    private func report(_ error: Error) {
        let alert = NSAlert(error: error)
        if let parentWindow, parentWindow.attachedSheet == nil {
            alert.beginSheetModal(for: parentWindow)
        } else {
            alert.runModal()
        }
    }
}
