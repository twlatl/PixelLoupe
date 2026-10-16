import AppKit
import CoreData
import Testing
@testable import PixelLoupe

/// The import window's progress and lock, Previous Import and the summary (RAW-81).
@Suite("Import progress", .serialized)
struct ImportProgressTests {
    @Test func anImportIsNamedByWhoeverStartsIt() async throws {
        let directory = try TemporaryDirectory()
        let card = try directory.subdirectory("Card")
        try Fixtures.writeJPEG(to: card.appending(path: "a.jpg"))
        try Fixtures.writeJPEG(to: card.appending(path: "b.jpg"), captureDate: "2026:10:13 10:00:00")
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "Test.pixelloupe"))
        let service = ImportService(store: store)
        let files = try await service.scan([card]).files.map(\.candidate)
        let first = UUID(), second = UUID()
        _ = try await service.importPhotos([files[0]], importID: first)
        _ = try await service.importPhotos([files[1]], importID: second)

        #expect(Photo.latestImportID(in: store.viewContext) == second)
        var filter = LibraryFilter()
        filter.scope = .previousImport(id: second)
        let request = Photo.fetchRequest()
        request.predicate = filter.predicate
        #expect(try store.viewContext.fetch(request).map(\.fileName) == ["b.jpg"])
    }

    @Test func previousImportShowsAnImportFromItsStart() async throws {
        let directory = try TemporaryDirectory()
        let card = try directory.subdirectory("Card")
        try Fixtures.writeJPEG(to: card.appending(path: "a.jpg"))
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "Test.pixelloupe"))
        let state = LibraryState()
        let sidebar = SidebarViewController(store: store, state: state)
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        let outline = try #require(sidebar.view.descendants.compactMap { $0 as? NSOutlineView }.first)
        func previous() -> SidebarViewController.Item? {
            (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SidebarViewController.Item }
                .first { if case .previousImport = $0.kind { true } else { false } }
        }
        /// The import the row shows.
        func shown() -> UUID? {
            if case .previousImport(let id)? = previous()?.kind { id } else { nil }
        }
        sidebar.reload()
        #expect(previous() != nil && shown() == nil, "nothing imported yet: the row is dimmed")

        // Import clicked: the Library shows Previous Import while it's still empty…
        let id = UUID()
        state.importingID = id
        state.filter.scope = .previousImport(id: id)
        sidebar.reload()
        #expect(shown() == id && previous()?.count == 0)
        #expect(state.filter.scope == .previousImport(id: id), "not reset to All Photographs")

        // …fills as photos come in…
        let files = try await ImportService(store: store).scan([card]).files.map(\.candidate)
        _ = try await ImportService(store: store).importPhotos(files, importID: id)
        sidebar.reload()
        #expect(previous()?.count == 1)
        #expect(outline.item(atRow: outline.selectedRow) as? SidebarViewController.Item === previous())

        // …and stays once it's over.
        state.importingID = nil
        sidebar.reload()
        #expect(state.filter.scope == .previousImport(id: id))
    }

    @Test func importLocksTheWindowUntilItFinishes() async throws {
        let directory = try TemporaryDirectory()
        let card = try directory.subdirectory("Card")
        try Fixtures.writeJPEG(to: card.appending(path: "a.jpg"))
        let info = Fixtures.managedInfo(storage: try directory.subdirectory("Storage"))
        let catalog = directory.url.appending(path: "Test.pixelloupe")
        let store = try CatalogStore.inMemory(info: info, packageURL: catalog)
        let controller = ImportWindowController(service: ImportService(store: store), catalogURL: catalog, info: info, source: .init(urls: [card]))
        var imported = 0
        var cancelled = 0
        controller.onImport = { _, _, _, _, _ in imported += 1 }
        controller.onCancelImport = { cancelled += 1 }
        let content = try #require(controller.window?.contentView)
        let grid = try #require(content.descendant(identifier: "importGrid") as? NSCollectionView)
        let button = try #require(content.descendant(identifier: "importButton") as? NSButton)
        let progress = try #require(content.descendant(identifier: "importProgress") as? NSProgressIndicator)
        let summary = try #require(content.descendant(identifier: "importSummary") as? NSTextField)
        for _ in 0..<200 where grid.numberOfSections == 0 { try await Task.sleep(for: .milliseconds(20)) }

        button.performClick(nil)
        #expect(imported == 1)
        #expect(controller.isImporting)
        #expect(button.isHidden && !progress.isHidden)
        #expect(controller.options.isLocked)
        let shield = try #require(content.descendants.compactMap { $0 as? ImportLockShield }.first)
        #expect(!shield.isHidden)
        #expect(shield.hitTest(NSPoint(x: shield.frame.midX, y: shield.frame.midY)) === shield, "the panes don't take clicks")

        controller.importDidProgress(ImportProgress(completed: 1, total: 1))
        #expect(progress.doubleValue == 1)
        #expect(summary.stringValue == "Importing 1 of 1…")

        // Closing asks first instead of closing.
        let window = try #require(controller.window)
        #expect(controller.windowShouldClose(window) == false)
        window.attachedSheet.map { window.endSheet($0) }

        // Cancel stops the import.
        let cancel = try #require(content.descendants.compactMap { $0 as? NSButton }.first { $0.title == "Cancel" })
        cancel.performClick(nil)
        #expect(cancelled == 1)

        controller.importDidFinish(failures: [])
        #expect(!controller.isImporting)
        #expect(window.isVisible == false)
    }

    @Test func theSummarySaysWhatHappened() {
        var summary = ImportSummary()
        summary.imported = 34
        #expect(CatalogWindowController.importMessage(for: summary) == "Imported 34 photos")
        summary.imported = 1
        summary.skippedDuplicates = 6
        summary.skippedRejected = 2
        summary.failures = ["x"]
        #expect(CatalogWindowController.importMessage(for: summary) == "Imported 1 photo · 6 already in the catalog · 2 rejected left out · 1 failed")
    }

    @Test func overlayShowsMessagesLongerThanMarks() {
        let overlay = MarkOverlayView()
        overlay.show(.message("Imported 3 photos"))
        #expect(overlay.shownMark == .message("Imported 3 photos"))
        #expect(PhotoMark.message("Hi").spokenText == "Hi")
    }
}

private extension NSView {
    func descendant(identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier { return self }
        for subview in subviews {
            if let match = subview.descendant(identifier: identifier) { return match }
        }
        return nil
    }
}
