import AppKit
import CoreData
import UniformTypeIdentifiers

nonisolated extension NSPasteboard.PasteboardType {
    /// Photos dragged within PixelLoupe (to collections), as object URIs.
    static let pixelLoupePhotos = NSPasteboard.PasteboardType("net.pixegen.pixelloupe.photos")
}

/// Dragging photos from the grid and filmstrip: onto collections in the sidebar, and out of the
/// app (the Desktop, Finder, Mail…) as JPEGs of the photos as they look in PixelLoupe.
enum PhotoDrag {
    /// One dragged photo, for a collection view's pasteboard writer.
    static func pasteboardItem(for id: NSManagedObjectID) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(id.uriRepresentation().absoluteString, forType: .pixelLoupePhotos)
        return item
    }

    /// One dragged photo, for the grid and filmstrip: a JPEG file for other apps (rendered when
    /// one asks for it), and the photo's object URI for PixelLoupe's own drop targets.
    static func pasteboardWriter(for id: NSManagedObjectID, store: CatalogStore) -> any NSPasteboardWriting {
        guard let photo = try? store.viewContext.existingObject(with: id) as? Photo else { return pasteboardItem(for: id) }
        return DraggedPhoto(
            objectURI: id.uriRepresentation().absoluteString,
            source: photo.fileURL,
            adjustments: photo.adjustments,
            fileName: photo.fileURL.deletingPathExtension().lastPathComponent + ".jpg"
        )
    }

    /// The photos on a drag's pasteboard that belong to this catalog.
    static func objectIDs(from pasteboard: NSPasteboard, store: CatalogStore) -> [NSManagedObjectID] {
        let coordinator = store.container.persistentStoreCoordinator
        return (pasteboard.pasteboardItems ?? []).compactMap { item in
            item.string(forType: .pixelLoupePhotos)
                .flatMap(URL.init(string:))
                .flatMap { coordinator.managedObjectID(forURIRepresentation: $0) }
        }
    }
}

/// A dragged photo. Other apps (Finder, Messages, Mail, TextEdit, Photoshop, Pixelmator) ask for
/// its file URL when it's dropped; only then is it rendered, as a full-size sRGB JPEG with its
/// edits, into a temporary folder for them to copy, so the drag itself starts instantly. Its
/// values are captured when the drag starts, so it never touches Core Data off the main thread.
///
/// (A file promise would also suit Finder, but apps that only take files ignore promises, and
/// NSFilePromiseProvider won't supply a lazily rendered file URL alongside one.)
nonisolated final class DraggedPhoto: NSPasteboardItem, NSPasteboardItemDataProvider, @unchecked Sendable {
    let source: URL
    let adjustments: PhotoAdjustments
    let fileName: String

    private let renderLock = NSLock()
    private var renderedURL: URL?

    init(objectURI: String, source: URL, adjustments: PhotoAdjustments, fileName: String) {
        self.source = source
        self.adjustments = adjustments
        self.fileName = fileName
        super.init()
        setString(objectURI, forType: .pixelLoupePhotos)
        setDataProvider(self, forTypes: [.fileURL])
    }

    /// Only written to pasteboards, never read back as this class.
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        nil
    }

    // AppKit may call this on any thread; nothing here needs the main actor.
    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .fileURL, let url = renderedFile() else { return }
        item.setString(url.absoluteString, forType: .fileURL)
    }

    /// The JPEG in a temporary folder of its own (so its name stays the original's), rendered
    /// once however often it's asked for.
    nonisolated func renderedFile() -> URL? {
        renderLock.lock()
        defer { renderLock.unlock() }
        if let renderedURL { return renderedURL }
        Self.removeOldRenders()
        let folder = Self.rendersFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let url = folder.appending(path: fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try render(to: url)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        renderedURL = url
        return url
    }

    private static let rendersFolder = FileManager.default.temporaryDirectory
        .appending(path: "Dragged Photos", directoryHint: .isDirectory)

    /// Renders from drags more than a day old, which their apps have long since copied.
    private static func removeOldRenders() {
        let cutoff = Date(timeIntervalSinceNow: -24 * 60 * 60)
        let folders = (try? FileManager.default.contentsOfDirectory(at: rendersFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders where ((try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast) < cutoff {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Renders the JPEG and waits for it: the app asking is waiting for an answer.
    private func render(to url: URL) throws {
        let done = DispatchSemaphore(value: 0)
        let result = ResultBox()
        let (source, adjustments) = (source, adjustments)
        Task {
            do {
                try await PhotoRenderer.writeJPEG(of: source, adjustments: adjustments, to: url)
            } catch {
                result.error = error
            }
            done.signal()
        }
        done.wait()
        if let error = result.error { throw error }
    }

    private final class ResultBox: @unchecked Sendable {
        var error: Error?
    }
}
