import CoreData
import Foundation
import OSLog

nonisolated struct ImportProgress: Sendable {
    var completed: Int
    var total: Int
}

nonisolated struct ImportSummary: Sendable {
    var imported = 0
    var skippedDuplicates = 0
    var failures: [String] = []
}

/// Imports image files into a catalog.
///
/// Managed catalogs copy each file into `storage/YYYY/MM-DD/` (by capture date) and leave the source
/// untouched. Referenced catalogs record files where they are. Metadata reading, copying and
/// thumbnail generation run concurrently off the main thread; rows are inserted in batches on a
/// background context, and the view context picks them up through automatic merging.
final class ImportService {
    private let store: CatalogStore
    nonisolated private static let logger = Logger(subsystem: "net.pixegen.PixelLoupe", category: "Import")
    private static let batchSize = 32

    init(store: CatalogStore) {
        self.store = store
    }

    func importPhotos(
        from urls: [URL],
        progress: (ImportProgress) -> Void = { _ in }
    ) async throws -> ImportSummary {
        let sources = await Self.collectSources(urls, info: store.info)
        let defaults = ImportSettings.defaults(for: store.info)
        return try await importBatches(
            count: sources.count, transfer: defaults.transfer, destination: defaults.destination, progress: progress
        ) { range in
            await Self.readCandidates(Array(sources[range]))
        }
    }

    /// Imports files already read by `scan(_:includeSubfolders:)`, such as those checked in the import
    /// window: copied into `destination`'s folders, or added where they are. Without a transfer, the
    /// catalog's own default (copy into its storage, or add in place).
    func importPhotos(
        _ candidates: [Candidate],
        transfer: ImportTransfer? = nil,
        destination: ImportDestination? = nil,
        progress: (ImportProgress) -> Void = { _ in }
    ) async throws -> ImportSummary {
        let defaults = ImportSettings.defaults(for: store.info)
        return try await importBatches(
            count: candidates.count, transfer: transfer ?? defaults.transfer,
            destination: destination ?? defaults.destination, progress: progress
        ) { range in
            Array(candidates[range])
        }
    }

    private func importBatches(
        count: Int,
        transfer: ImportTransfer,
        destination: ImportDestination,
        progress: (ImportProgress) -> Void,
        candidates: (Range<Int>) async -> [Candidate]
    ) async throws -> ImportSummary {
        let rule = transfer.duplicateRule
        var summary = ImportSummary()
        progress(ImportProgress(completed: 0, total: count))
        guard count > 0 else { return summary }

        let context = store.newBackgroundContext()
        // Every photo this import adds shares it, so Previous Import can show them together.
        let importID = UUID()
        var seenKeys = try await Self.existingKeys(in: context, mode: rule)
        var reservedDestinations = Set<String>()
        let thumbnailDirectory = store.thumbnails.directory
        var completed = 0

        for batchStart in stride(from: 0, to: count, by: Self.batchSize) {
            try Task.checkCancellation()
            let range = batchStart..<min(batchStart + Self.batchSize, count)

            // Read metadata concurrently, then de-duplicate and assign destinations in order so
            // results are deterministic.
            let batch = await candidates(range)
            var planned: [PlannedImport] = []
            for candidate in batch {
                guard let metadata = candidate.metadata else {
                    summary.failures.append("\(candidate.source.url.lastPathComponent): not a readable image")
                    continue
                }
                let key = Self.dedupeKey(for: candidate, metadata: metadata, mode: rule)
                guard seenKeys.insert(key).inserted else {
                    summary.skippedDuplicates += 1
                    continue
                }
                let captureDate = metadata.captureDate ?? candidate.fileDate
                let target: URL
                let anchor: URL
                switch transfer {
                case .copy:
                    target = Self.uniqueDestination(
                        in: destination.folder(for: captureDate),
                        fileName: candidate.source.url.lastPathComponent,
                        reserved: &reservedDestinations
                    )
                    // The destination's subfolders become roots in the catalog's folder tree.
                    anchor = destination.root
                case .add:
                    target = candidate.source.url
                    anchor = candidate.source.anchor
                }
                planned.append(PlannedImport(
                    id: UUID(),
                    source: candidate.source.url,
                    destination: target,
                    anchor: anchor,
                    dedupeKey: key,
                    sidecars: candidate.source.sidecars,
                    fileSize: candidate.fileSize,
                    captureDate: captureDate,
                    metadata: metadata
                ))
            }

            let prepared = await Self.prepareFiles(
                planned, copy: transfer == .copy, thumbnailDirectory: thumbnailDirectory
            )
            var ready: [PlannedImport] = []
            for result in prepared {
                switch result {
                case .success(let item): ready.append(item)
                case .failure(let message): summary.failures.append(message)
                }
            }

            try await Self.insert(ready, importID: importID, into: context)
            summary.imported += ready.count
            completed += range.count
            progress(ImportProgress(completed: completed, total: count))
        }

        Self.logger.info(
            "Imported \(summary.imported) photos, skipped \(summary.skippedDuplicates), failed \(summary.failures.count)"
        )
        return summary
    }

    // MARK: - Scanning

    /// A file found by `scan`, and whether the catalog (or an earlier file in the same scan) already
    /// has it, under each duplicate rule (see `ImportTransfer.duplicateRule`).
    nonisolated struct ScannedFile: Sendable {
        var candidate: Candidate
        var metadata: ImageMetadata
        var isDuplicateWhenCopied: Bool
        var isDuplicateWhenAdded: Bool
        var captureDate: Date { metadata.captureDate ?? candidate.fileDate }

        func isDuplicate(for transfer: ImportTransfer) -> Bool {
            transfer == .copy ? isDuplicateWhenCopied : isDuplicateWhenAdded
        }
    }

    nonisolated struct ScanResult: Sendable {
        var files: [ScannedFile] = []
        /// Names of supported files whose metadata couldn't be read.
        var unreadable: [String] = []
    }

    /// Reads what `urls` hold without importing anything, marking files the catalog already has.
    func scan(_ urls: [URL], includeSubfolders: Bool = true) async throws -> ScanResult {
        let sources = await Self.collectSources(urls, info: store.info, includeSubfolders: includeSubfolders)
        let context = store.newBackgroundContext()
        var copiedKeys = try await Self.existingKeys(in: context, mode: .managed)
        var addedKeys = try await Self.existingKeys(in: context, mode: .referenced)
        var result = ScanResult()
        for candidate in await Self.readCandidates(sources) {
            try Task.checkCancellation()
            guard let metadata = candidate.metadata else {
                result.unreadable.append(candidate.source.url.lastPathComponent)
                continue
            }
            result.files.append(ScannedFile(
                candidate: candidate, metadata: metadata,
                isDuplicateWhenCopied: !copiedKeys.insert(Self.dedupeKey(for: candidate, metadata: metadata, mode: .managed)).inserted,
                isDuplicateWhenAdded: !addedKeys.insert(Self.dedupeKey(for: candidate, metadata: metadata, mode: .referenced)).inserted
            ))
        }
        return result
    }

    /// Whether `urls` hold photos the catalog doesn't have, judged by file name and size: no metadata is
    /// read, so it's quick enough to run as a card is inserted (the import window's New badge).
    func hasNewPhotos(in urls: [URL]) async throws -> Bool {
        let sources = await Self.collectSources(urls, info: store.info)
        guard !sources.isEmpty else { return false }
        let known = try await Self.knownNamesAndSizes(in: store.newBackgroundContext())
        return await Self.containsUnknown(sources.map(\.url), known: known)
    }

    nonisolated static func nameAndSizeKey(name: String, size: Int64) -> String {
        "\(name.lowercased())|\(size)"
    }

    @concurrent
    nonisolated private static func containsUnknown(_ urls: [URL], known: Set<String>) async -> Bool {
        urls.contains { url in
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            return !known.contains(nameAndSizeKey(name: url.lastPathComponent, size: size))
        }
    }

    nonisolated private static func knownNamesAndSizes(in context: NSManagedObjectContext) async throws -> Set<String> {
        try await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "Photo")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = [#keyPath(Photo.fileName), #keyPath(Photo.originalPath), #keyPath(Photo.fileSize)]
            var keys = Set<String>()
            for row in try context.fetch(request) {
                let size = (row[#keyPath(Photo.fileSize)] as? NSNumber)?.int64Value ?? 0
                if let name = row[#keyPath(Photo.fileName)] as? String { keys.insert(nameAndSizeKey(name: name, size: size)) }
                // A copy renamed on a collision (IMG_0001-1.JPG) still came from IMG_0001.JPG.
                if let original = row[#keyPath(Photo.originalPath)] as? String {
                    keys.insert(nameAndSizeKey(name: (original as NSString).lastPathComponent, size: size))
                }
            }
            return keys
        }
    }

    // MARK: - Planning

    nonisolated struct ImportSource: Sendable {
        var url: URL
        /// Extensions of image files that go with this one (a JPEG shot with a raw file).
        var sidecars: [String] = []
        /// Folder whose subfolders become root folders in the catalog's folder tree (referenced mode).
        var anchor: URL
    }

    nonisolated struct Candidate: Sendable {
        var source: ImportSource
        var metadata: ImageMetadata?
        var fileSize: Int64
        var fileDate: Date
    }

    nonisolated struct PlannedImport: Sendable {
        var id: UUID
        var source: URL
        var destination: URL
        var anchor: URL
        var dedupeKey: String
        var sidecars: [String] = []
        var fileSize: Int64
        var captureDate: Date
        var metadata: ImageMetadata
    }

    nonisolated enum PrepareResult: Sendable {
        case success(PlannedImport)
        case failure(String)
    }

    /// Expands folders (recursively unless `includeSubfolders` is off) and filters to supported image types, sorted by path.
    @concurrent
    nonisolated static func collectSources(
        _ urls: [URL], info: CatalogInfo, includeSubfolders: Bool = true,
        separateJPEGs: Bool = AppSettings.treatsJPEGsAsSeparate
    ) async -> [ImportSource] {
        let fileManager = FileManager.default
        var sources: [ImportSource] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
                continue
            }
            if isDirectory.boolValue {
                // Selecting a folder makes that folder a root in the catalog's folder tree.
                let anchor = url.deletingLastPathComponent()
                let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: includeSubfolders
                        ? [.skipsHiddenFiles, .skipsPackageDescendants]
                        : [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
                )
                while let fileURL = enumerator?.nextObject() as? URL {
                    if SupportedImageTypes.isSupported(fileURL) {
                        sources.append(ImportSource(url: fileURL.standardizedFileURL, anchor: anchor))
                    }
                }
            } else if SupportedImageTypes.isSupported(url) {
                let anchor = url.deletingLastPathComponent().deletingLastPathComponent()
                sources.append(ImportSource(url: url.standardizedFileURL, anchor: anchor))
            }
        }
        let sorted = sources.sorted { $0.url.path().localizedStandardCompare($1.url.path()) == .orderedAscending }
        return separateJPEGs ? sorted : pairSidecars(sorted)
    }

    /// A JPEG (or similar image) with the same name as a raw file beside it, both being imported, is that
    /// raw photo's sidecar rather than a photo of its own (Lightroom's default). The raw photo notes
    /// the sidecar's extension, and removing the photo removes both files.
    nonisolated static func pairSidecars(_ sources: [ImportSource]) -> [ImportSource] {
        func key(_ url: URL) -> String { url.deletingPathExtension().path(percentEncoded: false).lowercased() }
        var raws: [String: Int] = [:]
        for (index, source) in sources.enumerated() where SupportedImageTypes.isRaw(source.url) { raws[key(source.url)] = index }
        var result = sources
        var paired = Set<Int>()
        for (index, source) in sources.enumerated() {
            let ext = source.url.pathExtension.uppercased()
            guard SupportedImageTypes.sidecarImageExtensions.contains(ext), !SupportedImageTypes.isRaw(source.url),
                  let rawIndex = raws[key(source.url)] else { continue }
            result[rawIndex].sidecars.append(ext)
            paired.insert(index)
        }
        return result.enumerated().filter { !paired.contains($0.offset) }.map(\.element)
    }

    nonisolated static func dedupeKey(for candidate: Candidate, metadata: ImageMetadata, mode: CatalogInfo.StorageMode) -> String {
        dedupeKey(url: candidate.source.url, fileSize: candidate.fileSize, date: metadata.captureDate ?? candidate.fileDate, mode: mode)
    }

    nonisolated static func dedupeKey(url: URL, fileSize: Int64, date: Date, mode: CatalogInfo.StorageMode) -> String {
        switch mode {
        case .referenced:
            return url.path(percentEncoded: false)
        case .managed:
            // A copy of the same shot from another card or folder is still a duplicate.
            return "\(url.lastPathComponent.lowercased())|\(fileSize)|\(Int(date.timeIntervalSince1970))"
        }
    }

    nonisolated static func dateFolder(for date: Date, under storageURL: URL) -> URL {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", components.year ?? 0)
        let day = String(format: "%02d-%02d", components.month ?? 0, components.day ?? 0)
        return storageURL
            .appending(path: year, directoryHint: .isDirectory)
            .appending(path: day, directoryHint: .isDirectory)
    }

    /// Picks `name.ext`, or `name-1.ext`, `name-2.ext`… if that path is taken on disk or in this import.
    nonisolated static func uniqueDestination(in folder: URL, fileName: String, reserved: inout Set<String>) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appending(path: fileName)
        var counter = 1
        while reserved.contains(candidate.path(percentEncoded: false))
                || FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            candidate = folder.appending(path: name)
            counter += 1
        }
        reserved.insert(candidate.path(percentEncoded: false))
        return candidate
    }

    // MARK: - File work

    @concurrent
    nonisolated static func readCandidates(_ sources: [ImportSource]) async -> [Candidate] {
        await withTaskGroup(of: (Int, Candidate).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    let values = try? source.url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
                    let candidate = Candidate(
                        source: source,
                        metadata: await ImageMetadata.readMedia(from: source.url),
                        fileSize: Int64(values?.fileSize ?? 0),
                        fileDate: values?.creationDate ?? Date()
                    )
                    return (index, candidate)
                }
            }
            var results = [Candidate?](repeating: nil, count: sources.count)
            for await (index, candidate) in group { results[index] = candidate }
            return results.compactMap { $0 }
        }
    }

    @concurrent
    nonisolated private static func prepareFiles(
        _ items: [PlannedImport], copy: Bool, thumbnailDirectory: URL
    ) async -> [PrepareResult] {
        await withTaskGroup(of: (Int, PrepareResult).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    (index, await prepare(item, copy: copy, thumbnailDirectory: thumbnailDirectory))
                }
            }
            var results = [PrepareResult?](repeating: nil, count: items.count)
            for await (index, result) in group { results[index] = result }
            return results.compactMap { $0 }
        }
    }

    nonisolated private static func prepare(_ item: PlannedImport, copy: Bool, thumbnailDirectory: URL) async -> PrepareResult {
        let fileManager = FileManager.default
        if copy {
            do {
                try fileManager.createDirectory(
                    at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: item.source, to: item.destination)
                // The images that go with it (a raw file's JPEG) come along under the same name.
                for ext in item.sidecars {
                    for candidate in [ext, ext.lowercased()] {
                        let source = item.source.deletingPathExtension().appendingPathExtension(candidate)
                        if fileManager.fileExists(atPath: source.path(percentEncoded: false)) {
                            try? fileManager.copyItem(at: source, to: item.destination.deletingPathExtension().appendingPathExtension(candidate))
                            break
                        }
                    }
                }
            } catch {
                return .failure("\(item.source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        do {
            let thumbnail = ThumbnailStore.url(for: item.id, in: thumbnailDirectory)
            if SupportedImageTypes.isVideo(item.destination) {
                try await VideoSupport.writeThumbnail(from: item.destination, to: thumbnail)
            } else {
                try ThumbnailStore.generateThumbnail(from: item.destination, to: thumbnail)
            }
        } catch {
            // The photo is still usable without a thumbnail; the grid shows a placeholder.
            logger.error("Thumbnail failed for \(item.destination.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return .success(item)
    }

    // MARK: - Core Data

    nonisolated private static func existingKeys(
        in context: NSManagedObjectContext, mode: CatalogInfo.StorageMode
    ) async throws -> Set<String> {
        try await context.perform {
            let keyPath = mode == .managed ? #keyPath(Photo.dedupeKey) : #keyPath(Photo.filePath)
            let request = NSFetchRequest<NSDictionary>(entityName: "Photo")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = [keyPath]
            let rows = try context.fetch(request)
            return Set(rows.compactMap { $0[keyPath] as? String })
        }
    }

    nonisolated private static func insert(_ items: [PlannedImport], importID: UUID, into context: NSManagedObjectContext) async throws {
        guard !items.isEmpty else { return }
        try await context.perform {
            var folders: [String: Folder] = [:]
            var tags: [String: Tag] = [:]
            let now = Date()
            for item in items {
                let photo = Photo(context: context)
                photo.id = item.id
                photo.fileName = item.destination.lastPathComponent
                photo.filePath = item.destination.path(percentEncoded: false)
                photo.originalPath = item.source == item.destination ? nil : item.source.path(percentEncoded: false)
                photo.dedupeKey = item.dedupeKey
                photo.fileType = item.destination.pathExtension.uppercased()
                photo.fileSize = item.fileSize
                photo.captureDate = item.captureDate
                photo.importDate = now
                photo.importID = importID
                photo.editDate = now
                photo.cameraMake = item.metadata.cameraMake
                photo.cameraModel = item.metadata.cameraModel
                photo.lensModel = item.metadata.lensModel
                photo.pixelWidth = Int32(item.metadata.pixelWidth)
                photo.pixelHeight = Int32(item.metadata.pixelHeight)
                photo.orientation = Int16(item.metadata.orientation)
                photo.apply(item.metadata.shooting)
                photo.isVideo = item.metadata.isVideo
                photo.duration = item.metadata.duration
                photo.sidecarExtensions = item.sidecars.isEmpty ? nil : item.sidecars.joined(separator: ",")
                photo.folder = FolderTree.folder(
                    for: item.destination.deletingLastPathComponent(),
                    anchor: item.anchor,
                    in: context,
                    cache: &folders
                )
                for keyword in item.metadata.keywords {
                    let tag = tags[keyword.lowercased()] ?? Tag.findOrCreate(named: keyword, in: context)
                    tags[keyword.lowercased()] = tag
                    photo.tags.insert(tag)
                }
            }
            try context.save()
            context.reset()
        }
    }
}

/// Maintains the catalog's folder tree as photos are imported.
nonisolated enum FolderTree {
    /// Returns the folder for `directory`, creating it and any missing ancestors below `anchor`.
    static func folder(
        for directory: URL,
        anchor: URL,
        in context: NSManagedObjectContext,
        cache: inout [String: Folder]
    ) -> Folder {
        let directoryPath = directory.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
        let anchorPath = anchor.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")

        // Paths from the anchor down to the directory, e.g. /Storage/2026, /Storage/2026/10-12.
        var chain: [String] = []
        if directoryPath.hasPrefix(anchorPath + "/") {
            var current = directoryPath
            while current != anchorPath && current.count > anchorPath.count {
                chain.insert(current, at: 0)
                current = (current as NSString).deletingLastPathComponent
            }
        } else {
            chain = [directoryPath]
        }

        var parent: Folder?
        for path in chain {
            let folder = existingFolder(at: path, in: context, cache: &cache) ?? {
                let folder = Folder(context: context)
                folder.path = path
                folder.name = (path as NSString).lastPathComponent
                adoptOrphans(of: folder, in: context)
                cache[path] = folder
                return folder
            }()
            if folder.parent == nil, let parent { folder.parent = parent }
            parent = folder
        }
        return parent!
    }

    private static func existingFolder(at path: String, in context: NSManagedObjectContext, cache: inout [String: Folder]) -> Folder? {
        if let cached = cache[path] { return cached }
        let request = Folder.fetchRequest()
        request.predicate = NSPredicate(format: "path == %@", path)
        request.fetchLimit = 1
        let folder = try? context.fetch(request).first
        if let folder { cache[path] = folder }
        return folder
    }

    /// Re-parents existing root folders that turn out to be direct children of a newly created folder,
    /// e.g. importing `/Photos` after `/Photos/Trip` was imported on its own.
    private static func adoptOrphans(of folder: Folder, in context: NSManagedObjectContext) {
        let request = Folder.fetchRequest()
        request.predicate = NSPredicate(format: "parent == nil AND path BEGINSWITH %@", folder.path + "/")
        guard let roots = try? context.fetch(request) else { return }
        for root in roots where (root.path as NSString).deletingLastPathComponent == folder.path {
            root.parent = folder
        }
    }
}

nonisolated extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        guard count > suffix.count, hasSuffix(suffix) else { return self }
        return String(dropLast(suffix.count))
    }
}
