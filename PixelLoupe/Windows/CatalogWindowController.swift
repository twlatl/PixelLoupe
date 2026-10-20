import AppKit
import CoreData
import SwiftUI
import UniformTypeIdentifiers

/// The main window for an open catalog: sidebar plus the Library or Develop module.
final class CatalogWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSUserInterfaceValidations {
    let store: CatalogStore
    let state = LibraryState()
    var onClose: (() -> Void)?

    let rootViewController: RootViewController
    private let modeSelection = ModeSelection()
    private(set) var importTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var fullScreenController: FullScreenPhotoController?
    var editing: PhotoEditing { PhotoEditing(store: store) }

    private static let modeItem = NSToolbarItem.Identifier("mode")
    private static let importItem = NSToolbarItem.Identifier("import")
    private static let loupeItem = NSToolbarItem.Identifier("loupe")
    private static let inspectorItem = NSToolbarItem.Identifier("inspector")
    static let displayItem = NSToolbarItem.Identifier("secondaryDisplay")
    /// The secondary window (Window ▸ Secondary Display), while it's showing.
    var secondaryWindowController: SecondaryWindowController?
    /// Window ▸ Impromptu Slideshow (⌘Return), while it plays on the main window's display.
    var slideshowController: SlideshowController?
    /// The Secondary Window menu's Slideshow (⌥⇧⌘Return), while it plays on the secondary display.
    var secondarySlideshowController: SlideshowController?
    /// Window ▸ Contact Sheet windows that are open (each keeps the photos it opened with).
    var contactSheetControllers: [ContactSheetWindowController] = []
    /// The display button (shown only with more than one display).
    private(set) var displayToolbarItem: NSMenuToolbarItem?
    private let inspectorButton = NSButton()
    private let loupeButton = NSButton()

    init(store: CatalogStore) {
        self.store = store
        CollectionEditing(store: store).createDefaultSmartCollections()
        Self.restoreSelection(store.viewState, into: state, context: store.viewContext)
        store.pruneOrphanedPreviews()
        rootViewController = RootViewController(store: store, state: state)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = store.name
        window.subtitle = store.info.storageDescription
        // The name and storage show at the top of the sidebar instead (the title stays for the Window menu).
        window.titleVisibility = .hidden
        window.representedURL = store.packageURL
        window.minSize = NSSize(width: 900, height: 560)
        window.identifier = NSUserInterfaceItemIdentifier("catalogWindow")
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.contentViewController = rootViewController
        window.setContentSize(NSSize(width: 1400, height: 900))
        window.center()
        window.setFrameAutosaveName("CatalogWindow")
        window.delegate = self
        window.registerForDraggedTypes([.fileURL])

        let toolbar = NSToolbar(identifier: "CatalogToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [Self.modeItem]
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        modeSelection.onSelect = { [weak self] mode in self?.switchTo(mode) }
        store.availability.start()
        store.thumbnailMaintenance.start()
        store.smartPreviewBuilder.onProgress = { [weak self] progress in self?.state.smartPreviewStatus = progress }
        store.smartPreviewBuilder.start()
        Task { [store] in await store.smartPreviews.load() }
        store.externalEdits.start()
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange(_:)), name: AppSettings.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(secondaryDisplaySettingsDidChange(_:)),
            name: SecondaryDisplaySettings.didChangeNotification, object: nil
        )
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(undoManagerDidUndoOrRedo(_:)),
                name: name, object: store.viewContext.undoManager
            )
        }
        state.addObserver(self) { [weak self] change in
            guard let self else { return }
            switch change {
            case .mode:
                modeSelection.mode = state.mode
                updateLoupeButton()
                updateInspectorButton()
            case .loupe:
                updateLoupeButton()
            case .presentation: updateFullScreen()
            case .filter, .selection: scheduleSelectionSave()
            default: break
            }
            // Selecting a folder rechecks its files, in case a drive came back or went away.
            if case .filter = change, case .folder(let path) = state.filter.scope { store.availability.refresh(folderPath: path) }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
            return handled ? nil : event
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens the window filling the display it was last on (its usable area, below the menu bar and
    /// beside the Dock), so both sidebars get their full width. Done when a catalog is presented, not
    /// in `init`, so windows made by tests keep their size.
    func fillScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(screen.visibleFrame, display: false)
    }

    /// Edits to the catalog undo from anywhere in the window, not just while the grid has focus.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        store.viewContext.undoManager
    }

    @objc private func undoManagerDidUndoOrRedo(_ notification: Notification) {
        store.save()
        // Undoing a relink moves paths back.
        store.availability.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        saveSelection()
        store.availability.stop()
        store.thumbnailMaintenance.stop()
        store.smartPreviewBuilder.stop()
        store.externalEdits.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        state.presentation = .grid
        importTask?.cancel()
        importWindowController?.close()
        slideshowController?.stop()
        secondarySlideshowController?.stop()
        for controller in contactSheetControllers { controller.close() }
        // Closed quietly, so it reopens with the next catalog.
        secondaryWindowController?.closeQuietly()
        secondaryWindowController = nil
        exportTask?.cancel()
        mergeTask?.cancel()
        editInTask?.cancel()
        store.save()
        rootViewController.main.sidebar.stop()
        onClose?()
    }

    // MARK: - Saved selection

    private var selectionSave: DispatchWorkItem?

    /// Shows the folder and photos that were selected when the catalog was last closed.
    private static func restoreSelection(_ viewState: CatalogViewState, into state: LibraryState, context: NSManagedObjectContext) {
        if let id = viewState.collectionID, let collection = PhotoCollection.with(id: id, in: context) {
            state.filter.scope = .collection(id: id, content: collection.content)
        } else if viewState.showsPreviousImport, let id = Photo.latestImportID(in: context) {
            state.filter.scope = .previousImport(id: id)
        } else if let path = viewState.folderPath {
            let request = Folder.fetchRequest()
            request.predicate = NSPredicate(format: "path == %@", path)
            if ((try? context.count(for: request)) ?? 0) > 0 { state.filter.scope = .folder(path: path) }
        }
        guard !viewState.selectedPhotos.isEmpty else { return }
        let request = Photo.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", viewState.selectedPhotos)
        let byID = Dictionary(((try? context.fetch(request)) ?? []).map { ($0.id, $0.objectID) }) { first, _ in first }
        state.selectedPhotoIDs = viewState.selectedPhotos.compactMap { byID[$0] }
    }

    /// Saves the folder and selection shortly after they change (stepping through photos changes
    /// them often), and when the window closes.
    private func scheduleSelectionSave() {
        selectionSave?.cancel()
        let save = DispatchWorkItem { [weak self] in self?.saveSelection() }
        selectionSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: save)
    }

    func saveSelection() {
        selectionSave?.cancel()
        selectionSave = nil
        var viewState = store.viewState
        if case .folder(let path) = state.filter.scope { viewState.folderPath = path } else { viewState.folderPath = nil }
        viewState.collectionID = state.filter.scope.collectionID
        if case .previousImport = state.filter.scope { viewState.showsPreviousImport = true } else { viewState.showsPreviousImport = false }
        viewState.selectedPhotos = state.selectedPhotoIDs.prefix(CatalogViewState.maximumSavedSelection).compactMap {
            (try? store.viewContext.existingObject(with: $0) as? Photo)?.id
        }
        store.viewState = viewState
    }

    // MARK: - Modes

    private func switchTo(_ mode: AppMode) {
        state.presentation = .grid
        state.mode = mode
    }

    @objc func showLibrary(_ sender: Any?) {
        switchTo(.library)
    }

    @objc func showDevelop(_ sender: Any?) {
        switchTo(.develop)
    }

    // MARK: - Keyboard

    /// Single-key shortcuts (G, D, 0–5, P/X/U, Return, F, Escape, ← →) for the catalog window and its
    /// full-screen view. Keys typed into text fields, sheets and alerts are left alone.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let eventWindow = event.window,
              eventWindow === window || eventWindow === fullScreenController?.window
                || eventWindow === secondaryWindowController?.window,
              eventWindow.attachedSheet == nil,
              !((eventWindow.firstResponder as? NSText)?.isEditable ?? false),
              let command = KeyCommand(event: event)
        else { return false }
        if eventWindow === secondaryWindowController?.window, let secondary = secondaryWindowController {
            return performInSecondaryWindow(command, secondary)
        }
        return perform(command)
    }

    /// Returns false when the command doesn't apply, so the key reaches the focused view.
    func perform(_ command: KeyCommand) -> Bool {
        let selection = state.selectedPhotoIDs
        let cropping = state.mode == .develop && state.developTool == .crop
        let develop = rootViewController.main.develop
        // While cropping, Return applies, Esc cancels and X flips the orientation (as in Lightroom).
        if cropping {
            switch command {
            case .toggleEnlarge:
                state.developTool = .adjust
                return true
            case .exit:
                develop.cancelCrop()
                return true
            case .flag(.rejected):
                develop.flipCropOrientation()
                return true
            default:
                break
            }
        }
        switch command {
        case .cropTool:
            if state.mode != .develop {
                guard !selection.isEmpty else { return false }
                switchTo(.develop)
                state.developTool = .crop
            } else {
                state.developTool = cropping ? .adjust : .crop
            }
        case .showLibrary:
            switchTo(.library)
        case .showDevelop:
            switchTo(.develop)
        case .rating(let rating):
            guard !selection.isEmpty else { return false }
            editing.setRating(rating, for: ratingTargets)
        case .adjustRating(let step):
            guard !selection.isEmpty else { return false }
            editing.adjustRating(by: step, for: ratingTargets)
        case .flag(let flag):
            guard !selection.isEmpty else { return false }
            editing.setFlag(flag, for: ratingTargets)
        case .toggleStack:
            guard stacksInSelection else { return false }
            toggleStack(nil)
        case .moveToTopOfStack:
            guard stacksInSelection else { return false }
            moveToTopOfStack(nil)
        case .colorLabel(let label):
            guard !selection.isEmpty else { return false }
            editing.setColorLabel(label, for: ratingTargets, toggling: true)
        case .compare:
            if state.presentation == .compare {
                state.presentation = .grid
            } else {
                guard enterCompare() else { return false }
            }
        case .survey:
            if state.presentation == .survey {
                state.presentation = .grid
            } else {
                guard enterSurvey() else { return false }
            }
        case .toggleEnlarge:
            guard state.mode == .library else { return false }
            switch state.presentation {
            case .grid:
                guard !selection.isEmpty else { return false }
                state.selectedPhotoIDs = [selection[0]]
                state.presentation = .loupe
            case .loupe:
                state.presentation = .grid
            case .fullScreen, .compare, .survey:
                break
            }
        case .enlarge:
            // Like Lightroom's E: show the enlarged view, from Develop too.
            guard !selection.isEmpty else { return false }
            if state.mode != .library { switchTo(.library) }
            state.selectedPhotoIDs = [selection[0]]
            state.presentation = .loupe
        case .toggleZoom:
            // Like Lightroom's Z: in the Library grid it enlarges the photo zoomed in; otherwise it switches
            // between the Navigator's fit choice and its zoom.
            guard !selection.isEmpty, state.presentation != .compare, state.presentation != .survey,
                  state.presentation != .fullScreen else { return false }
            if state.mode == .library, state.presentation == .grid {
                state.selectedPhotoIDs = [selection[0]]
                state.zoom.isZoomed = true
                state.presentation = .loupe
            } else {
                state.zoom.toggle()
            }
        case .largerThumbnails, .smallerThumbnails:
            guard state.mode == .library, state.presentation == .grid else { return false }
            state.thumbnailSize += command == .largerThumbnails ? 40 : -40
        case .fullScreen:
            if state.presentation == .fullScreen {
                state.presentation = .grid
            } else {
                guard !selection.isEmpty else { return false }
                state.selectedPhotoIDs = [selection[0]]
                state.presentation = .fullScreen
            }
        case .exit:
            guard state.presentation != .grid else { return false }
            state.presentation = .grid
        case .addToTargetCollection:
            guard !state.selectedPhotoIDs.isEmpty else { return false }
            addToTargetCollection(nil)
        case .toggleSidebars:
            rootViewController.main.toggleSidebars()
            updateInspectorButton()
        case .removePhoto:
            // In Spot Removal, Delete removes the selected spot instead of the photo.
            if state.mode == .develop, develop.deleteSelectedSpot() { return true }
            guard !removeTargets.isEmpty else { return false }
            removePhoto(nil)
        case .showClipping:
            guard state.mode == .develop else { return false }
            rootViewController.main.develop.toggleClipping()
        case .maskingTool:
            if state.mode != .develop {
                guard !selection.isEmpty else { return false }
                switchTo(.develop)
                state.developTool = .mask
            } else {
                state.developTool = state.developTool == .mask ? .adjust : .mask
            }
        case .spotRemovalTool:
            if state.mode != .develop {
                guard !selection.isEmpty else { return false }
                switchTo(.develop)
                state.developTool = .retouch
            } else {
                state.developTool = state.developTool == .retouch ? .adjust : .retouch
            }
        case .linearMask:
            guard state.mode == .develop else { return false }
            develop.addMask(.linear)
        case .radialMask:
            guard state.mode == .develop else { return false }
            develop.addMask(.radial)
        case .maskOverlay:
            guard state.mode == .develop, state.developTool == .mask else { return false }
            develop.toggleMaskOverlay()
        case .whiteBalanceTool:
            guard state.mode == .develop, state.developTool == .adjust else { return false }
            develop.toggleWhiteBalancePicker()
        case .toggleLoupe:
            // In Develop the preview handles ` itself (press to toggle, hold and click to place).
            guard state.mode != .develop else { return false }
            toggleLoupe(nil)
        case .previous where state.presentation == .compare, .next where state.presentation == .compare:
            activeCompareController.stepCandidate(by: command == .previous ? -1 : 1)
        case .previous where state.presentation == .survey, .next where state.presentation == .survey:
            rootViewController.main.library.surveyController.stepActive(by: command == .previous ? -1 : 1)
        case .previous, .next:
            // Enlarged and full-screen views step through photos; so does Develop (the filmstrip),
            // unless a control such as a slider has keyboard focus.
            let developStrip = state.mode == .develop && !(window?.firstResponder is NSControl)
            guard state.presentation != .grid || developStrip else { return false }
            state.stepSelection(by: command == .previous ? -1 : 1)
        case .secondaryView(let view):
            guard hasSecondaryDisplay else { return false }
            setSecondaryView(view)
        }
        return true
    }

    /// Keys pressed in the secondary window: its own thumbnail size and views; ← / → step through
    /// photos while it shows one; everything else (ratings, flags, labels…) as in the main window.
    private func performInSecondaryWindow(_ command: KeyCommand, _ secondary: SecondaryWindowController) -> Bool {
        switch command {
        case .largerThumbnails, .smallerThumbnails:
            guard secondary.view == .grid else { return false }
            secondary.state.thumbnailSize += command == .largerThumbnails ? 40 : -40
        case .enlarge, .toggleEnlarge:
            setSecondaryView(secondary.view == .grid ? .loupe : .grid)
        case .exit:
            guard secondary.view != .grid else { return false }
            setSecondaryView(.grid)
        case .compare:
            setSecondaryView(secondary.view == .compare ? .grid : .compare)
        case .toggleZoom:
            // Z or Space: the loupe's own zoom (the choices along the bottom of the screen).
            guard secondary.view != .grid, secondary.view != .compare, secondary.view != .survey else { return false }
            secondary.state.zoom.toggle()
        case .previous where secondary.view == .compare, .next where secondary.view == .compare:
            secondary.content.compare.stepCandidate(by: command == .previous ? -1 : 1)
        case .previous where secondary.view == .survey, .next where secondary.view == .survey:
            secondary.content.survey.stepActive(by: command == .previous ? -1 : 1)
        case .previous, .next:
            // Live and Locked show a photo of their own; ← / → step the selection in Normal.
            guard secondary.view == .loupe else { return false }
            secondary.state.stepSelection(by: command == .previous ? -1 : 1)
        case .rating, .adjustRating, .flag, .colorLabel, .secondaryView, .showLibrary, .showDevelop, .addToTargetCollection:
            return perform(command)
        default:
            return false
        }
        return true
    }

    /// Ratings and flags apply to the active photo while comparing or surveying, otherwise to the selection.
    private var ratingTargets: [NSManagedObjectID] {
        state.presentation == .compare || state.presentation == .survey
            ? Array(state.selectedPhotoIDs.prefix(1)) : state.selectedPhotoIDs
    }

    private var activeCompareController: CompareViewController {
        rootViewController.main.library.compareController
    }

    /// Compares the first two selected photos, or the selected photo and the next one. Compare is a
    /// Library view, as in Lightroom: from Develop this switches to Library first.
    @discardableResult
    private func enterCompare() -> Bool {
        guard let pair = ComparePair.make(selection: state.selectedPhotoIDs, order: state.photoOrder) else { return false }
        if state.mode != .library { switchTo(.library) }
        state.comparePhotos = pair
        state.activeCompareIndex = 0
        state.selectedPhotoIDs = [pair.select, pair.candidate]
        state.presentation = .compare
        return true
    }

    /// Surveys the selected photos (Lightroom's N). Survey is a Library view: from Develop this
    /// switches to Library first.
    @discardableResult
    private func enterSurvey() -> Bool {
        guard !state.selectedPhotoIDs.isEmpty else { return false }
        if state.mode != .library { switchTo(.library) }
        state.presentation = .survey
        return true
    }

    // MARK: - Rotate and flip (Photo menu)

    private func changeOrientation(_ change: PhotoAdjustments.OrientationChange) {
        if state.mode == .develop, state.developTool == .crop { rootViewController.main.develop.commitCrop() }
        editing.apply(change, to: state.selectedPhotoIDs)
    }

    @objc func rotateLeft(_ sender: Any?) { changeOrientation(.rotateLeft) }
    @objc func rotateRight(_ sender: Any?) { changeOrientation(.rotateRight) }
    @objc func flipHorizontal(_ sender: Any?) { changeOrientation(.flipHorizontal) }
    @objc func flipVertical(_ sender: Any?) { changeOrientation(.flipVertical) }

    @objc func resetToCameraOrientation(_ sender: Any?) {
        editing.resetOrientation(of: state.selectedPhotoIDs, rereadMetadata: false)
    }

    @objc func restoreOrientationFromMetadata(_ sender: Any?) {
        editing.resetOrientation(of: state.selectedPhotoIDs, rereadMetadata: true)
    }

    @objc func cropTool(_ sender: Any?) {
        _ = perform(.cropTool)
    }

    @objc func compare(_ sender: Any?) {
        _ = perform(.compare)
    }

    @objc func survey(_ sender: Any?) {
        _ = perform(.survey)
    }

    /// The bottom toolbar's view buttons (Grid, Loupe, Compare, Survey), which do what their keys do.
    @objc func chooseLibraryView(_ sender: ViewModeControl) {
        guard let view = sender.chosenView else { return }
        _ = perform(view.command)
    }

    @objc func showClipping(_ sender: Any?) {
        _ = perform(.showClipping)
    }

    @objc func whiteBalanceSelector(_ sender: Any?) {
        _ = perform(.whiteBalanceTool)
    }

    @objc func maskingTool(_ sender: Any?) { _ = perform(.maskingTool) }
    @objc func spotRemovalTool(_ sender: Any?) { _ = perform(.spotRemovalTool) }
    @objc func addLinearMask(_ sender: Any?) { _ = perform(.linearMask) }
    @objc func addRadialMask(_ sender: Any?) { _ = perform(.radialMask) }
    @objc func showMaskOverlay(_ sender: Any?) { _ = perform(.maskOverlay) }

    /// F6, as in Lightroom.
    @objc func toggleFilmstrip(_ sender: Any?) {
        state.isFilmstripVisible.toggle()
    }

    /// Shows or hides the Develop loupe, switching to Develop if needed.
    @objc func toggleLoupe(_ sender: Any?) {
        if state.mode != .develop {
            switchTo(.develop)
            state.isLoupeVisible = true
        } else {
            state.isLoupeVisible.toggle()
        }
        updateLoupeButton()
    }

    /// The collection dialog last shown (for tests).
    var lastCollectionDialog: CollectionDialog?
    /// The Copy / Sync Settings dialog last shown (for tests).
    var lastDevelopSettingsDialog: DevelopSettingsDialogModel?
    /// Develop Settings ▸ Auto White Balance or Auto Settings, while it works out the photos' settings.
    var autoDevelopTask: Task<Void, Never>?
    /// The last Synchronize Folder dialog shown (tests drive it).
    var lastSynchronizeModel: SynchronizeFolderModel?
    /// The running export (File ▸ Export…), cancelled from the bottom bar.
    var exportTask: Task<Void, Never>?
    var lightroomReportController: LightroomImportReportWindowController?
    var lastExportDialog: ExportDialogController?
    /// Photo ▸ Photo Merge's merge (HDR or Panorama), running in the background.
    var mergeTask: Task<Void, Never>?
    var mergeSheet: NSWindowController?
    /// Photo ▸ Edit In's copies being written.
    var editInTask: Task<Void, Never>?
    var editInSheet: EditPhotoSheetController?

    /// ⌘K: the cursor in the right sidebar's Keywords field (switching to the Library and showing
    /// the sidebar if needed).
    @objc func addKeywords(_ sender: Any?) {
        guard !state.selectedPhotoIDs.isEmpty else { return }
        if state.mode != .library { switchTo(.library) }
        if [.fullScreen, .compare, .survey].contains(state.presentation) { state.presentation = .grid }
        rootViewController.main.addKeywords()
        updateInspectorButton()
    }

    /// The toolbar's `sidebar.right` button: the Library's inspector, or Develop's panel. It stays in
    /// the toolbar in both modules so the Library/Develop control doesn't move when switching.
    @objc func toggleRightSidebar(_ sender: Any?) {
        rootViewController.main.toggleRightSidebar()
        updateInspectorButton()
    }

    private func updateInspectorButton() {
        showToolbarToggle(inspectorButton, isOn: rootViewController.main.isRightSidebarVisible)
    }

    private func updateLoupeButton() {
        showToolbarToggle(loupeButton, isOn: state.isLoupeVisible && state.mode == .develop)
    }

    /// A toolbar toggle draws the system accent behind it when on, whatever tint it's given. In
    /// Monochrome Mode it's a plain button instead, and shows "on" by tinting its symbol.
    private func showToolbarToggle(_ button: NSButton, isOn: Bool) {
        if AppSettings.shared.isMonochrome {
            button.setButtonType(.momentaryPushIn)
            button.state = .off
            button.contentTintColor = isOn ? Accent.color : nil
        } else {
            button.setButtonType(.pushOnPushOff)
            button.state = isOn ? .on : .off
            button.contentTintColor = nil
        }
        button.setAccessibilityValue(isOn ? "on" : "off")
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        updateInspectorButton()
        updateLoupeButton()
    }

    // MARK: - Removing photos

    /// The photos Remove Photo acts on: the selection in the grid; the photo being shown when
    /// enlarged, full screen, in Compare (the active one) or in Develop.
    private var removeTargets: [NSManagedObjectID] {
        state.mode == .library && state.presentation == .grid ? state.selectedPhotoIDs : Array(ratingTargets.prefix(1))
    }

    /// Delete: Remove Photo.
    @objc func removePhoto(_ sender: Any?) {
        confirmRemoval(of: removeTargets)
    }

    /// ⇧Delete: every selected photo, wherever it's shown.
    @objc func removeSelectedPhotos(_ sender: Any?) {
        confirmRemoval(of: state.selectedPhotoIDs)
    }

    /// ⌥⇧⌘Delete: removes the photos and moves their files to the Trash.
    @objc func removeAndTrashPhotos(_ sender: Any?) {
        let ids = state.selectedPhotoIDs
        guard !ids.isEmpty, let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = ids.count == 1 ? "Move this photo to the Trash?" : "Move these \(ids.count) photos to the Trash?"
        alert.informativeText = (ids.count == 1 ? "The photo" : "The photos")
            + " will be removed from your PixelLoupe Catalog and moved to the Finder’s Trash."
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.removeAskingAboutCopies(ids, trash: true)
        }
    }

    /// The Remove Photo dialog: remove from the catalog, or also move the files to the Trash.
    private func confirmRemoval(of ids: [NSManagedObjectID]) {
        guard !ids.isEmpty, let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        if ids.count == 1 {
            alert.messageText = "Remove Photo from PixelLoupe Catalog"
            alert.informativeText = "This photo will be removed from your PixelLoupe Catalog. Select \"Delete from Disk\" to also move the selected photos on your computer to the Finder’s trash."
        } else {
            alert.messageText = "Remove \(ids.count) Photos from PixelLoupe Catalog"
            alert.informativeText = "These \(ids.count) photos will be removed from your PixelLoupe Catalog. Select \"Delete from Disk\" to also move the selected photos on your computer to the Finder’s trash."
        }
        Self.addRemovalButtons(to: alert)
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.removeAskingAboutCopies(ids, trash: false)
            case .alertSecondButtonReturn: self?.removeAskingAboutCopies(ids, trash: true)
            default: break
            }
        }
    }

    /// Removing a master that has virtual copies not being removed asks whether to remove the copies
    /// too, as Lightroom does. Keeping them leaves them as photos of their own.
    func removeAskingAboutCopies(_ ids: [NSManagedObjectID], trash: Bool) {
        let removing = Set(ids)
        let copies = editing.photos(ids).flatMap(\.virtualCopies).filter { !removing.contains($0.objectID) }
        guard !copies.isEmpty, let window else {
            remove(ids, trash: trash)
            return
        }
        let alert = NSAlert()
        alert.messageText = copies.count == 1 ? "Also remove its virtual copy?" : "Also remove its \(copies.count) virtual copies?"
        alert.informativeText = "Virtual copies share the photo's file. If you keep them, they stay in your catalog"
            + (trash ? ", and the file stays on disk for them." : ".")
        alert.addButton(withTitle: "Remove Copies Too")
        alert.addButton(withTitle: "Keep Copies")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.remove(ids + copies.map(\.objectID), trash: trash)
            case .alertSecondButtonReturn: self?.remove(ids, trash: trash)
            default: break
            }
        }
    }

    private static func addRemovalButtons(to alert: NSAlert) {
        alert.addButton(withTitle: "Remove from PixelLoupe")
        alert.addButton(withTitle: "Delete from Disk").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
    }

    /// ⌘Delete: shows only the rejected photos in the catalog (or the folder being shown) and asks
    /// whether to delete them from disk or just remove them; then shows what was shown before.
    @objc func deleteRejectedPhotos(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        var rejected = LibraryFilter()
        rejected.scope = state.filter.scope
        rejected.flags = [.rejected]
        rejected.sortKey = state.filter.sortKey
        rejected.ascending = state.filter.ascending
        let request = Photo.fetchRequest()
        request.predicate = rejected.predicate
        request.sortDescriptors = rejected.sortDescriptors
        let ids = ((try? store.viewContext.fetch(request)) ?? []).map(\.objectID)
        guard !ids.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "There are no rejected photos to delete."
            alert.informativeText = "Mark photos as rejected with X."
            alert.beginSheetModal(for: window)
            return
        }

        let previous = (filter: state.filter, mode: state.mode, presentation: state.presentation, selection: state.selectedPhotoIDs)
        state.presentation = .grid
        state.mode = .library
        state.filter = rejected

        let alert = NSAlert()
        alert.messageText = ids.count == 1
            ? "Delete the rejected master photo from disk, or just remove it from PixelLoupe?"
            : "Delete the \(ids.count) rejected master photos from disk, or just remove them from PixelLoupe?"
        alert.informativeText = (ids.count == 1 ? "1 photo" : "\(ids.count) photos")
            + " will be removed from your PixelLoupe Catalog. Select \"Delete from Disk\" to also move the selected photos on your computer to the Finder’s trash."
        Self.addRemovalButtons(to: alert)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let removed: Set<NSManagedObjectID>
            switch response {
            case .alertFirstButtonReturn: removed = remove(ids, trash: false, actionName: "Delete Rejected Photos")
            case .alertSecondButtonReturn: removed = remove(ids, trash: true, actionName: "Delete Rejected Photos")
            default: removed = []
            }
            state.filter = previous.filter
            state.mode = previous.mode
            state.presentation = previous.presentation == .compare ? .grid : previous.presentation
            state.selectedPhotoIDs = previous.selection.filter { !removed.contains($0) }
        }
    }

    /// Removes the photos and selects the photo after them (as Lightroom does); reports files that
    /// couldn't be moved to the Trash. Returns the photos removed.
    @discardableResult
    private func remove(_ ids: [NSManagedObjectID], trash: Bool, actionName: String? = nil) -> Set<NSManagedObjectID> {
        let order = state.photoOrder
        let removing = Set(ids)
        if state.presentation == .compare || state.presentation == .survey { state.presentation = .grid }
        let failure = PhotoRemoval(store: store).remove(
            ids, trash: trash,
            actionName: actionName ?? (ids.count == 1 ? "Remove Photo" : "Remove Photos")
        )
        let removed = removing.filter { (try? store.viewContext.existingObject(with: $0))?.isDeleted ?? true }
        // The photo after the last one removed (or before it, at the end).
        if let last = order.lastIndex(where: { removed.contains($0) }) {
            let next = order[(last + 1)...].first { !removed.contains($0) } ?? order[..<last].last { !removed.contains($0) }
            state.selectedPhotoIDs = next.map { [$0] } ?? []
            if next == nil, state.presentation != .grid { state.presentation = .grid }
        } else {
            state.selectedPhotoIDs = state.selectedPhotoIDs.filter { !removed.contains($0) }
        }
        if let failure, let window {
            let alert = NSAlert()
            alert.messageText = failure.fileNames.count == 1
                ? "\(failure.fileNames[0]) couldn’t be moved to the Trash."
                : "\(failure.fileNames.count) photos couldn’t be moved to the Trash."
            alert.informativeText = "They’re still in the catalog. Check that the files aren’t locked and that you can write to their folders."
                + (failure.fileNames.count > 1 ? "\n\n" + failure.fileNames.prefix(10).joined(separator: "\n") : "")
            alert.beginSheetModal(for: window)
        }
        return Set(removed)
    }

    /// ⇧⌘R (Lightroom's Reset): clears all Develop settings of the selected photos. Undoable.
    @objc func revertToOriginal(_ sender: Any?) {
        editing.edit(state.selectedPhotoIDs, actionName: "Revert to Original") { $0.adjustments = .default }
    }

    /// ⇧⌘C: copies the selected photo's settings (all but what belongs to that photo alone: crop,
    /// rotation, spots, red eye and masks) for Paste Settings.
    @objc func copySettings(_ sender: Any?) {
        guard let photo = editing.photos(state.selectedPhotoIDs).first else { return }
        let adjustments = state.mode == .develop ? rootViewController.main.develop.currentAdjustments ?? photo.adjustments : photo.adjustments
        SettingsClipboard.content = .settings(adjustments, from: photo.fileName)
    }

    /// ⇧⌘V: applies the copied settings or preset to every selected photo, as one undoable step.
    @objc func pasteSettings(_ sender: Any?) {
        guard let content = SettingsClipboard.content else { return }
        changeDevelopSettings(state.selectedPhotoIDs, actionName: "Paste Settings", historyName: content.title) { photo, before in
            SettingsClipboard.applied(content, to: before, isRaw: SupportedImageTypes.isRaw(photo.fileURL),
                                      cameraModel: photo.cameraModel, iso: photo.iso > 0 ? Double(photo.iso) : nil)
        }
    }

    /// ⌘U (Lightroom's Auto Tone): Light ▸ Auto for the photo in Develop.
    @objc func autoLight(_ sender: Any?) {
        rootViewController.main.develop.applyAutoLight()
    }

    @objc func enlargePhoto(_ sender: Any?) {
        _ = perform(.toggleEnlarge)
    }

    @objc func viewPhotoFullScreen(_ sender: Any?) {
        _ = perform(.fullScreen)
    }

    @objc func setRatingFromMenu(_ sender: NSMenuItem) {
        editing.setRating(sender.tag, for: state.selectedPhotoIDs)
    }

    @objc func decreaseRating(_ sender: Any?) {
        editing.adjustRating(by: -1, for: state.selectedPhotoIDs)
    }

    @objc func increaseRating(_ sender: Any?) {
        editing.adjustRating(by: 1, for: state.selectedPhotoIDs)
    }

    // MARK: - Stacks

    /// Whether any selected photo is in a stack.
    private var stacksInSelection: Bool {
        editing.photos(state.selectedPhotoIDs).contains { $0.stack != nil }
    }

    /// Photos hidden by a collapsed stack can't stay selected: the stack's top photo is selected instead.
    func selectTopsOfCollapsedStacks(for photos: [Photo]? = nil) {
        var result: [NSManagedObjectID] = []
        for photo in photos ?? editing.photos(state.selectedPhotoIDs) {
            let shown = photo.isHiddenInStack ? (photo.stack?.topPhoto ?? photo) : photo
            if !result.contains(shown.objectID) { result.append(shown.objectID) }
        }
        if result != state.selectedPhotoIDs { state.selectedPhotoIDs = result }
    }

    /// ⌘G: the selected photos (in grid order) become a stack, collapsed under the first.
    @objc func groupIntoStack(_ sender: Any?) {
        let order = state.photoOrder
        let selected = state.selectedPhotoIDs.sorted { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
        let photos = editing.photos(selected)
        guard selected.count >= 2, editing.groupIntoStack(selected) else { return }
        selectTopsOfCollapsedStacks(for: photos)
    }

    /// ⇧⌘G
    @objc func unstack(_ sender: Any?) {
        editing.unstack(state.selectedPhotoIDs)
    }

    /// S: collapses or expands the stacks of the selected photos.
    @objc func toggleStack(_ sender: Any?) {
        // The photos are noted first: collapsing hides them, and the grid then drops them from the selection.
        let photos = editing.photos(state.selectedPhotoIDs)
        editing.toggleCollapsed(state.selectedPhotoIDs)
        selectTopsOfCollapsedStacks(for: photos)
    }

    /// ⇧S
    @objc func moveToTopOfStack(_ sender: Any?) {
        for id in state.selectedPhotoIDs { editing.moveToTopOfStack(id) }
    }

    @objc func removeFromStack(_ sender: Any?) {
        editing.removeFromStack(state.selectedPhotoIDs)
    }

    @objc func collapseAllStacks(_ sender: Any?) {
        let photos = editing.photos(state.selectedPhotoIDs)
        editing.setAllStacksCollapsed(true)
        selectTopsOfCollapsedStacks(for: photos)
    }

    @objc func expandAllStacks(_ sender: Any?) {
        editing.setAllStacksCollapsed(false)
    }

    /// Clicking the count badge of a stack in the grid collapses or expands it.
    @objc func toggleStackFromBadge(_ sender: Any?) {
        guard let id = (sender as? PhotoGridCellView)?.photoObjectID else { return }
        editing.toggleCollapsed([id])
        state.selectedPhotoIDs = [id]
    }

    /// ⌘': a virtual copy of each selected photo, inserted after its master and selected.
    @objc func createVirtualCopy(_ sender: Any?) {
        guard !state.selectedPhotoIDs.isEmpty else { return }
        let copies = editing.createVirtualCopies(of: state.selectedPhotoIDs)
        if !copies.isEmpty { state.selectedPhotoIDs = copies }
    }

    /// Makes the selected virtual copy the master of its group.
    @objc func setCopyAsMaster(_ sender: Any?) {
        guard let id = state.selectedPhotoIDs.first, state.selectedPhotoIDs.count == 1 else { return }
        editing.setAsMaster(id)
    }

    @objc func setColorLabelFromMenu(_ sender: NSMenuItem) {
        editing.setColorLabel(ColorLabel(rawValue: Int16(sender.tag)) ?? .none, for: state.selectedPhotoIDs)
    }

    @objc func setFlagFromMenu(_ sender: NSMenuItem) {
        editing.setFlag(PhotoFlag(rawValue: Int16(sender.tag)) ?? .unflagged, for: state.selectedPhotoIDs)
    }

    private func updateFullScreen() {
        if state.presentation == .fullScreen {
            guard fullScreenController == nil, let screen = window?.screen ?? NSScreen.main else { return }
            let controller = FullScreenPhotoController(store: store, state: state, screen: screen)
            fullScreenController = controller
            controller.present()
        } else if let controller = fullScreenController {
            fullScreenController = nil
            controller.dismiss()
            window?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Import

    @objc func importPhotos(_ sender: Any?) {
        showImportWindow(source: nil)
    }

    /// The import window, while it's open.
    private(set) var importWindowController: ImportWindowController?

    /// Opens the import window (bringing it forward if it's open), showing `source` if given.
    func showImportWindow(source: ImportWindowController.Source?) {
        guard importTask == nil else { return }
        if let importWindowController {
            if let source { importWindowController.open(source) } else { importWindowController.showWindow(nil) }
            return
        }
        let controller = ImportWindowController(
            service: ImportService(store: store), catalogURL: store.packageURL, info: store.info, source: source)
        controller.window?.title = "Import Photos into “\(store.info.name)”"
        controller.onImport = { [weak self] candidates, transfer, destination, extras, card in
            self?.runImport(candidates, transfer: transfer, destination: destination, extras: extras, eject: card)
        }
        controller.onClose = { [weak self] in self?.importWindowController = nil }
        importWindowController = controller
        controller.showWindow(nil)
    }

    /// Imports what the import window checked. The Library switches to Previous Import at once, so
    /// photos appear as they come in; the import window shows the progress, and closes when it's done
    /// (or lists what failed). Cancel there stops the import, keeping what's in so far.
    func runImport(
        _ candidates: [ImportService.Candidate], transfer: ImportTransfer, destination: ImportDestination,
        extras: ImportExtras = ImportExtras(), eject card: URL? = nil
    ) {
        let service = ImportService(store: store)
        let importID = UUID()
        state.presentation = .grid
        state.mode = .library
        state.importingID = importID
        state.filter.scope = .previousImport(id: importID)
        rootViewController.main.sidebar.reload()
        importWindowController?.onCancelImport = { [weak self] in self?.importTask?.cancel() }
        importTask = Task { [weak self] in
            defer {
                self?.importTask = nil
                self?.state.importStatus = nil
            }
            do {
                let summary = try await service.importPhotos(
                    candidates, transfer: transfer, destination: destination, extras: extras, importID: importID
                ) { progress in
                    self?.state.importStatus = LibraryState.ImportStatus(completed: progress.completed, total: progress.total)
                    self?.importWindowController?.importDidProgress(progress)
                }
                self?.importWindowController?.importDidFinish(failures: summary.failures)
                self?.announce(Self.importMessage(for: summary))
                // Eject After Import: only when everything came across, so nothing is left to retry.
                if let card, summary.failures.isEmpty, let error = await ImportCards.eject(card) {
                    self?.showError(error)
                }
            } catch is CancellationError {
                self?.importWindowController?.importDidFinish(failures: [])
                self?.announceStoppedImport(importID)
            } catch {
                self?.importWindowController?.importDidFinish(failures: [])
                self?.showError(error)
            }
            // Previous Import falls back to the import before when nothing came in.
            self?.state.importingID = nil
            self?.rootViewController.main.sidebar.reload()
        }
    }

    /// "Imported 34 photos · 6 already in the catalog", for the pill over the photos.
    static func importMessage(for summary: ImportSummary) -> String {
        var parts = [summary.imported == 1 ? "Imported 1 photo" : "Imported \(summary.imported) photos"]
        if summary.skippedDuplicates > 0 { parts.append("\(summary.skippedDuplicates) already in the catalog") }
        if summary.skippedRejected > 0 { parts.append("\(summary.skippedRejected) rejected left out") }
        if !summary.failures.isEmpty { parts.append("\(summary.failures.count) failed") }
        return parts.joined(separator: " · ")
    }

    private func announceStoppedImport(_ importID: UUID) {
        let request = Photo.fetchRequest()
        request.predicate = NSPredicate(format: "importID == %@", importID as CVarArg)
        let count = (try? store.viewContext.count(for: request)) ?? 0
        announce("Import stopped · \(count == 1 ? "1 photo" : "\(count) photos") imported")
    }

    private func announce(_ message: String) {
        rootViewController.main.markOverlay.show(.message(message))
    }

    // Files and folders dropped on the window open the import window with them.

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        importableURLs(in: sender).isEmpty ? [] : .copy
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = importableURLs(in: sender)
        guard !urls.isEmpty, importTask == nil else { return false }
        showImportWindow(source: ImportWindowController.Source(urls: urls))
        return true
    }

    private func importableURLs(in info: any NSDraggingInfo) -> [URL] {
        // Photos dragged out of this app's own grid aren't new photos.
        guard info.draggingSource == nil else { return [] }
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(SupportedImageTypes.isImportable)
    }

    func showError(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if let valid = validateSecondaryDisplayItem(item) { return valid }
        if let valid = validateSlideshowItem(item) { return valid }
        if let valid = validateContactSheetItem(item) { return valid }
        if let valid = validateDevelopSettingsItem(item) { return valid }
        if let valid = validateFolderItem(item) { return valid }
        if let valid = validateSmartPreviewItem(item) { return valid }
        switch item.action {
        case #selector(addKeywords(_:)):
            return !state.selectedPhotoIDs.isEmpty
        case #selector(newCollection(_:)):
            // ⌘N makes a snapshot in Develop and a collection elsewhere.
            (item as? NSMenuItem)?.title = state.mode == .develop ? "New Snapshot" : "New Collection…"
            return window?.attachedSheet == nil
        case #selector(newSmartCollection(_:)), #selector(newCollectionSet(_:)):
            return window?.attachedSheet == nil
        case #selector(addToTargetCollection(_:)):
            // Shown with B in the menu; disabled while typing so the key reaches the text field.
            let typing = (window?.firstResponder as? NSText)?.isEditable ?? false
            let target = store.viewState.targetCollectionID.flatMap { collectionEditing.collection($0) }
            (item as? NSMenuItem)?.title = target.map { "Add to Target Collection (\($0.name))" } ?? "Add to Target Collection"
            return !typing && target != nil && !state.selectedPhotoIDs.isEmpty
        case #selector(removeFromCollection(_:)):
            return isShowingCollection && !state.selectedPhotoIDs.isEmpty
        case #selector(addToCollection(_:)):
            return !state.selectedPhotoIDs.isEmpty
        case #selector(importPhotos(_:)):
            return importTask == nil
        case #selector(locateMissingPhoto(_:)):
            return missingSelectedPhoto != nil
        case #selector(findMissingFolder(_:)):
            return window?.attachedSheet == nil
        case #selector(showLightroomImportReport(_:)):
            return LightroomImportReport.exists(in: store.packageURL)
        case #selector(exportPhotos(_:)), #selector(exportWithPrevious(_:)), #selector(exportWithPreset(_:)):
            return exportTask == nil && window?.attachedSheet == nil && !state.selectedPhotoIDs.isEmpty
        case #selector(cancelExport(_:)):
            return exportTask != nil
        case #selector(photoMergeHDR(_:)), #selector(photoMergePanorama(_:)), #selector(photoMergePanoramaWithPreviousSettings(_:)):
            return mergeTask == nil && window?.attachedSheet == nil
                && state.selectedPhotoIDs.count >= 2
                && editing.photos(state.selectedPhotoIDs).filter { SupportedImageTypes.isRaw($0.fileURL) }.count >= 2
        case #selector(cancelPhotoMerge(_:)):
            return mergeTask != nil
        case #selector(editInPrimary(_:)):
            return canEditIn(.primary)
        case #selector(editInAdditional(_:)):
            return canEditIn(.additional)
        case #selector(editInPreset(_:)):
            return (item as? NSMenuItem)?.representedObject.flatMap { $0 as? String }.map { canEditIn(.preset($0)) } ?? false
        case #selector(openInOtherApplication(_:)):
            return canEditIn(.otherApplication)
        case #selector(toggleFilmstrip(_:)):
            (item as? NSMenuItem)?.title = state.isFilmstripVisible ? "Hide Filmstrip" : "Show Filmstrip"
            return true
        case #selector(toggleLoupe(_:)):
            (item as? NSMenuItem)?.title = state.isLoupeVisible && state.mode == .develop ? "Hide Loupe" : "Show Loupe"
            return true
        case #selector(enlargePhoto(_:)):
            return state.mode == .library && !state.selectedPhotoIDs.isEmpty
        case #selector(rotateLeft(_:)), #selector(rotateRight(_:)), #selector(flipHorizontal(_:)),
             #selector(flipVertical(_:)), #selector(restoreOrientationFromMetadata(_:)):
            return !state.selectedPhotoIDs.isEmpty
        case #selector(resetToCameraOrientation(_:)):
            return editing.photos(state.selectedPhotoIDs).contains { !$0.adjustments.orientation.isIdentity }
        case #selector(cropTool(_:)):
            // Shown with R in the menu; disabled while typing so the key reaches the text field.
            let typing = (window?.firstResponder as? NSText)?.isEditable ?? false
            (item as? NSMenuItem)?.state = state.mode == .develop && state.developTool == .crop ? .on : .off
            return !typing && (state.mode == .develop || !state.selectedPhotoIDs.isEmpty)
        case #selector(showClipping(_:)):
            // Shown with J in the menu; disabled while typing so the key reaches the text field.
            let typing = (window?.firstResponder as? NSText)?.isEditable ?? false
            (item as? NSMenuItem)?.title = state.mode == .develop && rootViewController.main.develop.isShowingClipping
                ? "Hide Clipping" : "Show Clipping"
            return !typing && state.mode == .develop
        case #selector(maskingTool(_:)):
            let typing = (window?.firstResponder as? NSText)?.isEditable ?? false
            (item as? NSMenuItem)?.state = state.mode == .develop && state.developTool == .mask ? .on : .off
            return !typing && (state.mode == .develop || !state.selectedPhotoIDs.isEmpty)
        case #selector(spotRemovalTool(_:)):
            let typing = (window?.firstResponder as? NSText)?.isEditable ?? false
            (item as? NSMenuItem)?.state = state.mode == .develop && state.developTool == .retouch ? .on : .off
            return !typing && (state.mode == .develop || !state.selectedPhotoIDs.isEmpty)
        case #selector(addLinearMask(_:)), #selector(addRadialMask(_:)):
            let typing = (window?.firstResponder as? NSText)?.isEditable ?? false
            return !typing && state.mode == .develop
        case #selector(showMaskOverlay(_:)):
            let typing = (window?.firstResponder as? NSText)?.isEditable ?? false
            return !typing && state.mode == .develop && state.developTool == .mask
        case #selector(whiteBalanceSelector(_:)):
            // Shown with W in the menu; disabled while typing so the key reaches the text field.
            let typing = (window?.firstResponder as? NSText)?.isEditable ?? false
            return !typing && state.mode == .develop && state.developTool == .adjust
        case #selector(compare(_:)):
            // Shown with C in the menu; disabled while typing so the key reaches the text field.
            (item as? NSMenuItem)?.title = state.presentation == .compare ? "Exit Compare" : "Compare"
            let typing = (window?.firstResponder as? NSText)?.isEditable ?? false
            return !typing && (state.presentation == .compare
                || ComparePair.make(selection: state.selectedPhotoIDs, order: state.photoOrder) != nil)
        case #selector(survey(_:)):
            // Shown with N in the menu; disabled while typing so the key reaches the text field.
            (item as? NSMenuItem)?.title = state.presentation == .survey ? "Exit Survey" : "Survey"
            let typing = (window?.firstResponder as? NSText)?.isEditable ?? false
            return !typing && (state.presentation == .survey || !state.selectedPhotoIDs.isEmpty)
        case #selector(removePhoto(_:)), #selector(removeSelectedPhotos(_:)), #selector(removeAndTrashPhotos(_:)),
             #selector(deleteRejectedPhotos(_:)):
            // Shown with Delete in the menu; disabled while typing so the keys edit the text.
            let typing = (window?.firstResponder as? NSText)?.isEditable ?? false
            guard !typing, window?.attachedSheet == nil else { return false }
            switch item.action {
            case #selector(removePhoto(_:)): return !removeTargets.isEmpty
            case #selector(deleteRejectedPhotos(_:)): return true
            default: return !state.selectedPhotoIDs.isEmpty
            }
        case #selector(copySettings(_:)):
            return state.selectedPhotoIDs.count >= 1
        case #selector(pasteSettings(_:)):
            if let content = SettingsClipboard.content { (item as? NSMenuItem)?.title = "Paste Settings (\(content.title))" }
            else { (item as? NSMenuItem)?.title = "Paste Settings" }
            return SettingsClipboard.content != nil && !state.selectedPhotoIDs.isEmpty
        case #selector(revertToOriginal(_:)):
            return editing.photos(state.selectedPhotoIDs).contains { $0.adjustmentsData != nil }
        case #selector(autoLight(_:)):
            return state.mode == .develop && rootViewController.main.develop.canAutoLight
        case #selector(groupIntoStack(_:)):
            return state.selectedPhotoIDs.count >= 2
        case #selector(unstack(_:)), #selector(removeFromStack(_:)):
            return stacksInSelection
        case #selector(toggleStack(_:)), #selector(moveToTopOfStack(_:)):
            // Shown with S and ⇧S in the menu; disabled while typing so the keys reach the text field.
            let typing = (window?.firstResponder as? NSText)?.isEditable ?? false
            if item.action == #selector(toggleStack(_:)) {
                let stacks = Set(editing.photos(state.selectedPhotoIDs).compactMap(\.stack))
                (item as? NSMenuItem)?.title = !stacks.isEmpty && stacks.allSatisfy({ !$0.isCollapsed }) ? "Collapse Stack" : "Expand Stack"
            }
            return !typing && stacksInSelection
        case #selector(createVirtualCopy(_:)):
            return !state.selectedPhotoIDs.isEmpty
        case #selector(setCopyAsMaster(_:)):
            return state.selectedPhotoIDs.count == 1 && editing.photos(state.selectedPhotoIDs).first?.isVirtualCopy == true
        case #selector(setRatingFromMenu(_:)), #selector(setFlagFromMenu(_:)), #selector(decreaseRating(_:)),
             #selector(increaseRating(_:)):
            // Shown with 0–5, [ ], P, U and X; disabled while typing so the keys reach the text field.
            let typing = (window?.firstResponder as? NSText)?.isEditable ?? false
            return !typing && !state.selectedPhotoIDs.isEmpty
        case #selector(viewPhotoFullScreen(_:)), #selector(setColorLabelFromMenu(_:)):
            return !state.selectedPhotoIDs.isEmpty
        default:
            return true
        }
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The flexible space puts the sidebar button flush right in the sidebar, clear of the Navigator below.
        [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.modeItem, .flexibleSpace, Self.loupeItem, Self.importItem,
         Self.displayItem, Self.inspectorItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.modeItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Module"
            let picker = NSHostingView(rootView: ModePicker(selection: modeSelection))
            picker.setAccessibilityIdentifier("modeControl")
            item.view = picker
            return item
        case .sidebarTrackingSeparator:
            // The sidebar lives in the inner split view, below the filmstrip's outer split.
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier, splitView: rootViewController.main.splitView, dividerIndex: 0
            )
        case Self.loupeItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Loupe"
            item.toolTip = "Loupe — hold ` and click to place it"
            loupeButton.image = NSImage(systemSymbolName: "loupe", accessibilityDescription: "Loupe")
                ?? NSImage(systemSymbolName: "magnifyingglass.circle", accessibilityDescription: "Loupe")
            loupeButton.setButtonType(.pushOnPushOff)
            loupeButton.bezelStyle = .toolbar
            loupeButton.imagePosition = .imageOnly
            loupeButton.target = self
            loupeButton.action = #selector(toggleLoupe(_:))
            updateLoupeButton()
            loupeButton.setAccessibilityIdentifier("loupeToolbarButton")
            item.view = loupeButton
            return item
        case Self.inspectorItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Right Sidebar"
            item.toolTip = "Show or hide the right sidebar (Tab hides both sidebars)"
            inspectorButton.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Right sidebar")
            inspectorButton.setButtonType(.pushOnPushOff)
            inspectorButton.bezelStyle = .toolbar
            inspectorButton.imagePosition = .imageOnly
            inspectorButton.target = self
            inspectorButton.action = #selector(toggleRightSidebar(_:))
            inspectorButton.setAccessibilityIdentifier("rightSidebarToolbarButton")
            item.view = inspectorButton
            updateInspectorButton()
            return item
        case Self.displayItem:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Secondary Display"
            item.toolTip = "Secondary Window (⌘F11)"
            item.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Secondary Display")
            item.menu = SecondaryDisplayMenu.make(header: true)
            item.showsIndicator = true
            displayToolbarItem = item
            updateDisplayToolbarItem()
            return item
        case Self.importItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Import"
            item.toolTip = "Import Photos (⇧⌘I)"
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Import")
            item.target = self
            item.action = #selector(importPhotos(_:))
            return item
        default:
            return nil
        }
    }
}
