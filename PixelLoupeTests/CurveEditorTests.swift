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

    @Test("In parametric mode, dragging a divider moves the split")
    func dragSplit() {
        editor.isParametric = true
        editor.parametric = ParametricCurve()
        editor.mouseDown(with: event(.leftMouseDown, at: point(0.25, 0.5)))
        editor.mouseDragged(with: event(.leftMouseDragged, at: point(0.15, 0.5)))
        editor.mouseUp(with: event(.leftMouseUp, at: point(0.15, 0.5)))
        #expect(abs(editor.parametric.shadowSplit - 0.15) < 0.02)
        #expect(changes.parametric.last?.isFinal == true)
        #expect(changes.values.isEmpty, "the point curve is untouched")
    }
}
