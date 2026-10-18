import AppKit
import CoreData
import Testing
@testable import PixelLoupe

@Suite("Filmstrip")
struct FilmstripTests {
    let directory: TemporaryDirectory
    let store: CatalogStore
    let state = LibraryState()
    let ids: [NSManagedObjectID]

    init() throws {
        directory = try TemporaryDirectory()
        store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url)
        let context = store.viewContext
        let photos = (0..<5).map { index in
            let photo = Photo(context: context)
            photo.id = UUID()
            photo.fileName = "IMG_\(index).jpg"
            photo.filePath = "/Photos/Trip/IMG_\(index).jpg"
            photo.captureDate = Date()
            photo.importDate = Date()
            photo.editDate = Date()
            return photo
        }
        try context.save()
        ids = photos.map(\.objectID)   // permanent IDs, as the grid's fetches provide
    }

    private func makeFilmstrip() -> (FilmstripViewController, NSCollectionView) {
        let filmstrip = FilmstripViewController(store: store, state: state)
        filmstrip.view.frame = NSRect(x: 0, y: 0, width: 800, height: FilmstripViewController.height)
        filmstrip.view.layoutSubtreeIfNeeded()
        let collection = filmstrip.view.descendants.compactMap { $0 as? NSCollectionView }.first!
        return (filmstrip, collection)
    }

    private func info(_ filmstrip: FilmstripViewController) -> String {
        filmstrip.view.descendants.compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "filmstripInfo" }?.stringValue ?? ""
    }

    @Test func showsTheGridsPhotosInOrder() {
        state.photoOrder = Array(ids.reversed())
        let (_, collection) = makeFilmstrip()
        #expect(collection.numberOfItems(inSection: 0) == 5)
        state.photoOrder = Array(ids.prefix(2))
        #expect(collection.numberOfItems(inSection: 0) == 2, "follows filter changes in the grid")
    }

    @Test func selectionStaysInSync() {
        state.photoOrder = ids
        let (_, collection) = makeFilmstrip()

        state.selectedPhotoIDs = [ids[3]]
        #expect(collection.selectionIndexPaths == [IndexPath(item: 3, section: 0)], "follows the grid")

        collection.selectItems(at: [IndexPath(item: 1, section: 0)], scrollPosition: [])
        collection.delegate?.collectionView?(collection, didSelectItemsAt: [IndexPath(item: 1, section: 0)])
        collection.deselectItems(at: [IndexPath(item: 3, section: 0)])
        collection.delegate?.collectionView?(collection, didDeselectItemsAt: [IndexPath(item: 3, section: 0)])
        #expect(state.selectedPhotoIDs == [ids[1]], "drives the grid")
    }

    @Test func headerShowsFolderCountSelectionAndPath() {
        state.photoOrder = ids
        state.filter.scope = .folder(path: "/Photos/Trip")
        let (filmstrip, _) = makeFilmstrip()
        #expect(info(filmstrip) == "Folder: Trip  ·  5 photos")

        state.selectedPhotoIDs = [ids[2]]
        #expect(info(filmstrip) == "Folder: Trip  ·  5 photos / 1 selected  ·  /Photos/Trip/IMG_2.jpg")

        state.filter.scope = .allPhotos
        #expect(info(filmstrip).hasPrefix("All Photographs  ·  "))
    }

    /// Regression: an outer split-view controller shrank the whole window to the filmstrip header's width.
    @Test func catalogWindowKeepsItsSizeWithTheFilmstrip() throws {
        let controller = CatalogWindowController(store: store)
        let window = try #require(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
        window.layoutIfNeeded()
        #expect(window.frame.width == 1400)
        #expect(window.contentView?.frame.width == 1400)
        let filmstrip = try #require(window.contentView?.descendants.first { $0.accessibilityIdentifier() == "filmstripView" })
        let strip = try #require(filmstrip.descendants.compactMap { $0 as? NSScrollView }.first)
        #expect(filmstrip.frame.width == 1400)
        #expect(strip.frame.height > 90)
        controller.close()
    }

    @Test func steppingMovesThroughTheStrip() {
        state.photoOrder = ids
        state.selectedPhotoIDs = [ids[0]]
        #expect(state.stepSelection(by: 1))
        #expect(state.selectedPhotoIDs == [ids[1]])
    }
}

extension NSView {
    var descendants: [NSView] { subviews + subviews.flatMap(\.descendants) }
}
