import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

/// The Assisted Culling Info panel (RAW-71).
@Suite("Culling info")
@MainActor
struct CullingInfoTests {
    private func scores(subject: Double = 0.9, eye: Double = 0.85, eyes: (Double, Double) = (1, 1), faces: Int = 1) -> CullingScores {
        var scores = CullingScores()
        scores.subjectFocus = subject
        scores.eyeFocus = eye
        scores.eyesOpenMin = eyes.0
        scores.eyesOpenMax = eyes.1
        scores.faceCount = faces
        return scores
    }

    @Test func aSelectShowsItsScores() {
        let info = CullingInfo(scores: scores(), criteria: CullingCriteria(), isOffline: false)
        #expect(info.verdict == .select)
        #expect(info[.verdict] == "Select")
        #expect(info[.rejectedBy] == "—")
        #expect(info[.subjectFocus] == "90 / 100")
        #expect(info[.eyeFocus] == "85 / 100")
        #expect(info[.eyesOpen] == "Open")
        #expect(info[.faces] == "1")
        #expect(info[.exposure] == "OK" && info[.misfire] == "No" && info[.document] == "No")
        #expect(info.note == nil)
    }

    @Test func aRejectSaysWhatRejectedIt() {
        var rejected = scores(subject: 0.2, eyes: (0, 0.1), faces: 2)
        rejected.misfire = true
        let info = CullingInfo(scores: rejected, criteria: CullingCriteria(), isOffline: false)
        #expect(info[.verdict] == "Reject")
        #expect(info[.rejectedBy] == "Subject Focus, Eyes Open, and Misfires")
        #expect(info[.eyesOpen] == "Closed")
        #expect(info[.misfire] == "Yes")
        #expect(info[.faces] == "2")
    }

    @Test func eyesAreDescribedByTheCriteriasBands() {
        func eyes(_ least: Double, _ most: Double) -> String {
            CullingInfo(scores: scores(eyes: (least, most), faces: 2), criteria: CullingCriteria(), isOffline: false)[.eyesOpen]
        }
        #expect(eyes(0.7, 1) == "Open")
        #expect(eyes(0, 0.3) == "Closed")
        #expect(eyes(0.5, 0.5) == "Ambiguous")
        #expect(eyes(0.1, 0.9) == "Some closed")
        let landscape = CullingInfo(scores: scores(eye: -1, eyes: (-1, -1), faces: 0), criteria: CullingCriteria(), isOffline: false)
        #expect(landscape[.eyeFocus] == "No eyes detected" && landscape[.eyesOpen] == "No eyes detected")
    }

    @Test func focusStillToBeMeasuredIsSaidSo() {
        var pending = scores(subject: -1, eye: -1)
        pending.focusPending = true
        let offline = CullingInfo(scores: pending, criteria: CullingCriteria(), isOffline: true)
        #expect(offline[.subjectFocus] == "Not measured yet" && offline[.eyeFocus] == "Not measured yet")
        #expect(offline.note?.contains("offline") == true)
        #expect(offline.verdict == .select, "unknown focus passes")
        #expect(CullingInfo(scores: pending, criteria: CullingCriteria(), isOffline: false).note == "Focus will be measured shortly.")
    }

    @Test func unanalyzedPhotosAndVideosShowNoScores() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let photo = makePhoto(in: store, directory: directory)
        var info = CullingInfo(photo: photo, criteria: CullingCriteria(), status: .original)
        #expect(info[.verdict] == "—" && info[.subjectFocus] == "—" && info.verdict == nil)
        #expect(info.note?.hasPrefix("Not analyzed") == true)

        photo.cullVersion = CullingAnalyzer.version + 1
        info = CullingInfo(photo: photo, criteria: CullingCriteria(), status: .original)
        #expect(info.note?.hasPrefix("Analyzed by a different version") == true)

        photo.isVideo = true
        #expect(CullingInfo(photo: photo, criteria: CullingCriteria(), status: .original).note == "Videos aren't analyzed.")
        #expect(CullingInfo(photo: nil, criteria: CullingCriteria(), status: nil).note == "No photo selected.")
    }

    private func makePhoto(in store: CatalogStore, directory: TemporaryDirectory, index: Int = 0) -> Photo {
        let photo = Photo(context: store.viewContext)
        photo.id = UUID()
        photo.fileName = "IMG_\(index).jpg"
        photo.filePath = directory.url.appending(path: photo.fileName).path(percentEncoded: false)
        photo.fileType = "JPG"
        photo.captureDate = Date(timeIntervalSince1970: Double(index))
        photo.importDate = Date()
        photo.editDate = Date()
        return photo
    }

    @Test func thePanelFollowsTheTargetPhotoItsScoresAndTheCriteria() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let first = makePhoto(in: store, directory: directory), second = makePhoto(in: store, directory: directory, index: 1)
        scores(subject: 0.4).write(to: second)
        try store.viewContext.save()
        let state = LibraryState()
        let controller = LibraryInspectorViewController(store: store, state: state)
        controller.view.frame = NSRect(x: 0, y: 0, width: 300, height: 1600)
        controller.view.layoutSubtreeIfNeeded()
        let panel = controller.cullingInfoPanel
        #expect(panel.noteLabel.stringValue == "No photo selected.")

        state.selectedPhotoIDs = [second.objectID, first.objectID]
        #expect(panel.values[.verdict]?.stringValue == "Reject", "the target photo is the first selected")
        #expect(panel.values[.rejectedBy]?.stringValue == "Subject Focus")
        #expect(panel.noteLabel.isHidden)

        // Loosening the criteria changes the verdict.
        var criteria = controller.cullingCriteria
        criteria.subjectFocusMinimum = 0.3
        controller.setCullingCriteria(criteria)
        #expect(panel.values[.verdict]?.stringValue == "Select")
        CullingCriteria.saved = CullingCriteria()

        // Scores arriving for the shown photo show up.
        state.selectedPhotoIDs = [first.objectID]
        #expect(panel.values[.verdict]?.stringValue == "—")
        scores(subject: 0.1).write(to: first)
        store.viewContext.processPendingChanges()
        #expect(panel.values[.subjectFocus]?.stringValue == "10 / 100")
    }
}
