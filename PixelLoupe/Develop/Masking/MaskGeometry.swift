import CoreGraphics
import Foundation

/// Where a mask's handles are and what dragging each one does, in unit coordinates of the photo's
/// frame (origin bottom-left). The overlay draws and hit-tests with this; the tests exercise it.
nonisolated enum MaskGeometry {
    enum LinearHandle: Equatable, Sendable { case zero, full, move }
    enum RadialHandle: Equatable, Sendable { case center, right, left, top, bottom, rotate }

    /// Defaults for a mask added with a key press: a graduated filter fading in from the top, and
    /// an ellipse around the middle.
    static func defaultLinear() -> PhotoAdjustments.LinearGradient {
        .init(zero: .init(x: 0.5, y: 0.55), full: .init(x: 0.5, y: 0.9))
    }

    static func defaultRadial() -> PhotoAdjustments.RadialGradient {
        .init(center: .init(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.25, angle: 0, feather: 0.5)
    }

    // MARK: Linear

    /// The line through `zero` at right angles to the gradient, as two end points spanning the frame,
    /// for drawing the "zero" and "full" lines.
    static func lines(of gradient: PhotoAdjustments.LinearGradient, frame: CGSize) -> (zero: (CGPoint, CGPoint), full: (CGPoint, CGPoint)) {
        let zero = CGPoint(x: gradient.zero.x * frame.width, y: gradient.zero.y * frame.height)
        let full = CGPoint(x: gradient.full.x * frame.width, y: gradient.full.y * frame.height)
        let direction = CGPoint(x: full.x - zero.x, y: full.y - zero.y)
        let length = max(hypot(direction.x, direction.y), 0.0001)
        let across = CGPoint(x: -direction.y / length, y: direction.x / length)
        let reach = hypot(frame.width, frame.height)
        func line(through p: CGPoint) -> (CGPoint, CGPoint) {
            (CGPoint(x: p.x - across.x * reach, y: p.y - across.y * reach), CGPoint(x: p.x + across.x * reach, y: p.y + across.y * reach))
        }
        return (line(through: zero), line(through: full))
    }

    /// What a press at `point` (frame pixels) grabs: either line, or the middle of the gradient.
    static func linearHandle(at point: CGPoint, gradient: PhotoAdjustments.LinearGradient, frame: CGSize, tolerance: CGFloat) -> LinearHandle? {
        let zero = CGPoint(x: gradient.zero.x * frame.width, y: gradient.zero.y * frame.height)
        let full = CGPoint(x: gradient.full.x * frame.width, y: gradient.full.y * frame.height)
        let direction = CGPoint(x: full.x - zero.x, y: full.y - zero.y)
        let length = hypot(direction.x, direction.y)
        guard length > 0.0001 else { return nil }
        // How far along the gradient's direction the point is, from the zero line.
        let along = ((point.x - zero.x) * direction.x + (point.y - zero.y) * direction.y) / length
        if abs(along) <= tolerance { return .zero }
        if abs(along - length) <= tolerance { return .full }
        if along > 0 && along < length { return .move }
        return nil
    }

    /// The gradient after dragging `handle` from `start` by `delta` (frame pixels).
    static func dragLinear(
        _ handle: LinearHandle, gradient: PhotoAdjustments.LinearGradient, by delta: CGPoint, frame: CGSize
    ) -> PhotoAdjustments.LinearGradient {
        let dx = Double(delta.x / max(frame.width, 1)), dy = Double(delta.y / max(frame.height, 1))
        func moved(_ p: PhotoAdjustments.UnitPoint) -> PhotoAdjustments.UnitPoint { .init(x: p.x + dx, y: p.y + dy) }
        var result = gradient
        switch handle {
        case .zero: result.zero = moved(gradient.zero)
        case .full: result.full = moved(gradient.full)
        case .move:
            result.zero = moved(gradient.zero)
            result.full = moved(gradient.full)
        }
        return result
    }

    // MARK: Radial

    /// A handle's position in frame pixels.
    static func position(of handle: RadialHandle, in ellipse: PhotoAdjustments.RadialGradient, frame: CGSize) -> CGPoint {
        let center = CGPoint(x: ellipse.center.x * frame.width, y: ellipse.center.y * frame.height)
        let rx = ellipse.radiusX * frame.width, ry = ellipse.radiusY * frame.height
        let local: CGPoint = switch handle {
        case .center: .zero
        case .right: CGPoint(x: rx, y: 0)
        case .left: CGPoint(x: -rx, y: 0)
        case .top: CGPoint(x: 0, y: ry)
        case .bottom: CGPoint(x: 0, y: -ry)
        case .rotate: CGPoint(x: rx + 28, y: 0)
        }
        let angle = ellipse.angle * .pi / 180
        return CGPoint(x: center.x + local.x * cos(angle) - local.y * sin(angle), y: center.y + local.x * sin(angle) + local.y * cos(angle))
    }

    static func radialHandle(at point: CGPoint, ellipse: PhotoAdjustments.RadialGradient, frame: CGSize, tolerance: CGFloat) -> RadialHandle? {
        let handles: [RadialHandle] = [.rotate, .right, .left, .top, .bottom, .center]
        for handle in handles {
            let p = position(of: handle, in: ellipse, frame: frame)
            if hypot(p.x - point.x, p.y - point.y) <= tolerance { return handle }
        }
        // Anywhere inside the ellipse moves it.
        let center = position(of: .center, in: ellipse, frame: frame)
        let angle = -ellipse.angle * .pi / 180
        let dx = point.x - center.x, dy = point.y - center.y
        let x = dx * cos(angle) - dy * sin(angle), y = dx * sin(angle) + dy * cos(angle)
        let rx = max(ellipse.radiusX * frame.width, 1), ry = max(ellipse.radiusY * frame.height, 1)
        return (x / rx) * (x / rx) + (y / ry) * (y / ry) <= 1 ? .center : nil
    }

    /// The ellipse with `handle` dragged to `point` (frame pixels).
    static func dragRadial(_ handle: RadialHandle, ellipse: PhotoAdjustments.RadialGradient, to point: CGPoint, from start: CGPoint, frame: CGSize) -> PhotoAdjustments.RadialGradient {
        var result = ellipse
        let center = CGPoint(x: ellipse.center.x * frame.width, y: ellipse.center.y * frame.height)
        let angle = ellipse.angle * .pi / 180
        // The pointer in the ellipse's own axes.
        func local(_ p: CGPoint) -> CGPoint {
            let dx = p.x - center.x, dy = p.y - center.y
            return CGPoint(x: dx * cos(-angle) - dy * sin(-angle), y: dx * sin(-angle) + dy * cos(-angle))
        }
        switch handle {
        case .center:
            result.center = .init(x: ellipse.center.x + Double((point.x - start.x) / max(frame.width, 1)),
                                  y: ellipse.center.y + Double((point.y - start.y) / max(frame.height, 1)))
        case .right, .left:
            result.radiusX = max(0.01, Double(abs(local(point).x) / max(frame.width, 1)))
        case .top, .bottom:
            result.radiusY = max(0.01, Double(abs(local(point).y) / max(frame.height, 1)))
        case .rotate:
            let dx = point.x - center.x, dy = point.y - center.y
            result.angle = (atan2(dy, dx) * 180 / .pi).truncatingRemainder(dividingBy: 360)
        }
        return result
    }

    // MARK: Brush

    /// What the next brush stroke is painted with (the Brush sliders). A stroke keeps the settings it was
    /// painted with, so changing them doesn't touch what is already painted.
    struct BrushSettings: Equatable, Sendable {
        /// The radius as a fraction of the frame's long edge.
        var size = 0.04
        var feather = 0.5
        var flow = 1.0
        var density = 1.0

        static let sizeRange = 0.002...0.25

        /// [ and ] (Lightroom's brush size keys): a step smaller or larger.
        mutating func stepSize(_ steps: Int) {
            size = (size * pow(1.2, Double(steps))).clamped(to: Self.sizeRange)
        }

        /// ⇧[ and ⇧]: a tenth less or more feather.
        mutating func stepFeather(_ steps: Int) {
            feather = ((feather + 0.1 * Double(steps)) * 10).rounded() / 10
            feather = feather.clamped(to: 0...1)
        }

        /// A two-finger swipe (or the scroll wheel) of `amount` points upward: larger, or with ⇧ softer;
        /// downward is smaller or harder.
        mutating func scroll(by amount: Double, feather: Bool) {
            if feather {
                self.feather = (self.feather + amount * 0.004).clamped(to: 0...1)
            } else {
                size = (size * pow(1.01, amount)).clamped(to: Self.sizeRange)
            }
        }

        func stroke(at point: PhotoAdjustments.UnitPoint, erasing: Bool) -> PhotoAdjustments.BrushStroke {
            .init(points: [point], size: size, feather: feather, flow: flow, density: density, isErasing: erasing)
        }
    }

    /// A point on the frame (pixels) as a unit point, rounded to keep painted strokes small in the catalog.
    static func unitPoint(_ point: CGPoint, frame: CGSize) -> PhotoAdjustments.UnitPoint {
        func rounded(_ value: Double) -> Double { (value * 100_000).rounded() / 100_000 }
        return .init(x: rounded(Double(point.x / max(frame.width, 1))), y: rounded(Double(point.y / max(frame.height, 1))))
    }

    /// The brush's radius in frame pixels.
    static func brushRadius(_ size: Double, frame: CGSize) -> CGFloat {
        CGFloat(size) * max(frame.width, frame.height)
    }
}
