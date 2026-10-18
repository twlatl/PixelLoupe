import AppKit
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Import window", .serialized)
struct ImportWindowTests {
    private func file(_ name: String, date: String, duplicate: Bool = false, addedDuplicate: Bool? = nil, size: Int64 = 1) -> ImportService.ScannedFile {
        let url = URL(filePath: "/Card/DCIM/\(name)")
        var metadata = ImageMetadata()
        metadata.captureDate = Self.date(date)
        return ImportService.ScannedFile(
            candidate: .init(source: .init(url: url, anchor: URL(filePath: "/Card")), metadata: metadata, fileSize: size, fileDate: .distantPast),
            metadata: metadata,
            isDuplicateWhenCopied: duplicate,
            isDuplicateWhenAdded: addedDuplicate ?? duplicate
        )
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return formatter.date(from: text)
    }

    @Test func selectionSortsNumbersAndLeavesDuplicatesUnchecked() {
        var selection = ImportSelection(files: [
            file("C.jpg", date: "2026-10-13T08:00:00", size: 300),
            file("A.cr3", date: "2026-10-12T18:00:00", size: 200),
            file("B.jpg", date: "2026-10-12T09:00:00", duplicate: true, size: 100),
        ])
        let names = { (s: ImportSelection) in s.shown.map { s.files[$0].candidate.source.url.lastPathComponent } }
        #expect(names(selection) == ["B.jpg", "A.cr3", "C.jpg"], "capture time")
        #expect(selection.files.indices.map(selection.number) == [3, 2, 1])
        #expect(selection.checkedCount == 2, "duplicates start unchecked")
        #expect(selection.checkedBytes == 500)
        #expect(selection.checkedCandidates.map(\.source.url.lastPathComponent) == ["A.cr3", "C.jpg"])

        selection.setSort(.fileName)
        #expect(names(selection) == ["A.cr3", "B.jpg", "C.jpg"])
        selection.setSort(.fileType)
        #expect(names(selection) == ["A.cr3", "B.jpg", "C.jpg"])

        selection.setFilter(.new)
        #expect(names(selection) == ["A.cr3", "C.jpg"], "New Photos leaves out what's in the library")
        #expect(selection.number(of: 0) == 3, "numbers count every photo")
    }

    @Test func destinationFoldersGroupsByWhereCopiesGo() {
        let root = URL(filePath: "/Pictures", directoryHint: .isDirectory)
        var selection = ImportSelection(
            files: [file("A.jpg", date: "2026-10-12T09:00:00"), file("B.jpg", date: "2026-10-13T09:00:00"), file("C.jpg", date: "2026-10-12T10:00:00")],
            filter: .destinationFolders,
            destination: ImportDestination(root: root, subfolder: "Trip", layout: .yearAndDate))
        #expect(selection.sections.map(\.title) == ["Trip/2026/2026-10-12", "Trip/2026/2026-10-13"])
        #expect(selection.sections.map(\.items.count) == [2, 1])
        selection.setTransfer(.add)
        #expect(selection.sections.map(\.title) == ["/Card/DCIM/"], "added photos stay in their folder")
    }

    @Test func switchingToAddRechecksByPath() {
        // Copied before (same name, size and time) but not from this path.
        var selection = ImportSelection(files: [file("A.jpg", date: "2026-10-12T09:00:00", duplicate: true, addedDuplicate: false)])
        #expect(!selection.isChecked(0))
        selection.setTransfer(.add)
        #expect(!selection.isDuplicate(0))
        #expect(selection.isChecked(0))
        selection.setTransfer(.copy)
        #expect(!selection.isChecked(0))
    }

    @Test func toggleChecksAllUnlessAllAreChecked() {
        var selection = ImportSelection(files: [
            file("A.jpg", date: "2026-10-12T09:00:00"),
            file("B.jpg", date: "2026-10-12T10:00:00"),
            file("C.jpg", date: "2026-10-12T11:00:00", duplicate: true),
        ])
        selection.toggle([0])
        #expect(!selection.isChecked(0))
        selection.toggle([0, 1])
        #expect(selection.isChecked(0) && selection.isChecked(1))
        selection.toggle([0, 1, 2])
        #expect(!selection.isChecked(0) && !selection.isChecked(1))
        selection.setAll(true)
        #expect(selection.checkedCount == 2, "a duplicate can't be checked")
    }

    @Test func shiftClickChecksOrUnchecksTheRange() {
        var selection = ImportSelection(files: (1...6).map { file("IMG_\($0).jpg", date: "2026-10-12T09:0\($0):00", duplicate: $0 == 4) })
        selection.setAll(false)
        // Click 2, then Shift-click 5: 2 through 5 are checked (4 is in the library and stays unchecked).
        selection.toggle([1])
        selection.checkRange(from: 1, to: 4)
        #expect(selection.files.indices.map(selection.isChecked) == [false, true, true, false, true, false])
        // Shift-click 3 (checked) from 5: 3 through 5 are unchecked.
        selection.checkRange(from: 4, to: 2)
        #expect(selection.files.indices.map(selection.isChecked) == [false, true, false, false, false, false])
        // Backwards from 3 to 1 checks them.
        selection.checkRange(from: 2, to: 0)
        #expect(selection.files.indices.map(selection.isChecked) == [true, true, true, false, false, false])
    }

    @Test func folderLayouts() throws {
        let date = try #require(Self.date("2026-10-05T09:00:00"))
        let root = URL(filePath: "/Pictures", directoryHint: .isDirectory)
        let expected: [ImportFolderLayout: String] = [
            .yearAndDate: "/Pictures/Trip/2026/2026-10-05/",
            .yearAndMonthDay: "/Pictures/Trip/2026/10-05/",
            .yearMonthDay: "/Pictures/Trip/2026/10/05/",
            .date: "/Pictures/Trip/2026-10-05/",
            .yearMonthNameDay: "/Pictures/Trip/2026/\(Calendar.current.standaloneMonthSymbols[9])/05/",
            .oneFolder: "/Pictures/Trip/",
        ]
        for (layout, path) in expected {
            let destination = ImportDestination(root: root, subfolder: "Trip", layout: layout)
            #expect(destination.folder(for: date).path(percentEncoded: false) == path)
        }
        #expect(ImportDestination(root: root, subfolder: "  ", layout: .date).base == root, "a blank subfolder is no subfolder")
    }

    @Test func settingsAreRememberedPerCatalog() throws {
        let defaults = try #require(UserDefaults(suiteName: "ImportWindowTests.settings"))
        defer { defaults.removePersistentDomain(forName: "ImportWindowTests.settings") }
        let storage = URL(filePath: "/Storage", directoryHint: .isDirectory)
        let managed = Fixtures.managedInfo(storage: storage)
        let catalog = URL(filePath: "/Catalogs/A.pixelloupe")

        let initial = ImportSettings.load(for: catalog, info: managed, defaults: defaults)
        #expect(initial.transfer == .copy)
        #expect(initial.destination == ImportDestination(root: storage, subfolder: nil, layout: .yearAndMonthDay))
        #expect(ImportSettings.load(for: catalog, info: Fixtures.referencedInfo, defaults: defaults).transfer == .add)

        let changed = ImportSettings(transfer: .copy, destination: .init(root: URL(filePath: "/Pictures"), subfolder: "Trip", layout: .date))
        changed.save(for: catalog, defaults: defaults)
        #expect(ImportSettings.load(for: catalog, info: managed, defaults: defaults) == changed)
        #expect(ImportSettings.load(for: URL(filePath: "/Catalogs/B.pixelloupe"), info: managed, defaults: defaults) == initial)
    }

    @Test func copyIntoAChosenDestinationFromAReferencedCatalog() async throws {
        let directory = try TemporaryDirectory()
        let card = try directory.subdirectory("Card/DCIM")
        let pictures = try directory.subdirectory("Pictures")
        try Fixtures.writeJPEG(to: card.appending(path: "IMG_0001.jpg"))
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "Test.pixelloupe"))
        let service = ImportService(store: store)
        let destination = ImportDestination(root: pictures, subfolder: "Trip", layout: .yearAndDate)

        let scan = try await service.scan([card])
        let summary = try await service.importPhotos(scan.files.map(\.candidate), transfer: .copy, destination: destination)
        #expect(summary.imported == 1)
        let photo = try #require(try store.viewContext.fetch(Photo.fetchRequest()).first)
        let root = pictures.path(percentEncoded: false).trimmingSuffix("/")
        #expect(photo.filePath == "\(root)/Trip/2026/2026-10-12/IMG_0001.jpg")
        #expect(FileManager.default.fileExists(atPath: photo.filePath))
        #expect(photo.folder?.path == "\(root)/Trip/2026/2026-10-12")

        // The same card again: a duplicate when copied, but not when added (that path isn't in the catalog).
        let again = try await service.scan([card])
        #expect(again.files.map(\.isDuplicateWhenCopied) == [true])
        #expect(again.files.map(\.isDuplicateWhenAdded) == [false])
    }

    @Test func addInPlaceFromAManagedCatalog() async throws {
        let directory = try TemporaryDirectory()
        let folder = try directory.subdirectory("Folder")
        let storage = try directory.subdirectory("Storage")
        let original = try Fixtures.writeJPEG(to: folder.appending(path: "a.jpg"))
        let store = try CatalogStore.inMemory(info: Fixtures.managedInfo(storage: storage), packageURL: directory.url.appending(path: "Test.pixelloupe"))
        let service = ImportService(store: store)

        let scan = try await service.scan([folder])
        _ = try await service.importPhotos(scan.files.map(\.candidate), transfer: .add)
        let photo = try #require(try store.viewContext.fetch(Photo.fetchRequest()).first)
        #expect(photo.filePath == original.path(percentEncoded: false))
        #expect(try FileManager.default.contentsOfDirectory(atPath: storage.path(percentEncoded: false)).isEmpty, "nothing copied")
    }

    @Test func scanMarksPhotosAlreadyInTheCatalog() async throws {
        let directory = try TemporaryDirectory()
        let card = try directory.subdirectory("Card/DCIM")
        let storage = try directory.subdirectory("Storage")
        try Fixtures.writeJPEG(to: card.appending(path: "IMG_0001.jpg"))
        try Fixtures.writeJPEG(to: card.appending(path: "IMG_0002.jpg"), captureDate: "2026:10:13 10:00:00")
        try Data("not an image".utf8).write(to: card.appending(path: "IMG_0003.jpg"))

        let store = try CatalogStore.inMemory(info: Fixtures.managedInfo(storage: storage), packageURL: directory.url.appending(path: "Test.pixelloupe"))
        let service = ImportService(store: store)
        let first = try await service.scan([card])
        #expect(first.files.map(\.isDuplicateWhenCopied) == [false, false])
        #expect(first.unreadable == ["IMG_0003.jpg"])
        #expect(try photoCount(in: store) == 0, "scanning imports nothing")

        // Import just the first, as the window does with the checked files.
        let summary = try await service.importPhotos([first.files[0].candidate])
        #expect(summary.imported == 1)

        let second = try await service.scan([card])
        #expect(second.files.map(\.isDuplicateWhenCopied) == [true, false])
    }

    @Test func scanCanLeaveOutSubfolders() async throws {
        let directory = try TemporaryDirectory()
        let folder = try directory.subdirectory("Trip")
        let nested = try directory.subdirectory("Trip/Day 2")
        try Fixtures.writeJPEG(to: folder.appending(path: "a.jpg"))
        try Fixtures.writeJPEG(to: nested.appending(path: "b.jpg"))
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "Test.pixelloupe"))
        let service = ImportService(store: store)

        #expect(try await service.scan([folder]).files.count == 2)
        let shallow = try await service.scan([folder], includeSubfolders: false)
        #expect(shallow.files.map(\.candidate.source.url.lastPathComponent) == ["a.jpg"])
    }

    @Test func recentSourcesKeepTheNewestFoldersThatExist() throws {
        let directory = try TemporaryDirectory()
        let defaults = try #require(UserDefaults(suiteName: "ImportWindowTests.recent"))
        defer { defaults.removePersistentDomain(forName: "ImportWindowTests.recent") }
        let a = try directory.subdirectory("A"), b = try directory.subdirectory("B")
        RecentImportSources.note(a, in: defaults)
        RecentImportSources.note(b, in: defaults)
        RecentImportSources.note(a, in: defaults)
        RecentImportSources.note(directory.url.appending(path: "Gone"), in: defaults)
        #expect(RecentImportSources.folders(in: defaults).map(\.lastPathComponent) == ["A", "B"])

        for index in 0..<RecentImportSources.maximumCount + 2 {
            RecentImportSources.note(try directory.subdirectory("F\(index)"), in: defaults)
        }
        #expect(RecentImportSources.folders(in: defaults).count == RecentImportSources.maximumCount)
    }

    @Test func previewLoaderReadsAFileOutsideTheCatalog() async throws {
        let directory = try TemporaryDirectory()
        let photo = try Fixtures.writeJPEG(to: directory.url.appending(path: "a.jpg"), width: 1200, height: 800)
        let loader = ImportPreviewLoader()
        #expect(loader.cachedImage(for: photo) == nil)
        let image = try #require(await loader.image(for: photo, isVideo: false))
        #expect(max(image.width, image.height) <= ImportPreviewLoader.gridPixelSize)
        #expect(loader.cachedImage(for: photo) != nil)
    }

    @Test func windowListsTheDroppedSourceAndImportsCheckedPhotos() async throws {
        let directory = try TemporaryDirectory()
        let card = try directory.subdirectory("Card")
        let storage = try directory.subdirectory("Storage")
        try Fixtures.writeJPEG(to: card.appending(path: "a.jpg"))
        try Fixtures.writeJPEG(to: card.appending(path: "b.jpg"))
        let info = Fixtures.managedInfo(storage: storage)
        let catalog = directory.url.appending(path: "Test.pixelloupe")
        let store = try CatalogStore.inMemory(info: info, packageURL: catalog)

        let controller = ImportWindowController(service: ImportService(store: store), catalogURL: catalog, info: info, source: .init(urls: [card]))
        var imported: [ImportService.Candidate] = []
        var importedTo: ImportDestination?
        controller.onImport = { candidates, _, destination, _ in
            imported = candidates
            importedTo = destination
        }
        let content = try #require(controller.window?.contentView)
        let grid = try #require(content.firstDescendant(identifier: "importGrid") as? NSCollectionView)
        let button = try #require(content.firstDescendant(identifier: "importButton") as? ProminentButton)
        let summary = try #require(content.firstDescendant(identifier: "importSummary") as? NSTextField)

        for _ in 0..<200 where grid.numberOfSections == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(grid.numberOfItems(inSection: 0) == 2)
        #expect(button.title == "Import 2 Photos")
        // Filled with the accent, or in Monochrome Mode with the monochrome fill, keeping its text.
        button.applyAccent(monochrome: false)
        #expect(button.bezelColor == .controlAccentColor)
        button.applyAccent(monochrome: true)
        #expect(button.bezelColor != .controlAccentColor && button.bezelColor != nil)
        #expect(button.title == "Import 2 Photos")
        #expect(summary.stringValue.hasPrefix("2 photos · "))
        button.performClick(nil)
        #expect(imported.map(\.source.url.lastPathComponent) == ["a.jpg", "b.jpg"])
        #expect(importedTo?.root.standardizedFileURL == storage.standardizedFileURL, "a managed catalog copies into its storage")
        #expect(RecentImportSources.folders().contains(card.standardizedFileURL))
        let eject = try #require(content.firstDescendant(identifier: "importEjectAfterImport") as? NSButton)
        #expect(!eject.isEnabled, "only a card can be ejected after importing")
        controller.close()
    }

    @Test func panesFillTheWindowAndDividersStopAtTheirLimits() throws {
        let directory = try TemporaryDirectory()
        let info = Fixtures.managedInfo(storage: try directory.subdirectory("Storage"))
        let catalog = directory.url.appending(path: "Test.pixelloupe")
        let store = try CatalogStore.inMemory(info: info, packageURL: catalog)
        let controller = ImportWindowController(service: ImportService(store: store), catalogURL: catalog, info: info)
        let window = try #require(controller.window)
        controller.showWindow(nil)
        window.setFrame(NSRect(x: 0, y: 0, width: 1240, height: 800), display: true)
        window.layoutIfNeeded()
        let content = try #require(window.contentView)
        let split = try #require(content.firstDescendant(where: { $0 is NSSplitView }) as? NSSplitView)
        func panes() -> [NSRect] { Array(split.subviews.prefix(3).map(\.frame)) }

        // The panes span the window (they used to float in the middle, leaving a gap at the left).
        #expect(split.frame.width == content.frame.width)
        #expect(panes()[0].minX == 0)
        #expect(panes()[2].maxX == split.bounds.maxX)

        // The sidebar's divider moves, and stops at the sidebar's limits.
        split.setPosition(300, ofDividerAt: 0)
        window.layoutIfNeeded()
        #expect(panes()[0].width == 300)
        split.setPosition(700, ofDividerAt: 0)
        window.layoutIfNeeded()
        #expect(panes()[0].width == 340)
        split.setPosition(20, ofDividerAt: 0)
        window.layoutIfNeeded()
        #expect(panes()[0].width == 200)
        #expect(panes()[0].minX == 0)

        // The inspector's too, staying against the right edge.
        split.setPosition(300, ofDividerAt: 1)
        window.layoutIfNeeded()
        #expect(panes()[1].width >= ImportWindowController.centerMinimumWidth)
        #expect(panes()[2].maxX == split.bounds.maxX)
        #expect(panes()[2].width <= 420)

        // Never narrower than every pane at its narrowest.
        #expect(window.minSize.width >= 200 + ImportWindowController.centerMinimumWidth + 280)
        controller.close()
    }

    @Test func cardsAreVolumesWithADCIMFolder() throws {
        let directory = try TemporaryDirectory()
        let card = try directory.subdirectory("Card")
        _ = try directory.subdirectory("Card/DCIM/100MSDCF")
        let disk = try directory.subdirectory("Disk")
        #expect(ImportCards.isCard(card))
        #expect(!ImportCards.isCard(disk))
        // A folder on the startup disk is never on a card, DCIM or not.
        #expect(!ImportCards.isOnCard([card]))
        #expect(ImportCards.card(containing: card) == nil)
    }

    @Test func cameraNamesReadNaturally() {
        #expect(ImportCards.displayName(make: "SONY", model: "ILCE-7M4") == "Sony ILCE-7M4")
        #expect(ImportCards.displayName(make: "Canon", model: "Canon EOS R5") == "Canon EOS R5")
        #expect(ImportCards.displayName(make: "NIKON CORPORATION", model: "NIKON Z 8") == "NIKON Z 8")
        #expect(ImportCards.displayName(make: "FUJIFILM", model: "X-T5") == "Fujifilm X-T5")
        #expect(ImportCards.displayName(make: "SONY", model: nil) == "Sony")
        #expect(ImportCards.displayName(make: nil, model: nil) == nil)
    }

    @Test func newPhotosAreThoseTheCatalogDoesNotHave() async throws {
        let directory = try TemporaryDirectory()
        let card = try directory.subdirectory("Card/DCIM/100MSDCF")
        let storage = try directory.subdirectory("Storage")
        try Fixtures.writeJPEG(to: card.appending(path: "DSC00001.JPG"))
        let store = try CatalogStore.inMemory(info: Fixtures.managedInfo(storage: storage), packageURL: directory.url.appending(path: "Test.pixelloupe"))
        let service = ImportService(store: store)
        #expect(try await service.hasNewPhotos(in: [card]))
        _ = try await service.importPhotos(from: [card])
        #expect(try await !service.hasNewPhotos(in: [card]), "everything on the card is imported")
        try Fixtures.writeJPEG(to: card.appending(path: "DSC00002.JPG"), captureDate: "2026:10:13 10:00:00")
        #expect(try await service.hasNewPhotos(in: [card]))
    }

    @Test func addIsUnavailableForCardsWithoutForgettingTheChoice() {
        let model = ImportOptionsModel(settings: .init(transfer: .add, destination: .init(root: URL(filePath: "/Pictures"), subfolder: nil, layout: .date)))
        #expect(model.effectiveTransfer == .add)
        model.addUnavailableReason = "card"
        #expect(model.effectiveTransfer == .copy)
        #expect(model.settings.transfer == .add, "Add is still chosen for the next source")
        model.addUnavailableReason = nil
        #expect(model.effectiveTransfer == .add)
    }

    @Test func openingOnCardInsertIsOffByDefault() {
        #expect(!AppSettings.shared.opensImportOnCardInsert)
    }

    private func photoCount(in store: CatalogStore) throws -> Int {
        try store.viewContext.count(for: Photo.fetchRequest())
    }
}

private extension NSView {
    func firstDescendant(identifier: String) -> NSView? {
        firstDescendant { $0.accessibilityIdentifier() == identifier }
    }

    func firstDescendant(where matches: (NSView) -> Bool) -> NSView? {
        if matches(self) { return self }
        for subview in subviews {
            if let match = subview.firstDescendant(where: matches) { return match }
        }
        return nil
    }
}
