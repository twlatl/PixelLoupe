import AppKit
import CoreData
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PixelLoupe

/// Auto Stack (RAW-71).
@Suite("Auto Stack")
@MainActor
struct AutoStackingTests {
    @Test func runsOfPhotosThatJoinTheOneBeforeBecomeStacks() {
        #expect(AutoStacking.groups(joining: []) == [])
        #expect(AutoStacking.groups(joining: [false, true, true, false, false, true]) == [[0, 1, 2], [4, 5]])
        #expect(AutoStacking.groups(joining: [true, false, false]) == [], "the first photo has no one to join, and singles aren't stacks")
    }

    @Test func photosTakenWithinTheGapJoin() {
        let start = Date(timeIntervalSince1970: 0)
        let dates = [0, 2, 3, 70, 200, 201].map { start.addingTimeInterval($0) }
        #expect(AutoStacking.joins(dates: dates, gap: 60) == [false, true, true, false, false, true])
        #expect(AutoStacking.groups(joining: AutoStacking.joins(dates: dates, gap: 1)) == [[1, 2], [4, 5]])
        #expect(AutoStacking.groups(joining: AutoStacking.joins(dates: dates, gap: 3600)) == [[0, 1, 2, 3, 4, 5]])
    }

    @Test func strictnessSetsHowAlikePhotosMustLook() {
        #expect(AutoStacking.threshold(strictness: 0) == AutoStacking.looseDistance)
        #expect(AutoStacking.threshold(strictness: 1) == AutoStacking.strictDistance)
        let distances: [Double?] = [nil, 0.05, 0.2, nil, 0.4]
        #expect(AutoStacking.joins(distances: distances, strictness: 1) == [false, true, false, false, false])
        #expect(AutoStacking.joins(distances: distances, strictness: 0.5) == [false, true, true, false, false])
        #expect(AutoStacking.joins(distances: distances, strictness: 0) == [false, true, true, false, true])
    }

    /// A JPEG of stripes at `period` pixels, so pictures can be made alike or not.
    private static func writeStripes(to url: URL, period: Int, vertical: Bool) throws {
        let width = 320, height = 240
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { bytes[y * width + x] = ((vertical ? x : y) / period) % 2 == 0 ? 30 : 220 }
        }
        let image = try #require(bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )?.makeImage()
        })
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    @Test func picturesThatLookAlikeAreCloserThanOnesThatDont() async throws {
        let directory = try TemporaryDirectory()
        let urls = (0..<4).map { directory.url.appending(path: "\($0).jpg") }
        try Self.writeStripes(to: urls[0], period: 20, vertical: true)
        try Self.writeStripes(to: urls[1], period: 20, vertical: true)
        try Self.writeStripes(to: urls[2], period: 4, vertical: false)
        var progress: [Int] = []
        let distances = await AutoStacking.distances(urls) { progress.append($0) }
        #expect(distances.count == 4)
        #expect(distances[0] == nil, "the first has nothing before it")
        let same = try #require(distances[1]), different = try #require(distances[2])
        #expect(same < 0.01)
        #expect(different > same)
        #expect(distances[3] == nil, "a missing thumbnail can't be compared")
        #expect(progress == [1, 2, 3, 4])
    }

    // MARK: Catalog

    private struct Setup {
        let directory: TemporaryDirectory
        let store: CatalogStore
        let photos: [Photo]
        var editing: PhotoEditing { PhotoEditing(store: store) }
    }

    /// Six photos: a burst of three, a pair, and one on its own.
    private func makeCatalog() throws -> Setup {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        var photos: [Photo] = []
        for (index, seconds) in [0.0, 1, 2, 300, 301, 900].enumerated() {
            let photo = Photo(context: store.viewContext)
            photo.id = UUID()
            photo.fileName = "IMG_\(index).jpg"
            photo.filePath = directory.url.appending(path: photo.fileName).path(percentEncoded: false)
            photo.fileType = "JPG"
            photo.captureDate = Date(timeIntervalSince1970: 1_000_000 + seconds)
            photo.importDate = Date()
            photo.editDate = Date()
            photos.append(photo)
        }
        try store.viewContext.save()
        store.viewContext.undoManager?.removeAllActions()
        return Setup(directory: directory, store: store, photos: photos)
    }

    private func score(_ photo: Photo, quality: Double, sharp: Bool = true) {
        var scores = CullingScores()
        scores.subjectFocus = sharp ? 0.9 : 0.1
        scores.quality = quality
        scores.write(to: photo)
    }

    @Test func theBestSelectGoesOnTopOtherwiseTheFirstPhoto() throws {
        let setup = try makeCatalog()
        let burst = Array(setup.photos.prefix(3))
        #expect(AutoStacking.top(of: burst, criteria: CullingCriteria()) == burst[0], "nothing analyzed: the earliest")
        score(burst[1], quality: 0.4)
        score(burst[2], quality: 0.9, sharp: false)
        #expect(AutoStacking.top(of: burst, criteria: CullingCriteria()) == burst[1], "a Select beats a better-looking Reject")
        score(burst[1], quality: 0.4, sharp: false)
        #expect(AutoStacking.top(of: burst, criteria: CullingCriteria()) == burst[2], "with no Selects, the best-looking")
    }

    @Test func autoStackMakesOpenStacksInOneUndoStep() throws {
        let setup = try makeCatalog()
        let photos = setup.photos
        score(photos[2], quality: 0.8)
        let ids = photos.map(\.objectID)

        let made = setup.editing.autoStack([[ids[0], ids[1], ids[2]], [ids[3], ids[4]]], criteria: CullingCriteria())

        #expect(made == 2)
        let burst = try #require(photos[0].stack)
        #expect(burst.orderedPhotos == [photos[2], photos[0], photos[1]], "the best on top, the rest in order")
        #expect(!burst.isCollapsed && photos.allSatisfy { !$0.isHiddenInStack })
        #expect(photos[3].stack?.orderedPhotos == [photos[3], photos[4]])
        #expect(photos[5].stack == nil)
        let undo = try #require(setup.store.viewContext.undoManager)
        #expect(undo.undoActionName == "Auto Stack")
        undo.undo()
        #expect(photos.allSatisfy { $0.stack == nil })
    }

    @Test func photosAlreadyStackedAreLeftAlone() throws {
        let setup = try makeCatalog()
        let photos = setup.photos
        setup.editing.groupIntoStack([photos[3].objectID, photos[4].objectID])
        let existing = photos[3].stack
        let made = setup.editing.autoStack([[photos[3].objectID, photos[4].objectID, photos[5].objectID]], criteria: CullingCriteria())
        #expect(made == 0, "one unstacked photo isn't a stack")
        #expect(photos[3].stack === existing && photos[5].stack == nil)
    }

    // MARK: Sheet

    @Test func theSheetCountsTheStacksItWouldMake() throws {
        let setup = try makeCatalog()
        let model = AutoStackModel(photoIDs: setup.photos.map(\.objectID), dates: setup.photos.map(\.captureDate), isSelection: false)
        model.method = .captureTime
        model.gapPosition = AutoStackModel.position(ofGap: 60)
        #expect(model.gap == 60 && model.gapTitle == "1 minute")
        #expect(model.title == "Auto Stack 6 photos")
        #expect(model.groups == [[0, 1, 2], [3, 4]])
        #expect(model.summary == "Makes 2 stacks from 5 photos." && model.canStack)
        model.gapPosition = 0
        #expect(model.gap == 1 && model.groups == [[0, 1, 2], [3, 4]])
        model.gapPosition = 1
        #expect(model.gap == 3600 && model.groups == [[0, 1, 2, 3, 4, 5]])

        var asked = false
        model.onNeedsDistances = { asked = true }
        model.method = .similarity
        #expect(asked)
        #expect(model.groups == nil && !model.canStack)
        #expect(model.summary == "Comparing photos… 0 of 6")
        model.distances = [nil, 0.01, 0.01, 0.9, 0.9, 0.9]
        #expect(model.groups == [[0, 1, 2]])
        model.distances = [nil, 0.9, 0.9, 0.9, 0.9, 0.9]
        #expect(model.summary == "No photos are close enough to stack." && !model.canStack)

        // Remembered for next time; the test defaults are thrown away.
        #expect(AutoStackModel(photoIDs: [], dates: [], isSelection: true).method == .similarity)
        model.method = .captureTime
    }

    @Test func autoStackWorksOnTheSelectionOrTheSourceLeavingStacksOut() throws {
        let setup = try makeCatalog()
        let photos = setup.photos
        setup.editing.groupIntoStack([photos[3].objectID, photos[4].objectID])
        photos[3].stack?.isCollapsed = false
        photos[3].stack?.refreshHidden()
        let state = LibraryState()
        let controller = LibraryInspectorViewController(store: setup.store, state: state)
        controller.view.frame = NSRect(x: 0, y: 0, width: 300, height: 1600)
        controller.view.layoutSubtreeIfNeeded()

        state.selectedPhotoIDs = [photos[5].objectID]
        var (shown, isSelection) = controller.autoStackPhotos()
        #expect(!isSelection && shown == [photos[0], photos[1], photos[2], photos[5]], "one photo selected: the source")

        state.selectedPhotoIDs = [photos[2].objectID, photos[0].objectID, photos[4].objectID]
        (shown, isSelection) = controller.autoStackPhotos()
        #expect(isSelection && shown == [photos[0], photos[2]], "in capture-time order, without stacked photos")
    }
}
