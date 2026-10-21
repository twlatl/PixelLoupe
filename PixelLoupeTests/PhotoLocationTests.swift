import CoreData
import Foundation
import ImageIO
import Testing
@testable import PixelLoupe

@Suite("Photo location (model v16)")
@MainActor
struct PhotoLocationTests {
    private func makeStore() throws -> CatalogStore {
        try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: try TemporaryDirectory().url.appending(path: "L.pixelloupe"))
    }

    private func photo(_ name: String, path: String? = nil, in context: NSManagedObjectContext) -> Photo {
        let photo = Photo(context: context)
        photo.id = UUID(); photo.fileName = name; photo.filePath = path ?? "/x/\(name)"
        photo.captureDate = Date(); photo.importDate = Date(); photo.editDate = Date()
        return photo
    }

    private static let sanFrancisco = GPSCoordinate(latitude: 37.774_929, longitude: -122.419_416)!

    // MARK: Coordinates

    @Test("Reads the Metadata panel's degrees-minutes-seconds and decimal degrees, and rejects the rest")
    func parsing() throws {
        let shown = Self.sanFrancisco.formatted
        #expect(shown.hasPrefix("37°46′") && shown.hasSuffix("W"))
        let parsed = try #require(GPSCoordinate(parsing: shown))
        #expect(abs(parsed.latitude - 37.774_929) < 0.000_03 && abs(parsed.longitude + 122.419_416) < 0.000_03)
        #expect(GPSCoordinate(parsing: " 51.5007, -0.1246 ") == GPSCoordinate(latitude: 51.5007, longitude: -0.1246))
        #expect(GPSCoordinate(parsing: "33°51′ S 151°12′ E")?.latitude ?? 0 < -33.8)
        for text in ["", "London", "91, 0", "0, 181", "122°25′ W 37°46′ N", "1, 2, 3"] {
            #expect(GPSCoordinate(parsing: text) == nil, "\(text)")
        }
    }

    // MARK: Override

    @Test("GPS typed into the metadata sets, removes and reverts the location override, and hasGPS follows")
    func overrideThroughMetadata() throws {
        let store = try makeStore()
        let photo = photo("a.jpg", in: store.viewContext)
        photo.setFileLocation(GPSCoordinate(latitude: 48.8584, longitude: 2.2945), altitude: 35)
        #expect(photo.hasGPS && photo.locationKind == .file && photo.metadata[.gps] == nil)

        var metadata = photo.metadata
        metadata[.gps] = Self.sanFrancisco.formatted
        metadata[.title] = "Bridge"
        photo.metadata = metadata
        #expect(photo.locationKind == .set && photo.hasGPS)
        #expect(photo.metadata[.gps] == Self.sanFrancisco.formatted && photo.metadata[.title] == "Bridge")
        #expect(!(String(data: photo.metadataData ?? Data(), encoding: .utf8) ?? "").contains("gps"), "not stored as text")

        metadata = photo.metadata
        metadata[.gps] = ""
        photo.metadata = metadata
        #expect(photo.locationKind == .cleared && !photo.hasGPS && photo.location == nil && photo.metadata[.gps] == "")

        metadata = photo.metadata
        metadata[.gps] = nil
        photo.metadata = metadata
        #expect(photo.locationKind == .file && photo.hasGPS && photo.location == photo.fileLocation)
        #expect(photo.fileAltitude?.doubleValue == 35)
    }

    @Test("Saving other metadata keeps the override at full precision")
    func precision() throws {
        let store = try makeStore()
        let photo = photo("a.jpg", in: store.viewContext)
        photo.setLocationOverride(.set, Self.sanFrancisco)
        var metadata = photo.metadata
        metadata[.caption] = "Fog"
        photo.metadata = metadata
        #expect(photo.overrideLocation == Self.sanFrancisco)
    }

    @Test("Until the file is read, only an override changes hasGPS")
    func unreadFile() throws {
        let store = try makeStore()
        let photo = photo("a.jpg", in: store.viewContext)
        photo.hasGPS = true
        photo.setLocationOverride(.file)
        #expect(photo.hasGPS, "the import's answer stands")
        photo.setLocationOverride(.cleared)
        #expect(!photo.hasGPS)
    }

    @Test("The Has GPS smart collection rule follows the override")
    func smartCollectionRule() throws {
        let store = try makeStore()
        let context = store.viewContext
        let cleared = photo("cleared.jpg", in: context), typed = photo("typed.jpg", in: context), none = photo("none.jpg", in: context)
        cleared.setFileLocation(Self.sanFrancisco, altitude: nil)
        cleared.setLocationOverride(.cleared)
        typed.setFileLocation(nil, altitude: nil)
        typed.setLocationOverride(.set, Self.sanFrancisco)
        none.setFileLocation(nil, altitude: nil)
        try context.save()
        let request = Photo.fetchRequest()
        request.predicate = SmartCollectionRules.Rule(field: .hasGPS, operator: .is, value: "true").predicate(now: Date(), calendar: .current)
        #expect(try context.fetch(request).map(\.fileName) == ["typed.jpg"])
    }

    // MARK: Import and copies

    @Test("Import reads the file's location and altitude")
    func importReadsLocation() throws {
        let directory = try TemporaryDirectory()
        let url = try Fixtures.writeJPEG(to: directory.url.appending(path: "g.jpg"), gps: (-33.8568, 151.2153, -4))
        let metadata = try #require(ImageMetadata.read(from: url))
        #expect(metadata.hasGPS && abs((metadata.location?.latitude ?? 0) + 33.8568) < 0.000_01)
        #expect(metadata.location?.longitude ?? 0 > 151 && metadata.altitude == -4)
        let plain = try #require(ImageMetadata.read(from: try Fixtures.writeJPEG(to: directory.url.appending(path: "p.jpg"))))
        #expect(!plain.hasGPS && plain.altitude == nil)

        let store = try makeStore()
        let photo = photo("g.jpg", in: store.viewContext)
        photo.apply(metadata.shooting)
        #expect(photo.locationRead && photo.hasGPS && photo.fileLocation == metadata.location && photo.fileAltitude?.doubleValue == -4)
    }

    @Test("A virtual copy starts with its master's location and keeps its own override")
    func virtualCopy() throws {
        let store = try makeStore()
        let master = photo("a.jpg", in: store.viewContext)
        master.setFileLocation(Self.sanFrancisco, altitude: nil)
        master.setLocationOverride(.set, GPSCoordinate(latitude: 1, longitude: 2))
        try store.viewContext.save()
        let editing = PhotoEditing(store: store)
        let copy = try #require(editing.photos(editing.createVirtualCopies(of: [master.objectID])).first)
        #expect(copy.fileLocation == Self.sanFrancisco && copy.overrideLocation == master.overrideLocation && copy.hasGPS)
        copy.setLocationOverride(.cleared)
        #expect(master.locationKind == .set && master.hasGPS)
    }

    // MARK: Backfill

    @Test("The backfill reads located files, converts typed GPS text, and leaves unreadable files for later")
    func backfill() async throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore()
        let context = store.viewContext
        let located = photo("g.jpg", path: try Fixtures.writeJPEG(to: directory.url.appending(path: "g.jpg"), gps: (35.6586, 139.7454, 333)).path, in: context)
        located.hasGPS = true
        let plain = photo("p.jpg", in: context)
        let typed = photo("t.jpg", in: context)
        typed.metadataData = try JSONEncoder().encode(PhotoMetadata(values: ["gps": "51.5007, -0.1246", "title": "Clock"]))
        let missing = photo("m.jpg", path: directory.url.appending(path: "gone.jpg").path, in: context)
        missing.hasGPS = true
        try context.save()

        let result = await LocationBackfill.run(in: store.newBackgroundContext(), mergingInto: [context])
        #expect(result.read == 2 && result.unreadable == 1, "the plain photo is marked read without being counted")
        for photo in [located, plain, typed, missing] { context.refresh(photo, mergeChanges: false) }

        #expect(located.locationRead && located.hasGPS && located.fileAltitude?.doubleValue == 333)
        #expect(abs((located.fileLocation?.latitude ?? 0) - 35.6586) < 0.000_01)
        #expect(plain.locationRead && !plain.hasGPS)
        #expect(typed.locationRead && typed.hasGPS && typed.overrideLocation == GPSCoordinate(latitude: 51.5007, longitude: -0.1246))
        #expect(typed.metadata[.title] == "Clock" && typed.metadata.values.keys.sorted() == ["gps", "title"])
        #expect(!(String(data: typed.metadataData ?? Data(), encoding: .utf8) ?? "").contains("gps"))
        #expect(!missing.locationRead && missing.hasGPS, "tried again next time")

        let again = await LocationBackfill.run(in: store.newBackgroundContext())
        #expect(again.read == 0 && again.unreadable == 1)
    }

    @Test("Opens a version fifteen catalog; its typed GPS still shows until the backfill converts it")
    func migratesVersionFifteen() async throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "V15.pixelloupe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(Fixtures.referencedInfo).write(to: CatalogPackage.infoURL(in: packageURL))
        let momd = try #require(Bundle(for: Photo.self).url(forResource: "PixelLoupe", withExtension: "momd"))
        let v15 = try #require(NSManagedObjectModel(contentsOf: momd.appending(path: "PixelLoupe 15.mom")))
        #expect(v15.entitiesByName["Photo"]?.attributesByName["locationOverride"] == nil)
        let typed = Self.sanFrancisco.formatted
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: v15)
            _ = try coordinator.addPersistentStore(type: .sqlite, at: CatalogPackage.databaseURL(in: packageURL))
            let context = NSManagedObjectContext(.mainQueue)
            context.persistentStoreCoordinator = coordinator
            let photo = NSEntityDescription.insertNewObject(forEntityName: "Photo", into: context)
            photo.setValue(UUID(), forKey: "id")
            photo.setValue("v15.jpg", forKey: "fileName")
            photo.setValue("/nowhere/v15.jpg", forKey: "filePath")
            photo.setValue(true, forKey: "hasGPS")
            photo.setValue(try JSONEncoder().encode(PhotoMetadata(values: ["gps": typed])), forKey: "metadataData")
            photo.setValue(Date(), forKey: "captureDate"); photo.setValue(Date(), forKey: "importDate"); photo.setValue(Date(), forKey: "editDate")
            try context.save()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }
        let store = try CatalogStore.open(at: packageURL)
        let photo = try #require(try store.viewContext.fetch(Photo.fetchRequest()).first)
        #expect(!photo.locationRead && photo.locationKind == .file && photo.hasGPS)
        #expect(photo.metadata[.gps] == typed, "the text shows as before")

        _ = await LocationBackfill.run(in: store.newBackgroundContext())
        store.viewContext.refresh(photo, mergeChanges: false)
        #expect(photo.locationKind == .set && photo.metadata[.gps] == typed && photo.hasGPS)
        #expect(!photo.locationRead, "the file is offline, so it's read when it's back")
    }
}
