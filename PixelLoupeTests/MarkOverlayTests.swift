import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Rating, flag and label overlay")
@MainActor
struct MarkOverlayTests {
    @Test func applyingAMarkShowsItBrieflyInTheLowerThird() async throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let photo = Photo(context: store.viewContext)
        photo.id = UUID()
        photo.fileName = "IMG.jpg"
        photo.filePath = directory.url.appending(path: "IMG.jpg").path(percentEncoded: false)
        photo.fileType = "JPG"
        photo.captureDate = Date()
        photo.importDate = Date()
        photo.editDate = Date()
        try store.viewContext.save()
        let controller = CatalogWindowController(store: store)
        defer { controller.close() }
        controller.showWindow(nil)
        let overlay = controller.rootViewController.main.markOverlay
        let editing = PhotoEditing(store: store)
        let ids = [photo.objectID]

        editing.setRating(3, for: ids)
        #expect(overlay.shownMark == .rating(3) && !overlay.isHidden)
        editing.setFlag(.rejected, for: ids)
        #expect(overlay.shownMark == .flag(.rejected), "a new mark replaces the one showing")
        editing.setColorLabel(.red, for: ids, toggling: true)
        #expect(overlay.shownMark == .label(.red))
        editing.setColorLabel(.red, for: ids, toggling: true)
        #expect(overlay.shownMark == .label(.none), "pressing 6 again clears the label, and says so")
        editing.setRating(4, for: [])
        #expect(overlay.shownMark == .label(.none), "nothing applied, nothing shown")

        // Centered horizontally, in the lower third of the content area, above the photos.
        let container = try #require(overlay.superview)
        container.layoutSubtreeIfNeeded()
        let frame = overlay.frame
        #expect(abs(frame.midX - container.bounds.midX) <= 1)
        let fromTop = container.isFlipped ? frame.midY : container.bounds.height - frame.midY
        #expect(fromTop > container.bounds.height * 2 / 3 && fromTop < container.bounds.height, "\(fromTop) of \(container.bounds.height)")
        #expect(container.subviews.last === overlay)
        #expect(overlay.hitTest(NSPoint(x: frame.midX, y: frame.midY)) == nil, "clicks go to the photos")

        // Switching to Develop keeps it on top; then it fades.
        controller.state.mode = .develop
        #expect(container.subviews.last === overlay)
        try await Task.sleep(for: MarkOverlayView.displayDuration)
        // By turns rather than by the clock: other tests can hold the main thread for seconds.
        for _ in 0..<400 where !overlay.isHidden { try await Task.sleep(for: .milliseconds(50)) }
        #expect(overlay.shownMark == nil && overlay.isHidden)
    }

    @Test func eachMarkReadsAsTheScreenshotsShow() {
        #expect(PhotoMark.rating(3).spokenText == "Rating: 3 stars")
        #expect(PhotoMark.rating(0).spokenText == "Rating: none")
        #expect(PhotoMark.flag(.rejected).spokenText == "Flag: Rejected")
        #expect(PhotoMark.label(.red).spokenText == "Label: Red")
    }
}
