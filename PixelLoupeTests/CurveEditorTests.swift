import AppKit
import Testing
@testable import PixelLoupe

@MainActor
struct CurveEditorTests {
    private let window: NSWindow
    private let editor: CurveEditorView
    private var changes: Changes

    @MainActor
    final class Changes {
        var values: [(curve: ToneCurve, isFinal: Bool)] = []
        var parametric: [(curve: ParametricCurve, isFinal: Bool)] = []
    }

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 212, height: 192), styleMask: [.borderless], backing: .buffered, defer: false)
        editor = CurveEditorView(frame: NSRect(x: 0, y: 6, width: 212, height: 180))
        window.contentView?.addSubview(editor)
        changes = Changes()
        let log = changes
        editor.onChange = { curve, isFinal in log.values.append((curve, isFinal)) }
        editor.onParametricChange = { curve, isFinal in log.parametric.append((curve, isFinal)) }
    }

    /// The view point for a curve coordinate.
    private func point(_ x: Double, _ y: Double) -> NSPoint {
        let plot = editor.bounds.insetBy(dx: 6, dy: 6)
        return editor.convert(NSPoint(x: plot.minX + x * plot.width, y: plot.minY + y * plot.height), to: nil)
    }

    private func event(_ type: NSEvent.EventType, at location: NSPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    private func click(_ x: Double, _ y: Double, clicks: Int = 1) {
        editor.mouseDown(with: event(.leftMouseDown, at: point(x, y), clicks: clicks))
        editor.mouseUp(with: event(.leftMouseUp, at: point(x, y), clicks: clicks))
    }

    @Test("Clicking the graph adds a point that can be dragged")
    func addAndDrag() {
        click(0.5, 0.5)
        #expect(editor.curve.points.count == 3)
        editor.mouseDown(with: event(.leftMouseDown, at: point(0.5, 0.5)))
        editor.mouseDragged(with: event(.leftMouseDragged, at: point(0.4, 0.7)))
        editor.mouseUp(with: event(.leftMouseUp, at: point(0.4, 0.7)))
        let moved = editor.curve.points[1]
        #expect(abs(moved.x - 0.4) < 0.02 && abs(moved.y - 0.7) < 0.02)
        #expect(changes.values.last?.isFinal == true)
        #expect(changes.values.contains { !$0.isFinal }, "drags report intermediate values")
    }

    @Test("Dragging a point off the graph or double-clicking it deletes it; double-clicking empty space resets")
    func deleteAndReset() {
        editor.curve = ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.3, y: 0.6), .init(x: 0.7, y: 0.4), .init(x: 1, y: 1)])
        editor.mouseDown(with: event(.leftMouseDown, at: point(0.3, 0.6)))
        let far = NSPoint(x: point(0.3, 0.6).x, y: point(0.3, 1).y + 80)
        editor.mouseDragged(with: event(.leftMouseDragged, at: far))
        #expect(editor.isDeleting && editor.curve.points.count == 4, "marked, not yet removed")
        editor.mouseUp(with: event(.leftMouseUp, at: far))
        #expect(editor.curve.points.count == 3 && !editor.isDeleting)

        click(0.7, 0.4, clicks: 2)
        #expect(editor.curve.points.count == 2)
        // Two points are the minimum.
        click(1, 1, clicks: 2)
        #expect(editor.curve.points.count == 2)

        editor.curve = ToneCurve(points: [.init(x: 0, y: 0.2), .init(x: 1, y: 0.9)])
        click(0.5, 0.1, clicks: 2)
        #expect(editor.curve.isIdentity)
    }

    @Test("The last point clicked or added is selected; typing an input or output moves it")
    func selection() {
        var selectionChanges = 0
        editor.onSelectionChange = { selectionChanges += 1 }
        #expect(editor.selectedPoint == nil)
        click(0.5, 0.6)
        let added = editor.selectedPoint
        #expect(added.map { abs($0.x - 0.5) < 0.01 && abs($0.y - 0.6) < 0.01 } == true)
        #expect(selectionChanges > 0)

        changes.values.removeAll()
        editor.moveSelectedPoint(x: 100.0 / 255)
        #expect(editor.selectedPoint.map(CurveEditorView.levels)?.input == 100)
        editor.moveSelectedPoint(y: 200.0 / 255)
        #expect(editor.selectedPoint.map(CurveEditorView.levels)?.output == 200)
        #expect(changes.values.count == 2 && changes.values.allSatisfy(\.isFinal), "each typed value is one edit")

        click(0, 0)
        #expect(editor.selectedPoint == ToneCurve.Point(x: 0, y: 0), "clicking an existing point selects it")
        editor.channel = .red
        #expect(editor.selectedPoint == nil, "a different curve has nothing selected")
    }

    @Test("Hovering shows the input under the pointer and the curve's output there")
    func hoverReadout() {
        editor.curve = ToneCurve(points: [.init(x: 0, y: 0.2), .init(x: 1, y: 1)])
        #expect(editor.readoutPoint == nil)
        editor.mouseMoved(with: event(.mouseMoved, at: point(0.5, 0.1)))
        let readout = editor.readoutPoint.map(CurveEditorView.levels)
        #expect(readout?.input == 128 && readout?.output == Int((editor.curve.value(at: 128.0 / 255) * 255).rounded()))
        editor.mouseExited(with: event(.mouseMoved, at: point(0.5, 0.1)))
        #expect(editor.readoutPoint == nil)
    }

    @Test("In parametric mode, dragging up or down changes the region under the pointer; a click alone changes nothing")
    func dragRegion() {
        editor.isParametric = true
        editor.parametric = ParametricCurve()
        var highlighted: [Int?] = []
        editor.onHighlightRegion = { highlighted.append($0) }

        // Darks (0.25…0.5): a quarter of the graph's height up is +0.5.
        editor.mouseDown(with: event(.leftMouseDown, at: point(0.4, 0.3)))
        #expect(editor.highlightedRegion == 1 && highlighted.last == 1)
        editor.mouseDragged(with: event(.leftMouseDragged, at: point(0.9, 0.55)))
        editor.mouseUp(with: event(.leftMouseUp, at: point(0.9, 0.55)))
        #expect(abs(editor.parametric.darks - 0.5) < 0.02, "the region where the drag began, wherever it goes")
        #expect(editor.parametric.lights == 0)
        #expect(changes.parametric.last?.isFinal == true)
        #expect(editor.parametric.splits == ParametricCurve.defaultSplits, "the splits are on the bar now")
        #expect(changes.values.isEmpty, "the point curve is untouched")

        changes.parametric.removeAll()
        click(0.9, 0.5)
        #expect(changes.parametric.isEmpty)

        // Far past the top clamps at +1.
        editor.mouseDown(with: event(.leftMouseDown, at: point(0.9, 0.5)))
        editor.mouseDragged(with: event(.leftMouseDragged, at: point(0.9, 3)))
        editor.mouseUp(with: event(.leftMouseUp, at: point(0.9, 3)))
        #expect(editor.parametric.highlights == 1)
    }

    @Test("Hovering in parametric mode highlights the region under the pointer")
    func hoverRegion() {
        editor.isParametric = true
        editor.mouseMoved(with: event(.mouseMoved, at: point(0.1, 0.5)))
        #expect(editor.highlightedRegion == 0)
        editor.mouseMoved(with: event(.mouseMoved, at: point(0.6, 0.5)))
        #expect(editor.highlightedRegion == 2)
        editor.mouseExited(with: event(.mouseMoved, at: point(0.6, 0.5)))
        #expect(editor.highlightedRegion == nil)
        editor.mouseMoved(with: event(.mouseMoved, at: point(0.6, 0.5)))
        editor.isParametric = false
        #expect(editor.highlightedRegion == nil, "only in parametric mode")
    }

    @Test("The split bar: drag a triangle to move its split, double-click it to put it back; a click alone changes nothing")
    func splitBar() {
        let bar = ParametricSplitBar(frame: NSRect(x: 0, y: 200, width: 212, height: 16))
        window.contentView?.addSubview(bar)
        var log: [(ParametricCurve, Bool)] = []
        bar.onChange = { log.append(($0, $1)) }
        func at(_ split: Double) -> NSPoint { bar.convert(NSPoint(x: 6 + split * 200, y: 4), to: nil) }

        bar.mouseDown(with: event(.leftMouseDown, at: at(0.25)))
        bar.mouseUp(with: event(.leftMouseUp, at: at(0.25)))
        #expect(log.isEmpty)

        bar.mouseDown(with: event(.leftMouseDown, at: at(0.25)))
        bar.mouseDragged(with: event(.leftMouseDragged, at: at(0.15)))
        bar.mouseUp(with: event(.leftMouseUp, at: at(0.15)))
        #expect(abs(bar.parametric.shadowSplit - 0.15) < 0.01 && log.last?.1 == true)

        bar.mouseDown(with: event(.leftMouseDown, at: at(0.15), clicks: 2))
        #expect(bar.parametric.shadowSplit == 0.25 && log.last?.1 == true)
    }

    @Test("Parametric regions: which one an input falls in, and amounts by region clamped to -1…1")
    func regions() {
        var curve = ParametricCurve()
        #expect([0.1, 0.3, 0.6, 0.9].map(curve.region(at:)) == [0, 1, 2, 3])
        curve[region: 2] = 1.7
        #expect(curve.lights == 1)
        curve[region: 0] = -0.4
        #expect(curve.shadows == -0.4 && curve[region: 0] == -0.4)
    }
}
