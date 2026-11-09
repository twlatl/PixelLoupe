import CoreData
import Foundation
import Testing
@testable import PixelLoupe

/// Catalog Settings ▸ Metadata ▸ Duplicate Detection (RAW-292): hashing originals and marking photos whose original
/// has the same contents as another's.
@Suite("Duplicate detection")
@MainActor
struct DuplicateDetectionTests {
    private struct Setup {
        let directory: TemporaryDirectory
        let store: CatalogStore
        let folder: URL
    }

    private func makeSetup() throws -> Setup {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.create(
            at: directory.url.appending(path: "C.pixelloupe", directoryHint: .isDirectory), info: Fixtures.referencedInfo
        )
        return Setup(directory: directory, store: store, folder: try directory.subdirectory("Photos"))
    }

    /// A photo whose original holds `contents`; nil contents leaves the file missing.
    @discardableResult
    private func addPhoto(_ name: String, contents: String?, to setup: Setup, master: Photo? = nil) throws -> Photo {
        let url = setup.folder.appending(path: name)
        if let contents { try Data(contents.utf8).write(to: url) }
        let photo = Photo(context: setup.store.viewContext)
        photo.id = UUID()
        photo.fileName = name
        photo.filePath = url.path(percentEncoded: false)
        photo.fileType = url.pathExtension.uppercased()
        photo.captureDate = Date()
        photo.importDate = Date()
        photo.editDate = Date()
        photo.master = master
        return photo
    }

    private func duplicates(in store: CatalogStore) throws -> Set<String> {
        var filter = LibraryFilter()
        filter.scope = .duplicates
        let request = Photo.fetchRequest()
        request.predicate = filter.scopePredicate
        return Set(try store.viewContext.fetch(request).map(\.fileName))
    }

    /// Waits for `condition`, which a pass started by a save makes true; fails after a few seconds.
    private func waitFor(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while try !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func hashIsTheSHA256OfTheFileAndNilWhenUnreadable() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "abc.jpg")
        try Data("abc".utf8).write(to: url)
        #expect(await DuplicateDetection.contentHash(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(await DuplicateDetection.contentHash(of: directory.url.appending(path: "missing.jpg")) == nil)
    }

    /// Photos with the same contents are marked; a virtual copy is never hashed or marked; an original that can't be read
    /// stays unhashed so it's tried again.
    @Test func photosWithTheSameContentsAreMarked() async throws {
        let setup = try makeSetup()
        let first = try addPhoto("A.jpg", contents: "same", to: setup)
        try addPhoto("A copy.jpg", contents: "same", to: setup)
        try addPhoto("B.jpg", contents: "different", to: setup)
        let copy = try addPhoto("A.jpg", contents: nil, to: setup, master: first)
        let missing = try addPhoto("Missing.jpg", contents: nil, to: setup)
        try setup.store.viewContext.save()

        let context = setup.store.newBackgroundContext()
        var progress: [(Int, Int)] = []
        #expect(await DuplicateDetection.hashUnhashed(in: context) { progress.append(($0, $1)) } == 3)
        #expect(progress.first ?? (-1, -1) == (0, 4))
        #expect(progress.last ?? (-1, -1) == (4, 4))
        let (marked, changed) = await DuplicateDetection.markDuplicates(in: context, mergingInto: [setup.store.viewContext])
        #expect(marked == 2)
        #expect(changed)
        #expect(try duplicates(in: setup.store) == ["A.jpg", "A copy.jpg"])
        #expect(first.hasDuplicate, "the batch update reaches the view context")
        #expect(copy.contentHash == nil && !copy.hasDuplicate)
        #expect(missing.contentHash == nil)

        // Nothing changed: nothing to hash, and the marks stay as they are.
        #expect(await DuplicateDetection.hashUnhashed(in: context) == 0)
        #expect(await DuplicateDetection.markDuplicates(in: context, mergingInto: [setup.store.viewContext]) == (2, false))
    }

    @Test func removingTheOtherPhotoUnmarksTheOne() async throws {
        let setup = try makeSetup()
        let first = try addPhoto("A.jpg", contents: "same", to: setup)
        let second = try addPhoto("A copy.jpg", contents: "same", to: setup)
        try setup.store.viewContext.save()
        let context = setup.store.newBackgroundContext()
        _ = await DuplicateDetection.hashUnhashed(in: context)
        _ = await DuplicateDetection.markDuplicates(in: context, mergingInto: [setup.store.viewContext])
        #expect(first.hasDuplicate)

        setup.store.viewContext.delete(second)
        try setup.store.viewContext.save()
        #expect(await DuplicateDetection.markDuplicates(in: context, mergingInto: [setup.store.viewContext]) == (0, true))
        #expect(!first.hasDuplicate)
        #expect(try duplicates(in: setup.store).isEmpty)
    }

    /// Turning the setting on starts a pass; photos saved while it's on are hashed and marked, and the grid and sidebar
    /// are told. Turning it off keeps the hashes.
    @Test func theSettingDrivesDetection() async throws {
        let setup = try makeSetup()
        let store = setup.store
        let first = try addPhoto("A.jpg", contents: "same", to: setup)
        try store.viewContext.save()
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: DuplicateDetection.didMarkNotification, object: store, queue: nil
        ) { _ in MainActor.assumeIsolated { notifications += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.settings.detectsDuplicates = true
        #expect(CatalogSettings.load(from: store.packageURL).detectsDuplicates)
        await store.duplicateDetection.waitUntilIdle()
        store.viewContext.refresh(first, mergeChanges: true)
        #expect(first.contentHash != nil)
        #expect(!first.hasDuplicate)
        #expect(notifications == 0, "no mark changed")

        let second = try addPhoto("A copy.jpg", contents: "same", to: setup)
        try store.viewContext.save()
        try await waitFor { second.hasDuplicate && first.hasDuplicate }
        await store.duplicateDetection.waitUntilIdle()
        #expect(notifications >= 1)
        #expect(store.duplicateDetection.progress == nil)

        store.settings.detectsDuplicates = false
        try addPhoto("B.jpg", contents: "different", to: setup)
        try store.viewContext.save()
        try await Task.sleep(for: .milliseconds(200))
        await store.duplicateDetection.waitUntilIdle()
        let request = Photo.fetchRequest()
        request.predicate = NSPredicate(format: "contentHash == nil")
        #expect(try store.viewContext.fetch(request).map(\.fileName) == ["B.jpg"], "off: new photos aren't hashed, old hashes stay")
    }

    @Test func settingDefaultsOffAndRoundTrips() throws {
        #expect(!CatalogSettings().detectsDuplicates)
        let directory = try TemporaryDirectory()
        var settings = CatalogSettings()
        settings.detectsDuplicates = true
        try settings.save(to: directory.url)
        #expect(CatalogSettings.load(from: directory.url).detectsDuplicates)
    }
}
