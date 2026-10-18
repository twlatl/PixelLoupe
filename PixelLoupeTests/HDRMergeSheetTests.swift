import AppKit
import Foundation
import Testing
@testable import PixelLoupe

@Suite("HDR merge sheet")
@MainActor
struct HDRMergeSheetTests {
    @Test func previewWellKeepsTheLayoutBeforeTheImageLoads() throws {
        let bracket = try Bracket()
        let sheet = HDRMergeSheetController(sources: bracket.sources, options: HDRMergeOptions())
        let window = try #require(sheet.window)
        window.setContentSize(NSSize(width: 1080, height: 680))
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(sheet.previewView.image == nil)
        let well = sheet.previewWell.convert(sheet.previewWell.bounds, to: nil)
        let options = sheet.autoAlignCheckbox.convert(sheet.autoAlignCheckbox.bounds, to: nil)
        // The well fills the left side and the options stay on the right.
        #expect(well.width > 700 && well.height > 400, "\(well)")
        #expect(options.minX > well.maxX, "\(options) beside \(well)")
        #expect(sheet.spinner.superview === sheet.previewWell)
        #expect(sheet.previewWell.layer?.borderWidth == 1)
        #expect(sheet.previewWell.layer?.borderColor == NSColor(white: 0.5, alpha: 1).cgColor)
        sheet.cancel(nil)
    }

    private func click(_ view: NSView, at point: NSPoint, dragTo end: NSPoint? = nil) {
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        view.mouseDown(with: event(.leftMouseDown, point))
        if let end { view.mouseDragged(with: event(.leftMouseDragged, end)) }
        view.mouseUp(with: event(.leftMouseUp, end ?? point))
    }

    @Test func clickZoomsTo100PercentAndBack() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        let view = MergePreviewView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        window.contentView = view
        view.photoSize = CGSize(width: 6000, height: 4000)
        view.image = NSImage(size: NSSize(width: 600, height: 400))
        var requests: [(CGPoint, CGSize)] = []
        view.onDetailNeeded = { requests.append(($0, $1)) }

        // The 3:2 photo is fitted 400 × 267 in the middle; a click a quarter of the way across zooms there.
        click(view, at: NSPoint(x: 100, y: 200))
        #expect(view.isZoomed)
        let first = try #require(requests.last)
        #expect(abs(first.0.x - 0.25) < 0.01 && abs(first.0.y - 0.5) < 0.01, "\(first.0)")
        #expect(first.1 == view.detailPixels)

        // Dragging right moves the view left, toward the photo's left edge, and asks for the new part.
        click(view, at: NSPoint(x: 200, y: 200), dragTo: NSPoint(x: 300, y: 200))
        let panned = try #require(requests.last)
        #expect(requests.count == 2 && panned.0.x < first.0.x)
        // It stops at the edge: the view is half its width from it.
        click(view, at: NSPoint(x: 0, y: 200), dragTo: NSPoint(x: 4000, y: 200))
        let half = view.detailPixels.width / 2 / 6000
        #expect(abs((requests.last?.0.x ?? 0) - half) < 0.001)

        click(view, at: NSPoint(x: 200, y: 200))
        #expect(!view.isZoomed)
        // A dragged 100% view doesn't draw outside the well.
        #expect(view.clipsToBounds)
    }

    @Test func detailIsTheMergeAtFullResolution() async throws {
        let bracket = try Bracket()
        let previewer = try HDRMergePreviewer(sources: bracket.sources)
        var options = HDRMergeOptions()
        options.autoAlign = false
        let whole = try await previewer.render(options: options, maxPixels: 240)
        #expect(whole.image.width == 240)
        let detail = try await previewer.renderDetail(options: options, center: CGPoint(x: 0.5, y: 0.5), pixels: CGSize(width: 300, height: 200), maxPixels: 240)
        #expect(detail.image.width == 300 && detail.image.height == 200)
        // Near an edge, the part stays inside the photo.
        let corner = try await previewer.renderDetail(options: options, center: .zero, pixels: CGSize(width: 300, height: 200), maxPixels: 240)
        #expect(corner.image.width == 300 && corner.image.height == 200)
    }
}
