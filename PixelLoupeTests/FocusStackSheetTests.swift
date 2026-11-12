import AppKit
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Focus stack sheet")
@MainActor
struct FocusStackSheetTests {
    /// A sheet on `count` frames, each sharp in its own band, laid out at its usual size.
    private func makeSheet(_ fixture: FocusFixture, options: FocusStackOptions = FocusStackOptions()) throws -> FocusStackSheetController {
        let sheet = FocusStackSheetController(sources: fixture.sources, options: options)
        let window = try #require(sheet.window)
        window.setContentSize(NSSize(width: 1180, height: 720))
        window.contentView?.layoutSubtreeIfNeeded()
        return sheet
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<600 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(condition(), "\(what)")
    }

    private func cell(_ sheet: FocusStackSheetController, _ row: Int) throws -> FocusStackSourceCell {
        try #require(sheet.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? FocusStackSourceCell)
    }

    @Test func laysOutThePreviewBesideTheSourcesAndSettings() throws {
        var fixture = try FocusFixture()
        try fixture.addBands(3)
        let sheet = try makeSheet(fixture)
        #expect(sheet.window?.title == "Focus Stack Preview")
        #expect(sheet.sourcesHeading.stringValue == "Source Photos (3)")
        #expect(sheet.tableView.numberOfRows == 3)
        #expect(try cell(sheet, 0).nameLabel.stringValue == "DSC_0000.dng")

        let well = sheet.previewWell.convert(sheet.previewWell.bounds, to: nil)
        let list = try #require(sheet.tableView.enclosingScrollView).convert(sheet.tableView.enclosingScrollView!.bounds, to: nil)
        let picker = sheet.showingControl.convert(sheet.showingControl.bounds, to: nil)
        let radius = sheet.radiusSlider.convert(sheet.radiusSlider.bounds, to: nil)
        // The well fills the left side with the picker under it; the list and the settings stay on the right.
        #expect(well.width > 700 && well.height > 400, "\(well)")
        #expect(list.minX > well.maxX && radius.minX > well.maxX, "\(list) and \(radius) beside \(well)")
        #expect(picker.maxY <= well.minY && picker.midX > well.minX && picker.midX < well.maxX, "\(picker) under \(well)")
        #expect(radius.maxY < list.minY, "\(radius) below \(list)")
        #expect(sheet.showingControl.segmentCount == 3)
        #expect((0..<3).map { sheet.showingControl.label(forSegment: $0) } == ["Original", "Rendered", "Depth Map"])
        #expect(sheet.methodButtons.map(\.title) == ["Weighted Average", "Depth Map", "Pyramid"])
        // Nothing can be changed, or merged, before the photos have been read.
        #expect(!sheet.mergeButton.isEnabled && !sheet.radiusSlider.isEnabled)
        sheet.cancel(nil)
    }

    @Test func showsTheStackThenTheOriginalAndTheDepthMap() async throws {
        var fixture = try FocusFixture()
        try fixture.addBands(3)
        let sheet = try makeSheet(fixture)
        await waitUntil("the first preview") { sheet.mergeButton.isEnabled && sheet.hasRenderedPreview }
        #expect(sheet.showing == .rendered)
        #expect(sheet.showingControl.selectedSegment == FocusStackSheetController.Showing.rendered.rawValue)
        // No photo is selected yet, so there's no Original to show; Depth Map has its map.
        #expect(!sheet.showingControl.isEnabled(forSegment: 0))
        #expect(sheet.showingControl.isEnabled(forSegment: 1) && sheet.showingControl.isEnabled(forSegment: 2))
        #expect(sheet.methodButtons[1].state == .on && sheet.methodButtons[1].isEnabled)
        // The methods still to come can't be chosen.
        #expect(!sheet.methodButtons[0].isEnabled && !sheet.methodButtons[2].isEnabled)

        let stack = try #require(sheet.previewView.image)
        // Clicking a photo in the list shows it.
        sheet.tableView.selectRowIndexes([1], byExtendingSelection: false)
        #expect(sheet.showing == .original)
        #expect(sheet.showingControl.isEnabled(forSegment: 0))
        await waitUntil("the original") { sheet.previewView.image !== stack }
        let original = try #require(sheet.previewView.image)

        sheet.showingControl.selectedSegment = FocusStackSheetController.Showing.depthMap.rawValue
        _ = sheet.showingControl.sendAction(sheet.showingControl.action, to: sheet.showingControl.target)
        #expect(sheet.showing == .depthMap)
        let map = try #require(sheet.previewView.image)
        #expect(map !== original && map !== stack)

        sheet.showingControl.selectedSegment = FocusStackSheetController.Showing.rendered.rawValue
        _ = sheet.showingControl.sendAction(sheet.showingControl.action, to: sheet.showingControl.target)
        #expect(sheet.showing == .rendered)
        #expect(sheet.previewView.image != nil)
        sheet.cancel(nil)
    }

    @Test func uncheckingPhotosLeavesThemOutAndNeedsTwoToMerge() async throws {
        var fixture = try FocusFixture()
        try fixture.addBands(3)
        let sheet = try makeSheet(fixture)
        await waitUntil("the photos to be read") { sheet.mergeButton.isEnabled }
        #expect(sheet.stackedCount == 3)

        try cell(sheet, 1).checkbox.performClick(nil)
        #expect(sheet.excluded == [fixture.sources[1].url])
        #expect(sheet.stackedCount == 2 && sheet.mergeButton.isEnabled)

        try cell(sheet, 2).checkbox.performClick(nil)
        #expect(sheet.stackedCount == 1)
        #expect(!sheet.mergeButton.isEnabled)
        #expect(sheet.messageLabel.stringValue == "Check at least two photos to stack.")

        try cell(sheet, 2).checkbox.performClick(nil)
        #expect(sheet.mergeButton.isEnabled && sheet.messageLabel.stringValue.isEmpty)

        var finished: (options: FocusStackOptions, excluding: Set<URL>)?
        sheet.onFinish = { finished = $0 }
        sheet.merge(nil)
        #expect(finished?.excluding == [fixture.sources[1].url])
        #expect(finished?.options == sheet.options)
    }

    @Test func settingsFollowTheControlsAndResetRestoresThem() async throws {
        var fixture = try FocusFixture()
        try fixture.addBands(2)
        var saved = FocusStackOptions()
        saved.radius = 20
        saved.smoothing = 7
        saved.createsStack = false
        // A method that can't be chosen yet falls back to Depth Map.
        saved.method = .pyramid
        let sheet = try makeSheet(fixture, options: saved)
        await waitUntil("the photos to be read") { sheet.mergeButton.isEnabled }
        #expect(sheet.options.method == .depthMap)
        #expect(sheet.radiusSlider.integerValue == 20 && sheet.radiusField.integerValue == 20)
        #expect(sheet.smoothingSlider.integerValue == 7 && sheet.smoothingField.integerValue == 7)
        #expect(sheet.createStackCheckbox.state == .off)
        #expect(sheet.radiusSlider.minValue == 1 && sheet.radiusSlider.maxValue == 50)
        #expect(sheet.smoothingSlider.minValue == 0 && sheet.smoothingSlider.maxValue == 10)

        sheet.radiusSlider.integerValue = 12
        _ = sheet.radiusSlider.sendAction(sheet.radiusSlider.action, to: sheet.radiusSlider.target)
        #expect(sheet.options.radius == 12 && sheet.radiusField.integerValue == 12)
        // A number typed outside the range is brought into it.
        sheet.smoothingField.integerValue = 40
        _ = sheet.smoothingField.sendAction(sheet.smoothingField.action, to: sheet.smoothingField.target)
        #expect(sheet.options.smoothing == 10 && sheet.smoothingSlider.integerValue == 10)

        sheet.resetButton.performClick(nil)
        #expect(sheet.options.method == .depthMap && sheet.options.radius == 8 && sheet.options.smoothing == 4)
        #expect(sheet.radiusSlider.integerValue == 8 && sheet.smoothingSlider.integerValue == 4)
        // Reset leaves Create Stack alone.
        #expect(!sheet.options.createsStack)
        sheet.createStackCheckbox.performClick(nil)
        #expect(sheet.options.createsStack)

        var finished: (options: FocusStackOptions, excluding: Set<URL>)? = (FocusStackOptions(), [])
        sheet.onFinish = { finished = $0 }
        sheet.cancel(nil)
        #expect(finished == nil)
    }

    @Test func marksAPhotoThatDoesNotLineUp() async throws {
        var fixture = try FocusFixture()
        var other = try FocusFixture(seed: 99)
        try other.addFrame(second: 1.5) { _, _ in true }
        try fixture.addBands(3)
        let stray = other.sources[0]
        let sheet = FocusStackSheetController(sources: fixture.sources + [stray], options: FocusStackOptions())
        sheet.window?.setContentSize(NSSize(width: 1180, height: 720))
        sheet.window?.contentView?.layoutSubtreeIfNeeded()
        await waitUntil("the photos to be lined up") { sheet.mergeButton.isEnabled }
        #expect(sheet.skipped == [stray.url])
        // The list is in the order the photos were taken: the stray one is third.
        #expect(sheet.sources.map(\.url) == [fixture.sources[0].url, fixture.sources[1].url, stray.url, fixture.sources[2].url])
        let row = try cell(sheet, 2)
        #expect(!row.checkbox.isEnabled && row.checkbox.state == .off)
        #expect(row.noteLabel.stringValue == "Doesn’t line up" && !row.noteLabel.isHidden)
        #expect(sheet.stackedCount == 3)
        #expect(sheet.messageLabel.stringValue == "3 of 4 photos merged. The others don’t line up with them.")
        sheet.cancel(nil)
    }

    @Test func previewerDrawsTheStackItsDepthMapAndAPartAtFullSize() async throws {
        var fixture = try FocusFixture()
        try fixture.addBands(3, raw: false)
        let previewer = try FocusStackPreviewer(sources: fixture.sources)
        #expect(try await previewer.align { _ in }.isEmpty)
        let progress = Counter()
        let whole = try await previewer.render(options: FocusStackOptions(), excluding: [], maxPixels: 240) { _ in progress.add() }
        #expect(whole.mergedCount == 3)
        #expect(abs(whole.image.width - 240) <= 2 && abs(whole.depthMap.width - 240) <= 2)
        // The depth map after each frame, then smoothed.
        #expect(progress.count == 4)
        // The same settings again are the same preview, without stacking again.
        let again = try await previewer.render(options: FocusStackOptions(), excluding: [], maxPixels: 240) { _ in progress.add() }
        #expect(again.image === whole.image && progress.count == 4)
        // Another Smoothing reuses the depth map's state: only the smoothed map is reported.
        var smoother = FocusStackOptions()
        smoother.smoothing = 8
        _ = try await previewer.render(options: smoother, excluding: [], maxPixels: 240) { _ in progress.add() }
        #expect(progress.count == 5)

        let detail = try await previewer.renderDetail(
            options: FocusStackOptions(), excluding: [], center: CGPoint(x: 0.5, y: 0.5), pixels: CGSize(width: 200, height: 120), maxPixels: 240
        )
        #expect(detail.width == 200 && detail.height == 120)
        #expect(previewer.original(fixture.sources[0].url, maxPixels: 100)?.width == 100)
    }

    @Test func detailReadsOnlyTheFramesSharpAroundThere() {
        // A depth map of 10 frames, left to right: the left edge is frame 0, the right edge frame 9.
        let width = 100, height = 10
        let pixels = (0..<(width * height)).map { UInt8(Double($0 % width) / Double(width - 1) * 255) }
        let map = FocusDepthMap(width: width, height: height, pixels: pixels)
        let photo = CGSize(width: 1000, height: 100)
        // The middle fifth names frames 3.6 to 5.4: frames 3…6, and one either side.
        let middle = FocusStackPreviewer.frames(in: map, region: CGRect(x: 400, y: 0, width: 200, height: 100), photoSize: photo, count: 10, margin: 1)
        #expect(middle == 2...7)
        // At the ends it stays inside the stack.
        let left = FocusStackPreviewer.frames(in: map, region: CGRect(x: 0, y: 0, width: 50, height: 100), photoSize: photo, count: 10, margin: 3)
        #expect(left == 0...4)
        // Never fewer than two frames.
        let flat = FocusDepthMap(width: 4, height: 4, pixels: Array(repeating: 0, count: 16))
        #expect(FocusStackPreviewer.frames(in: flat, region: CGRect(x: 0, y: 0, width: 10, height: 10), photoSize: photo, count: 10, margin: 0) == 0...1)
    }
}

/// Counts calls from any thread.
private nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}
