import CoreData
import CoreGraphics
import Foundation

enum AppMode: Int, CaseIterable {
    case library
    case develop
    /// Photos with a location, as pins on a map (RAW-165).
    case map

    var title: String {
        switch self {
        case .library: "Library"
        case .develop: "Develop"
        case .map: "Map"
        }
    }

    /// Whether the right column shows the Library's inspector (Library and Map) rather than Develop's panel.
    var showsLibraryInspector: Bool { self != .develop }
}

enum DevelopTool {
    case adjust
    /// Lightroom presets (RAW-13).
    case presets
    case crop
    case lens
    case mask
    case retouch
    case history
}

/// How the Library shows the selected photo.
enum PhotoPresentation {
    case grid
    /// Enlarged to fill the grid area (Return or double-click).
    case loupe
    /// Black, full-screen view on the window's display (F).
    case fullScreen
    /// Two photos side by side (C), in Library or Develop.
    case compare
    /// Every selected photo side by side (N), to pick the best; the active one is first in the selection.
    case survey
}

/// UI state shared by the views of a catalog window.
final class LibraryState {
    enum Change {
        case filter
        /// The Library Filter bar was shown or hidden (\).
        case filterBar
        /// The Library Filter's Metadata columns were resized.
        case metadataBrowserHeight
        case selection
        case thumbnailSize
        case mode
        case photoCount
        case importStatus
        case presentation
        case loupe
        case photoOrder
        case filmstrip
        case compare
        case developTool
        /// Develop's Before/After view (View ▸ Before/After).
        case beforeAfter
        /// The zoom (Navigator, click-to-zoom, Z): Fit or Fill, the zoom ratio, zoomed or not, where.
        case zoom
        /// The part of the photo the enlarged view or Develop shows, for the Navigator's rectangle.
        case zoomVisibleRect
        /// The photo as a preset being hovered would make it, for the Navigator.
        case navigatorPreview
        /// The photo under the pointer in the grid or filmstrip.
        case hover
        /// Whether the grid and filmstrip report the photo under the pointer.
        case hoverTracking
    }

    struct ImportStatus: Equatable {
        var completed: Int
        var total: Int
    }

    static let thumbnailSizeRange: ClosedRange<Double> = 80...400
    static let thumbnailSizeKey = "ThumbnailSize"
    /// Where the thumbnail size is saved: the main window's, or the secondary window's own.
    private let thumbnailSizeKey: String

    var filter = LibraryFilter() {
        didSet { if filter != oldValue { notify(.filter) } }
    }

    /// Selected photos in grid order.
    var selectedPhotoIDs: [NSManagedObjectID] = [] {
        didSet { if selectedPhotoIDs != oldValue { notify(.selection) } }
    }

    var thumbnailSize: Double {
        didSet {
            let clamped = thumbnailSize.clamped(to: Self.thumbnailSizeRange)
            if clamped != thumbnailSize { thumbnailSize = clamped; return }
            guard thumbnailSize != oldValue else { return }
            Defaults.store.set(thumbnailSize, forKey: thumbnailSizeKey)
            notify(.thumbnailSize)
        }
    }

    var mode: AppMode = .library {
        didSet { if mode != oldValue { notify(.mode) } }
    }

    /// The Develop sidebar's tool: Adjust (the RAW tools) or Crop & Straighten.
    var developTool: DevelopTool = .adjust {
        didSet { if developTool != oldValue { notify(.developTool) } }
    }

    /// How Develop shows the photo before its edits (`nil`: just the edited photo). Kept from photo
    /// to photo, as in Lightroom.
    var beforeAfter: BeforeAfterView? {
        didSet { if beforeAfter != oldValue { notify(.beforeAfter) } }
    }

    /// Whether the Develop loupe is showing.
    var isLoupeVisible = false {
        didSet { if isLoupeVisible != oldValue { notify(.loupe) } }
    }

    /// The Select (left) and Candidate (right) photos while comparing.
    var comparePhotos: (select: NSManagedObjectID, candidate: NSManagedObjectID)? {
        didSet { notify(.compare) }
    }

    /// Which Compare pane is active (0 = Select, 1 = Candidate). The active photo is first in
    /// `selectedPhotoIDs`, so ratings and Develop edits apply to it.
    var activeCompareIndex = 0 {
        didSet { if activeCompareIndex != oldValue { notify(.compare) } }
    }

    var presentation: PhotoPresentation = .grid {
        didSet { if presentation != oldValue { notify(.presentation) } }
    }

    /// Photos in the grid, in display order; used to step through photos when enlarged.
    var photoOrder: [NSManagedObjectID] = [] {
        didSet {
            photoCount = photoOrder.count
            if photoOrder != oldValue { notify(.photoOrder) }
        }
    }

    private static let filmstripVisibleKey = "FilmstripVisible"

    /// Whether the filmstrip along the bottom of the window is showing (F6).
    var isFilmstripVisible = Defaults.store.object(forKey: LibraryState.filmstripVisibleKey) as? Bool ?? true {
        didSet {
            guard isFilmstripVisible != oldValue else { return }
            Defaults.store.set(isFilmstripVisible, forKey: Self.filmstripVisibleKey)
            notify(.filmstrip)
        }
    }

    /// Whether the Library Filter bar is showing above the grid (\ in Library). Hiding it keeps its
    /// filters, as in Lightroom; the filmstrip says when photos are filtered out.
    var isFilterBarVisible = true {
        didSet { if isFilterBarVisible != oldValue { notify(.filterBar) } }
    }

    static let metadataBrowserHeightRange: ClosedRange<Double> = 80...480

    /// The height of the Library Filter's Metadata columns (drag their bottom edge), saved with the
    /// catalog. Not part of the filter, so resizing doesn't refetch the grid.
    var metadataBrowserHeight: Double = 160 {
        didSet {
            let clamped = metadataBrowserHeight.clamped(to: Self.metadataBrowserHeightRange)
            if clamped != metadataBrowserHeight { metadataBrowserHeight = clamped; return }
            if metadataBrowserHeight != oldValue { notify(.metadataBrowserHeight) }
        }
    }

    /// Number of photos currently shown in the grid.
    private(set) var photoCount = 0 {
        didSet { if photoCount != oldValue { notify(.photoCount) } }
    }

    /// Number of photos in the grid's source (folder, collection…) before the filter bar's criteria,
    /// for the filmstrip's "42 of 310 photos". Set by the grid.
    var scopePhotoCount = 0 {
        didSet { if scopePhotoCount != oldValue { notify(.photoCount) } }
    }

    /// Selects the photo `offset` places from the current one in grid order. Returns false at either end.
    @discardableResult
    func stepSelection(by offset: Int) -> Bool {
        guard let current = selectedPhotoIDs.first,
              let index = photoOrder.firstIndex(of: current),
              photoOrder.indices.contains(index + offset) else { return false }
        selectedPhotoIDs = [photoOrder[index + offset]]
        return true
    }

    /// How the enlarged Library view and Develop show the photo. Shared, so the Navigator, a click on
    /// the photo and Z all act on the same zoom, and it carries over from photo to photo and between
    /// the modules (as in Lightroom).
    var zoom = PhotoZoom() {
        didSet { if zoom != oldValue { notify(.zoom) } }
    }

    /// The part of the photo the view on screen shows, in unit photo coordinates (origin bottom-left);
    /// `nil` when it shows all of it. Set by that view after it lays out, zooms or pans.
    var zoomVisibleRect: CGRect? {
        didSet { if zoomVisibleRect != oldValue { notify(.zoomVisibleRect) } }
    }

    /// Develop's preview of a preset under the pointer, shown in the Navigator in place of the photo's
    /// thumbnail (`nil` shows the thumbnail).
    var navigatorPreview: CGImage? {
        didSet { if navigatorPreview !== oldValue { notify(.navigatorPreview) } }
    }

    /// The photo under the pointer in the grid or filmstrip (nil when it's over neither), which the
    /// secondary window's Loupe – Live shows.
    var hoveredPhotoID: NSManagedObjectID? {
        didSet { if hoveredPhotoID != oldValue { notify(.hover) } }
    }

    /// Set while something needs `hoveredPhotoID` (Loupe – Live), so the grid and filmstrip only
    /// track the pointer then.
    var tracksHover = false {
        didSet {
            guard tracksHover != oldValue else { return }
            if !tracksHover { hoveredPhotoID = nil }
            notify(.hoverTracking)
        }
    }

    var importStatus: ImportStatus? {
        didSet { if importStatus != oldValue { notify(.importStatus) } }
    }

    /// The import under way, which Previous Import shows from its start, before its first photo is in.
    var importingID: UUID?

    /// File ▸ Export's progress, shown like import's.
    var exportStatus: ImportStatus? {
        didSet { if exportStatus != oldValue { notify(.importStatus) } }
    }

    /// Publish's progress (RAW-179), shown like import's.
    var publishStatus: ImportStatus? {
        didSet { if publishStatus != oldValue { notify(.importStatus) } }
    }

    /// The service `publishStatus` is for.
    var publishingServiceName = ""

    /// Photo ▸ Photo Merge's progress, in percent, shown like import's.
    var mergeStatus: ImportStatus? {
        didSet { if mergeStatus != oldValue { notify(.importStatus) } }
    }

    /// Which kind of merge `mergeStatus` is for.
    var mergeKind = PhotoMergeKind.hdr

    /// A note about the merge that just finished (a panorama that left photos out), shown where the
    /// progress was for a few seconds.
    var mergeMessage: String? {
        didSet { if mergeMessage != oldValue { notify(.importStatus) } }
    }

    /// Photo ▸ Edit In's progress writing copies, shown like import's.
    var editInStatus: ImportStatus? {
        didSet { if editInStatus != oldValue { notify(.importStatus) } }
    }

    /// Library ▸ Previews ▸ Build Smart Previews' progress, shown like import's when nothing else is.
    var smartPreviewStatus: ImportStatus? {
        didSet { if smartPreviewStatus != oldValue { notify(.importStatus) } }
    }

    /// The editor Edit In is preparing photos for, for the progress label.
    var editInApplicationName = ""

    private var observers: [(owner: () -> AnyObject?, handler: (Change) -> Void)] = []

    init(thumbnailSizeKey: String = LibraryState.thumbnailSizeKey) {
        self.thumbnailSizeKey = thumbnailSizeKey
        let stored = Defaults.store.double(forKey: thumbnailSizeKey)
        thumbnailSize = stored > 0 ? stored.clamped(to: Self.thumbnailSizeRange) : 180
    }

    /// Calls `handler` on every change for as long as `owner` is alive.
    func addObserver(_ owner: AnyObject, handler: @escaping (Change) -> Void) {
        observers.append(({ [weak owner] in owner }, handler))
    }

    private func notify(_ change: Change) {
        observers.removeAll { $0.owner() == nil }
        for observer in observers { observer.handler(change) }
    }
}

nonisolated extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
