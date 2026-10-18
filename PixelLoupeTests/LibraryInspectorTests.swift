import AppKit
import CoreData
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PixelLoupe

@Suite("Metadata fields and sets")
struct MetadataFieldTests {
    @Test func theSetsAreLightroomsInOrder() {
        #expect(MetadataSet.all.map(\.title) == [
            "Default", "All Plug-in Metadata", "DNG", "EXIF", "EXIF and IPTC", "IPTC", "IPTC Extension",
            "Large Caption", "Location", "Minimal", "Quick Describe", "Three Dimensional Projection", "Video",
        ])
        #expect(MetadataSet.named("Default").groups[0].fields.map(\.label) == [
            "File Name", "Folder", "Title", "Caption", "Copyright", "Creator", "Rating", "Capture Date",
            "File Dimensions", "Current Dimensions",
        ])
        #expect(MetadataSet.named("IPTC").groups.compactMap(\.title) == ["Contact", "Content", "Image", "Status"])
        #expect(MetadataSet.named("Nonsense").title == "Default")
    }

    @Test func everyFieldIsDefined() {
        for id in MetadataField.ID.allCases { #expect(MetadataField.all[id] != nil, "\(id)") }
        #expect(MetadataField.field(.title).isEditable && !MetadataField.field(.fileName).isEditable)
        // IPTC calls the caption "Description"; it's the same field.
        let content = MetadataSet.named("IPTC").groups.first { $0.title == "Content" }!
        #expect(content.fields.contains { $0.id == .caption && $0.label == "Description" })
    }
}

@Suite("File metadata")
struct FileMetadataTests {
    @Test func formatsExifLikeLightroom() {
        let metadata = FileMetadata(properties: [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifExposureTime: 1.0 / 60, kCGImagePropertyExifFNumber: 3.2,
                kCGImagePropertyExifFocalLength: 5.9, kCGImagePropertyExifISOSpeedRatings: [200],
                kCGImagePropertyExifExposureBiasValue: 0.0, kCGImagePropertyExifFlash: 16,
                kCGImagePropertyExifMeteringMode: 5, kCGImagePropertyExifExposureProgram: 2,
                kCGImagePropertyExifDateTimeOriginal: "2010:04:07 12:31:39",
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon PowerShot SD780 IS",
            ] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.7749, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.4194, kCGImagePropertyGPSLongitudeRef: "W",
                kCGImagePropertyGPSAltitude: 12.5,
            ] as [CFString: Any],
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCObjectName: "Bridge", kCGImagePropertyIPTCCaptionAbstract: "At dusk",
            ] as [CFString: Any],
        ])
        #expect(metadata[.exposure] == "1/60 sec at ƒ / 3.2")
        #expect(metadata[.focalLength] == "5.9 mm")
        #expect(metadata[.isoSpeedRating] == "ISO 200")
        #expect(metadata[.exposureBias] == "0 EV")
        #expect(metadata[.flash] == "Did not fire")
        #expect(metadata[.meteringMode] == "Pattern")
        #expect(metadata[.exposureProgram] == "Normal")
        #expect(metadata[.camera] == "Canon PowerShot SD780 IS", "not \"Canon Canon…\"")
        #expect(metadata[.gps]?.hasPrefix("37°46′") == true && metadata[.gps]?.hasSuffix("W") == true)
        #expect(metadata.coordinate?.longitude ?? 0 < 0)
        #expect(metadata[.altitude] == "12.5 m")
        #expect(metadata[.dngVersion] == "Unknown")
        #expect(metadata[.title] == "Bridge" && metadata[.caption] == "At dusk")
        #expect(metadata[.dateTimeOriginal]?.contains("39") == true)
    }

    @Test func readsXMPFromTheFile() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "x.jpg")
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let xmp = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueWithPath(xmp, nil, "photoshop:Headline" as CFString, "Big news" as CFString)
        CGImageMetadataSetValueWithPath(xmp, nil, "photoshop:City" as CFString, "Lisbon" as CFString)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImageAndMetadata(destination, context.makeImage()!, xmp, nil)
        #expect(CGImageDestinationFinalize(destination))
        let metadata = FileMetadata.read(from: url)
        #expect(metadata[.headline] == "Big news")
        #expect(metadata[.city] == "Lisbon")
    }
}

@Suite("Library inspector")
@MainActor
struct LibraryInspectorTests {
    private func makeCatalog() throws -> (CatalogStore, [Photo], TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        var photos: [Photo] = []
        for index in 0..<2 {
            let url = try Fixtures.writeJPEG(to: directory.url.appending(path: "IMG_\(index).jpg"), width: 400, height: 300)
            let photo = Photo(context: store.viewContext)
            photo.id = UUID()
            photo.fileName = url.lastPathComponent
            photo.filePath = url.path(percentEncoded: false)
            photo.fileType = "JPG"
            photo.captureDate = Date(timeIntervalSince1970: 1_270_643_499)
            photo.importDate = Date()
            photo.editDate = Date()
            photo.pixelWidth = 400
            photo.pixelHeight = 300
            photos.append(photo)
        }
        try store.viewContext.save()
        store.viewContext.undoManager?.removeAllActions()
        return (store, photos, directory)
    }

    private func inspector(_ store: CatalogStore, selecting photos: [Photo]) -> (LibraryInspectorViewController, LibraryState) {
        let state = LibraryState()
        state.selectedPhotoIDs = photos.map(\.objectID)
        let controller = LibraryInspectorViewController(store: store, state: state)
        controller.view.frame = NSRect(x: 0, y: 0, width: 300, height: 900)
        controller.view.layoutSubtreeIfNeeded()
        return (controller, state)
    }

    @Test func metadataValuesPreferCatalogEdits() throws {
        let (store, photos, directory) = try makeCatalog()
        _ = directory
        var file = FileMetadata()
        file.values[.title] = "From the file"
        let photo = photos[0]
        var values = MetadataValues(info: .init(photo: photo), file: file)
        #expect(values.value(.title) == "From the file")
        #expect(values.value(.metadataStatus) == "Up to date")
        #expect(values.value(.fileDimensions) == "400 x 300")

        photo.metadata[.title] = "Typed in PixelLoupe"
        var adjustments = photo.adjustments
        adjustments.crop.rect = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        adjustments.orientation.quarterTurns = 1
        photo.adjustments = adjustments
        values = MetadataValues(info: .init(photo: photo), file: file)
        #expect(values.value(.title) == "Typed in PixelLoupe")
        #expect(values.value(.metadataStatus) == "Has been changed")
        #expect(values.value(.currentDimensions) == "150 x 200", "rotated, then cropped")
        let other = MetadataValues(info: .init(photo: photos[1]), file: file)
        #expect(MetadataValues.common(.title, of: [values, other]) == nil, "mixed")
        #expect(MetadataValues.common(.fileType, of: [values, other]) == "JPEG")
        _ = store
    }

    @Test func keywordsAddToAndRemoveFromEverySelectedPhoto() throws {
        let (store, photos, directory) = try makeCatalog()
        defer { _ = directory }
        let context = store.viewContext
        photos[0].tags = [Tag.findOrCreate(named: "Family", in: context)]
        try context.save()
        let (controller, _) = inspector(store, selecting: photos)
        #expect(controller.keywordField.pillTitles == ["Family *"], "on some of the photos")

        controller.keywordField.enter("Beach, Sun")   // a comma ends a keyword
        #expect(photos.allSatisfy { $0.tagNames.contains("Beach") })
        controller.keywordField.commitTyping()        // Return ends one too
        #expect(photos.allSatisfy { $0.tagNames.contains("Sun") })
        #expect(controller.keywordField.pillTitles == ["Beach", "Family *", "Sun"])

        // Its own undo step (in the app, each event is one).
        let undoManager = try #require(context.undoManager)
        undoManager.removeAllActions()
        undoManager.groupsByEvent = false
        defer { undoManager.groupsByEvent = true }
        undoManager.beginUndoGrouping()
        controller.removeKeyword("Family")
        undoManager.endUndoGrouping()
        #expect(photos.allSatisfy { !$0.tagNames.contains("Family") })
        undoManager.undo()
        #expect(photos[0].tagNames.contains("Family"), "undoable")
    }

    @Test func editsGoToTheTargetOrEverySelectedPhoto() throws {
        let (store, photos, directory) = try makeCatalog()
        defer { _ = directory }
        let (controller, _) = inspector(store, selecting: photos)
        controller.target = .selectedPhotos
        controller.edit(.copyright, "© Alex")
        #expect(photos.allSatisfy { $0.metadata[.copyright] == "© Alex" })
        #expect(store.viewContext.undoManager?.undoActionName == "Edit Copyright")

        controller.target = .targetPhoto
        controller.edit(.title, "Only the first")
        #expect(photos[0].metadata[.title] == "Only the first" && photos[1].metadata[.title] == nil)

        store.viewContext.undoManager?.undo()
        #expect(photos[0].metadata[.title] == nil)
    }

    @Test func showsTheSelectedSetAndMixedValues() throws {
        let (store, photos, directory) = try makeCatalog()
        defer { _ = directory }
        photos[0].metadata[.caption] = "One"
        photos[1].metadata[.caption] = "Two"
        let (controller, _) = inspector(store, selecting: photos)
        controller.target = .selectedPhotos
        controller.setPopUp.selectItem(withTitle: "Minimal")
        _ = controller.setPopUp.target?.perform(controller.setPopUp.action, with: controller.setPopUp)
        #expect(controller.metadataPanel.metadataSet.title == "Minimal")
        let caption = try #require(controller.metadataPanel.control(.caption) as? NSTextField)
        #expect(caption.stringValue.isEmpty && caption.placeholderString == "‹mixed›")
        let fileName = try #require(controller.metadataPanel.control(.fileName) as? NSTextField)
        #expect(fileName.stringValue == "‹mixed›")
        Defaults.store.removeObject(forKey: "LibraryMetadataSet")
    }

    @Test func presetsSaveAndApply() throws {
        let saved = Defaults.store.object(forKey: LibraryInspectorViewController.presetsKey)
        defer { Defaults.store.set(saved, forKey: LibraryInspectorViewController.presetsKey) }
        let (store, photos, directory) = try makeCatalog()
        defer { _ = directory }
        photos[0].metadata[.copyright] = "© Alex"
        photos[0].metadata[.creator] = "Ted"
        let (controller, state) = inspector(store, selecting: [photos[0]])
        let values = controller.currentPresetValues()
        #expect(values["copyright"] == "© Alex" && values["creator"] == "Ted")
        LibraryInspectorViewController.presets["Mine"] = values

        state.selectedPhotoIDs = [photos[1].objectID]
        controller.applyPreset(named: "Mine")
        #expect(photos[1].metadata[.copyright] == "© Alex" && photos[1].metadata[.creator] == "Ted")
    }

    @Test func theHistogramIsntEditable() throws {
        let (store, photos, directory) = try makeCatalog()
        defer { _ = directory }
        let (controller, _) = inspector(store, selecting: photos)
        #expect(!controller.histogram.isEditingEnabled)
        #expect(!controller.histogram.showsClippingIndicators)
    }
}

@Suite("Keyword focus")
@MainActor
struct KeywordFocusTests {
    private func window(selectingFirstOf count: Int) throws -> (CatalogWindowController, TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        for index in 0..<count {
            let photo = Photo(context: store.viewContext)
            photo.id = UUID()
            photo.fileName = "IMG_\(index).jpg"
            photo.filePath = directory.url.appending(path: photo.fileName).path(percentEncoded: false)
            photo.fileType = "JPG"
            photo.captureDate = Date(timeIntervalSince1970: Double(index))
            photo.importDate = Date()
            photo.editDate = Date()
        }
        try store.viewContext.save()
        let controller = CatalogWindowController(store: store)
        controller.showWindow(nil)
        controller.window?.layoutIfNeeded()
        if let first = controller.state.photoOrder.first { controller.state.selectedPhotoIDs = [first] }
        return (controller, directory)
    }

    @Test func theFieldNeverTakesFocusOnItsOwn() throws {
        let key = "LibraryInspectorVisible"
        let saved = Defaults.store.object(forKey: key)
        defer { Defaults.store.set(saved, forKey: key) }
        Defaults.store.set(true, forKey: key)
        let (controller, directory) = try window(selectingFirstOf: 2)
        defer { controller.close(); _ = directory }
        let field = controller.rootViewController.main.inspector.keywordField
        #expect(!field.isFocused, "not when the window opens")
        let input = field.inputField
        #expect(!input.acceptsFirstResponder && !input.canBecomeKeyView, "not by default, and Tab skips it")
        // Code asking directly is refused too (the window ends up first responder instead).
        controller.window?.makeFirstResponder(input)
        #expect(!field.isFocused && controller.window?.firstResponder !== input)
        controller.window?.recalculateKeyViewLoop()
        controller.window?.selectNextKeyView(nil)
        #expect(!field.isFocused, "not through the key view loop")

        field.focus()
        #expect(field.isFocused, "only when asked")
    }

    /// Regression: enlarging a photo (double-click or Return) put the cursor in Metadata's Title.
    @Test func noFieldTakesFocusWhenTheViewChanges() throws {
        let key = "LibraryInspectorVisible"
        let saved = Defaults.store.object(forKey: key)
        defer { Defaults.store.set(saved, forKey: key) }
        Defaults.store.set(true, forKey: key)
        let (controller, directory) = try window(selectingFirstOf: 3)
        defer { controller.close(); _ = directory }
        let window = try #require(controller.window)
        func focusedField() -> NSTextField? {
            ((window.firstResponder as? NSText)?.delegate as? NSTextField)
        }
        #expect(controller.perform(.toggleEnlarge))
        window.layoutIfNeeded()
        #expect(focusedField() == nil, "enlarged: \(String(describing: focusedField()?.identifier))")
        #expect(controller.perform(.toggleEnlarge))
        window.layoutIfNeeded()
        #expect(focusedField() == nil, "back to the grid")
        controller.state.mode = .develop
        controller.state.mode = .library
        #expect(focusedField() == nil, "switching modules")

        // The metadata fields refuse focus they didn't ask for, even from code.
        let title = try #require(controller.rootViewController.main.inspector.metadataPanel.control(.title) as? NSTextField)
        #expect(title is ClickToFocusTextField && !title.canBecomeKeyView)
        window.makeFirstResponder(title)
        #expect(focusedField() !== title)
    }

    /// Regression: the Keyword List's "Filter keywords" and the filter bar's search field were plain
    /// search fields, which AppKit gives focus to on its own. Only a click (or ⌘F) may.
    @Test func searchFieldsOnlyTakeFocusWhenAskedOrClicked() throws {
        let key = "LibraryInspectorVisible"
        let saved = Defaults.store.object(forKey: key)
        defer { Defaults.store.set(saved, forKey: key) }
        Defaults.store.set(true, forKey: key)
        let (controller, directory) = try window(selectingFirstOf: 2)
        defer { controller.close(); _ = directory }
        let window = try #require(controller.window)
        let keywordFilter = controller.rootViewController.main.inspector.keywordList.filter
        #expect(keywordFilter is ClickToFocusSearchField && !keywordFilter.canBecomeKeyView)
        window.makeFirstResponder(keywordFilter)
        #expect(window.firstResponder !== keywordFilter.currentEditor() && window.firstResponder !== keywordFilter)

        let search = try #require(window.contentView?.descendants.first { $0.accessibilityIdentifier() == "metadataSearch" } as? ClickToFocusSearchField)
        window.makeFirstResponder(search)
        #expect(window.firstResponder !== search.currentEditor() && window.firstResponder !== search)
        controller.rootViewController.main.library.focusSearch(nil)
        #expect(window.firstResponder === search.currentEditor(), "⌘F still goes to the search field")
    }

    /// Regression: the right-sidebar button was hidden in Develop, narrowing the toolbar and moving the
    /// Library/Develop control. It stays, and works on Develop's panel there.
    @Test func theRightSidebarButtonStaysInDevelop() throws {
        let key = "LibraryInspectorVisible"
        let saved = Defaults.store.object(forKey: key)
        defer { Defaults.store.set(saved, forKey: key) }
        Defaults.store.set(true, forKey: key)
        let (controller, directory) = try window(selectingFirstOf: 2)
        defer { controller.close(); _ = directory }
        let window = try #require(controller.window)
        // The window's usual width. A screen narrower than that (CI's is 1024 × 768) squeezes the toolbar anyway.
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 700), display: true)
        window.layoutIfNeeded()
        let fitsItsScreen = window.frame.width <= (window.screen ?? NSScreen.main)?.visibleFrame.width ?? .infinity
        func button() -> NSButton? {
            window.toolbar?.items.compactMap(\.view).first { $0.accessibilityIdentifier() == "rightSidebarToolbarButton" } as? NSButton
        }
        func pickerFrame() -> NSRect? {
            window.toolbar?.items.compactMap(\.view).first { $0.accessibilityIdentifier() == "modeControl" }
                .map { $0.convert($0.bounds, to: nil) }
        }
        let main = controller.rootViewController.main
        let itemCount = window.toolbar?.visibleItems?.count
        let libraryPicker = pickerFrame()
        #expect(button() != nil && libraryPicker != nil)
        controller.state.mode = .develop
        window.layoutIfNeeded()
        #expect(button() != nil && window.toolbar?.visibleItems?.count == itemCount)
        if fitsItsScreen {
            #expect(pickerFrame() == libraryPicker, "the Library/Develop control doesn't move")
        } else {
            // RAW-102: in a squeezed toolbar the control shifts a few points between modes.
            withKnownIssue("RAW-102: the Library/Develop control moves in a toolbar squeezed by a small screen", isIntermittent: true) {
                #expect(pickerFrame() == libraryPicker)
            }
        }
        let columns = main.splitView.arrangedSubviews.map(\.frame.width)
        #expect(columns.count == 3 && columns[2] >= 366, "the right column stays open, as wide as Develop's panel needs")
        #expect(button()?.state == .on && main.isRightSidebarVisible)
        controller.toggleRightSidebar(nil)
        #expect(!main.isDevelopPanelVisible && !main.isRightSidebarVisible && button()?.state == .off)
        controller.toggleRightSidebar(nil)
        #expect(main.isDevelopPanelVisible && button()?.state == .on)
        controller.state.mode = .library
        #expect(main.isLibraryInspectorVisible == main.isRightSidebarVisible)
    }

    @Test func commandKShowsTheSidebarAndFocusesKeywords() throws {
        let key = "LibraryInspectorVisible"
        let saved = Defaults.store.object(forKey: key)
        defer { Defaults.store.set(saved, forKey: key) }
        Defaults.store.set(false, forKey: key)
        let (controller, directory) = try window(selectingFirstOf: 2)
        defer { controller.close(); _ = directory }
        controller.state.mode = .develop

        controller.addKeywords(nil)
        let main = controller.rootViewController.main
        #expect(controller.state.mode == .library, "switches to the Library")
        #expect(main.isLibraryInspectorVisible, "shows the right sidebar")
        #expect(main.inspector.keywordField.isFocused)
    }
}

@Suite("Sidebars")
@MainActor
struct SidebarToggleTests {
    @Test func tabTogglesBothSidebarsAndTheButtonTheRightOne() throws {
        let key = "LibraryInspectorVisible"
        let saved = Defaults.store.object(forKey: key)
        defer { Defaults.store.set(saved, forKey: key) }
        Defaults.store.set(true, forKey: key)

        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let controller = CatalogWindowController(store: store)
        defer { controller.close() }
        controller.showWindow(nil)
        let main = controller.rootViewController.main
        #expect(main.isSidebarVisible && main.isLibraryInspectorVisible)

        #expect(controller.perform(.toggleSidebars))
        #expect(!main.isSidebarVisible && !main.isLibraryInspectorVisible, "Tab hides both")
        #expect(controller.perform(.toggleSidebars))
        #expect(main.isSidebarVisible && main.isLibraryInspectorVisible, "and shows both")

        controller.toggleRightSidebar(nil)
        #expect(!main.isLibraryInspectorVisible && main.isSidebarVisible, "the toolbar button: just the right one")
        controller.toggleRightSidebar(nil)

        // In Develop, the right sidebar is Develop's panel.
        controller.state.mode = .develop
        #expect(controller.perform(.toggleSidebars))
        #expect(!main.isDevelopPanelVisible && !main.isSidebarVisible)
        #expect(main.isLibraryInspectorVisible, "Library's right sidebar keeps its setting")
        #expect(controller.perform(.toggleSidebars))
        #expect(main.isDevelopPanelVisible)
    }

    @Test func tabIsAKeyCommand() {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        #expect(KeyCommand(event: event) == .toggleSidebars)
    }
}
