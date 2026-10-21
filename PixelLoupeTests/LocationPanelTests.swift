import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Location panel")
@MainActor
struct LocationPanelTests {
    private static let camera = GPSCoordinate(latitude: 48.8584, longitude: 2.2945)!
    private static let typed = GPSCoordinate(latitude: 40.7484, longitude: -73.9857)!

    /// Three photos: one the camera located, one with nothing, one whose location was removed.
    private func makeCatalog() throws -> (CatalogStore, [Photo], TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let photos = (0..<3).map { index in
            let photo = Photo(context: store.viewContext)
            photo.id = UUID(); photo.fileName = "IMG_\(index).jpg"; photo.filePath = "/missing/IMG_\(index).jpg"; photo.fileType = "JPG"
            photo.captureDate = Date(); photo.importDate = Date(); photo.editDate = Date()
            return photo
        }
        photos[0].setFileLocation(Self.camera, altitude: nil)
        photos[1].setFileLocation(nil, altitude: nil)
        photos[2].setFileLocation(Self.camera, altitude: nil)
        photos[2].setLocationOverride(.cleared)
        try store.viewContext.save()
        store.viewContext.undoManager?.removeAllActions()
        return (store, photos, directory)
    }

    private func inspector(_ store: CatalogStore, selecting photos: [Photo]) -> (LibraryInspectorViewController, LibraryState) {
        let state = LibraryState()
        state.selectedPhotoIDs = photos.map(\.objectID)
        let controller = LibraryInspectorViewController(store: store, state: state)
        controller.view.frame = NSRect(x: 0, y: 0, width: 300, height: 1200)
        controller.view.layoutSubtreeIfNeeded()
        controller.target = .selectedPhotos
        return (controller, state)
    }

    @Test("It shows the photos' location: one, several, or none")
    func showsTheLocation() throws {
        let (store, photos, directory) = try makeCatalog()
        _ = directory
        let (controller, state) = inspector(store, selecting: [photos[0]])
        let panel = controller.locationPanel
        #expect(panel.locationLabel.stringValue == Self.camera.formatted)
        #expect(panel.removeButton.isEnabled && !panel.applyButton.isEnabled, "nothing found to apply yet")

        state.selectedPhotoIDs = [photos[0].objectID, photos[1].objectID]
        #expect(panel.locationLabel.stringValue == "Multiple locations", "follows the selection")

        let (other, _) = inspector(store, selecting: [photos[1], photos[2]])
        #expect(other.locationPanel.locationLabel.stringValue == "No location" && !other.locationPanel.removeButton.isEnabled)
    }

    @Test("Apply fills in only the photos without a location, as one undoable step")
    func apply() throws {
        let (store, photos, directory) = try makeCatalog()
        _ = directory
        let (controller, _) = inspector(store, selecting: photos)
        controller.locationPanel.lookUp("40.7484, -73.9857")
        #expect(controller.locationPanel.pending == Self.typed && controller.locationPanel.applyButton.isEnabled)
        controller.locationPanel.apply(nil)
        #expect(photos[0].location == Self.camera, "the camera's location stays")
        #expect(photos[1].location == Self.typed && photos[1].hasGPS)
        #expect(photos[2].location == Self.typed, "a removed location counts as none")
        #expect(store.viewContext.undoManager?.undoActionName == "Set Location")
        store.viewContext.undoManager?.undo()
        #expect(photos[1].location == nil && !photos[1].hasGPS && photos[2].locationKind == .cleared)
    }

    @Test("Replace asks before overwriting a camera's location, and then sets every photo")
    func replace() throws {
        let (store, photos, directory) = try makeCatalog()
        _ = directory
        let (controller, _) = inspector(store, selecting: photos)
        var asked: [Int] = []
        controller.confirmReplacingCameraLocations = { asked.append($0); return false }
        controller.setLocation(Self.typed, replacing: true)
        #expect(asked == [1] && photos[0].locationKind == .file && photos[1].location == nil, "cancelled: nothing changes")

        controller.confirmReplacingCameraLocations = { asked.append($0); return true }
        controller.setLocation(Self.typed, replacing: true)
        #expect(photos.allSatisfy { $0.location == Self.typed && $0.hasGPS })
        #expect(photos[0].fileLocation == Self.camera, "the file's location is kept for Revert and Undo")

        // Replacing photos that only have typed locations doesn't ask.
        controller.setLocation(Self.camera, replacing: true)
        #expect(asked == [1, 1] && photos.allSatisfy { $0.location == Self.camera })
    }

    @Test("Remove takes the location away, even the camera's, and Target Photo limits it to one")
    func remove() throws {
        let (store, photos, directory) = try makeCatalog()
        _ = directory
        let (controller, _) = inspector(store, selecting: [photos[0], photos[1]])
        controller.target = .targetPhoto
        controller.locationPanel.remove(nil)
        #expect(photos[0].locationKind == .cleared && !photos[0].hasGPS && photos[0].location == nil)
        #expect(photos[1].locationKind == .file)
        #expect(store.viewContext.undoManager?.undoActionName == "Remove Location")
        #expect(photos[0].metadata[.gps] == "", "the Metadata panel's GPS field shows it removed")
    }

    @Test("↑ ↓ and Return work the places found from the keyboard")
    func keyboard() throws {
        let panel = LocationPanelView()
        let textView = NSTextView()
        #expect(!panel.control(panel.searchField, textView: textView, doCommandBy: #selector(NSResponder.moveDown(_:))),
                "with nothing found, the field keeps its own keys")
        panel.searchField.stringValue = "33°51′ S 151°12′ E"
        #expect(panel.control(panel.searchField, textView: textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(panel.pending?.latitude ?? 0 < -33.8, "typed coordinates are used without a search")
        #expect(!panel.applyButton.isEnabled, "no photos selected")
    }
}
