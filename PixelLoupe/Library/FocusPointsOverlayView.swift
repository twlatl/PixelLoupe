import AppKit
import QuartzCore

/// The camera's focus points in red over the Develop preview (Show Focus Points, RAW-308). It takes no clicks.
final class FocusPointsOverlayView: NSView {
    /// The focus points of the photo on show, as read from its file, and its camera orientation (EXIF 1–8).
    var focusPoints: (points: FocusPoints, fileOrientation: Int)? { didSet { update() } }
    /// Rotate/Flip of the photo on show.
    var orientation = PhotoAdjustments.Orientation() { didSet { if orientation != oldValue { update() } } }
    /// The photo on show was read and its file names no focus point: shows ``FocusPointsNoteView``.
    var noPointRecorded = false { didSet { note.isHidden = !noPointRecorded } }
    /// Where the photo's whole frame sits in the view.
    var previewFrame = PreviewFrame.zero { didSet { if previewFrame != oldValue { update() } } }

    private let shapeLayer = CAShapeLayer()
    private let note = FocusPointsNoteView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        shapeLayer.fillColor = nil
        shapeLayer.strokeColor = NSColor.systemRed.cgColor
        shapeLayer.lineWidth = 2
        shapeLayer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(shapeLayer)
        note.pin(in: self)
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

/// "No focus point recorded", at the top of the photo while Show Focus Points is on and the photo's file names no
/// focus point (many Nikon DSLR frames leave it empty, for one), so an empty photo doesn't look like a failure.
final class FocusPointsNoteView: NSVisualEffectView {
    static let text = "No focus point recorded"

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 6
        isHidden = true
        let label = NSTextField(labelWithString: Self.text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
        setAccessibilityIdentifier("focusPointsNote")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Adds the note to `view`, centered 16 points below its top.
    func pin(in view: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(self)
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
        ])
    }

    /// Whether the note belongs on a photo whose read came back with `points`: none read, but the file is there.
    static func applies(to points: FocusPoints?, url: URL) -> Bool {
        points == nil && FileManager.default.fileExists(atPath: url.path)
    }
}
