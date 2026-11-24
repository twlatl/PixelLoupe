import CoreData
import Foundation
import Testing
@testable import PixelLoupe

/// Catalog Settings ▸ Metadata ▸ Automatically clear history (RAW-309).
@Suite("Automatic history cleanup")
@MainActor
struct HistoryCleanupTests {
    private let calendar = Calendar(identifier: .gregorian)
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    // MARK: Schedule

    @Test func defaultsToNever() {
        let settings = CatalogSettings()
        #expect(settings.historyCleanup == .never)
        #expect(!settings.isHistoryCleanupDue())
        #expect(CatalogSettings.HistoryCleanup.allCases.map(\.title) == [
            "Never", "When PixelLoupe next relaunches", "Every time PixelLoupe relaunches", "Once a month", "Once a year",
        ])
    }

    @Test func nextLaunchRunsOnceThenGoesBackToNever() {
        var settings = CatalogSettings()
        settings.chooseHistoryCleanup(.nextLaunch, now: date(2026, 1, 1))
        #expect(settings.isHistoryCleanupDue(now: date(2026, 1, 1), calendar: calendar))
        settings.historyDidClear(at: date(2026, 1, 2))
        #expect(settings.historyCleanup == .never)
        #expect(settings.lastHistoryCleanup == date(2026, 1, 2))
        #expect(!settings.isHistoryCleanupDue(now: date(2026, 1, 3), calendar: calendar))
    }

    @Test func everyLaunchStaysDue() {
        var settings = CatalogSettings()
        settings.chooseHistoryCleanup(.everyLaunch, now: date(2026, 1, 1))
        settings.historyDidClear(at: date(2026, 1, 2))
        #expect(settings.historyCleanup == .everyLaunch)
        #expect(settings.isHistoryCleanupDue(now: date(2026, 1, 2), calendar: calendar))
    }

    /// Choosing starts the clock, so nothing is cleared at the next launch just because it never has been.
    @Test func monthlyCountsFromChoosingThenFromLastClear() {
        var settings = CatalogSettings()
        settings.chooseHistoryCleanup(.monthly, now: date(2026, 1, 15))
        #expect(!settings.isHistoryCleanupDue(now: date(2026, 1, 16), calendar: calendar))
        #expect(!settings.isHistoryCleanupDue(now: date(2026, 2, 14), calendar: calendar))
        #expect(settings.isHistoryCleanupDue(now: date(2026, 2, 15), calendar: calendar))
        settings.historyDidClear(at: date(2026, 2, 20))
        #expect(!settings.isHistoryCleanupDue(now: date(2026, 3, 19), calendar: calendar))
        #expect(settings.isHistoryCleanupDue(now: date(2026, 3, 20), calendar: calendar))
    }

    @Test func yearlyCountsFromTheLaterOfLastClearAndChoosing() {
        var settings = CatalogSettings()
        settings.chooseHistoryCleanup(.everyLaunch, now: date(2025, 1, 1))
        settings.historyDidClear(at: date(2025, 1, 1))
        // Switching to Once a year later restarts the clock rather than clearing straight away.
        settings.chooseHistoryCleanup(.yearly, now: date(2026, 6, 1))
        #expect(!settings.isHistoryCleanupDue(now: date(2026, 6, 2), calendar: calendar))
        #expect(!settings.isHistoryCleanupDue(now: date(2027, 5, 31), calendar: calendar))
        #expect(settings.isHistoryCleanupDue(now: date(2027, 6, 1), calendar: calendar))
    }

    @Test func roundTripsThroughTheSettingsFile() throws {
        let directory = try TemporaryDirectory()
        var settings = CatalogSettings()
        settings.chooseHistoryCleanup(.yearly, now: date(2026, 3, 1))
        settings.historyDidClear(at: date(2026, 4, 1))
        try settings.save(to: directory.url)
        let loaded = CatalogSettings.load(from: directory.url)
        #expect(loaded == settings)
        #expect(loaded.historyCleanup == .yearly && loaded.lastHistoryCleanup == date(2026, 4, 1))
    }

    @Test func unknownValueReadsAsNever() throws {
        let directory = try TemporaryDirectory()
        let plist = ["historyCleanup": "hourly"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: CatalogPackage.settingsURL(in: directory.url))
        #expect(CatalogSettings.load(from: directory.url).historyCleanup == .never)
    }

    // MARK: Clearing

    private func makeStore() throws -> CatalogStore {
        try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: try TemporaryDirectory().url.appending(path: "H.pixelloupe"))
    }

    private func addPhoto(named name: String, exposure: Double, to store: CatalogStore) -> Photo {
        let photo = Photo(context: store.viewContext)
        photo.id = UUID()
        photo.fileName = name
        photo.filePath = "/x/\(name)"
        photo.captureDate = Date(); photo.importDate = Date(); photo.editDate = Date()
        photo.pixelWidth = 6000; photo.pixelHeight = 4000
        var adjustments = PhotoAdjustments()
        for step in [0.0, exposure / 2, exposure] {
            adjustments.light.exposure = step
            DevelopHistory.record(adjustments, name: "Adjust Exposure", for: photo)
        }
        photo.adjustments = adjustments
        DevelopHistory.createSnapshot(named: "Keep", adjustments: adjustments, for: photo)
        return photo
    }

    @Test func clearingKeepsCurrentSettingsAndSnapshots() async throws {
        let store = try makeStore()
        let a = addPhoto(named: "A.jpg", exposure: 1, to: store)
        let b = addPhoto(named: "B.jpg", exposure: -0.5, to: store)
        store.save()
        store.settings.chooseHistoryCleanup(.nextLaunch)
        store.viewContext.processPendingChanges()
        store.viewContext.undoManager?.removeAllActions()

        await store.clearHistoryIfDue()

        #expect(try store.viewContext.count(for: DevelopHistoryStep.fetchRequest()) == 0)
        #expect(DevelopHistory.steps(for: a).isEmpty && DevelopHistory.steps(for: b).isEmpty)
        #expect(try store.viewContext.count(for: DevelopSnapshot.fetchRequest()) == 2, "snapshots stay")
        #expect(a.adjustments.light.exposure == 1 && b.adjustments.light.exposure == -0.5, "current settings stay")
        #expect(store.settings.historyCleanup == .never && store.settings.lastHistoryCleanup != nil)
        #expect(store.viewContext.undoManager?.canUndo == false, "the clear isn't on the undo stack")
        // New edits record history again.
        #expect(DevelopHistory.record(PhotoAdjustments(), name: "Reset", for: a) != nil)
    }

    @Test func nothingIsClearedWhenNotDue() async throws {
        let store = try makeStore()
        _ = addPhoto(named: "A.jpg", exposure: 1, to: store)
        store.save()
        store.settings.chooseHistoryCleanup(.monthly)

        await store.clearHistoryIfDue()

        #expect(try store.viewContext.count(for: DevelopHistoryStep.fetchRequest()) == 3)
        #expect(store.settings.lastHistoryCleanup == nil)
    }
}
