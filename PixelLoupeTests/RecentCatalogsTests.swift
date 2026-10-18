import AppKit
import Foundation
import Testing
@testable import PixelLoupe

/// A throwaway preferences domain, so tests don't share (or touch) the app's recent catalogs.
private final class ScratchDefaults {
    let name = "net.pixegen.PixelLoupe.RecentCatalogsTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: name)!

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }
}

@Suite("Recent catalogs") @MainActor
struct RecentCatalogsTests {
    private let scratch = ScratchDefaults()
    private var recents: RecentCatalogs { RecentCatalogs(defaults: scratch.defaults) }

    private func catalog(_ name: String) -> URL {
        URL(filePath: "/Volumes/Photo SSD/\(name).pixelloupe", directoryHint: .isDirectory)
    }

    @Test func newestFirstAndCappedAtFive() {
        let recents = recents
        for (index, name) in ["A", "B", "C", "D", "E", "F"].enumerated() {
            recents.noteOpened(catalog(name), name: name, at: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(recents.entries.map(\.name) == ["F", "E", "D", "C", "B"])
    }

    @Test func reopeningMovesACatalogToTheTop() {
        let recents = recents
        recents.noteOpened(catalog("A"), name: "A")
        recents.noteOpened(catalog("B"), name: "B")
        recents.noteOpened(catalog("A").appending(path: ""), name: "Renamed A")
        #expect(recents.entries.map(\.name) == ["Renamed A", "B"])
        #expect(recents.entries.first?.path == "/Volumes/Photo SSD/A.pixelloupe")
    }

    @Test func persistsAcrossInstances() {
        recents.noteOpened(catalog("A"), name: "A", at: Date(timeIntervalSince1970: 100))
        let reloaded = RecentCatalogs(defaults: scratch.defaults)
        #expect(reloaded.entries == [.init(path: "/Volumes/Photo SSD/A.pixelloupe", name: "A", openedAt: Date(timeIntervalSince1970: 100))])
    }

    @Test func removeAndClear() {
        let recents = recents
        recents.noteOpened(catalog("A"), name: "A")
        recents.noteOpened(catalog("B"), name: "B")
        recents.remove(catalog("A"))
        #expect(recents.entries.map(\.name) == ["B"])
        recents.clear()
        #expect(recents.entries.isEmpty)
        #expect(scratch.defaults.object(forKey: RecentCatalogs.defaultsKey) == nil)
    }

    @Test func postsChanges() {
        let recents = recents
        nonisolated final class Counter: @unchecked Sendable { var count = 0 }
        let counter = Counter()
        let observer = NotificationCenter.default.addObserver(forName: RecentCatalogs.didChange, object: recents, queue: nil) { _ in
            counter.count += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        recents.noteOpened(catalog("A"), name: "A")
        recents.clear()
        #expect(counter.count == 2)
    }

    @Test func folderIsShownRelativeToHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let inHome = RecentCatalogs.Entry(
            path: home.appending(path: "Pictures/PixelLoupe/Iceland.pixelloupe").path(percentEncoded: false), name: "Iceland", openedAt: .now)
        #expect(inHome.displayFolder == "~/Pictures/PixelLoupe")
        let onDrive = RecentCatalogs.Entry(path: "/Volumes/Photo SSD/Family.pixelloupe", name: "Family", openedAt: .now)
        #expect(onDrive.displayFolder == "/Volumes/Photo SSD")
        #expect(!onDrive.isAvailable)
    }

    @Test(arguments: [
        (0, "Today"), (1, "Yesterday"), (3, "3 days ago"), (6, "6 days ago"), (7, "Last week"), (13, "Last week"),
    ])
    func relativeDates(daysAgo: Int, expected: String) {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 9))!
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        #expect(RecentCatalogs.relativeDate(date, now: now, calendar: calendar) == expected)
    }

    @Test func olderDatesAreShortDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 9))!
        let thisYear = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 9))!
        let lastYear = calendar.date(from: DateComponents(year: 2025, month: 9, day: 28, hour: 9))!
        #expect(RecentCatalogs.relativeDate(thisYear, now: now, calendar: calendar).contains("28"))
        #expect(!RecentCatalogs.relativeDate(thisYear, now: now, calendar: calendar).contains("2026"))
        #expect(RecentCatalogs.relativeDate(lastYear, now: now, calendar: calendar).contains("2025"))
    }

    @Test func previewPrefersTheLastSelectedPhoto() async throws {
        let directory = try TemporaryDirectory()
        let package = try directory.subdirectory("Test.pixelloupe")
        let thumbnails = try directory.subdirectory("Test.pixelloupe/Thumbnails")
        let selected = UUID()
        try Fixtures.writeJPEG(to: ThumbnailStore.url(for: UUID(), in: thumbnails), width: 40, height: 40)
        try Fixtures.writeJPEG(to: ThumbnailStore.url(for: selected, in: thumbnails), width: 80, height: 40)
        try CatalogViewState(selectedPhotos: [selected]).save(to: package)

        let image = try #require(await RecentCatalogs.previewImage(forCatalogAt: package))
        #expect(image.width == 80)
    }

    @Test func previewFallsBackToAnyThumbnailOrNothing() async throws {
        let directory = try TemporaryDirectory()
        let package = try directory.subdirectory("Test.pixelloupe")
        #expect(await RecentCatalogs.previewImage(forCatalogAt: package) == nil)
        let thumbnails = try directory.subdirectory("Test.pixelloupe/Thumbnails")
        try Fixtures.writeJPEG(to: ThumbnailStore.url(for: UUID(), in: thumbnails), width: 40, height: 30)
        #expect(await RecentCatalogs.previewImage(forCatalogAt: package)?.width == 40)
    }
}

@Suite("Open Recent menu") @MainActor
struct OpenRecentMenuTests {
    private let scratch = ScratchDefaults()

    @Test func listsCatalogsThenClearMenu() throws {
        let directory = try TemporaryDirectory()
        let available = try directory.subdirectory("Iceland 2025.pixelloupe")
        let recents = RecentCatalogs(defaults: scratch.defaults)
        recents.noteOpened(URL(filePath: "/Volumes/Missing/Family.pixelloupe"), name: "Family Archive", at: .now)
        recents.noteOpened(available, name: "Iceland 2025", at: .now)

        let menu = NSMenu()
        RecentCatalogsMenu(recents: recents, header: nil, keepingFirst: 0).fill(menu)
        #expect(menu.items.map(\.title) == ["Iceland 2025", "Family Archive", "", "Clear Menu"])
        let iceland = menu.items[0]
        #expect(iceland.isEnabled)
        #expect(iceland.action == #selector(PixelLoupeActions.openRecentCatalog(_:)))
        #expect((iceland.representedObject as? URL)?.standardizedFileURL == available.standardizedFileURL)
        #expect(iceland.subtitle?.hasSuffix("· Today") == true)
        #expect(iceland.image?.size == RecentCatalogsMenu.imageSize)
        #expect(!menu.items[1].isEnabled, "a catalog on an unmounted drive is listed but disabled")
        #expect(menu.items[3].isEnabled)
        #expect(menu.items[3].action == #selector(PixelLoupeActions.clearRecentCatalogs(_:)))
    }

    @Test func emptyListHasOnlyADisabledClearMenu() {
        let menu = NSMenu()
        RecentCatalogsMenu(recents: RecentCatalogs(defaults: scratch.defaults), header: "Recent Catalogs", keepingFirst: 0).fill(menu)
        #expect(menu.items.map(\.title) == ["Clear Menu"])
        #expect(menu.items.first?.isEnabled == false)
    }

    @Test func keepsThePullDownTitleAndAddsAHeader() {
        let recents = RecentCatalogs(defaults: scratch.defaults)
        recents.noteOpened(URL(filePath: "/Volumes/Missing/Street.pixelloupe"), name: "Street — Lisbon")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        let filler = RecentCatalogsMenu(recents: recents, header: "Recent Catalogs", keepingFirst: 1)
        filler.fill(menu)
        filler.fill(menu)
        #expect(menu.items.map(\.title) == ["Open Recent", "Recent Catalogs", "Street — Lisbon", "", "Clear Menu"])
        #expect(menu.items[1].isSectionHeader)
    }

    @Test func fileMenuHasOpenRecentUnderOpenCatalog() throws {
        let file = try #require(MainMenu.make().items.first { $0.title == "File" }?.submenu)
        let titles = file.items.map(\.title)
        let open = try #require(titles.firstIndex(of: "Open Catalog…"))
        #expect(titles[open + 1] == "Open Recent")
        #expect(file.items[open + 1].submenu?.delegate === RecentCatalogsMenu.fileMenu)
    }
}

@Suite("Welcome window") @MainActor
struct WelcomeWindowTests {
    @Test func versionComesFromTheBundle() {
        #expect(WelcomeWindowController.versionString(info: ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45"]) == "Version 1.2.3 (45)")
        #expect(WelcomeWindowController.versionString(info: nil) == "Version ? (?)")
    }

    @Test func layoutMatchesTheMockup() throws {
        let controller = WelcomeWindowController()
        let window = try #require(controller.window)
        #expect(window.contentRect(forFrameRect: window.frame).size == WelcomeWindowController.size)
        #expect(!window.styleMask.contains(.resizable))

        let views = Self.allSubviews(of: try #require(window.contentView))
        let labels = views.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(labels.contains("Welcome to PixelLoupe"))
        #expect(labels.contains(WelcomeWindowController.tagline))
        #expect(labels.contains(WelcomeWindowController.versionString()))
        #expect(labels.contains("FEATURED PHOTO"))
        #expect(labels.contains("Photo by TED · Joshua Tree National Park, California"))

        let newCatalog = try #require(views.first { $0.accessibilityIdentifier() == "newCatalogButton" } as? ProminentButton)
        #expect(newCatalog.label == "New Catalog…")
        #expect(newCatalog.keyEquivalent == "\r")
        #expect(views.contains { $0.accessibilityIdentifier() == "openCatalogButton" })
        #expect(views.contains { $0.accessibilityIdentifier() == "importLightroomCatalogButton" })
        let photo = try #require(views.first { $0.accessibilityIdentifier() == "welcomePhoto" })
        #expect(photo.accessibilityRole() == .image)

        let recent = try #require(controller.openRecentButton)
        #expect(recent.pullsDown)
        #expect(recent.itemArray.first?.title == "Open Recent")
        #expect(recent.isEnabled == !RecentCatalogs.shared.entries.isEmpty)
    }

    @Test func featuredPhotoIsInTheAssetCatalog() {
        #expect(NSImage(named: "WelcomeScreen") != nil)
    }

    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }
}

@Suite("Welcome window recent list") @MainActor
struct RecentCatalogsListTests {
    private let scratch = ScratchDefaults()

    @Test func hiddenUntilACatalogHasBeenOpened() {
        let list = RecentCatalogsListView(recents: RecentCatalogs(defaults: scratch.defaults))
        #expect(list.isHidden)
        #expect(list.tableView.numberOfRows == 0)
    }

    @Test func listsTheCatalogsNewestFirstAndGrowsToFitThem() throws {
        let directory = try TemporaryDirectory()
        let iceland = try directory.subdirectory("Iceland 2025.pixelloupe")
        let recents = RecentCatalogs(defaults: scratch.defaults)
        recents.noteOpened(URL(filePath: "/Volumes/Missing/Family.pixelloupe"), name: "Family Archive")
        recents.noteOpened(iceland, name: "Iceland 2025")
        let list = RecentCatalogsListView(recents: recents)
        #expect(!list.isHidden)
        #expect(list.entries.map(\.name) == ["Iceland 2025", "Family Archive"])
        #expect(list.tableView.numberOfRows == 2)
        list.layoutSubtreeIfNeeded()
        #expect(list.fittingSize.height == RecentCatalogsListView.height(forRows: 2))
        #expect(RecentCatalogsListView.height(forRows: 5) > RecentCatalogsListView.height(forRows: 2))

        let cell = try #require(list.tableView(list.tableView, viewFor: nil, row: 0) as? RecentCatalogCell)
        #expect(cell.textField?.stringValue == "Iceland 2025")
        #expect(cell.accessibilityLabel()?.contains("Today") == true)
        #expect(list.tableView(list.tableView, shouldSelectRow: 0))
        #expect(!list.tableView(list.tableView, shouldSelectRow: 1), "an unreachable catalog can't be chosen")
    }

    @Test func clickingACatalogAsksToOpenIt() throws {
        let directory = try TemporaryDirectory()
        let iceland = try directory.subdirectory("Iceland 2025.pixelloupe")
        let recents = RecentCatalogs(defaults: scratch.defaults)
        recents.noteOpened(iceland, name: "Iceland 2025")
        let list = RecentCatalogsListView(recents: recents)
        list.open(row: 0)
        #expect(list.recentCatalogURL?.standardizedFileURL == iceland.standardizedFileURL)
        list.open(row: 5)
        #expect(list.recentCatalogURL?.standardizedFileURL == iceland.standardizedFileURL, "rows out of range are ignored")
    }

    @Test func menuItemsCarryTheirCatalog() {
        let item = NSMenuItem()
        let url = URL(filePath: "/Volumes/Photo SSD/Family.pixelloupe")
        item.representedObject = url
        #expect(item.recentCatalogURL == url)
    }

    @Test func welcomeWindowShowsTheListUnderTheButtons() throws {
        let controller = WelcomeWindowController()
        let content = try #require(controller.window?.contentView)
        func all(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(all) }
        #expect(all(content).contains { $0 === controller.recentList })
        #expect(controller.recentList.isHidden == RecentCatalogs.shared.entries.isEmpty)
    }
}

@Suite("Catalog window size") @MainActor
struct CatalogWindowSizeTests {
    @Test func opensFillingItsDisplay() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let controller = CatalogWindowController(store: store)
        defer { controller.window?.close() }
        controller.fillScreen()
        let window = try #require(controller.window)
        let screen = try #require(window.screen ?? NSScreen.main)
        #expect(window.frame == screen.visibleFrame)
    }
}
