import CoreData
import Foundation
import Testing
@testable import PixelLoupe

/// The import window's File Renaming (RAW-82).
@Suite("Import renaming")
struct ImportRenamingTests {
    private let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9))!

    @Test func templatesNameFilesAsTheirTitlesSay() {
        var renaming = ImportRenaming(isOn: true, customText: "Trip", shootName: "California Adventure", startNumber: 7)
        let expected: [ImportRenaming.Template: String] = [
            .dateFilename: "2026-10-15-DSC00112.ARW",
            .filename: "DSC00112.ARW",
            .shootNameSequence: "California Adventure-0008",
            .customTextSequence: "Trip-0008",
            .customTextFilename: "Trip-DSC00112.ARW",
            .dateSequence: "2026-10-15-0008",
        ]
        for template in ImportRenaming.Template.allCases {
            renaming.template = template
            let name = renaming.name(for: "DSC00112.ARW", date: date, index: 1)
            #expect(name == expected[template].map { template.usesSequence ? $0 + ".ARW" : $0 }, "\(template)")
        }
    }

    @Test func extensionsAndUnsafeCharacters() {
        var renaming = ImportRenaming(isOn: true, template: .customTextFilename, customText: "A/B:C", extensionCase: .lowercase)
        #expect(renaming.name(for: "IMG_1.JPG", date: date, index: 0) == "A-B-C-IMG_1.jpg")
        renaming.extensionCase = .uppercase
        renaming.template = .filename
        #expect(renaming.name(for: "img_1.heic", date: date, index: 0) == "img_1.HEIC")
        renaming.template = .customTextSequence
        renaming.customText = "  "
        #expect(renaming.name(for: "x.jpg", date: date, index: 0) == "Untitled-0001.JPG", "blank text has a stand-in")
    }

    @Test func copiesAreRenamedInOrderWithTheirSidecars() async throws {
        let directory = try TemporaryDirectory()
        let card = try directory.subdirectory("Card")
        let storage = try directory.subdirectory("Storage")
        try Fixtures.writeJPEG(to: card.appending(path: "IMG_0001.JPG"), captureDate: "2026:10:15 09:00:00")
        try Fixtures.writeJPEG(to: card.appending(path: "IMG_0002.JPG"), captureDate: "2026:10:15 09:01:00")
        try Data("tiff".utf8).write(to: card.appending(path: "IMG_0001.TIF"))
        let store = try CatalogStore.inMemory(info: Fixtures.managedInfo(storage: storage), packageURL: directory.url.appending(path: "Test.pixelloupe"))
        let service = ImportService(store: store)
        var files = try await service.scan([card]).files.sorted { $0.captureDate < $1.captureDate }.map(\.candidate)
        files[0].source.sidecars = ["TIF"]

        var extras = ImportExtras()
        extras.renaming = ImportRenaming(isOn: true, template: .shootNameSequence, shootName: "Disneyland", extensionCase: .lowercase)
        let destination = ImportDestination(root: storage, subfolder: nil, layout: .oneFolder)
        _ = try await service.importPhotos(files, transfer: .copy, destination: destination, extras: extras)
        let names = try FileManager.default.contentsOfDirectory(atPath: storage.path(percentEncoded: false)).sorted()
        #expect(names == ["Disneyland-0001.jpg", "Disneyland-0001.tif", "Disneyland-0002.jpg"])

        // Added in place, nothing is renamed.
        let added = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "B.pixelloupe"))
        _ = try await ImportService(store: added).importPhotos(files, transfer: .add, extras: extras)
        #expect(try added.viewContext.fetch(Photo.fetchRequest()).map(\.fileName).sorted() == ["IMG_0001.JPG", "IMG_0002.JPG"])
    }

    @Test func shootNameFollowsTheSubfolderUntilTyped() {
        let model = ImportOptionsModel(settings: .init(
            transfer: .copy, destination: .init(root: URL(filePath: "/Pictures"), subfolder: "Trip", layout: .date)))
        #expect(model.renaming.shootName == "Trip")
        model.subfolderName = "Disneyland"
        #expect(model.renaming.shootName == "Disneyland")
        model.renaming.shootName = "Mine"
        model.renaming.shootNameEdited = true
        model.subfolderName = "Elsewhere"
        #expect(model.renaming.shootName == "Mine")
        model.renaming.isOn = true
        model.renaming.template = .shootNameSequence
        model.exampleFile = ("DSC00112.ARW", date)
        #expect(model.renamingExample == "Mine-0001.ARW")
        #expect(model.extras.renaming?.shootName == "Mine")
    }
}
