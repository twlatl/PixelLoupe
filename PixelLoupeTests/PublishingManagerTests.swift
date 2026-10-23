import AppKit
import CoreData
import Testing
@testable import PixelLoupe

@Suite("Publishing Manager")
@MainActor
struct PublishingManagerTests {
    private struct Setup {
        let directory: TemporaryDirectory
        let store: CatalogStore
        var context: NSManagedObjectContext { store.viewContext }

        init() throws {
            directory = try TemporaryDirectory()
            store = try CatalogStore.create(at: directory.url.appending(path: "C.pixelloupe", directoryHint: .isDirectory), info: Fixtures.referencedInfo)
        }

        let credentials = MemoryFlickrCredentialStore()

        func model() -> PublishingManagerModel {
            PublishingManagerModel(context: context, credentials: credentials)
        }

        func controller() -> PublishingManagerWindowController {
            PublishingManagerWindowController(model: model(),
                                              watermarks: WatermarkPresets(directory: directory.url.appending(path: "Watermarks")))
        }

        /// A Hard Drive service with one published photo.
        @discardableResult
        func publishedService() -> PublishService {
            let service = PublishService.make(.hardDrive, in: context)
            let photo = Photo(context: context)
            photo.id = UUID()
            photo.fileName = "A.jpg"
            photo.captureDate = .now; photo.importDate = .now
            photo.editDate = Date(timeIntervalSince1970: 0)
            service.add([photo])
            let entry = service.publishedPhotos.first
            entry?.publishedDate = .now
            entry?.metadataFingerprint = PublishedPhoto.fingerprint(ExportItem(photo))
            store.save()
            return service
        }
    }

    private func sectionTitles(_ controller: PublishingManagerWindowController) -> [String] {
        func sections(in view: NSView) -> [InspectorSectionView] {
            view.subviews.flatMap { ($0 as? InspectorSectionView).map { [$0] } ?? sections(in: $0) }
        }
        return sections(in: controller.window!.contentView!).map(\.title)
    }

    @Test func addingAServiceSelectsItUnsaved() throws {
        let setup = try Setup()
        let controller = setup.controller()
        #expect(controller.model.drafts.isEmpty && !controller.removeButton.isEnabled)
        controller.add(.flickr)
        #expect(controller.selectedIndex == 0 && controller.removeButton.isEnabled)
        let cell = try #require(controller.serviceList.view(atColumn: 0, row: 0, makeIfNecessary: true))
        #expect(cell.accessibilityLabel() == "Flickr, (not saved)")
        #expect(controller.descriptionField.stringValue == "Flickr")
        #expect(try PublishService.all(in: setup.context).isEmpty, "nothing is saved yet")
    }

    @Test func eachKindShowsItsSections() throws {
        let setup = try Setup()
        let controller = setup.controller()
        controller.add(.flickr)
        #expect(sectionTitles(controller) == ["Publish Service", "Flickr Account", "Flickr Title", "File Naming", "Video", "File Settings",
                                              "Image Sizing", "Output Sharpening", "Metadata", "Watermarking", "Privacy and Safety"])
        let form = try #require(controller.form)
        #expect(!form.formatPopUp.isEnabled && form.formatPopUp.titleOfSelectedItem == "JPEG", "Flickr takes JPEGs")
        #expect(!form.limitSizeCheckbox.state.isOn, "no file size limit by default")
        controller.add(.hardDrive)
        #expect(sectionTitles(controller) == ["Publish Service", "Publish Location", "File Naming", "Video", "File Settings",
                                              "Image Sizing", "Output Sharpening", "Metadata", "Watermarking"])
        #expect(controller.form?.formatPopUp.isEnabled == true)
    }

    @Test func privacyControlsFollowPublicAndPrivate() throws {
        let setup = try Setup()
        let controller = setup.controller()
        controller.add(.flickr)
        #expect(controller.publicRadio.state == .on && !controller.familyCheckbox.isEnabled)
        controller.privateRadio.performClick(nil)
        #expect(controller.model.drafts[0].settings.isPublic == false)
        #expect(controller.familyCheckbox.isEnabled && controller.friendsCheckbox.isEnabled)
        controller.familyCheckbox.performClick(nil)
        controller.safetyPopUp.selectItem(withTitle: "Restricted")
        controller.safetyPopUp.sendAction(controller.safetyPopUp.action, to: controller.safetyPopUp.target)
        let settings = controller.model.drafts[0].settings
        #expect(settings.isVisibleToFamily && !settings.isVisibleToFriends && settings.safety == .restricted)
    }

    @Test func saveWritesTheServicesAndCancelDoesNot() throws {
        let setup = try Setup()
        let controller = setup.controller()
        controller.add(.hardDrive)
        controller.descriptionField.stringValue = "Backup Drive"
        controller.descriptionField.sendAction(controller.descriptionField.action, to: controller.descriptionField.target)
        let form = try #require(controller.form)
        form.formatPopUp.selectItem(withTitle: "PNG")
        form.formatPopUp.sendAction(form.formatPopUp.action, to: form.formatPopUp.target)
        controller.cancel(nil)
        #expect(PublishService.all(in: setup.context).isEmpty)

        let second = setup.controller()
        second.add(.hardDrive)
        second.add(.flickr)
        second.save(nil)
        #expect(PublishService.all(in: setup.context).map(\.kind) == [.hardDrive, .flickr])
        #expect(setup.context.undoManager?.canUndo != true, "setting up services isn't undoable")
    }

    @Test func editsAndRemovalsApplyOnSave() throws {
        let setup = try Setup()
        let service = setup.publishedService()
        let flickr = PublishService.make(.flickr, in: setup.context)
        setup.store.save()
        let model = setup.model()
        #expect(model.drafts.map(\.publishedCount) == [1, 0])
        #expect(!model.hasChanges)
        model.update(at: 0) { $0.name = "Archive" }
        model.remove(at: 1)
        #expect(model.hasChanges)
        #expect(flickr.managedObjectContext != nil, "nothing changes before Save")
        try model.save()
        #expect(PublishService.all(in: setup.context) == [service])
        #expect(service.name == "Archive")
    }

    @Test func onlyRenderingChangesAskToRepublish() throws {
        let setup = try Setup()
        setup.publishedService()
        let model = setup.model()
        model.update(at: 0) { $0.settings.isPublic = false; $0.settings.safety = .moderate }
        #expect(model.draftsChangingPublishedPhotos.isEmpty, "privacy applies to photos published from now on")
        model.update(at: 0) { $0.settings.export.quality = 95 }
        #expect(model.draftsChangingPublishedPhotos.map(\.displayName) == ["Hard Drive"])
    }

    @Test func republishingAllMarksThePublishedPhotosModified() throws {
        let setup = try Setup()
        let service = setup.publishedService()
        #expect(service.entries(in: .published).count == 1)
        let controller = setup.controller()
        var asked: [String] = []
        controller.askToRepublish = { drafts, answer in
            asked = drafts.map(\.displayName)
            answer(Set(drafts.map(\.id)))
        }
        let form = try #require(controller.form)
        form.qualityRow.onChange?(95)
        controller.save(nil)
        #expect(asked == ["Hard Drive"])
        #expect(service.settings.export.quality == 95)
        #expect(service.entries(in: .modified).count == 1)
    }

    @Test func goingBackFromTheRepublishQuestionKeepsEditing() throws {
        let setup = try Setup()
        let service = setup.publishedService()
        let controller = setup.controller()
        controller.askToRepublish = { _, answer in answer(nil) }
        controller.form?.qualityRow.onChange?(95)
        controller.save(nil)
        #expect(service.settings.export.quality != 95)
        #expect(controller.model.hasChanges)
    }

    /// A watermark made while the window is open shows up in the menu, and one made from its Edit
    /// Watermarks… is chosen (it once stayed on Simple Copyright Watermark, which was published instead).
    @Test func watermarksMadeMeanwhileAppearAndOneMadeFromHereIsChosen() throws {
        let setup = try Setup()
        let watermarks = WatermarkPresets(directory: setup.directory.url.appending(path: "Watermarks"))
        let controller = PublishingManagerWindowController(model: PublishingManagerModel(context: setup.context), watermarks: watermarks)
        controller.add(.flickr)
        let form = try #require(controller.form)
        try watermarks.save(WatermarkPreset(name: "Elsewhere", settings: WatermarkSettings()))
        #expect(form.watermarkPopUp.itemTitles.contains("Elsewhere"))
        #expect(controller.model.drafts[0].settings.export.watermarkName == WatermarkPresets.simpleCopyrightName, "not made from here")

        form.beginEditingWatermarks()
        try watermarks.save(WatermarkPreset(name: "TWL Upper Right Semi Opaque", settings: WatermarkSettings()))
        let export = controller.model.drafts[0].settings.export
        #expect(export.watermarks && export.watermarkName == "TWL Upper Right Semi Opaque")
        #expect(form.watermarkPopUp.titleOfSelectedItem == "TWL Upper Right Semi Opaque")
        controller.save(nil)
        #expect(PublishService.all(in: setup.context).first?.settings.export.watermarkName == "TWL Upper Right Semi Opaque")
    }

    @Test func theWindowMenuOpensIt() throws {
        let window = try #require(MainMenu.make().items.first { $0.submenu?.title == "Window" }?.submenu)
        let item = try #require(window.items.first { $0.title == "Publishing Manager…" })
        #expect(item.action == #selector(PixelLoupeActions.showPublishingManager(_:)))
    }
}

private extension NSControl.StateValue {
    var isOn: Bool { self == .on }
}
