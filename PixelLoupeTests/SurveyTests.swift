import AppKit
import CoreData
import Testing
@testable import PixelLoupe

@Suite("Survey layout")
struct SurveyLayoutTests {
    let bounds = CGRect(x: 0, y: 0, width: 1200, height: 600)

    private func cells(_ count: Int, aspect: CGFloat = 1.5, in bounds: CGRect? = nil) -> [CGRect] {
        SurveyLayout.cells(count: count, in: bounds ?? self.bounds, aspectRatio: aspect, spacing: 10, captionHeight: 20)
    }

    @Test func onePhotoFillsTheArea() {
        #expect(cells(1) == [bounds])
    }

    @Test func picksTheColumnsThatShowPhotosLargest() {
        // Two landscape photos in a wide area sit side by side; two portrait ones too.
        #expect(Set(cells(2).map(\.minY)).count == 1)
        #expect(Set(cells(2, aspect: 2.0 / 3).map(\.minY)).count == 1)
        // Two wide panoramas in a square area stack.
        #expect(Set(cells(2, aspect: 3, in: CGRect(x: 0, y: 0, width: 600, height: 600)).map(\.minX)).count == 1)
        // Four landscape photos in a 4:3 area: 2 × 2.
        let four = cells(4, in: CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(Set(four.map(\.minX)).count == 2 && Set(four.map(\.minY)).count == 2)
    }

    @Test func cellsStayInsideAndDontOverlap() {
        for count in 1...12 {
            let frames = cells(count)
            #expect(frames.count == count)
            for (index, frame) in frames.enumerated() {
                #expect(bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "cell \(index) of \(count) is outside")
                for other in frames[(index + 1)...] {
                    #expect(!frame.insetBy(dx: 0.5, dy: 0.5).intersects(other), "cells overlap with \(count) photos")
                }
            }
        }
    }

    @Test func aShortLastRowIsCentered() {
        // Five landscape photos in a 4:3 area: 3 + 2, the 2 centered under the 3.
        let area = CGRect(x: 0, y: 0, width: 900, height: 600)
        let frames = cells(5, in: area)
        let lastRow = frames.filter { $0.minY == frames.last!.minY }
        #expect(lastRow.count < frames.count)
        let left = lastRow.map(\.minX).min()!, right = lastRow.map(\.maxX).max()!
        #expect(abs((left - area.minX) - (area.maxX - right)) < 0.5)
    }

    @Test func surveyedPhotosFollowTheGridOrder() {
        #expect(SurveyViewController.surveyPhotos(selection: ["c", "a"], order: ["a", "b", "c"]) == ["a", "c"])
        #expect(SurveyViewController.surveyPhotos(selection: ["x"], order: ["a"]) == ["x"], "kept when the grid doesn't show it")
    }
}

/// Photos for the Survey tests: four landscape JPEGs that aren't on disk (thumbnails only).
@MainActor
func makeSurveyStore(_ count: Int = 4) throws -> (CatalogStore, [NSManagedObjectID], TemporaryDirectory) {
    let directory = try TemporaryDirectory()
    let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url)
    let context = store.viewContext
    let photos = (0..<count).map { index in
        let photo = Photo(context: context)
        photo.id = UUID()
        photo.fileName = "IMG_\(index).jpg"
        photo.filePath = "/missing/IMG_\(index).jpg"
        photo.pixelWidth = 6000
        photo.pixelHeight = 4000
        photo.captureDate = Date(timeIntervalSince1970: Double(index) * 60)
        photo.importDate = Date(); photo.editDate = Date()
        return photo
    }
    try context.save()
    return (store, photos.map(\.objectID), directory)
}

@Suite("Survey view") @MainActor
struct SurveyViewTests {
    private func makeSurvey(selected: [Int]) throws
        -> (SurveyViewController, LibraryState, [NSManagedObjectID], NSWindow, TemporaryDirectory) {
        let (store, ids, directory) = try makeSurveyStore()
        let state = LibraryState()
        state.photoOrder = ids
        state.selectedPhotoIDs = selected.map { ids[$0] }
        state.presentation = .survey
        let survey = SurveyViewController(store: store, state: state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = survey
        window.setContentSize(NSSize(width: 1200, height: 700))
        survey.refresh()
        survey.view.layoutSubtreeIfNeeded()
        return (survey, state, ids, window, directory)
    }

    @Test func showsEverySelectedPhotoInGridOrderWithTheActiveOneOutlined() throws {
        let (survey, _, ids, window, directory) = try makeSurvey(selected: [2, 0, 3])
        _ = (window, directory)
        #expect(survey.photoIDs == [ids[0], ids[2], ids[3]])
        let views = survey.photoViews
        #expect(views.count == 3)
        #expect(views.map(\.isActive) == [false, true, false], "the first selected photo is active")
        #expect(views.allSatisfy { !$0.frame.isEmpty && survey.view.bounds.contains($0.frame) })
        let captions = views.compactMap { view in
            view.subviews.compactMap { $0 as? NSTextField }.first?.stringValue
        }
        #expect(captions == ["IMG_0.jpg", "IMG_2.jpg", "IMG_3.jpg"])
    }

    @Test func clickingOrArrowingMakesAnotherPhotoActive() throws {
        let (survey, state, ids, window, directory) = try makeSurvey(selected: [0, 1, 2])
        _ = (window, directory)
        survey.activate(ids[2])
        #expect(state.selectedPhotoIDs.first == ids[2])
        #expect(Set(state.selectedPhotoIDs) == Set(ids[0...2]), "the survey keeps every photo")
        #expect(survey.photoViews.map(\.isActive) == [false, false, true])

        survey.stepActive(by: 1)
        #expect(state.selectedPhotoIDs.first == ids[2], "already the last")
        survey.stepActive(by: -1)
        #expect(state.selectedPhotoIDs.first == ids[1])
        #expect(survey.photoIDs == [ids[0], ids[1], ids[2]], "the order doesn't change")
    }

    @Test func removingAPhotoDropsItAndMovesTheActivePhotoOn() throws {
        let (survey, state, ids, window, directory) = try makeSurvey(selected: [1, 0, 2])
        _ = (window, directory)
        survey.remove(ids[1])
        #expect(survey.photoIDs == [ids[0], ids[2]])
        #expect(state.selectedPhotoIDs.first == ids[2], "the next photo becomes active")
        survey.remove(ids[0])
        #expect(survey.photoIDs == [ids[2]])
        survey.remove(ids[2])
        #expect(survey.photoIDs == [ids[2]], "the last photo stays")
    }

    @Test func followsTheSelectionAndLeavesWhenItsEmpty() throws {
        let (survey, state, ids, window, directory) = try makeSurvey(selected: [0, 1])
        _ = (window, directory)
        state.selectedPhotoIDs = [ids[3], ids[2], ids[1]]
        #expect(survey.photoIDs == [ids[1], ids[2], ids[3]])
        state.selectedPhotoIDs = []
        #expect(state.presentation == .grid)
    }
}

@Suite("Survey in the catalog window") @MainActor
struct SurveyWindowTests {
    private func key(_ characters: String, shift: Bool = false) -> KeyCommand? {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
        return KeyCommand(event: event)
    }

    @Test func nAndShiftNAreSurveyKeys() {
        #expect(key("n") == .survey)
        #expect(key("N", shift: true) == .secondaryView(.survey))
        #expect(SecondaryView.survey.key.character == "n" && SecondaryView.survey.key.modifiers == [.shift])
    }

    @Test func nSurveysTheSelectionFromDevelopAndAgainLeaves() throws {
        let (store, ids, directory) = try makeSurveyStore()
        _ = directory
        let controller = CatalogWindowController(store: store)
        defer { controller.close() }
        controller.state.photoOrder = ids
        controller.state.selectedPhotoIDs = []
        #expect(!controller.perform(.survey), "nothing to survey")

        controller.state.selectedPhotoIDs = [ids[0], ids[1], ids[2]]
        controller.state.mode = .develop
        #expect(controller.perform(.survey))
        #expect(controller.state.mode == .library)
        #expect(controller.state.presentation == .survey)
        #expect(controller.perform(.survey))
        #expect(controller.state.presentation == .grid)

        #expect(controller.perform(.survey))
        #expect(controller.perform(.exit))
        #expect(controller.state.presentation == .grid, "Esc leaves too")
    }

    @Test func ratingsApplyToTheActivePhotoAndArrowsMoveIt() throws {
        let (store, ids, directory) = try makeSurveyStore()
        _ = directory
        let controller = CatalogWindowController(store: store)
        controller.showWindow(nil)
        defer { controller.close() }
        controller.state.photoOrder = ids
        controller.state.selectedPhotoIDs = [ids[0], ids[1], ids[2]]
        #expect(controller.perform(.survey))
        #expect(controller.perform(.next))
        #expect(controller.state.selectedPhotoIDs.first == ids[1])
        #expect(controller.perform(.rating(4)))
        let photos = ids.map { try? store.viewContext.existingObject(with: $0) as? Photo }
        #expect(photos.map { $0?.rating } == [0, 4, 0, 0], "only the active photo is rated")
    }

    @Test func theSecondaryWindowSurveysTheSelectionOnItsOwn() throws {
        let (store, ids, directory) = try makeSurveyStore()
        _ = directory
        let main = LibraryState()
        main.photoOrder = ids
        main.selectedPhotoIDs = [ids[1], ids[3]]
        let controller = SecondaryWindowController(store: store, main: main, view: .grid)
        defer { controller.closeQuietly() }
        controller.view = .survey
        let survey = try #require(controller.content.current as? SurveyViewController)
        #expect(survey.photoIDs == [ids[1], ids[3]])
        #expect(main.presentation == .grid, "the main window doesn't enter Survey")
        survey.activate(ids[3])
        #expect(main.selectedPhotoIDs.first == ids[3], "the active photo is selected in the main window too")
    }
}
