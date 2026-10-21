import CoreData
import Foundation

/// A photo with a location, as the Map module shows it.
nonisolated struct MapPin: Equatable, Sendable {
    var objectID: NSManagedObjectID
    var photoID: UUID
    var fileName: String
    var coordinate: GPSCoordinate
}

nonisolated enum MapPins {
    /// The photos `filter` shows (the grid's source and Library Filter criteria) that have a location,
    /// in the grid's order. Locations come from the catalog (model v16), so no file is read.
    static func fetch(_ filter: LibraryFilter, in context: NSManagedObjectContext) -> [MapPin] {
        let request = Photo.fetchRequest()
        let located = NSPredicate(format: "hasGPS == YES")
        request.predicate = filter.predicate.map { NSCompoundPredicate(andPredicateWithSubpredicates: [$0, located]) } ?? located
        request.sortDescriptors = filter.sortDescriptors
        request.returnsObjectsAsFaults = false
        request.propertiesToFetch = [
            "id", "fileName", "fileLatitude", "fileLongitude", "locationOverride", "overrideLatitude", "overrideLongitude",
        ]
        let photos = (try? context.fetch(request)) ?? []
        return photos.compactMap { photo in
            photo.location.map { MapPin(objectID: photo.objectID, photoID: photo.id, fileName: photo.fileName, coordinate: $0) }
        }
    }
}
