import Foundation
import UniformTypeIdentifiers

/// Settings stored alongside the database inside a `.pixelloupe` catalog package.
nonisolated struct CatalogInfo: Codable, Equatable, Sendable {
    enum StorageMode: String, Codable, Sendable {
        /// Imported photos are copied into `storagePath`, organized into `YYYY/MM-DD` folders.
        case managed
        /// Imported photos stay where they are and the catalog references them in place.
        case referenced
    }

    static let currentFormatVersion = 1

    var formatVersion = CatalogInfo.currentFormatVersion
    var name: String
    var storageMode: StorageMode
    /// Root folder for imported photos. Only set for `.managed` catalogs.
    var storagePath: String?
    /// Whole seconds, since XML property lists don't store fractional dates.
    var createdAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    var storageURL: URL? {
        storagePath.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    var storageDescription: String {
        switch storageMode {
        case .managed: "Photos copied to \(storageURL?.path(percentEncoded: false) ?? "?")"
        case .referenced: "Photos referenced in place"
        }
    }
}

/// How the catalog's window was left (expanded sidebar folders, the folder being shown and the
/// selected photos), restored when it's reopened. Stored in the package rather than the user's
/// defaults so it travels with the catalog.
nonisolated struct CatalogViewState: Codable, Equatable, Sendable {
    var expandedFolderPaths: Set<String> = []
    /// The folder shown in the grid; nil for All Photographs.
    var folderPath: String?
    /// The selected photos (`Photo.id`), in selection order.
    var selectedPhotos: [UUID] = []

    /// The collection shown in the grid (instead of a folder).
    var collectionID: UUID?
    /// Whether the grid shows Previous Import (instead of a folder or collection).
    var showsPreviousImport = false
    /// Lightroom's target collection: where B adds photos.
    var targetCollectionID: UUID?
    /// Whether the starter smart collections have been made (so deleting them sticks).
    var createdDefaultCollections = false

    /// Selections larger than this (Select All in a big catalog) aren't worth restoring in full.
    static let maximumSavedSelection = 1000

    init(expandedFolderPaths: Set<String> = [], folderPath: String? = nil, selectedPhotos: [UUID] = []) {
        self.expandedFolderPaths = expandedFolderPaths
        self.folderPath = folderPath
        self.selectedPhotos = selectedPhotos
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expandedFolderPaths = try container.decodeIfPresent(Set<String>.self, forKey: .expandedFolderPaths) ?? []
        folderPath = try container.decodeIfPresent(String.self, forKey: .folderPath)
        selectedPhotos = try container.decodeIfPresent([UUID].self, forKey: .selectedPhotos) ?? []
        collectionID = try container.decodeIfPresent(UUID.self, forKey: .collectionID)
        showsPreviousImport = try container.decodeIfPresent(Bool.self, forKey: .showsPreviousImport) ?? false
        targetCollectionID = try container.decodeIfPresent(UUID.self, forKey: .targetCollectionID)
        createdDefaultCollections = try container.decodeIfPresent(Bool.self, forKey: .createdDefaultCollections) ?? false
    }

    /// Reads the state saved in a catalog package; a missing or unreadable file means the defaults.
    static func load(from package: URL) -> CatalogViewState {
        guard let data = try? Data(contentsOf: CatalogPackage.viewStateURL(in: package)),
              let state = try? PropertyListDecoder().decode(CatalogViewState.self, from: data) else { return .init() }
        return state
    }

    func save(to package: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(self).write(to: CatalogPackage.viewStateURL(in: package), options: .atomic)
    }
}

nonisolated extension UTType {
    static let pixelLoupeCatalog = UTType(exportedAs: "net.pixegen.pixelloupe.catalog", conformingTo: .package)
    /// Catalogs made while the app was called LightLoupe (`.lightloupe`). They open as before.
    static let lightLoupeCatalog = UTType(importedAs: "net.tedlee.lightloupe.catalog", conformingTo: .package)
    /// Catalogs made while the app was called RawLoupe (`.rawloupe`). They open as before.
    static let rawLoupeCatalog = UTType(importedAs: "net.tedlee.rawloupe.catalog", conformingTo: .package)

    /// Every kind of catalog the app opens: its own, then those from before each rename.
    static let catalogTypes: [UTType] = [.pixelLoupeCatalog, .lightLoupeCatalog, .rawLoupeCatalog]
}

/// File layout of a catalog package.
nonisolated enum CatalogPackage {
    static let fileExtension = "pixelloupe"
    /// The extensions catalogs had while the app was called LightLoupe and, before that, RawLoupe;
    /// still opened, never created.
    static let legacyFileExtensions = ["lightloupe", "rawloupe"]

    /// Whether `url` names a catalog package (current or from before a rename).
    static func isCatalog(_ url: URL) -> Bool {
        ([fileExtension] + legacyFileExtensions).contains(url.pathExtension.lowercased())
    }
    static let infoFileName = "Catalog.plist"
    static let databaseFileName = "Catalog.sqlite"
    static let thumbnailsDirectoryName = "Thumbnails"
    static let viewStateFileName = "ViewState.plist"
    static let lightroomImportReportFileName = "LightroomImport.json"

    static func infoURL(in package: URL) -> URL { package.appending(path: infoFileName) }
    static func databaseURL(in package: URL) -> URL { package.appending(path: databaseFileName) }
    static func viewStateURL(in package: URL) -> URL { package.appending(path: viewStateFileName) }
    static func lightroomImportReportURL(in package: URL) -> URL { package.appending(path: lightroomImportReportFileName) }
    static func thumbnailsURL(in package: URL) -> URL {
        package.appending(path: thumbnailsDirectoryName, directoryHint: .isDirectory)
    }
}
