import CoreData
import CoreGraphics

/// A single image file tracked by a catalog.
@objc(Photo)
nonisolated final class Photo: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var fileName: String
    @NSManaged var filePath: String
    @NSManaged var originalPath: String?
    @NSManaged var dedupeKey: String?
    @NSManaged var fileType: String
    @NSManaged var fileSize: Int64
    @NSManaged var captureDate: Date
    @NSManaged var importDate: Date
    /// The import that added the photo (model v15). Every photo from one import shares it, and the
    /// newest is what Previous Import shows. `nil` for photos from before v15 and for photos made in
    /// the app (merges, Edit In copies).
    @NSManaged var importID: UUID?
    @NSManaged var editDate: Date
    @NSManaged var rating: Int16
    @NSManaged var flag: Int16
    /// Color label (model v6): see ``ColorLabel``. 0 is none.
    @NSManaged var colorLabel: Int16
    /// The name of a label that has no color here, e.g. a custom Lightroom label (model v6).
    @NSManaged var labelText: String?
    @NSManaged var cameraMake: String?
    @NSManaged var cameraModel: String?
    @NSManaged var lensModel: String?
    @NSManaged var pixelWidth: Int32
    @NSManaged var pixelHeight: Int32
    @NSManaged var orientation: Int16
    @NSManaged var adjustmentsData: Data?
    /// ISO speed, or 0 when unknown (model v8). The next few are what smart collections search.
    @NSManaged var iso: Int32
    /// Focal length in millimeters, or 0.
    @NSManaged var focalLength: Double
    /// F-number (2.8 for ƒ/2.8), or 0.
    @NSManaged var aperture: Double
    /// Exposure time in seconds, or 0.
    @NSManaged var shutterSpeed: Double
    /// Whether the photo has a location: its override's, else its file's. Kept up to date by the
    /// location setters (see `PhotoLocation.swift`), for smart collections and the Library Filter.
    @NSManaged var hasGPS: Bool
    /// The location recorded in the file, in degrees and metres (model v16); nil when it has none.
    /// Only meaningful once `locationRead` is set.
    @NSManaged var fileLatitude: NSNumber?
    @NSManaged var fileLongitude: NSNumber?
    @NSManaged var fileAltitude: NSNumber?
    /// Whether the file's location has been read into `fileLatitude`… (model v16). Photos from before
    /// v16 are read by ``LocationBackfill``.
    @NSManaged var locationRead: Bool
    /// A location typed into the catalog (model v16): see ``LocationOverride``.
    @NSManaged var locationOverride: Int16
    @NSManaged var overrideLatitude: NSNumber?
    @NSManaged var overrideLongitude: NSNumber?
    /// Whether the file is a video (shown view-only: poster-frame thumbnail, playable, no Develop; model v11).
    @NSManaged var isVideo: Bool
    /// A video's length in seconds.
    @NSManaged var duration: Double
    /// Extensions of image files that go with this photo (`JPG` for a raw file shot with a JPEG), and
    /// are removed with it. Comma-separated (model v11).
    @NSManaged var sidecarExtensions: String?
    /// Whether the photo's crop or straightening changes its frame. Kept up to date by `adjustments`.
    @NSManaged var isCropped: Bool
    /// Whether the photo is developed in black and white.
    @NSManaged var isBlackAndWhite: Bool
    /// Assisted Culling's scores (model v17; see ``CullingScores``). `cullVersion` is the
    /// ``CullingAnalyzer/version`` that wrote them, 0 when the photo hasn't been analyzed. Scores run
    /// 0–1, and -1 means unknown: no faces for the eye scores, no full-size pixels for focus.
    @NSManaged var cullVersion: Int16
    @NSManaged var cullSubjectFocus: Double
    @NSManaged var cullEyeFocus: Double
    /// The least and most open eyes among the faces counted.
    @NSManaged var cullEyesOpenMin: Double
    @NSManaged var cullEyesOpenMax: Double
    @NSManaged var cullFaceCount: Int16
    @NSManaged var cullExposureIssue: Bool
    @NSManaged var cullMisfire: Bool
    @NSManaged var cullDocument: Bool
    /// Vision's overall aesthetics score mapped to 0–1, for choosing the best of a stack.
    @NSManaged var cullQuality: Double
    /// Whether focus is still to be measured because neither the original nor a Smart Preview could be read.
    @NSManaged var cullFocusPending: Bool
    /// Title, caption, creator and copyright as shown for the photo, for searching (model v8). Kept up
    /// to date by `metadata`, and filled in when a photo is imported.
    @NSManaged var titleText: String?
    @NSManaged var captionText: String?
    @NSManaged var creatorText: String?
    @NSManaged var copyrightText: String?
    /// Metadata entered in PixelLoupe, as JSON (model v3).
    @NSManaged var metadataData: Data?
    /// The Lightroom catalog's `id_global` for photos imported from Lightroom (model v5), for diagnostics
    /// and a possible re-import.
    @NSManaged var lightroomID: String?
    /// Reasons the photo's Lightroom settings were only partly carried over (model v5), as
    /// `|reason|reason|` keys; `nil` when everything came across. See ``LightroomImportReport``.
    @NSManaged var importDifferences: String?
    @NSManaged var folder: Folder?
    /// For a virtual copy, the photo it is a copy of (model v9). A virtual copy shares its master's
    /// file but has its own edits, rating, flag, label, keywords and metadata.
    @NSManaged var master: Photo?
    @NSManaged var virtualCopies: Set<Photo>
    /// The name of a virtual copy ("Copy 1"); nil for a master.
    ///
    /// Not `@NSManaged`: an Objective-C getter whose name starts with `copy` is taken to return an
    /// owned object, so Core Data's generated accessor (which returns an unowned one) would have its
    /// string over-released on every read, and Core Data later crashes freeing the row. Going
    /// through key-value coding avoids the Swift getter. (No attribute may start with `copy`, `new`,
    /// `alloc`, `init` or `mutableCopy` for the same reason.)
    var copyName: String? {
        get { value(forKey: "copyName") as? String }
        set { setValue(newValue, forKey: "copyName") }
    }
    @NSManaged var tags: Set<Tag>
    /// The Develop history, in the order of ``DevelopHistoryStep/sequence`` (model v12).
    @NSManaged var historySteps: Set<DevelopHistoryStep>
    @NSManaged var snapshots: Set<DevelopSnapshot>
    /// Faces found in the photo (model v13).
    @NSManaged var faceRegions: Set<FaceRegion>
    /// The photo's place in each publish service it's been added to (model v18). Deleting the photo leaves
    /// them, without it, so a published copy can still be removed from the service.
    @NSManaged var publications: Set<PublishedPhoto>

    @nonobjc class func fetchRequest() -> NSFetchRequest<Photo> {
        NSFetchRequest<Photo>(entityName: "Photo")
    }

    /// The most recent import that still has photos in the catalog (what Previous Import shows), or
    /// `nil` when there's none.
    static func latestImportID(in context: NSManagedObjectContext) -> UUID? {
        let request = NSFetchRequest<NSDictionary>(entityName: "Photo")
        request.resultType = .dictionaryResultType
        request.predicate = NSPredicate(format: "importID != nil")
        request.sortDescriptors = [NSSortDescriptor(key: #keyPath(Photo.importDate), ascending: false)]
        request.propertiesToFetch = [#keyPath(Photo.importID)]
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first?[#keyPath(Photo.importID)] as? UUID
    }

    var fileURL: URL { URL(filePath: filePath) }

    var isVirtualCopy: Bool { master != nil }

    /// The image sidecar extensions (`["JPG"]`), uppercased.
    var imageSidecars: [String] {
        (sidecarExtensions ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
    }

    /// Photos that use the same file as this one (the master and its virtual copies), this one included.
    var photosSharingFile: [Photo] {
        let root = master ?? self
        return [root] + root.virtualCopies.sorted { ($0.copyName ?? "").localizedStandardCompare($1.copyName ?? "") == .orderedAscending }
    }

    var photoFlag: PhotoFlag {
        get { PhotoFlag(rawValue: flag) ?? .unflagged }
        set { flag = newValue.rawValue }
    }

    /// Develop settings. Assigning default adjustments clears the stored data.
    var adjustments: PhotoAdjustments {
        get { PhotoAdjustments(data: adjustmentsData) }
        set {
            let data = newValue.encoded
            if data != adjustmentsData { adjustmentsData = data }
            let cropped = !newValue.crop.rect.equalTo(CGRect(x: 0, y: 0, width: 1, height: 1)) || newValue.crop.angle != 0
            if cropped != isCropped { isCropped = cropped }
        }
    }

    var tagNames: [String] {
        tags.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The photo's keywords with their full paths (`Places > Ireland`), sorted.
    var tagPaths: [String] {
        tags.map(\.displayPath).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Pick/reject state of a photo.
nonisolated enum PhotoFlag: Int16, CaseIterable, Codable, Sendable {
    case rejected = -1
    case unflagged = 0
    case picked = 1

    var title: String {
        switch self {
        case .rejected: "Rejected"
        case .unflagged: "Unflagged"
        case .picked: "Picked"
        }
    }
}
