import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Develop history and snapshots")
@MainActor
struct DevelopHistoryTests {
    private func makePhoto() throws -> (CatalogStore, Photo) {
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: try TemporaryDirectory().url.appending(path: "H.pixelloupe"))
        let photo = Photo(context: store.viewContext)
        photo.id = UUID()
        photo.fileName = "A.jpg"
        photo.filePath = "/x/A.jpg"
        photo.captureDate = Date(); photo.importDate = Date(); photo.editDate = Date()
        photo.pixelWidth = 6000; photo.pixelHeight = 4000
        return (store, photo)
    }

    private func edit(_ exposure: Double) -> PhotoAdjustments {
        var adjustments = PhotoAdjustments()
        adjustments.light.exposure = exposure
        return adjustments
    }

    // MARK: Recording

    @Test("Steps are numbered in order, named for the edit, and read back")
    func record() throws {
        let (_, photo) = try makePhoto()
        DevelopHistory.record(PhotoAdjustments(), name: "Original", for: photo)
        DevelopHistory.record(edit(0.5), name: "Adjust Exposure", for: photo)
        DevelopHistory.record(edit(1.0), name: "Adjust Exposure", for: photo)
        let steps = DevelopHistory.steps(for: photo)
        #expect(steps.map(\.sequence) == [1, 2, 3] && steps.map(\.name) == ["Original", "Adjust Exposure", "Adjust Exposure"])
        #expect(DevelopHistory.adjustments(of: steps[0]) == PhotoAdjustments())
        #expect(DevelopHistory.adjustments(of: steps[2])?.light.exposure == 1.0)
        // The same settings twice in a row are one step.
        #expect(DevelopHistory.record(edit(1.0), name: "Adjust Exposure", for: photo) == nil)
        #expect(DevelopHistory.steps(for: photo).count == 3)
    }

    @Test("Editing after going back drops the steps after that one")
    func cursor() throws {
        let (_, photo) = try makePhoto()
        for exposure in [0.0, 0.5, 1.0, 1.5] { DevelopHistory.record(edit(exposure), name: "Edit \(exposure)", for: photo) }
        let steps = DevelopHistory.steps(for: photo)
        DevelopHistory.record(edit(0.75), name: "New direction", for: photo, after: steps[1])
        let after = DevelopHistory.steps(for: photo)
        #expect(after.map(\.name) == ["Edit 0.0", "Edit 0.5", "New direction"] && after.map(\.sequence) == [1, 2, 3])
    }

    @Test("A photo keeps at most the maximum number of steps, dropping the oldest")
    func pruning() throws {
        let (_, photo) = try makePhoto()
        let total = DevelopHistory.maximumSteps + 12
        for index in 0..<total { DevelopHistory.record(edit(Double(index) / 1000), name: "Step \(index)", for: photo) }
        let steps = DevelopHistory.steps(for: photo)
        #expect(steps.count == DevelopHistory.maximumSteps)
        #expect(steps.first?.name == "Step 12" && steps.last?.name == "Step \(total - 1)")
    }

    @Test("History is stored compressed, a fraction of the settings' size")
    func compression() throws {
        // A typical step changes a section or two.
        var adjustments = PhotoAdjustments()
        adjustments.light = .init(exposure: 0.35, highlights: -0.4, shadows: 0.3, whites: 0.1, contrast: 0.2, blackPoint: 0.05)
        adjustments.curves.rgb = ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.25, y: 0.2), .init(x: 0.5, y: 0.55), .init(x: 1, y: 1)])
        let raw = try #require(adjustments.encoded)
        let stored = DevelopHistory.store(adjustments)
        #expect(stored.count < raw.count / 3, "\(stored.count) of \(raw.count) bytes")
        #expect(PhotoAdjustments(data: DevelopHistory.decompress(stored)) == adjustments)
        // At this size 56,000 steps are well under the 30 MB budget.
        #expect(stored.count * 56_000 < 30_000_000, "\(stored.count) bytes a step")
        // A heavily edited photo still round trips, and default settings are an empty object.
        var heavy = adjustments
        heavy.presence = .init(texture: 0.1, clarity: 0.2, dehaze: 0.1, vibrance: 0.3, saturation: 0.1)
        heavy.color.shadows = .init(hue: 0.6, amount: 0.3, luminance: 0)
        heavy.crop.rect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        heavy.masks = [.init(components: [.init(shape: .linear(MaskGeometry.defaultLinear()))], settings: .init(exposure: -1))]
        #expect(PhotoAdjustments(data: DevelopHistory.decompress(DevelopHistory.store(heavy))) == heavy)
        #expect(String(decoding: DevelopHistory.decompress(DevelopHistory.store(PhotoAdjustments())), as: UTF8.self) == "{}")
    }

    @Test("Clearing history removes the steps; deleting the photo removes steps and snapshots")
    func clearAndCascade() throws {
        let (store, photo) = try makePhoto()
        for exposure in [0.0, 0.5] { DevelopHistory.record(edit(exposure), name: "Edit", for: photo) }
        DevelopHistory.createSnapshot(named: "Keep", adjustments: edit(1), for: photo)
        store.save()
        DevelopHistory.clearHistory(for: photo)
        store.save()
        #expect(try store.viewContext.count(for: DevelopHistoryStep.fetchRequest()) == 0)
        #expect(try store.viewContext.count(for: DevelopSnapshot.fetchRequest()) == 1, "snapshots stay")
        store.viewContext.delete(photo)
        store.save()
        #expect(try store.viewContext.count(for: DevelopSnapshot.fetchRequest()) == 0)
    }

    // MARK: Snapshots

    @Test("Snapshots are created, read, renamed and listed in order")
    func snapshots() throws {
        let (_, photo) = try makePhoto()
        let early = DevelopHistory.createSnapshot(named: "Warm", adjustments: edit(0.3), for: photo, date: Date(timeIntervalSince1970: 1_000))
        DevelopHistory.createSnapshot(named: "Cool", adjustments: edit(-0.3), for: photo, date: Date(timeIntervalSince1970: 2_000))
        #expect(DevelopHistory.snapshots(for: photo).map(\.name) == ["Warm", "Cool"])
        early?.name = "Warmer"
        #expect(DevelopHistory.snapshots(for: photo).first.flatMap(DevelopHistory.adjustments(of:))?.light.exposure == 0.3)
        #expect(DevelopHistory.snapshots(for: photo).first?.name == "Warmer")
    }

    // MARK: Lightroom

    @Test("A Lightroom step keeps its text compressed and is converted the first time it is read")
    func lazyConversion() throws {
        let (store, photo) = try makePhoto()
        let step = DevelopHistoryStep(context: store.viewContext)
        step.id = UUID(); step.date = Date(); step.name = "Exposure"; step.sequence = 1
        step.lightroomData = DevelopHistory.compress(Data(#"s = { ProcessVersion = "11.0", Exposure2012 = 0.8, Contrast2012 = 20 }"#.utf8))
        step.photo = photo
        #expect(step.data == nil)
        let converted = try #require(DevelopHistory.adjustments(of: step))
        #expect(converted.light.exposure == 0.8 && converted.light.contrast == 0.2)
        #expect(step.data != nil && step.lightroomData == nil, "converted once, and the text dropped")
        #expect(DevelopHistory.adjustments(of: step) == converted)
        // A broken text gives nothing instead of crashing.
        let broken = DevelopHistoryStep(context: store.viewContext)
        broken.id = UUID(); broken.date = Date(); broken.name = "x"; broken.sequence = 2
        broken.lightroomData = DevelopHistory.compress(Data("not lua {{{".utf8))
        broken.photo = photo
        #expect(DevelopHistory.adjustments(of: broken) == nil)
    }

    @Test("Converting a step keeps the photo's own rotation")
    func keepsOrientation() throws {
        let (_, photo) = try makePhoto()
        var adjustments = PhotoAdjustments()
        adjustments.orientation = .init(quarterTurns: 1, isMirrored: false)
        photo.adjustments = adjustments
        let converted = try #require(DevelopHistory.convert(lightroomText: "s = { Exposure2012 = 0.2 }", processVersion: "11.0", photo: photo))
        #expect(converted.orientation.quarterTurns == 1 && converted.light.exposure == 0.2)
    }

    // MARK: Import

    private func createHistoryTables(_ fixture: PhotosFixture) throws {
        try fixture.run("""
            CREATE TABLE Adobe_libraryImageDevelopHistoryStep (id_local INTEGER PRIMARY KEY, image INTEGER, name, dateCreated, hasBigData INTEGER DEFAULT 0, text);
            CREATE TABLE Adobe_libraryImageDevelopSnapshot (id_local INTEGER PRIMARY KEY, image INTEGER, name, locked INTEGER DEFAULT 0, hasBigData INTEGER DEFAULT 0, text);
            INSERT INTO Adobe_libraryImageDevelopHistoryStep (image, name, dateCreated, hasBigData, text) VALUES
                (10, 'Import', 610000000.0, 0, 's = { ProcessVersion = "11.0", Exposure2012 = 0 }'),
                (10, 'Exposure +0.50', 610000100.0, 0, 's = { ProcessVersion = "11.0", Exposure2012 = 0.5 }'),
                (10, 'Contrast +20', 610000200.0, 0, 's = { ProcessVersion = "11.0", Exposure2012 = 0.5, Contrast2012 = 20 }'),
                (13, 'Import', 610000300.0, 0, 's = { ProcessVersion = "11.0" }'),
                (13, 'Big one', 610000400.0, 1, NULL),
                (99, 'Orphan', 610000500.0, 0, 's = { }');
            INSERT INTO Adobe_libraryImageDevelopSnapshot (image, name, locked, text) VALUES
                (10, 'Warm', 0, 's = { ProcessVersion = "11.0", Exposure2012 = 0.9 }'), (99, 'Nobody', 0, 's = { }');
            """)
    }

    @Test("The history phase imports steps in order with their dates, and snapshots, lazily converted")
    func importsHistory() async throws {
        let fixture = try PhotosFixture()
        try createHistoryTables(fixture)
        let (store, report) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }, { LightroomHistoryPhase() }])
        let photos = try store.viewContext.fetch(Photo.fetchRequest()).filter { !$0.isVirtualCopy }
        let a = try #require(photos.first { $0.fileName == "A.jpg" })
        let steps = DevelopHistory.steps(for: a)
        #expect(steps.map(\.name) == ["Import", "Exposure +0.50", "Contrast +20"] && steps.map(\.sequence) == [1, 2, 3])
        #expect(steps[1].date == Date(timeIntervalSinceReferenceDate: 610_000_100))
        #expect(steps.allSatisfy { $0.data == nil && $0.lightroomData != nil }, "nothing is converted at import")
        #expect(DevelopHistory.adjustments(of: steps[2])?.light.contrast == 0.2)
        #expect(DevelopHistory.snapshots(for: a).map(\.name) == ["Warm"])
        #expect(DevelopHistory.snapshots(for: a).first.flatMap(DevelopHistory.adjustments(of:))?.light.exposure == 0.9)
        let d = try #require(photos.first { $0.fileName == "D.cr2" })
        #expect(DevelopHistory.steps(for: d).map(\.name) == ["Import"], "a step whose settings live outside the file is skipped")
        #expect(report.imported.contains(.init(title: "Develop history steps", count: 4)) && report.imported.contains(.init(title: "Snapshots", count: 1)))
        #expect(report.warnings.contains { $0.contains("1 history step kept their") || $0.contains("1 history step") })
    }

    @Test("Without the option the history tables are never read; a catalog without them is fine")
    func optional() async throws {
        let fixture = try PhotosFixture()
        try createHistoryTables(fixture)
        let (store, _) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }])
        #expect(try store.viewContext.count(for: DevelopHistoryStep.fetchRequest()) == 0)
        let bare = try PhotosFixture()
        let (bareStore, bareReport) = try await bare.importAll(phases: [{ LightroomPhotosPhase() }, { LightroomHistoryPhase() }])
        #expect(try bareStore.viewContext.count(for: DevelopHistoryStep.fetchRequest()) == 0)
        #expect(bareReport.imported.allSatisfy { !$0.title.contains("history") })
    }

    // MARK: Panel and migration

    @Test("The panel lists steps newest first, marks the current one and reports clicks and edits")
    func panel() {
        let panel = HistoryPanelViewController()
        _ = panel.view
        let steps = (1...3).map { HistoryPanelViewController.StepRow(id: UUID(), name: "Step \($0)", date: Date()) }
        let snapshots = [HistoryPanelViewController.SnapshotRow(id: UUID(), name: "Warm")]
        panel.display(steps: steps, current: nil, snapshots: snapshots)
        #expect(panel.currentStepID == steps.last?.id)
        var selected: [UUID] = [], renamed: [(UUID, String)] = []
        panel.onSelectStep = { selected.append($0) }
        panel.onRenameSnapshot = { renamed.append(($0, $1)) }
        panel.onSelectSnapshot = { selected.append($0) }
        // Newest first: the first row is Step 3.
        let stepTable = tableView(in: panel.view, identifier: "historyList")
        #expect(stepTable?.numberOfRows == 3)
        stepTable?.selectRowIndexes([2], byExtendingSelection: false)   // Step 1
        #expect(selected.last == steps[0].id && panel.currentStepID == steps[0].id)
        let snapshotTable = tableView(in: panel.view, identifier: "snapshotList")
        snapshotTable?.selectRowIndexes([0], byExtendingSelection: false)
        #expect(selected.last == snapshots[0].id && panel.selectedSnapshotID == snapshots[0].id)
    }

    private func tableView(in view: NSView, identifier: String) -> NSTableView? {
        if let table = view as? NSTableView, table.accessibilityIdentifier() == identifier { return table }
        for subview in view.subviews { if let found = tableView(in: subview, identifier: identifier) { return found } }
        return nil
    }

    @Test("Opens a version eleven catalog and adds the history entities")
    func migratesVersionEleven() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "V11.pixelloupe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(Fixtures.referencedInfo).write(to: CatalogPackage.infoURL(in: packageURL))
        let momd = try #require(Bundle(for: Photo.self).url(forResource: "PixelLoupe", withExtension: "momd"))
        let v11 = try #require(NSManagedObjectModel(contentsOf: momd.appending(path: "PixelLoupe 11.mom")))
        #expect(v11.entitiesByName["DevelopHistoryStep"] == nil)
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: v11)
            _ = try coordinator.addPersistentStore(type: .sqlite, at: CatalogPackage.databaseURL(in: packageURL))
            let context = NSManagedObjectContext(.mainQueue)
            context.persistentStoreCoordinator = coordinator
            let photo = NSEntityDescription.insertNewObject(forEntityName: "Photo", into: context)
            photo.setValue(UUID(), forKey: "id")
            photo.setValue("v11.jpg", forKey: "fileName")
            photo.setValue(Date(), forKey: "captureDate"); photo.setValue(Date(), forKey: "importDate"); photo.setValue(Date(), forKey: "editDate")
            try context.save()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }
        let store = try CatalogStore.open(at: packageURL)
        let photo = try #require(try store.viewContext.fetch(Photo.fetchRequest()).first)
        #expect(photo.historySteps.isEmpty && photo.snapshots.isEmpty)
        DevelopHistory.record(PhotoAdjustments(), name: "Original", for: photo)
        store.save()
        #expect(photo.historySteps.count == 1)
    }
}
