import CoreData
import Foundation
import Testing
@testable import PixelLoupe

/// Catalog Settings ▸ Backups (RAW-269): the schedule, making backups, and listing, pruning and deleting them.
@Suite("Catalog backups")
@MainActor
struct CatalogBackupTests {
    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: string)!
    }

    /// A zip at `<folder>/<dated>/<name>.zip`.
    private func writeBackup(_ name: String, dated: String, in folder: URL, bytes: Int = 100) throws {
        let directory = folder.appending(path: dated, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: directory.appending(path: name + ".zip"))
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    // MARK: Settings

    @Test func settingsDefaultToWeeklyKeepingTenNextToTheCatalog() throws {
        let settings = CatalogSettings()
        #expect(settings.backupSchedule == .weekly)
        #expect(settings.backupsToKeep == 10)
        #expect(settings.testsBackupIntegrity)
        let package = URL(filePath: "/Photos/Family.pixelloupe", directoryHint: .isDirectory)
        #expect(settings.backupFolder(forCatalogAt: package).path(percentEncoded: false) == "/Photos/Backups/")

        var chosen = settings
        chosen.backupFolderPath = "/Volumes/Backup/Catalogs"
        chosen.backupsToKeep = 3
        chosen.testsBackupIntegrity = false
        chosen.chooseBackupSchedule(.daily)
        #expect(chosen.backupFolder(forCatalogAt: package).path(percentEncoded: false) == "/Volumes/Backup/Catalogs/")
        let directory = try TemporaryDirectory()
        try chosen.save(to: directory.url)
        #expect(CatalogSettings.load(from: directory.url) == chosen)
    }

    @Test func nextExitGoesBackToTheScheduleBeforeIt() {
        var settings = CatalogSettings()
        settings.chooseBackupSchedule(.monthly)
        settings.chooseBackupSchedule(.nextExit)
        #expect(settings.backupSchedule == .nextExit)
        settings.backupDidFinish()
        #expect(settings.backupSchedule == .monthly)

        // Another backup leaves an ordinary schedule alone.
        settings.backupDidFinish()
        #expect(settings.backupSchedule == .monthly)

        // Choosing something else in between forgets it.
        settings.chooseBackupSchedule(.nextExit)
        settings.chooseBackupSchedule(.daily)
        settings.chooseBackupSchedule(.nextExit)
        settings.backupDidFinish()
        #expect(settings.backupSchedule == .daily)
    }

    @Test func aBadKeepCountReadsAsAtLeastOne() throws {
        let directory = try TemporaryDirectory()
        let plist: [String: Any] = ["backupsToKeep": 0, "backupSchedule": "hourly"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: CatalogPackage.settingsURL(in: directory.url))
        let settings = CatalogSettings.load(from: directory.url)
        #expect(settings.backupsToKeep == 1)
        #expect(settings.backupSchedule == .weekly)
    }

    // MARK: Schedule

    @Test func backupsAreDueByTheSchedule() {
        let last = date("2026-11-01 12:00")
        #expect(!CatalogBackup.isDue(.never, lastBackup: nil))
        #expect(CatalogBackup.isDue(.everyExit, lastBackup: .now))
        #expect(CatalogBackup.isDue(.nextExit, lastBackup: .now))
        for schedule in [CatalogSettings.BackupSchedule.daily, .weekly, .monthly] {
            #expect(CatalogBackup.isDue(schedule, lastBackup: nil), "never backed up")
        }
        #expect(!CatalogBackup.isDue(.daily, lastBackup: last, now: date("2026-11-02 11:59")))
        #expect(CatalogBackup.isDue(.daily, lastBackup: last, now: date("2026-11-02 12:00")))
        #expect(!CatalogBackup.isDue(.weekly, lastBackup: last, now: date("2026-11-07 23:00")))
        #expect(CatalogBackup.isDue(.weekly, lastBackup: last, now: date("2026-11-08 12:00")))
        #expect(!CatalogBackup.isDue(.monthly, lastBackup: last, now: date("2026-11-30 12:00")))
        #expect(CatalogBackup.isDue(.monthly, lastBackup: last, now: date("2026-12-01 12:00")))
    }

    // MARK: Listing, pruning, deleting

    @Test func listingShowsOnlyThisCatalogsBackupsNewestFirst() throws {
        let directory = try TemporaryDirectory()
        let folder = directory.url
        try writeBackup("Family", dated: "2026-11-01 0900", in: folder, bytes: 10)
        try writeBackup("Family", dated: "2026-11-03 0900", in: folder, bytes: 20)
        try writeBackup("Family", dated: "2026-11-03 0900 2", in: folder, bytes: 30)
        try writeBackup("Work", dated: "2026-11-04 0900", in: folder)
        try Data(count: 5).write(to: folder.appending(path: "Family.zip"))

        let backups = CatalogBackup.backups(of: "Family", in: folder)
        #expect(backups.map(\.size) == [30, 20, 10])
        #expect(backups.last?.date == date("2026-11-01 09:00"))
        #expect(CatalogBackup.backups(of: "Missing", in: folder.appending(path: "Nowhere")).isEmpty)
    }

    @Test func pruningKeepsTheNewestAndLeavesOtherCatalogsAlone() throws {
        let directory = try TemporaryDirectory()
        let folder = directory.url
        for day in 1...4 { try writeBackup("Family", dated: "2026-11-0\(day) 0900", in: folder) }
        try writeBackup("Work", dated: "2026-11-01 0900", in: folder)

        let removed = CatalogBackup.prune(of: "Family", in: folder, keeping: 2)
        #expect(removed.count == 2)
        #expect(CatalogBackup.backups(of: "Family", in: folder).map(\.date) == [date("2026-11-04 09:00"), date("2026-11-03 09:00")])
        #expect(!exists(folder.appending(path: "2026-11-02 0900")), "an emptied dated folder goes too")
        #expect(exists(folder.appending(path: "2026-11-01 0900/Work.zip")), "another catalog's backup in the same folder stays")
    }

    // MARK: Backing up

    @Test func aBackupIsTheDatabaseAndSettingsAsAPackageThatOpens() async throws {
        let directory = try TemporaryDirectory()
        let package = directory.url.appending(path: "Family.pixelloupe", directoryHint: .isDirectory)
        let store = try CatalogStore.create(at: package, info: Fixtures.referencedInfo)
        let photo = Photo(context: store.viewContext)
        photo.id = UUID()
        photo.fileName = "IMG_1.jpg"
        photo.filePath = "/Photos/IMG_1.jpg"
        photo.fileType = "JPG"
        photo.captureDate = Date()
        photo.importDate = Date()
        photo.editDate = Date()
        try store.viewContext.save()
        store.settings.backupsToKeep = 4
        try Data(count: 1000).write(to: CatalogPackage.thumbnailsURL(in: package).appending(path: "thumb.jpg"))

        let folder = directory.url.appending(path: "Backups", directoryHint: .isDirectory)
        let phases = PhaseRecorder()
        let entry = try await CatalogBackup.backUp(
            package, to: folder, testsIntegrity: true, keeping: 10, now: date("2026-11-08 14:30")
        ) { phases.append($0) }
        #expect(phases.all == [.copying, .checkingIntegrity, .compressing])
        #expect(entry.url.path(percentEncoded: false) == folder.appending(path: "2026-11-08 1430/Family.zip").path(percentEncoded: false))
        #expect(entry.size > 0)
        let listed = CatalogBackup.backups(of: "Family", in: folder)
        #expect(listed.map { $0.url.resolvingSymlinksInPath() } == [entry.url.resolvingSymlinksInPath()])
        #expect(listed.map(\.size) == [entry.size])
        #expect(listed.map(\.date) == [entry.date])

        // Unzipped, it's a catalog with the photo and the settings, without the caches.
        let unzipped = try directory.subdirectory("Unzipped")
        let process = try Process.run(URL(filePath: "/usr/bin/ditto"), arguments: ["-x", "-k", entry.url.path(percentEncoded: false), unzipped.path(percentEncoded: false)])
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let restored = unzipped.appending(path: "Family.pixelloupe", directoryHint: .isDirectory)
        #expect(!exists(CatalogPackage.thumbnailsURL(in: restored).appending(path: "thumb.jpg")))
        let reopened = try CatalogStore.open(at: restored)
        #expect(try reopened.viewContext.count(for: Photo.fetchRequest()) == 1)
        #expect(reopened.settings.backupsToKeep == 4)

        // A second backup in the same minute gets its own folder.
        let second = try await CatalogBackup.backUp(package, to: folder, testsIntegrity: false, keeping: 10, now: date("2026-11-08 14:30"))
        #expect(second.url.deletingLastPathComponent().lastPathComponent == "2026-11-08 1430 2")
    }

    @Test func aDatabaseThatCantBeCopiedLeavesNoBackup() async throws {
        let directory = try TemporaryDirectory()
        let package = try directory.subdirectory("Broken.pixelloupe")
        try Data("not a database, just some bytes that go on for a while".utf8).write(to: CatalogPackage.databaseURL(in: package))
        let folder = directory.url.appending(path: "Backups", directoryHint: .isDirectory)
        await #expect(throws: CatalogBackup.Failure.self) {
            try await CatalogBackup.backUp(package, to: folder, testsIntegrity: true, keeping: 10)
        }
        #expect(CatalogBackup.backups(of: "Broken", in: folder).isEmpty)
    }

    @Test func integrityCheckPassesASoundDatabaseAndFailsAnotherFile() async throws {
        let directory = try TemporaryDirectory()
        let package = directory.url.appending(path: "Family.pixelloupe", directoryHint: .isDirectory)
        _ = try CatalogStore.create(at: package, info: Fixtures.referencedInfo)
        let copy = directory.url.appending(path: "Copy.sqlite")
        try CatalogBackup.vacuum(CatalogPackage.databaseURL(in: package), into: copy)
        #expect(try CatalogBackup.integrityProblems(of: copy).isEmpty)

        let garbage = directory.url.appending(path: "Garbage.sqlite")
        try Data(repeating: 0x5A, count: 8192).write(to: garbage)
        #expect(try !CatalogBackup.integrityProblems(of: garbage).isEmpty)
    }
}

private nonisolated final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [CatalogBackup.Phase] = []

    func append(_ phase: CatalogBackup.Phase) { lock.withLock { phases.append(phase) } }
    var all: [CatalogBackup.Phase] { lock.withLock { phases } }
}
