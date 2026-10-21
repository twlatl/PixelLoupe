import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

/// Times the Library's heavy operations on a large catalog, the way the app performs them.
@MainActor
enum LibraryTimings {
    struct Measurement {
        var name: String
        var seconds: Double
        var detail: String
    }

    static func time<T>(_ name: String, _ detail: (T) -> String = { _ in "" }, _ body: () throws -> T) rethrows -> (T, Measurement) {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try body()
        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return (value, Measurement(name: name, seconds: seconds, detail: detail(value)))
    }

    /// Runs the operations a user does in a large catalog and returns each one's duration.
    static func run(store: CatalogStore) throws -> [Measurement] {
        var results: [Measurement] = []
        let context = store.viewContext
        func record<T>(_ name: String, _ detail: (T) -> String = { _ in "" }, _ body: () throws -> T) rethrows -> T {
            let (value, measurement) = try time(name, detail, body)
            results.append(measurement)
            return value
        }

        // All Photographs, as the grid fetches it: a batched fetch, then the item identifiers.
        func gridFetch(_ filter: LibraryFilter, _ name: String) throws -> [NSManagedObjectID] {
            let request = Photo.fetchRequest()
            request.fetchBatchSize = 300
            request.predicate = filter.predicate
            request.sortDescriptors = filter.sortDescriptors
            let controller = NSFetchedResultsController(fetchRequest: request, managedObjectContext: context, sectionNameKeyPath: nil, cacheName: nil)
            return try record(name, { "\($0.count) photos" }) {
                try controller.performFetch()
                return controller.fetchedObjects?.map(\.objectID) ?? []
            }
        }

        let all = try gridFetch(LibraryFilter(), "All Photographs fetch + identifiers")

        // Previous Import: finding the newest import (each sidebar reload does), then showing it.
        let latestImport = record("Sidebar: Previous Import's newest import", { $0 == nil ? "none" : "found" }) {
            Photo.latestImportID(in: context)
        }
        if let latestImport {
            var previousImport = LibraryFilter()
            previousImport.scope = .previousImport(id: latestImport)
            _ = try gridFetch(previousImport, "Previous Import fetch + identifiers")
        }

        // Sidebar: the folder tree and counts.
        _ = try record("Sidebar: folder counts (grouped fetch)", { "\($0) folders" }) { () -> Int in
            let count = NSExpressionDescription()
            count.name = "count"
            count.expression = NSExpression(forFunction: "count:", arguments: [NSExpression(forKeyPath: "id")])
            count.expressionResultType = .integer64AttributeType
            let request = NSFetchRequest<NSDictionary>(entityName: "Photo")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["folder", count]
            request.propertiesToGroupBy = ["folder"]
            return try context.fetch(request).count
        }
        _ = try record("Sidebar: root folders + children", { "\($0) roots" }) { () -> Int in
            let request = Folder.fetchRequest()
            request.predicate = NSPredicate(format: "parent == nil")
            request.relationshipKeyPathsForPrefetching = ["children"]
            let roots = try context.fetch(request)
            func walk(_ folder: Folder) { for child in folder.sortedChildren { walk(child) } }
            roots.forEach(walk)
            return roots.count
        }

        // The biggest folder tree.
        let folderRequest = Folder.fetchRequest()
        folderRequest.predicate = NSPredicate(format: "parent == nil")
        let roots = try context.fetch(folderRequest)
        if let root = roots.max(by: { $0.photos.count + $0.children.count < $1.photos.count + $1.children.count }) {
            var folderFilter = LibraryFilter()
            folderFilter.scope = .folder(path: root.path)
            _ = try gridFetch(folderFilter, "Root folder fetch (whole tree)")
            if let child = root.sortedChildren.first {
                var childFilter = LibraryFilter()
                childFilter.scope = .folder(path: child.path)
                _ = try gridFetch(childFilter, "Subfolder fetch")
            }
        }

        // Smart collections: the defaults, and a rating one.
        let editing = CollectionEditing(store: store)
        editing.createDefaultSmartCollections()
        for collection in try context.fetch(PhotoCollection.fetchRequest()) where collection.kind == .smart {
            let request = Photo.fetchRequest()
            request.predicate = collection.content.predicate
            _ = try record("Smart collection count: \(collection.name)", { "\($0)" }) { try context.count(for: request) }
            var filter = LibraryFilter()
            filter.scope = .collection(id: collection.id, content: collection.content)
            _ = try gridFetch(filter, "Smart collection fetch: \(collection.name)")
        }

        // Filter bar and sorting.
        var rated = LibraryFilter(); rated.attributes.rating = 3
        _ = try gridFetch(rated, "Filter: rating >= 3")
        var flagged = LibraryFilter(); flagged.attributes.flags = [.picked, .rejected]
        _ = try gridFetch(flagged, "Filter: flags")
        var searched = LibraryFilter(); searched.text.query = "canon"
        _ = try gridFetch(searched, "Filter: search 'canon'")
        for key in PhotoSortKey.allCases {
            var sorted = LibraryFilter(); sorted.sortKey = key; sorted.ascending = false
            _ = try gridFetch(sorted, "Sort by \(key.title)")
        }

        // Select all, then change the rating of 10k photos as one undo step.
        let ten = Array(all.prefix(10_000))
        let undo = context.undoManager
        undo?.groupsByEvent = false
        undo?.removeAllActions()
        undo?.beginUndoGrouping()
        record("Set rating on \(ten.count) photos (edit + save)") {
            PhotoEditing(store: store).setRating(4, for: ten)
        }
        undo?.endUndoGrouping()
        results.append(Measurement(name: "Undo groups after rating", seconds: 0, detail: "can undo: \(undo?.canUndo ?? false), action: \(undo?.undoActionName ?? "")"))
        record("Undo the rating") { undo?.undo() }
        undo?.groupsByEvent = true
        context.refreshAllObjects()

        // Restoring a large selection.
        let ids = try context.fetch({ let r = NSFetchRequest<NSDictionary>(entityName: "Photo"); r.resultType = .dictionaryResultType; r.propertiesToFetch = ["id"]; r.fetchLimit = 5_000; return r }()).compactMap { $0["id"] as? UUID }
        _ = try record("Restore selection: fetch 1000 by id (maximumSavedSelection)", { "\($0)" }) { () -> Int in
            let request = Photo.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", Array(ids.prefix(CatalogViewState.maximumSavedSelection)))
            return try context.fetch(request).count
        }
        return results
    }

    /// The Library's views on a big catalog: the sidebar, the grid, and what a filter change costs them.
    static func runViews(store: CatalogStore) throws -> [Measurement] {
        var results: [Measurement] = []
        let state = LibraryState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)

        let (sidebar, sidebarLoad) = time("Sidebar: create + load view (folders, collections)") { () -> SidebarViewController in
            let controller = SidebarViewController(store: store, state: state)
            controller.loadViewIfNeeded()
            return controller
        }
        results.append(sidebarLoad)
        let (_, sidebarReload) = time("Sidebar: reload()") { sidebar.reload() }
        results.append(sidebarReload)

        let (grid, gridLoad) = time("Grid: create + load view (All Photographs)") { () -> GridViewController in
            let controller = GridViewController(store: store, state: state)
            window.contentViewController = controller
            controller.loadViewIfNeeded()
            controller.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
            controller.view.layoutSubtreeIfNeeded()
            return controller
        }
        results.append(gridLoad)
        results.append(time("Grid: photo count after load", { "\($0)" }) { state.photoOrder.count }.1)
        _ = grid

        let (_, filterRating) = time("Grid: filter rating >= 3 (refetch + snapshot)") {
            state.filter.attributes.rating = 3
            RunLoop.current.run(until: Date())
        }
        results.append(filterRating)
        let (_, filterClear) = time("Grid: clear filter (55k snapshot)") {
            state.filter.attributes.rating = nil
            RunLoop.current.run(until: Date())
        }
        results.append(filterClear)
        let (_, sortName) = time("Grid: sort by File Name") {
            state.filter.sortKey = .fileName
            RunLoop.current.run(until: Date())
        }
        results.append(sortName)

        if let folder = try store.viewContext.fetch(Folder.fetchRequest()).first(where: { $0.parent != nil && $0.photos.count > 20 }) {
            let (_, switchFolder) = time("Grid: switch to a folder") {
                state.filter.scope = .folder(path: folder.path)
                RunLoop.current.run(until: Date())
            }
            results.append(switchFolder)
        }
        window.contentViewController = nil
        sidebar.stop()
        return results
    }

    static func format(_ measurements: [Measurement]) -> String {
        measurements.map { String(format: "%8.0f ms  %@  %@", $0.seconds * 1000, $0.name, $0.detail) }.joined(separator: "\n")
    }
}

@Suite("Large-catalog performance")
@MainActor
struct LargeCatalogPerformanceTests {
    /// Point PIXELLOUPE_PERF_CATALOG at an imported catalog package (see the Lightroom import test's
    /// PIXELLOUPE_LR_IMPORT_PACKAGE) and PIXELLOUPE_PERF_REPORT at a file for the timings.
    @Test(
        "Times the Library on a real imported catalog",
        .enabled(if: ProcessInfo.processInfo.environment["PIXELLOUPE_PERF_CATALOG"] != nil), .timeLimit(.minutes(20)))
    func realCatalog() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["PIXELLOUPE_PERF_CATALOG"])
        let (store, opened) = try LibraryTimings.time("Open catalog") { try CatalogStore.open(at: URL(fileURLWithPath: path, isDirectory: true)) }
        var results = [opened] + (try LibraryTimings.run(store: store)) + (try LibraryTimings.runViews(store: store))
        // Checking 55k files on disk (off the main thread): how long until the badges are right.
        let clock = ContinuousClock()
        let start = clock.now
        store.availability.refresh()
        await store.availability.waitForRefresh()
        let elapsed = clock.now - start
        results.append(.init(
            name: "Background: file availability check", seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            detail: "\(store.availability.missingPhotoIDs.count) missing, \(store.availability.offlineFolderPaths.count) offline folders"))
        let report = LibraryTimings.format(results)
        print(report)
        if let output = ProcessInfo.processInfo.environment["PIXELLOUPE_PERF_REPORT"] {
            try report.write(toFile: output, atomically: true, encoding: .utf8)
        }
    }
}

/// A catalog like the 55k Lightroom reference (photos, 1,500 folders under 2 roots, 300 keywords,
/// about 37k keyword assignments), built directly so the performance test needs no Lightroom.
enum SyntheticCatalog {
    static func make(at packageURL: URL, photos: Int = 50_000, folders folderCount: Int = 1_500, tags tagCount: Int = 300) throws -> CatalogStore {
        let store = try CatalogStore.create(at: packageURL, info: CatalogInfo(name: "Synthetic", storageMode: .referenced))
        let context = store.newBackgroundContext()
        try context.performAndWait {
            // Two roots, each with year folders holding day folders.
            var folders: [Folder] = []
            for rootIndex in 0..<2 {
                let root = Folder(context: context)
                root.path = "/Volumes/Photos\(rootIndex)"
                root.name = "Photos\(rootIndex)"
                var years: [Folder] = []
                for year in 0..<15 {
                    let folder = Folder(context: context)
                    folder.path = root.path + "/\(2010 + year)"
                    folder.name = "\(2010 + year)"
                    folder.parent = root
                    years.append(folder)
                }
                var made = 0
                while made < folderCount / 2 - 16 {
                    let year = years[made % years.count]
                    let day = Folder(context: context)
                    day.path = year.path + "/day-\(made)"
                    day.name = "day-\(made)"
                    day.parent = year
                    folders.append(day)
                    made += 1
                }
            }
            var tags: [PixelLoupe.Tag] = []
            for index in 0..<tagCount {
                let tag = PixelLoupe.Tag(context: context)
                tag.name = "keyword \(index)"
                tags.append(tag)
            }
            try context.save()

            let base = Date(timeIntervalSince1970: 1_300_000_000)
            // Imports of 500 photos an hour apart.
            let importIDs = (0...(photos / 500)).map { _ in UUID() }
            let cameras = ["Canon EOS 5D", "Canon EOS R5", "Apple iPhone 5", "NIKON D850"]
            for index in 0..<photos {
                let photo = Photo(context: context)
                photo.id = UUID()
                photo.fileName = "IMG_\(String(format: "%05d", index)).\(index % 3 == 0 ? "CR2" : "JPG")"
                photo.fileType = index % 3 == 0 ? "CR2" : "JPG"
                let folder = folders[index % folders.count]
                photo.filePath = folder.path + "/" + photo.fileName
                photo.folder = folder
                photo.captureDate = base.addingTimeInterval(Double(index) * 600)
                photo.importDate = base.addingTimeInterval(Double(index / 500) * 3_600)
                photo.importID = importIDs[index / 500]
                photo.editDate = photo.importDate
                photo.rating = index % 25 == 0 ? Int16(1 + (index / 25) % 5) : 0
                photo.flag = index % 400 == 0 ? 1 : 0
                photo.cameraModel = cameras[index % cameras.count]
                photo.cameraMake = photo.cameraModel?.split(separator: " ").first.map(String.init)
                photo.pixelWidth = 6000
                photo.pixelHeight = 4000
                // About 37k assignments over a third of the photos... plus some doubles.
                if index % 3 != 2 {
                    for offset in 0..<(index % 5 == 0 ? 2 : 1) { photo.tags.insert(tags[(index * 7 + offset * 31) % tags.count]) }
                }
                if index % 2_000 == 1_999 {
                    try context.save()
                    context.reset()
                    // The folder and tag objects were reset with the context: fetch them again.
                    folders = try context.fetch(Folder.fetchRequest()).filter { $0.children.isEmpty }
                        .sorted { $0.path < $1.path }
                    tags = try context.fetch(PixelLoupe.Tag.fetchRequest()).sorted { $0.name < $1.name }
                }
            }
            try context.save()
        }
        // Reopen from disk, as the app does.
        let coordinator = store.container.persistentStoreCoordinator
        for persistent in coordinator.persistentStores { try coordinator.remove(persistent) }
        return try CatalogStore.open(at: packageURL)
    }
}

extension LargeCatalogPerformanceTests {
    @Test("A synthetic 50,000-photo catalog opens, filters and edits within the speed budget", .timeLimit(.minutes(10)))
    func syntheticCatalog() throws {
        let directory = try TemporaryDirectory()
        let (store, built) = try LibraryTimings.time("Build synthetic catalog") {
            try SyntheticCatalog.make(at: directory.url.appending(path: "Synthetic.pixelloupe", directoryHint: .isDirectory))
        }
        let (_, opened) = LibraryTimings.time("Open catalog") { () -> Int in (try? store.viewContext.count(for: Photo.fetchRequest())) ?? 0 }
        var measurements = [built, opened] + (try LibraryTimings.run(store: store)) + (try LibraryTimings.runViews(store: store))
        // A catalog from before import ids were recorded: finding it has no Previous Import is as quick.
        let clear = NSBatchUpdateRequest(entityName: "Photo")
        clear.propertiesToUpdate = [#keyPath(Photo.importID): NSExpression(forConstantValue: nil)]
        try store.viewContext.execute(clear)
        let (latest, noImports) = LibraryTimings.time("Sidebar: no Previous Import (no import ids)") {
            Photo.latestImportID(in: store.viewContext)
        }
        #expect(latest == nil)
        measurements.append(noImports)
        print(LibraryTimings.format(measurements))
        if let output = ProcessInfo.processInfo.environment["PIXELLOUPE_PERF_REPORT"] {
            try LibraryTimings.format(measurements).write(toFile: output + ".synthetic", atomically: true, encoding: .utf8)
        }
        func seconds(_ prefix: String) throws -> Double {
            try #require(measurements.first { $0.name.hasPrefix(prefix) }, "no measurement named \(prefix)").seconds
        }
        // The ticket's budgets, with headroom for a busy machine: the grid, folder and collection
        // switches, and a 10,000-photo rating edit.
        #expect(try seconds("All Photographs fetch") < 1.0)
        #expect(try seconds("Subfolder fetch") < 0.3)
        #expect(try seconds("Root folder fetch") < 0.5)
        #expect(try seconds("Smart collection fetch: Five Stars") < 0.3)
        #expect(try seconds("Smart collection count: Without Keywords") < 0.3)
        #expect(try seconds("Sidebar: folder counts") < 0.3)
        #expect(try seconds("Sidebar: Previous Import") < 0.3)
        #expect(try seconds("Previous Import fetch") < 0.3)
        #expect(try seconds("Sidebar: no Previous Import") < 0.3)
        #expect(try seconds("Filter: rating") < 0.3)
        #expect(try seconds("Set rating on") < 1.0)
        #expect(try seconds("Grid: create + load view") < 1.0)
        #expect(try seconds("Grid: switch to a folder") < 0.3)
        // One undo step for the whole rating change.
        let undo = measurements.first { $0.name == "Undo groups after rating" }
        #expect(undo?.detail == "can undo: true, action: Set Rating")
    }
}

@Suite("Sidebar reloads")
@MainActor
struct SidebarReloadTests {
    @Test("A burst of edits rebuilds the sidebar once, shortly afterwards, not once per edit")
    func coalescesEdits() async throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let context = store.viewContext
        var photos: [Photo] = []
        for index in 0..<30 {
            let photo = Photo(context: context)
            photo.id = UUID()
            photo.fileName = "\(index).jpg"
            photo.captureDate = Date()
            photo.importDate = Date()
            photo.editDate = Date()
            photos.append(photo)
        }
        try context.save()
        let sidebar = SidebarViewController(store: store, state: LibraryState())
        sidebar.loadViewIfNeeded()
        // Let the load's own change notifications settle.
        try await Task.sleep(for: .milliseconds(500))
        let before = sidebar.reloadCount

        for (index, photo) in photos.enumerated() {
            photo.rating = Int16(index % 5)
            try context.save()
        }
        // Nothing has been rebuilt yet: the edits only scheduled one reload.
        #expect(sidebar.reloadCount == before)
        try await Task.sleep(for: .milliseconds(600))
        #expect(sidebar.reloadCount == before + 1)
        sidebar.stop()
    }
}
