import CoreData
import CoreGraphics
import Foundation

/// A photo on a contact sheet, copied from the catalog on the main actor when the sheet opens, so
/// laying out, previewing and writing the PDF never touch Core Data.
nonisolated struct ContactSheetPhoto: Sendable, Equatable {
    let id: UUID
    let source: PhotoSourceLocation
    let adjustments: PhotoAdjustments
    /// Width / height as developed (cropped and rotated), from the catalog; 0 when unknown.
    let aspect: CGFloat
    let fileName: String
    let title: String?
    let caption: String?
    let captureDate: Date
    let camera: String?
    let lens: String?
    let exposure: String?
    let rating: Int
    let creator: String?
    let copyright: String?

    init(id: UUID = UUID(), source: PhotoSourceLocation, adjustments: PhotoAdjustments = PhotoAdjustments(),
         aspect: CGFloat = 1.5, fileName: String, title: String? = nil, caption: String? = nil,
         captureDate: Date = Date(timeIntervalSince1970: 0), camera: String? = nil, lens: String? = nil,
         exposure: String? = nil, rating: Int = 0, creator: String? = nil, copyright: String? = nil) {
        self.id = id
        self.source = source
        self.adjustments = adjustments
        self.aspect = aspect
        self.fileName = fileName
        self.title = title
        self.caption = caption
        self.captureDate = captureDate
        self.camera = camera
        self.lens = lens
        self.exposure = exposure
        self.rating = rating
        self.creator = creator
        self.copyright = copyright
    }

    /// What the caption shows for `field`; empty when the photo has no such value.
    func caption(_ field: ContactSheetSettings.CaptionField) -> String {
        switch field {
        case .fileName: fileName
        case .title: title ?? ""
        case .caption: caption ?? ""
        case .captureDate: captureDate.formatted(date: .abbreviated, time: .omitted)
        case .captureDateTime: captureDate.formatted(date: .abbreviated, time: .shortened)
        case .camera: camera ?? ""
        case .lens: lens ?? ""
        case .exposure: exposure ?? ""
        case .rating: rating > 0 ? String(repeating: "★", count: rating) : ""
        case .creator: creator ?? ""
        case .copyright: copyright ?? ""
        }
    }

    /// "1/250 sec · ƒ / 4 · ISO 200", from the catalog's shooting settings (0 is unknown).
    static func exposure(shutterSpeed: Double, aperture: Double, iso: Int) -> String? {
        let info = ShootingInfo(iso: iso > 0 ? iso : nil, aperture: aperture > 0 ? aperture : nil,
                                exposureTime: shutterSpeed > 0 ? shutterSpeed : nil)
        let parts = [info.exposureTimeText, info.apertureText, info.isoText].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension ContactSheetPhoto {
    /// The photos with `ids`, in that order, without videos (which a contact sheet leaves out).
    /// A fetch per thousand photos rather than a fault per photo, so a whole large grid opens quickly
    /// (and no fetch has more IDs than SQLite takes in one query).
    @MainActor
    static func photos(_ ids: [NSManagedObjectID], in store: CatalogStore) -> [ContactSheetPhoto] {
        var byID: [NSManagedObjectID: Photo] = [:]
        for start in stride(from: 0, to: ids.count, by: 1000) {
            let request = Photo.fetchRequest()
            request.predicate = NSPredicate(format: "self IN %@ AND isVideo == NO", Array(ids[start..<min(start + 1000, ids.count)]))
            request.returnsObjectsAsFaults = false
            for photo in (try? store.viewContext.fetch(request)) ?? [] { byID[photo.objectID] = photo }
        }
        return ids.compactMap { byID[$0] }.map { ContactSheetPhoto(photo: $0, store: store) }
    }

    @MainActor
    init(photo: Photo, store: CatalogStore) {
        let adjustments = photo.adjustments
        var aspect: CGFloat = 0
        if photo.pixelWidth > 0, photo.pixelHeight > 0 {
            var size = CGSize(width: Int(photo.pixelWidth), height: Int(photo.pixelHeight))
            if (photo.orientation >= 5) != adjustments.orientation.swapsDimensions { size = CGSize(width: size.height, height: size.width) }
            aspect = (size.width * adjustments.crop.rect.width) / (size.height * adjustments.crop.rect.height)
        }
        func text(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        self.init(
            id: photo.id, source: store.sourceLocation(of: photo), adjustments: adjustments, aspect: aspect,
            fileName: photo.copyName.map { "\(photo.fileName) (\($0))" } ?? photo.fileName,
            title: text(photo.titleText), caption: text(photo.captionText), captureDate: photo.captureDate,
            camera: text(FileMetadata.cameraName(make: photo.cameraMake, model: photo.cameraModel)),
            lens: text(photo.lensModel),
            exposure: Self.exposure(shutterSpeed: photo.shutterSpeed, aperture: photo.aperture, iso: Int(photo.iso)),
            rating: Int(photo.rating), creator: text(photo.creatorText), copyright: text(photo.copyrightText)
        )
    }
}
