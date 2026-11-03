import Foundation
import Testing
@testable import PixelLoupe

@Suite("Develop preview scale while resizing")
struct PreviewScaleHoldTests {
    private final class Photo {}

    @Test func settledRendersAtTheScaleAskedFor() {
        var hold = PreviewScaleHold()
        let photo = ObjectIdentifier(Photo())
        #expect(hold.scale(for: 0.2, source: photo) == 0.2)
        #expect(hold.scale(for: 0.3, source: photo) == 0.3)
    }

    @Test func resizingKeepsTheLastScaleThenCatchesUp() {
        var hold = PreviewScaleHold()
        let photo = ObjectIdentifier(Photo())
        _ = hold.scale(for: 0.2, source: photo)
        hold.isResizing = true
        #expect(hold.scale(for: 0.25, source: photo) == 0.2, "no re-decode on each frame of the slide")
        #expect(hold.scale(for: 0.3, source: photo) == 0.2)
        hold.isResizing = false
        #expect(hold.scale(for: 0.3, source: photo) == 0.3, "the sharp render once the size settles")
    }

    @Test func anotherPhotoGetsItsOwnScaleMidResize() {
        var hold = PreviewScaleHold()
        let first = Photo(), second = Photo()
        _ = hold.scale(for: 0.2, source: ObjectIdentifier(first))
        hold.isResizing = true
        #expect(hold.scale(for: 0.5, source: ObjectIdentifier(second)) == 0.5)
        #expect(hold.scale(for: 0.6, source: ObjectIdentifier(second)) == 0.5, "then that one is held")
    }

    @Test func nothingHeldBeforeTheFirstRender() {
        var hold = PreviewScaleHold()
        hold.isResizing = true
        #expect(hold.scale(for: 0.4, source: ObjectIdentifier(Photo())) == 0.4)
    }
}
