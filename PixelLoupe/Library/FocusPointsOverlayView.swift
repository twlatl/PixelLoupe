import AppKit
import QuartzCore

/// The camera's focus points in red over the Develop preview (Show Focus Points, RAW-308). It takes no clicks.
final class FocusPointsOverlayView: NSView {
    /// The focus points of the photo on show, as read from its file, and its camera orientation (EXIF 1–8).
    var focusPoints: (points: FocusPoints, fileOrientation: Int)? { didSet { update() } }
    /// Rotate/Flip of the photo on show.
    var orientation = PhotoAdjustments.Orientation() { didSet { if orientation != oldValue { update() } } }
    /// Where the photo's whole frame sits in the view.
    var previewFrame = PreviewFrame.zero { didSet { if previewFrame != oldValue { update() } } }

    private let shapeLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        shapeLayer.fillColor = nil
        shapeLayer.strokeColor = NSColor.systemRed.cgColor
        shapeLayer.lineWidth = 2
        shapeLayer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(shapeLayer)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { shapeLayer.strokeColor = NSColor.systemRed.cgColor }
    }

    private func update() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let focusPoints else {
            shapeLayer.path = nil
            return
        }
        let areas = focusPoints.points.frameAreas(fileOrientation: focusPoints.fileOrientation, orientation: orientation)
        shapeLayer.path = FocusPoints.markerPath(frameAreas: areas, in: previewFrame)
    }
}
