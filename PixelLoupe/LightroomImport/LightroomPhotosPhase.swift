import CoreData
import Foundation

/// Creates the folder tree and a `Photo` for every Lightroom photo: file details, rating, pick flag,
/// dates and orientation. Photos stay where they are (Referenced). Virtual copies are left to their
/// own phase, and file types PixelLoupe can't open are skipped and reported.
///
/// Files that can be reached are read for camera, lens, size and EXIF orientation, concurrently,
/// as a normal import does. Files on an unmounted volume are not touched: their details come from
/// what Lightroom harvested.
nonisolated final class LightroomPhotosPhase: LightroomImportPhase {
    let title = "Importing folders and photos"

    private static let batchSize = 200
    private static let maximumConcurrentReads = 12

    private var cursor: LightroomRowCursor<LRPhotoRecord>?
    private var folderIDs: [Int: NSManagedObjectID] = [:]
    private var folderPaths: [Int: String] = [:]
    private var onlineFolders: [Int: Bool] = [:]
    private var skipped: [String: Int] = [:]
    private var offline = 0
    private var imported = 0
    private var importedCopies = 0
    /// Virtual copies come after every master, so each copy's master is already in the catalog.
    private var copyCursor: LightroomRowCursor<LRPhotoRecord>?
    private var readingCopies = false
    /// Lightroom's Previous Import (image `id_local`s), which becomes the new catalog's, under one import id.
    private var previousImport: Set<Int> = []
    private let previousImportID = UUID()

    func prepare(_ context: LightroomImportContext) async throws -> Int {
        try await makeFolders(context)
        cursor = try context.catalog.photoCursor()
        copyCursor = try context.catalog.photoCursor(virtualCopies: true)
        previousImport = try context.catalog.previousImportImages()
        return try context.catalog.scalar("SELECT COUNT(*) FROM Adobe_images")
    }

    func importBatch(_ context: LightroomImportContext) async throws -> Int {
        guard let cursor, let copyCursor else { return 0 }
        var records = readingCopies ? [] : try cursor.next(Self.batchSize)
        if records.isEmpty {
            readingCopies = true
            records = try copyCursor.next(Self.batchSize)
        }
        guard !records.isEmpty else { return 0 }
        let isCopy = readingCopies

        // Split off types PixelLoupe can't open.
        var pending: [FileJob] = []
        for record in records {
            let name = record.fileName.isEmpty ? record.fileExtension : record.fileName
            guard SupportedImageTypes.isSupported(URL(filePath: "/x/" + name)) else {
                skipped[record.image.fileFormat.uppercased(), default: 0] += 1
                continue
            }
            guard let directory = folderPaths[record.folder] else {
                context.report.addWarning("\(record.fileName): its folder is missing from the catalog, so it was skipped.")
                continue
            }
            if onlineFolders[record.folder] == nil {
                var isDirectory: ObjCBool = false
                onlineFolders[record.folder] = FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            // A copy of a photo that wasn't imported has nothing to be a copy of.
            if isCopy, let master = record.image.masterImage, context.idMap.photoID(forLightroomID: master) == nil { continue }
            pending.append(FileJob(record: record, path: directory + "/" + record.fileName, isOnline: onlineFolders[record.folder] == true))
        }

        let jobs = pending
        let reads = await Self.readFiles(jobs)
        let folderIDs = folderIDs
        let importDate = context.importDate
        let previousImport = previousImport
        let previousImportID = previousImportID
        let managed = context.managedObjectContext
        let report = context.report
        // Each copy's master, by the Photo id the master was given.
        var masterIDs: [Int: UUID] = [:]
        if isCopy {
            for job in jobs {
                if let master = job.record.image.masterImage, let id = context.idMap.photoID(forLightroomID: master) { masterIDs[job.record.image.id] = id }
            }
        }
        let masters = masterIDs
        let created: [(lightroomID: Int, photoID: UUID)] = await managed.perform {
            var pairs: [(lightroomID: Int, photoID: UUID)] = []
            var masterPhotos: [UUID: Photo] = [:]
            if !masters.isEmpty {
                let request = Photo.fetchRequest()
                request.predicate = NSPredicate(format: "id IN %@", Array(Set(masters.values)))
                masterPhotos = Dictionary(((try? managed.fetch(request)) ?? []).map { ($0.id, $0) }) { first, _ in first }
            }
            for (job, read) in zip(jobs, reads) {
                guard let folderID = folderIDs[job.record.folder], let folder = try? managed.existingObject(with: folderID) as? Folder else { continue }
                let photo = Photo(context: managed)
                Self.fill(photo, from: job, read: read, folder: folder, importedAt: importDate, report: report)
                // A virtual copy goes with its master, as one made in PixelLoupe does.
                if previousImport.contains(job.record.image.masterImage ?? job.record.image.id) {
                    photo.importID = previousImportID
                }
                if let masterID = masters[job.record.image.id], let master = masterPhotos[masterID] {
                    photo.master = master
                    photo.copyName = job.record.image.copyName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Copy"
                }
                pairs.append((job.record.image.id, photo.id))
            }
            return pairs
        }
        try context.idMap.record(created)
        if isCopy { importedCopies += created.count } else { imported += created.count }
        offline += jobs.filter { !$0.isOnline }.count
        context.report.addImported(isCopy ? "Virtual copies" : "Photos", count: created.count)
        return records.count
    }

    func finish(_ context: LightroomImportContext) async throws {
        for (format, count) in skipped.sorted(by: { $0.key < $1.key }) {
            context.report.addWarning("\(count.formatted()) \(format) file\(count == 1 ? "" : "s") not imported: PixelLoupe can’t open this type of file.")
        }
        if offline > 0 {
            context.report.addWarning("\(offline.formatted()) photo\(offline == 1 ? " is" : "s are") missing on disk. They were imported from the catalog’s details and will show as missing.")
        }
    }

    // MARK: - Folders

    /// Creates a `Folder` for each Lightroom folder, with the same tree. Root folders have no parent.
    /// Folders Lightroom marks with a `visibility` are left out unless they hold photos.
    private func makeFolders(_ context: LightroomImportContext) async throws {
        let roots = Dictionary(uniqueKeysWithValues: try context.catalog.rootFolders().map { ($0.id, $0) })
        let folders = try context.catalog.folders()
        let withPhotos = try context.catalog.foldersWithPhotos()

        // Absolute paths, without the trailing slash PixelLoupe doesn't use.
        var built: [Int: String] = [:]
        for folder in folders {
            guard let root = roots[folder.rootFolder] else { continue }
            let path = (root.absolutePath + folder.pathFromRoot).trimmingSuffix("/")
            built[folder.id] = path.isEmpty ? "/" : path
        }
        folderPaths = built
        let paths = built

        // A folder is kept if it has no visibility, or it holds photos; so are the ancestors of kept
        // folders, to keep the tree connected.
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var kept = Set(folders.filter { $0.visibility == nil }.map(\.id))
        kept.formUnion(withPhotos)
        for id in Array(kept) {
            var parent = byID[id]?.parentID
            while let identifier = parent, kept.insert(identifier).inserted { parent = byID[identifier]?.parentID }
        }

        let ordered = folders.filter { kept.contains($0.id) && paths[$0.id] != nil }
        let parents = Self.parents(of: ordered, among: folders)
        let rootNames = roots.mapValues(\.name)
        let managed = context.managedObjectContext
        let ids: [Int: NSManagedObjectID] = try await managed.perform {
            var created: [Int: Folder] = [:]
            for folder in ordered {
                let object = Folder(context: managed)
                let path = paths[folder.id] ?? ""
                object.path = path
                object.name = folder.pathFromRoot.isEmpty
                    ? (rootNames[folder.rootFolder].flatMap { $0.isEmpty ? nil : $0 } ?? (path as NSString).lastPathComponent)
                    : (path as NSString).lastPathComponent
                created[folder.id] = object
            }
            for folder in ordered {
                if let parentID = parents[folder.id], let parent = created[parentID] { created[folder.id]?.parent = parent }
            }
            try managed.save()
            // Object IDs are permanent after the save, and survive the context being reset.
            return created.mapValues(\.objectID)
        }
        folderIDs = ids
    }

    /// The parent of each folder. Lightroom's `parentId` is often null, so the tree is also read from
    /// the paths: `2013/2013-02/` sits under `2013/`, which sits under the root folder's own row
    /// (an empty path). A folder whose direct parent isn't in the catalog goes under its nearest
    /// ancestor that is.
    static func parents(of folders: [LRFolder], among all: [LRFolder]) -> [Int: Int] {
        let byPath = Dictionary(all.map { ("\($0.rootFolder)|\($0.pathFromRoot)", $0.id) }) { first, _ in first }
        var parents: [Int: Int] = [:]
        for folder in folders {
            if let explicit = folder.parentID, explicit != folder.id {
                parents[folder.id] = explicit
                continue
            }
            var components = folder.pathFromRoot.split(separator: "/").map(String.init)
            while !components.isEmpty {
                components.removeLast()
                let path = components.isEmpty ? "" : components.joined(separator: "/") + "/"
                if let parent = byPath["\(folder.rootFolder)|\(path)"], parent != folder.id {
                    parents[folder.id] = parent
                    break
                }
            }
        }
        return parents
    }

    // MARK: - Reading files

    private struct FileJob: Sendable {
        var record: LRPhotoRecord
        var path: String
        var isOnline: Bool
    }

    private struct FileRead: Sendable {
        var metadata: ImageMetadata?
        var fileSize: Int64
        var creationDate: Date?
    }

    @concurrent
    private static func readFiles(_ jobs: [FileJob]) async -> [FileRead?] {
        await withTaskGroup(of: (Int, FileRead?).self) { group in
            var results = [FileRead?](repeating: nil, count: jobs.count)
            var next = 0
            func addNext() {
                guard next < jobs.count else { return }
                let index = next
                let job = jobs[index]
                next += 1
                group.addTask {
                    guard job.isOnline else { return (index, nil) }
                    let url = URL(filePath: job.path)
                    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]) else { return (index, nil) }
                    return (index, FileRead(
                        metadata: await ImageMetadata.readMedia(from: url), fileSize: Int64(values.fileSize ?? 0), creationDate: values.creationDate))
                }
            }
            for _ in 0..<min(maximumConcurrentReads, jobs.count) { addNext() }
            while let (index, read) = await group.next() {
                results[index] = read
                addNext()
            }
            return results
        }
    }

    // MARK: - Photos

    /// Lightroom stores the label's name: Red, Yellow, Green, Blue or Purple in the default set. A
    /// custom name has no color here, so it is kept as text and reported.
    static func applyColorLabel(_ name: String, to photo: Photo, report: LightroomImportReportBuilder) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let label = ColorLabel(name: trimmed) {
            photo.label = label
        } else {
            photo.labelText = trimmed
            let slug = String(trimmed.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            report.recordDifference("label-\(slug)", title: "Color label “\(trimmed)” has no matching color", for: photo)
        }
    }

    private static func fill(
        _ photo: Photo, from job: FileJob, read: FileRead?, folder: Folder, importedAt: Date, report: LightroomImportReportBuilder
    ) {
        let record = job.record
        let image = record.image
        let fileMetadata = read?.metadata

        photo.id = UUID()
        photo.lightroomID = image.globalID
        photo.fileName = record.fileName
        photo.filePath = job.path
        photo.fileType = record.fileExtension.uppercased()
        photo.fileSize = read?.fileSize ?? 0
        photo.folder = folder

        let importDate = LightroomDates.importDate(from: record.importDate) ?? read?.creationDate ?? importedAt
        let captureDate = LightroomDates.localDate(fromCaptureTime: image.captureTime)
            ?? fileMetadata?.captureDate ?? read?.creationDate ?? importDate
        photo.captureDate = captureDate
        photo.importDate = importDate
        photo.editDate = LightroomDates.touchDate(image.touchTime) ?? importDate

        photo.rating = Int16(min(5, max(0, image.rating ?? 0)))
        photo.flag = Int16(min(1, max(-1, image.pick)))
        applyColorLabel(image.colorLabels, to: photo, report: report)

        // Shooting details: from the file, else what Lightroom harvested.
        if let fileMetadata, fileMetadata.pixelWidth > 0 {
            photo.apply(fileMetadata.shooting)
            if record.hasGPS { photo.hasGPS = true }
        } else {
            photo.iso = Int32(clamping: record.harvestedISO)
            photo.focalLength = record.harvestedFocalLength
            photo.aperture = record.harvestedAperture
            photo.shutterSpeed = record.harvestedShutterSpeed
            photo.hasGPS = record.hasGPS
        }
        photo.isBlackAndWhite = record.isGrayscale

        // Video, and the images that go with a raw file.
        let isVideo = SupportedImageTypes.isVideo(URL(filePath: "/x/" + record.fileName))
        photo.isVideo = isVideo
        if isVideo {
            photo.duration = fileMetadata?.duration ?? 0
            if photo.duration <= 0 { photo.duration = record.videoDuration }
            // Trim points aren't used yet; keep them with the photo.
            var metadata = photo.metadata
            for (key, value) in [(PhotoMetadata.lightroomVideoTrimStartKey, record.videoTrimStart), (PhotoMetadata.lightroomVideoTrimEndKey, record.videoTrimEnd)] {
                if let seconds = VideoSupport.lightroomSeconds(value), seconds > 0 { metadata.values[key] = String(seconds) }
            }
            if let poster = VideoSupport.lightroomSeconds(record.videoPoster), poster > 0 { metadata.values[PhotoMetadata.lightroomVideoPosterKey] = String(poster) }
            photo.metadata = metadata
        }
        let sidecars = (record.sidecarExtensions ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { SupportedImageTypes.sidecarImageExtensions.contains($0) }
        photo.sidecarExtensions = sidecars.isEmpty ? nil : sidecars.joined(separator: ",")

        photo.cameraMake = fileMetadata?.cameraMake
        photo.cameraModel = fileMetadata?.cameraModel ?? record.harvestedCameraModel
        photo.lensModel = fileMetadata?.lensModel ?? record.harvestedLens
        photo.pixelWidth = Int32(fileMetadata.map(\.pixelWidth).flatMap { $0 > 0 ? $0 : nil } ?? image.fileWidth ?? 0)
        photo.pixelHeight = Int32(fileMetadata.map(\.pixelHeight).flatMap { $0 > 0 ? $0 : nil } ?? image.fileHeight ?? 0)

        // Lightroom's orientation includes the user's rotations. With the file at hand, keep the
        // file's own EXIF orientation and put the difference in the photo's orientation adjustment, so
        // Rotate and Reset to Camera Orientation behave. Without the file, store Lightroom's.
        let lightroom = LightroomOrientation.exif(forCode: image.orientation)
        if isVideo {
            photo.orientation = 1
        } else if let fileMetadata, fileMetadata.pixelWidth > 0 {
            photo.orientation = Int16(fileMetadata.orientation)
            if let lightroom {
                let turn = LightroomOrientation.adjustment(lightroom: lightroom, file: fileMetadata.orientation)
                if !turn.isIdentity {
                    var adjustments = photo.adjustments
                    adjustments.orientation = turn
                    photo.adjustments = adjustments
                }
            }
        } else {
            photo.orientation = Int16(lightroom ?? 1)
        }

        // Keep the capture time as it was before any edit in Lightroom.
        if let original = record.originalCaptureTime, !original.isEmpty, original != image.captureTime {
            var metadata = photo.metadata
            metadata.values[PhotoMetadata.lightroomOriginalCaptureTimeKey] = original
            photo.metadata = metadata
        }
    }
}

nonisolated extension PhotoMetadata {
    /// Catalog-only record of Lightroom's `originalCaptureTime` for photos whose capture time was
    /// edited there. Not a Metadata panel field.
    static let lightroomOriginalCaptureTimeKey = "lightroom.originalCaptureTime"
    /// Where a video's trim points (seconds) and poster frame (seconds) from Lightroom are kept.
    static let lightroomVideoTrimStartKey = "lightroom.videoTrimStart"
    static let lightroomVideoTrimEndKey = "lightroom.videoTrimEnd"
    static let lightroomVideoPosterKey = "lightroom.videoPoster"
}

nonisolated private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
