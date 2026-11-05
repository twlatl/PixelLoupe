import AppKit

/// The checkboxes in Choose Overlays to Cycle…: which guides O visits, and which ratios the Aspect
/// Ratios guide shows. Changes are saved as they're made; the last guide left in the cycle can't be
/// unticked.
final class CropGuideOptionsView: NSStackView {
    /// Called after either set changes.
    var onChange: () -> Void = {}

    private(set) var overlayBoxes: [CropGuideOverlay: NSButton] = [:]
    private(set) var aspectBoxes: [CropGuideOverlay.AspectRatio: NSButton] = [:]

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .top
        spacing = 32

        let cycle = CropGuideOverlay.cycle
        let overlays = column("Overlays to Cycle", CropGuideOverlay.allCases.map { overlay in
            let box = NSButton(checkboxWithTitle: overlay.title, target: self, action: #selector(overlayToggled(_:)))
            box.state = cycle.contains(overlay) ? .on : .off
            box.setAccessibilityIdentifier("cropGuideCycle.\(overlay.rawValue)")
            overlayBoxes[overlay] = box
            return box
        })
        let shown = CropGuideOverlay.shownAspectRatios
        let aspects = column("Aspect Ratios", CropGuideOverlay.AspectRatio.allCases.map { aspect in
            let box = NSButton(checkboxWithTitle: aspect.title, target: self, action: #selector(aspectToggled(_:)))
            box.state = shown.contains(aspect) ? .on : .off
            box.setAccessibilityIdentifier("cropGuideAspect.\(aspect.rawValue)")
            aspectBoxes[aspect] = box
            return box
        })
        addArrangedSubview(overlays)
        addArrangedSubview(aspects)
        updateLastOverlay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func column(_ title: String, _ boxes: [NSButton]) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let stack = NSStackView(views: [heading] + boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    @objc private func overlayToggled(_ sender: NSButton) {
        CropGuideOverlay.cycle = Set(overlayBoxes.filter { $0.value.state == .on }.keys)
        updateLastOverlay()
        onChange()
    }

    @objc private func aspectToggled(_ sender: NSButton) {
        CropGuideOverlay.shownAspectRatios = Set(aspectBoxes.filter { $0.value.state == .on }.keys)
        onChange()
    }

    /// The cycle can't be empty, so the only ticked guide is disabled.
    private func updateLastOverlay() {
        let ticked = overlayBoxes.values.filter { $0.state == .on }
        for box in overlayBoxes.values { box.isEnabled = !(ticked.count == 1 && box.state == .on) }
    }
}
