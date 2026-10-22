import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

/// Splitting photos into Selects and Rejects, the Review filter and Apply (RAW-71).
@Suite("Culling criteria")
@MainActor
struct CullingCriteriaTests {
    /// Scores of a sharp photo of one person with open eyes and nothing wrong.
    private func good() -> CullingScores {
        var scores = CullingScores()
        scores.subjectFocus = 0.9
        scores.eyeFocus = 0.9
        scores.eyesOpenMin = 1
        scores.eyesOpenMax = 1
        scores.faceCount = 1
        scores.quality = 0.6
        return scores
    }

    @Test func aPhotoThatFailsAnySelectCriterionOrHitsAnyRejectCriterionIsAReject() {
        let criteria = CullingCriteria()
        #expect(criteria.failures(good()).isEmpty)

        var soft = good()
        soft.subjectFocus = 0.3
        soft.eyeFocus = 0.2
        soft.misfire = true
        #expect(criteria.failures(soft) == [.subjectFocus, .eyeFocus, .misfires])

        var dark = good()
        dark.exposureIssue = true
        dark.document = true
        #expect(criteria.failures(dark) == [.exposureIssues, .documents])

        var unchecked = criteria
        unchecked.subjectFocus = false
        unchecked.eyeFocus = false
        unchecked.misfires = false
        #expect(unchecked.failures(soft).isEmpty, "only checked criteria count")
    }

    @Test func theSlidersSetTheLeastFocusASelectHas() {
        var scores = good()
        scores.subjectFocus = 0.6
        var criteria = CullingCriteria()
        #expect(criteria.failures(scores).isEmpty)
        criteria.subjectFocusMinimum = 0.7
        #expect(criteria.failures(scores) == [.subjectFocus])
        criteria.subjectFocusMinimum = 0
        scores.subjectFocus = 0
        #expect(criteria.failures(scores).isEmpty, "Soft keeps everything")
    }

    @Test func unknownFocusPasses() {
        var scores = good()
        scores.subjectFocus = -1
        scores.eyeFocus = -1
        scores.focusPending = true
        #expect(CullingCriteria().failures(scores).isEmpty)
    }

    @Test func photosWithoutEyesPassTheEyeCriteriaUnlessEyesAreRequired() {
        var landscape = good()
        landscape.eyeFocus = -1
        landscape.eyesOpenMin = -1
        landscape.eyesOpenMax = -1
        landscape.faceCount = 0
        var criteria = CullingCriteria()
        #expect(criteria.failures(landscape).isEmpty)
        criteria.eyeFocusNeedsEyes = true
        #expect(criteria.failures(landscape) == [.eyeFocus])
        criteria.eyesOpenNeedsEyes = true
        #expect(criteria.failures(landscape) == [.eyeFocus, .eyesOpen])
    }

    @Test func ambiguousEyesAreSelectsOnlyWhenAsked() {
        func eyes(_ least: Double, _ most: Double) -> CullingScores {
            var scores = good()
            scores.eyesOpenMin = least
            scores.eyesOpenMax = most
            scores.faceCount = 2
            return scores
        }
        let strict = CullingCriteria()
        var lenient = CullingCriteria()
        lenient.selectsAmbiguousEyes = true

        let open = eyes(0.8, 1), closed = eyes(0, 0.2), unsure = eyes(0.5, 0.5), disagree = eyes(0, 1)
        #expect(strict.failures(open).isEmpty && lenient.failures(open).isEmpty)
        #expect(strict.failures(closed) == [.eyesOpen] && lenient.failures(closed) == [.eyesOpen])
        #expect(strict.failures(unsure) == [.eyesOpen] && lenient.failures(unsure).isEmpty)
        #expect(strict.failures(disagree) == [.eyesOpen] && lenient.failures(disagree).isEmpty)
    }

    @Test func criteriaAreSavedAndReadBackWithDefaultsForWhatsMissing() throws {
        var criteria = CullingCriteria()
        criteria.eyeFocusMinimum = 0.8
        criteria.documents = false
        CullingCriteria.saved = criteria
        #expect(CullingCriteria.saved == criteria)

        let old = try JSONDecoder().decode(CullingCriteria.self, from: Data(#"{"subjectFocus": false}"#.utf8))
        #expect(!old.subjectFocus && old.eyeFocus && old.subjectFocusMinimum == 0.5)
        CullingCriteria.saved = CullingCriteria()
    }

    // MARK: Catalog

    private struct Setup {
        let directory: TemporaryDirectory
        let store: CatalogStore
        let photos: [Photo]
    }

    /// Photos with every mix of scores the criteria tell apart, a video and a photo never analyzed.
    private func makeCatalog() throws -> Setup {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let context = store.viewContext
        var photos: [Photo] = []
        func add(_ scores: CullingScores?, video: Bool = false) {
            let photo = Photo(context: context)
            photo.id = UUID()
            photo.fileName = "IMG_\(photos.count).jpg"
            photo.filePath = directory.url.appending(path: photo.fileName).path(percentEncoded: false)
            photo.fileType = "JPG"
            photo.captureDate = Date(timeIntervalSince1970: Double(photos.count))
            photo.importDate = Date()
            photo.editDate = Date()
            photo.isVideo = video
            scores?.write(to: photo)
            photos.append(photo)
        }
        let focus = [-1, 0.2, 0.5, 0.9]
        let eyes: [(Double, Double)] = [(-1, -1), (0, 0.1), (0.5, 0.5), (0.1, 0.9), (0.9, 1)]
        for subject in focus {
            for eye in focus {
                for (least, most) in eyes {
                    for problem in 0..<4 {
                        var scores = CullingScores()
                        scores.subjectFocus = subject
                        scores.eyeFocus = least < 0 ? -1 : eye
                        scores.eyesOpenMin = least
                        scores.eyesOpenMax = most
                        scores.faceCount = least < 0 ? 0 : 1
                        scores.exposureIssue = problem == 1
                        scores.misfire = problem == 2
                        scores.document = problem == 3
                        add(scores)
                    }
                }
            }
        }
        add(nil)
        add(nil, video: true)
        try context.save()
        context.undoManager?.removeAllActions()
        return Setup(directory: directory, store: store, photos: photos)
    }

    private func fetch(_ predicate: NSPredicate, in store: CatalogStore) throws -> Set<NSManagedObjectID> {
        let request = Photo.fetchRequest()
        request.predicate = predicate
        return Set(try store.viewContext.fetch(request).map(\.objectID))
    }

    @Test func thePredicatesSplitPhotosAsTheRulesDo() throws {
        let setup = try makeCatalog()
        var variants = [CullingCriteria()]
        var lenient = CullingCriteria()
        lenient.selectsAmbiguousEyes = true
        lenient.subjectFocusMinimum = 0.3
        lenient.exposureIssues = false
        variants.append(lenient)
        var strict = CullingCriteria()
        strict.eyeFocusNeedsEyes = true
        strict.eyesOpenNeedsEyes = true
        strict.eyeFocusMinimum = 0.95
        variants.append(strict)
        var nothing = CullingCriteria()
        (nothing.subjectFocus, nothing.eyeFocus, nothing.eyesOpen) = (false, false, false)
        (nothing.exposureIssues, nothing.misfires, nothing.documents) = (false, false, false)
        variants.append(nothing)

        for criteria in variants {
            let selects = try fetch(criteria.selectPredicate, in: setup.store)
            let rejects = try fetch(criteria.rejectPredicate, in: setup.store)
            for photo in setup.photos {
                switch criteria.verdict(for: photo) {
                case .select: #expect(selects.contains(photo.objectID) && !rejects.contains(photo.objectID))
                case .reject: #expect(rejects.contains(photo.objectID) && !selects.contains(photo.objectID))
                case nil: #expect(!selects.contains(photo.objectID) && !rejects.contains(photo.objectID), "unanalyzed")
                }
            }
            #expect(selects.count + rejects.count == setup.photos.count - 2)
        }
        #expect(try fetch(nothing.rejectPredicate, in: setup.store).isEmpty)
    }

    @Test func reviewNarrowsTheGridAndGoesBackToAllWhenTheSourceChanges() throws {
        let setup = try makeCatalog()
        var filter = LibraryFilter()
        #expect(!filter.isFiltering)
        filter.cullReview = CullingReview(kind: .rejects, criteria: CullingCriteria())
        #expect(filter.isFiltering)
        let shown = try fetch(try #require(filter.predicate), in: setup.store)
        #expect(shown == (try fetch(CullingCriteria().rejectPredicate, in: setup.store)))

        filter.sortKey = .fileName
        #expect(filter.cullReview != nil)
        filter.scope = .folder(path: "/Elsewhere")
        #expect(filter.cullReview == nil)
    }

    // MARK: Panel

    private func inspector(_ store: CatalogStore) -> (LibraryInspectorViewController, LibraryState) {
        let state = LibraryState()
        let controller = LibraryInspectorViewController(store: store, state: state)
        controller.view.frame = NSRect(x: 0, y: 0, width: 300, height: 1200)
        controller.view.layoutSubtreeIfNeeded()
        return (controller, state)
    }

    @Test func thePanelCountsTheSourceAndReviewsIt() throws {
        let setup = try makeCatalog()
        let (controller, state) = inspector(setup.store)
        let panel = controller.cullingPanel
        let selects = try fetch(CullingCriteria().selectPredicate, in: setup.store).count
        let rejects = try fetch(CullingCriteria().rejectPredicate, in: setup.store).count
        #expect(panel.statusLabel.stringValue == "\(selects) Selects · \(rejects) Rejects · 1 not analyzed")
        #expect(!panel.analyzeButton.isHidden)

        panel.reviewControl.selectedSegment = 0
        panel.reviewControl.sendAction(panel.reviewControl.action, to: panel.reviewControl.target)
        #expect(state.filter.cullReview?.kind == .selects)

        // A criterion changed while reviewing refilters the grid, and is remembered.
        panel.documentsBox.state = .off
        panel.documentsBox.sendAction(panel.documentsBox.action, to: panel.documentsBox.target)
        #expect(state.filter.cullReview?.criteria.documents == false)
        #expect(CullingCriteria.saved.documents == false)
        #expect(panel.statusLabel.stringValue.hasPrefix("\(try fetch(controller.cullingCriteria.selectPredicate, in: setup.store).count) Selects"))
        CullingCriteria.saved = CullingCriteria()

        state.filter.scope = .folder(path: "/Elsewhere")
        #expect(panel.reviewControl.selectedSegment == 2, "back to All")
        #expect(panel.statusLabel.stringValue == "No photos to analyze")
    }

    @Test func applyFlagsTheSplitInOneUndoStepAndLeavesFlaggedPhotosAlone() throws {
        let setup = try makeCatalog()
        let criteria = CullingCriteria()
        let flaggedSelect = try #require(setup.photos.first { criteria.verdict(for: $0) == .select })
        let flaggedReject = try #require(setup.photos.first { if case .reject = criteria.verdict(for: $0) { true } else { false } })
        flaggedSelect.photoFlag = .rejected
        flaggedReject.photoFlag = .picked
        try setup.store.viewContext.save()
        setup.store.viewContext.undoManager?.removeAllActions()
        let (controller, _) = inspector(setup.store)

        controller.cullingPanel.applyButton.performClick(nil)

        for photo in setup.photos where photo != flaggedSelect && photo != flaggedReject {
            switch criteria.verdict(for: photo) {
            case .select: #expect(photo.photoFlag == .picked)
            case .reject: #expect(photo.photoFlag == .rejected)
            case nil: #expect(photo.photoFlag == .unflagged, "unanalyzed photos and videos are left alone")
            }
        }
        #expect(flaggedSelect.photoFlag == .rejected && flaggedReject.photoFlag == .picked)
        let undo = try #require(setup.store.viewContext.undoManager)
        #expect(undo.undoActionName == "Apply Assisted Culling")
        undo.undo()
        #expect(Set(setup.photos.filter { $0.photoFlag != .unflagged }) == [flaggedSelect, flaggedReject])
    }
}
