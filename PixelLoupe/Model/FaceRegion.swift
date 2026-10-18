import CoreData
import CoreGraphics
import Foundation

/// A face found in a photo: where it is, and who (a person keyword) when it has been named.
///
/// The rectangle is in fractions of the photo as shown, origin at the top-left. Regions come from a
/// Lightroom import; a People view can build on them later.
@objc(FaceRegion)
nonisolated final class FaceRegion: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var x: Double
    @NSManaged var y: Double
    @NSManaged var width: Double
    @NSManaged var height: Double
    /// Lightroom's cluster of look-alike faces (0 when none).
    @NSManaged var clusterID: Int32
    @NSManaged var statusValue: Int16
    @NSManaged var person: Tag?
    @NSManaged var photo: Photo?

    enum Status: Int16, Sendable {
        /// Found, and perhaps given a name nobody has confirmed.
        case suggested = 0
        /// A person named it, or accepted the name.
        case confirmed = 1
        /// Marked as not a face worth naming.
        case ignored = 2
    }

    var status: Status {
        get { Status(rawValue: statusValue) ?? .suggested }
        set { statusValue = newValue.rawValue }
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    @nonobjc class func fetchRequest() -> NSFetchRequest<FaceRegion> {
        NSFetchRequest<FaceRegion>(entityName: "FaceRegion")
    }
}
