import AppKit
import CoreData
import MapKit
import Testing
@testable import PixelLoupe

@Suite("Map module")
@MainActor
struct MapModuleTests {
    /// A catalog window with photos in two folders: three located, one cleared, one without a location.
    private func makeWindow() throws -> (CatalogWindowController, [String: NSManagedObjectID], TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let context = store.viewContext
        let trip = Folder(context: context), home = Folder(context: context)
        trip.name = "Trip"; trip.path = "/Photos/Trip"
        home.name = "Home"; home.path = "/Photos/Home"
        var photos: [String: Photo] = [:]
        let places: [(String, Folder, GPSCoordinate?, LocationOverride, Int16)] = [
            ("a.jpg", trip, GPSCoordinate(latitude: 48.8584, longitude: 2.2945), .file, 3),
            ("b.jpg", trip, GPSCoordinate(latitude: 48.8606, longitude: 2.3376), .file, 0),
            ("c.jpg", trip, GPSCoordinate(latitude: 41.8902, longitude: 12.4922), .cleared, 5),
            ("d.jpg", home, nil, .set, 4),
            ("e.jpg", home, nil, .file, 0),
        ]
        for (index, (name, folder, file, kind, rating)) in places.enumerated() {
            let photo = Photo(context: context)
            photo.id = UUID(); photo.fileName = name; photo.filePath = "\(folder.path)/\(name)"; photo.fileType = "JPG"
            photo.captureDate = Date(timeIntervalSince1970: Double(index) * 60); photo.importDate = Date(); photo.editDate = Date()
            photo.folder = folder
            photo.rating = rating
            photo.setFileLocation(file, altitude: nil)
            if kind == .set { photo.setLocationOverride(.set, GPSCoordinate(latitude: 40.7484, longitude: -73.9857)) }
            if kind == .cleared { photo.setLocationOverride(.cleared) }
            photos[name] = photo
        }
        try context.save()
        let controller = CatalogWindowController(store: store)
        controller.showWindow(nil)
        controller.window?.layoutIfNeeded()
        return (controller, photos.mapValues(\.objectID), directory)
    }

    private func showMap(_ controller: CatalogWindowController) async -> MapViewController {
        controller.showMap(nil)
        let map = controller.rootViewController.main.map
        map.reload()
        await map.waitUntilLoaded()
        return map
    }

    private func pinNames(_ map: MapViewController) -> Set<String> {
        Set(map.annotations.values.compactMap(\.title))
    }

    @Test("Pins are the grid's photos with a location: the override's, else the file's")
    func pinsFollowTheFilter() throws {
        let (controller, _, directory) = try makeWindow()
        defer { controller.close(); _ = directory }
        let context = controller.store.viewContext
        var filter = LibraryFilter()
        var pins = MapPins.fetch(filter, in: context)
        #expect(pins.map(\.fileName) == ["a.jpg", "b.jpg", "d.jpg"], "in the grid's order; cleared and unlocated photos have none")
        #expect(pins.last?.coordinate == GPSCoordinate(latitude: 40.7484, longitude: -73.9857), "the typed location")

        filter.scope = .folder(path: "/Photos/Trip")
        #expect(MapPins.fetch(filter, in: context).map(\.fileName) == ["a.jpg", "b.jpg"])
        filter.modes = [.attribute]
        filter.attributes.rating = 3
        pins = MapPins.fetch(filter, in: context)
        #expect(pins.map(\.fileName) == ["a.jpg"], "the Library Filter's criteria too")
    }

    @Test("Map shows the Library's inspector, ⌘3 switches to it, and the right sidebar toggles the inspector")
    func modeAndRightColumn() async throws {
        let (controller, _, directory) = try makeWindow()
        defer { controller.close(); _ = directory }
        #expect(AppMode.allCases.map(\.title) == ["Library", "Develop", "Map"])
        #expect(AppMode.map.showsLibraryInspector && AppMode.library.showsLibraryInspector && !AppMode.develop.showsLibraryInspector)
        let main = controller.rootViewController.main
        let map = await showMap(controller)
        #expect(controller.state.mode == .map && map.view.window != nil)
        #expect(main.inspector.view.window != nil, "the Library's inspector, not Develop's panel")
        #expect(main.isRightSidebarVisible == main.isLibraryInspectorVisible)
        let item = try #require(NSApp.mainMenu?.items.lazy.compactMap { $0.submenu?.items.first { $0.title == "Map" } }.first)
        #expect(item.keyEquivalent == "3" && item.keyEquivalentModifierMask == .command)
    }

    @Test("The map shows the source's located photos, and follows the source and filter")
    func pinsOnTheMap() async throws {
        let (controller, _, directory) = try makeWindow()
        defer { controller.close(); _ = directory }
        let map = await showMap(controller)
        #expect(pinNames(map) == ["a.jpg", "b.jpg", "d.jpg"])
        #expect(map.countLabel.stringValue == "3 photos with a location" && map.emptyLabel.isHidden)

        controller.state.filter.scope = .folder(path: "/Photos/Home")
        try await Task.sleep(for: .milliseconds(100))
        await map.waitUntilLoaded()
        #expect(pinNames(map) == ["d.jpg"])

        // A location removed in the catalog takes its pin away.
        let d = try #require(map.annotations.values.first { $0.title == "d.jpg" })
        let photo = try #require(try controller.store.viewContext.existingObject(with: d.objectID) as? Photo)
        photo.setLocationOverride(.cleared)
        try controller.store.viewContext.save()
        try await Task.sleep(for: .milliseconds(100))
        await map.waitUntilLoaded()
        #expect(map.annotations.isEmpty && !map.emptyLabel.isHidden)
    }

    @Test("Clicking a pin selects its photo, and selecting photos highlights their pins")
    func selection() async throws {
        let (controller, _, directory) = try makeWindow()
        defer { controller.close(); _ = directory }
        let map = await showMap(controller)
        let a = try #require(map.annotations.values.first { $0.title == "a.jpg" })
        let b = try #require(map.annotations.values.first { $0.title == "b.jpg" })

        let view = PhotoMarkerView(annotation: b, reuseIdentifier: nil)
        map.mapView(map.mapView, didSelect: view)
        #expect(controller.state.selectedPhotoIDs == [b.objectID])
        #expect(b.isSelectedPhoto && !a.isSelectedPhoto)

        let cluster = MKClusterAnnotation(memberAnnotations: [b, a])
        map.mapView(map.mapView, didSelect: MKMarkerAnnotationView(annotation: cluster, reuseIdentifier: nil))
        #expect(controller.state.selectedPhotoIDs == [a.objectID, b.objectID], "a cluster's photos, in the grid's order")

        controller.state.selectedPhotoIDs = [a.objectID]
        #expect(a.isSelectedPhoto && !b.isSelectedPhoto, "selecting in the filmstrip")
    }

    @Test("Ratings in Map go to every selected photo")
    func ratingsGoToTheSelection() async throws {
        let (controller, ids, directory) = try makeWindow()
        defer { controller.close(); _ = directory }
        _ = await showMap(controller)
        let selection = try [#require(ids["b.jpg"]), #require(ids["e.jpg"])]
        controller.state.selectedPhotoIDs = selection
        #expect(controller.perform(.rating(2)))
        let ratings = selection.compactMap { (try? controller.store.viewContext.existingObject(with: $0) as? Photo)?.rating }
        #expect(ratings == [2, 2])
    }

    @Test func theZoomSliderIsALogScaleOfTheCameraDistance() {
        #expect(MapViewController.sliderValue(forDistance: MapViewController.farthest) == 0)
        #expect(abs(MapViewController.sliderValue(forDistance: MapViewController.nearest) - 1) < 1e-9)
        for value in [0.0, 0.25, 0.5, 0.9] {
            #expect(abs(MapViewController.sliderValue(forDistance: MapViewController.distance(forSliderValue: value)) - value) < 1e-9)
        }
        #expect(MapViewController.sliderValue(forDistance: 1) == 1, "clamped")
    }
}
