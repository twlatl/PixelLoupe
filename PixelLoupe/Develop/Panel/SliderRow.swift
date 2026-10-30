import AppKit

/// Whether the event that triggered a control's action ends the gesture (mouse up or a key press),
/// as opposed to an intermediate drag. Only final changes are saved and recorded for undo.
@MainActor
func isFinalControlEvent(_ event: NSEvent? = NSApp.currentEvent) -> Bool {
    switch event?.type {
    // The second click of a double-click is a slider's knob being reset (`AdjustmentSlider`).
    case .leftMouseDown: (event?.clickCount ?? 0) >= 2
    case .leftMouseDragged: false
    default: true
    }
}

/// How a slider's knob position maps to its value.
enum SliderScale {
    /// Evenly along the track.
    case linear
    /// Logarithmically, so the low end gets room: white balance temperature, where 2000–8000 K
    /// matters most of a 2000–50000 K range (as in Lightroom).
    case logarithmic(ClosedRange<Double>)

    /// The slider's own range: the value range, or 0…1 for a logarithmic slider.
    func trackRange(for range: ClosedRange<Double>) -> ClosedRange<Double> {
        switch self {
        case .linear: range
        case .logarithmic: 0...1
        }
    }

    func position(for value: Double) -> Double {
        switch self {
        case .linear: return value
        case .logarithmic(let range):
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            return log(clamped / range.lowerBound) / log(range.upperBound / range.lowerBound)
        }
    }

    func value(at position: Double) -> Double {
        switch self {
        case .linear: return position
        case .logarithmic(let range): return range.lowerBound * pow(range.upperBound / range.lowerBound, position)
        }
    }
}

/// A labelled slider with its current value. Double-click the label or the knob to reset it.
final class SliderRow: NSView {
    let slider: AdjustmentSlider
    private let titleLabel: NSTextField
    private let valueLabel = NSTextField(labelWithString: "")
    private let format: (Double) -> String
    let scale: SliderScale
    var defaultValue: Double {
        get { scale.value(at: slider.defaultValue) }
        set {
            slider.defaultValue = scale.position(for: newValue)
            showValue()
        }
    }

    var onChange: ((Double, Bool) -> Void)?

    var value: Double {
        get { scale.value(at: slider.doubleValue) }
        set {
            slider.doubleValue = scale.position(for: newValue)
            showValue()
        }
    }

    /// The value as the label shows it.
    var displayedValue: String { valueLabel.stringValue }

    /// Whether the value differs from the default, as the label shows it. As in Lightroom, a changed
    /// value is drawn bright and a default one dimmed.
    var isModified: Bool { format(value) != format(defaultValue) }

    /// `trackColors`: a gradient drawn as the track, low end first (white balance's Temp and Tint).
    init(
        title: String,
        range: ClosedRange<Double>,
        defaultValue: Double = 0,
        format: @escaping (Double) -> String = SliderRow.signed,
        scale: SliderScale = .linear,
        trackColors: [NSColor]? = nil
    ) {
        titleLabel = NSTextField(labelWithString: title)
        self.format = format
        self.scale = scale
        slider = trackColors.map { GradientSlider(colors: $0) } ?? AdjustmentSlider()
        super.init(frame: .zero)
        self.defaultValue = defaultValue

        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        titleLabel.textColor = .secondaryLabelColor
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right

        let track = scale.trackRange(for: range)
        slider.minValue = track.lowerBound
        slider.maxValue = track.upperBound
        slider.doubleValue = scale.position(for: defaultValue)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.onReset = { [weak self] in self?.resetToDefault(nil) }
        slider.setAccessibilityLabel(title)

        let reset = NSClickGestureRecognizer(target: self, action: #selector(resetToDefault(_:)))
        reset.numberOfClicksRequired = 2
        titleLabel.addGestureRecognizer(reset)
        titleLabel.toolTip = "Double-click to reset"

        for view in [titleLabel, valueLabel, slider] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            valueLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        value = defaultValue
        // Rows are also built while the window is showing (mask and spot panels), after its controls were tinted.
        Accent.apply(in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func showValue() {
        valueLabel.stringValue = format(value)
        valueLabel.textColor = isModified ? .labelColor : .secondaryLabelColor
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        showValue()
        onChange?(value, isFinalControlEvent())
    }

    @objc private func resetToDefault(_ sender: Any?) {
        value = defaultValue
        onChange?(defaultValue, true)
    }

    nonisolated static func signed(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == 0 ? "0.00" : String(format: "%+.2f", rounded)
    }

    nonisolated static func unsigned(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
