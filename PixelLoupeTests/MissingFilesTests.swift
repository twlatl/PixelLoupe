import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Missing files")
@MainActor
struct MissingFilesTests {
    /// A directory's path as the catalog stores it, without the trailing slash `URL` adds.
    private static func path(_ url: URL) -> String { url.path(percentEncoded: false).trimmingSuffix("/") }

    /// A catalog with photos in `Photos/Trip` (two files, one deleted afterwards) and `Photos/Gone`
    /// (a folder that doesn't exist, like an unplugged drive).
    private struct Setup {
        let directory: TemporaryDirectory
        let store: CatalogStore
        let root: URL
        let trip: URL
        let photos: [String: Photo]
        let folders: [String: Folder]

        func fileExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
    }

    private func makeSetup() throws -> Setup {
        let directory = try TemporaryDirectory()
        let root = try directory.subdirectory("Photos")
        let trip = try directory.subdirectory("Photos/Trip")
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let context = store.viewContext
        func folder(_ path: String, parent: Folder?) -> Folder {
            let folder = Folder(context: context)
            folder.path = path
            folder.name = (path as NSString).lastPathComponent
            folder.parent = parent
            return folder
        }
        let rootFolder = folder(Self.path(root), parent: nil)
        let tripFolder = folder(Self.path(trip), parent: rootFolder)
        let goneFolder = folder(Self.path(directory.url.appending(path: "Gone")), parent: nil)

        var photos: [String: Photo] = [:]
        func photo(_ name: String, in folder: Folder, exists: Bool) throws {
            let url = URL(filePath: folder.path).appending(path: name)
            if exists { try Fixtures.writeJPEG(to: url) }
            let photo = Photo(context: context)
            photo.id = UUID()
            photo.fileName = name
            photo.filePath = url.path(percentEncoded: false)
            photo.fileType = "JPG"
            photo.fileSize = exists ? Int64((try? Data(contentsOf: url).count) ?? 0) : 1234
            photo.captureDate = Date()
            photo.importDate = Date()
            photo.editDate = Date()
            photo.folder = folder
            photos[name] = photo
        }
        try photo("A.jpg", in: tripFolder, exists: true)
        try photo("B.jpg", in: tripFolder, exists: true)
        try photo("C.jpg", in: goneFolder, exists: false)
        try context.save()
        // The setup isn't something to undo; and without a run loop, groups must be explicit.
        context.undoManager?.groupsByEvent = false
        context.undoManager?.removeAllActions()
        return Setup(directory: directory, store: store, root: root, trip: trip, photos: photos,
                     folders: ["root": rootFolder, "trip": tripFolder, "gone": goneFolder])
    }

    @Test("Finds missing photos and offline folders in the background, and follows changes")
    func availability() async throws {
        let setup = try makeSetup()
        let availability = setup.store.availability
        #expect(!availability.hasChecked)
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: FileAvailability.didChangeNotification, object: availability, queue: .main) { _ in
            MainActor.assumeIsolated { notifications += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        availability.refresh()
        await availability.waitForRefresh()
        let a = setup.photos["A.jpg"]!, b = setup.photos["B.jpg"]!, c = setup.photos["C.jpg"]!
        #expect(availability.hasChecked)
        #expect(availability.missingPhotoIDs == [c.id])
        #expect(availability.offlineFolderPaths == [setup.folders["gone"]!.path])
        #expect(availability.isMissing(c.id) && !availability.isMissing(a.id))
        #expect(!availability.isOffline(folderPath: Self.path(setup.trip)))
        #expect(notifications == 1)

        // A file disappears from an online folder.
        try FileManager.default.removeItem(at: URL(filePath: b.filePath))
        availability.refresh()
        await availability.waitForRefresh()
        #expect(availability.missingPhotoIDs == [b.id, c.id])

        // The drive comes back: the offline folder's files appear, and the badges clear.
        let gone = URL(filePath: setup.folders["gone"]!.path)
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        try Fixtures.writeJPEG(to: URL(filePath: c.filePath))
        try Fixtures.writeJPEG(to: URL(filePath: b.filePath))
        availability.refresh()
        await availability.waitForRefresh()
        #expect(availability.missingPhotoIDs.isEmpty && availability.offlineFolderPaths.isEmpty)
        #expect(notifications == 3)

        // Nothing changed: no notification.
        availability.refresh()
        await availability.waitForRefresh()
        #expect(notifications == 3)
    }

    @Test("Selecting a folder rechecks just its photos")
    func scopedRefresh() async throws {
        let setup = try makeSetup()
        let availability = setup.store.availability
        availability.refresh()
        await availability.waitForRefresh()
        #expect(availability.missingPhotoIDs == [setup.photos["C.jpg"]!.id])

        let a = setup.photos["A.jpg"]!
        try FileManager.default.removeItem(at: URL(filePath: a.filePath))
        availability.refresh(folderPath: Self.path(setup.trip))
        await availability.waitForRefresh()
        // A is found missing; C, outside the folder, is untouched.
        #expect(availability.missingPhotoIDs == [a.id, setup.photos["C.jpg"]!.id])

        try Fixtures.writeJPEG(to: URL(filePath: a.filePath))
        availability.refresh(folderPath: Self.path(setup.trip))
        await availability.waitForRefresh()
        #expect(availability.missingPhotoIDs == [setup.photos["C.jpg"]!.id])
    }

    @Test("Relinking a moved folder rewrites every photo and folder as one undoable change")
    func relinkFolder() async throws {
        let setup = try makeSetup()
        let store = setup.store
        let oldPath = Self.path(setup.root)
        // Move the files to a new place on disk, as if the library moved to another drive.
        let moved = try setup.directory.subdirectory("NewDrive/Pictures")
        try FileManager.default.removeItem(at: moved)
        try FileManager.default.moveItem(at: setup.root, to: moved)
        let newPath = Self.path(moved)

        let preview = await FileRelinking.preview(folder: oldPath, to: newPath, context: store.newBackgroundContext())
        #expect(preview.total == 2 && preview.found == 2 && preview.missing == 0)
        #expect(preview.sizeMismatches == 0)

        let wrong = await FileRelinking.preview(folder: oldPath, to: Self.path(setup.directory.url), context: store.newBackgroundContext())
        #expect(wrong.total == 2 && wrong.found == 0)

        let rewritten = try FileRelinking.relinkFolder(oldPath, to: newPath, in: store)
        #expect(rewritten == 2)
        let a = setup.photos["A.jpg"]!
        #expect(a.filePath == newPath + "/Trip/A.jpg")
        #expect(setup.folders["root"]!.path == newPath && setup.folders["root"]!.name == "Pictures")
        #expect(setup.folders["trip"]!.path == newPath + "/Trip")
        #expect(setup.folders["trip"]!.name == "Trip")
        // Photos elsewhere are untouched.
        #expect(setup.photos["C.jpg"]!.filePath.hasSuffix("/Gone/C.jpg"))

        await store.availability.waitForRefresh()
        #expect(!store.availability.isMissing(a.id))

        // One undo step puts everything back.
        let undo = try #require(store.viewContext.undoManager)
        #expect(undo.undoActionName == "Find Missing Folder")
        undo.undo()
        #expect(a.filePath == oldPath + "/Trip/A.jpg")
        #expect(setup.folders["root"]!.path == oldPath && setup.folders["root"]!.name == "Photos")
        #expect(setup.folders["trip"]!.path == oldPath + "/Trip")
        undo.redo()
        #expect(a.filePath == newPath + "/Trip/A.jpg")
    }

    @Test("Preview notices files of a different size")
    func sizeMismatch() async throws {
        let setup = try makeSetup()
        let b = setup.photos["B.jpg"]!
        b.fileSize += 99
        try setup.store.viewContext.save()
        let preview = await FileRelinking.preview(
            folder: Self.path(setup.root), to: Self.path(setup.root),
            context: setup.store.newBackgroundContext())
        #expect(preview.total == 2 && preview.found == 2 && preview.sizeMismatches == 1)
    }

    @Test("Locating a photo points it at the chosen file, undoably")
    func locatePhoto() async throws {
        let setup = try makeSetup()
        let c = setup.photos["C.jpg"]!
        let elsewhere = try setup.directory.subdirectory("Found").appending(path: "renamed.jpg")
        try Fixtures.writeJPEG(to: elsewhere)

        try FileRelinking.locate(c, at: elsewhere, in: setup.store)
        #expect(c.filePath == elsewhere.path(percentEncoded: false) && c.fileName == "renamed.jpg" && c.fileSize > 0)
        await setup.store.availability.waitForRefresh()
        #expect(!setup.store.availability.isMissing(c.id))

        let undo = try #require(setup.store.viewContext.undoManager)
        #expect(undo.undoActionName == "Locate Photo")
        undo.undo()
        #expect(c.fileName == "C.jpg" && c.filePath.hasSuffix("/Gone/C.jpg"))
    }

    @Test("Develop and previews decline a missing file instead of failing")
    func developRefusesMissingFiles() async throws {
        let setup = try makeSetup()
        let missing = URL(filePath: setup.photos["C.jpg"]!.filePath)
        #expect(DevelopSource(url: missing) == nil)
        let rendered = await PhotoRenderer.render(missing, adjustments: PhotoAdjustments(), maxPixels: 512)
        #expect(rendered == nil)
    }
}
