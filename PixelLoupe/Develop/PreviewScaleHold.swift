import Foundation

/// The scale the Develop preview renders at while its canvas changes size (RAW-254).
///
/// The side panels sliding in or out (Tab, the panel buttons) or a window resize changes the canvas on
/// every frame, and the scale it asks for with it: re-decoding the photo at each one can't keep up, so
/// the last frame was left on screen, stretched. While resizing, the preview keeps the scale it was last
/// rendered at and is only re-fitted (cheap), then renders at the new scale once the size settles.
struct PreviewScaleHold {
    /// Whether the canvas is changing size.
    var isResizing = false
    /// The photo and scale last rendered while settled.
    private var held: (source: ObjectIdentifier, scale: CGFloat)?

    /// The scale to render `source` at, given the scale the canvas asks for. A different photo (opened
    /// mid-resize) always gets the scale it asks for.
    mutating func scale(for wanted: CGFloat, source: ObjectIdentifier) -> CGFloat {
        if isResizing, let held, held.source == source { return held.scale }
        held = (source, wanted)
        return wanted
    }
}
