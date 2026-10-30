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

/// A labelled slider with its current value. Double-click the label or the knob to reset it, and
/// the value to type a new one (as in Lightroom).
final class SliderRow: NSView, NSTextFieldDelegate {
    let slider: AdjustmentSlider
    private let titleLabel: NSTextField
    private let valueLabel = NSTextField(labelWithString: "")
    private let format: (Double) -> String
    private let range: ClosedRange<Double>
    let scale: SliderScale
    /// Whether the value is being typed; Escape ends the edit without changing the value.
    private(set) var isEditingValue = false
    private var cancelsEdit = false
    /// Keeps the field as wide as the row's longest value while it's edited; an editable field has no width of its
    /// own and would otherwise stretch across the row.
    private lazy var editingWidth = valueLabel.widthAnchor.constraint(equalToConstant: 0)
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
        self.range = range
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

        let edit = NSClickGestureRecognizer(target: self, action: #selector(beginEditingValue))
        edit.numberOfClicksRequired = 2
        valueLabel.addGestureRecognizer(edit)
        valueLabel.toolTip = "Double-click to enter a value"
        valueLabel.delegate = self
        valueLabel.setAccessibilityLabel("\(title) value")

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

    /// Makes the value label a text field with its text selected, for typing a new value.
    @objc func beginEditingValue() {
        guard !isEditingValue, let window else { return }
        isEditingValue = true
        cancelsEdit = false
        valueLabel.isEditable = true
        valueLabel.isSelectable = true
        valueLabel.isBezeled = true
        valueLabel.bezelStyle = .squareBezel
        valueLabel.drawsBackground = true
        valueLabel.backgroundColor = .textBackgroundColor
        valueLabel.textColor = .labelColor
        editingWidth.constant = editingFieldWidth
        editingWidth.isActive = true
        window.makeFirstResponder(valueLabel)
        valueLabel.currentEditor()?.selectAll(nil)
    }

    /// Wide enough for the longest text the row shows (its range's ends, "−180°", "50,000") plus the bezel's margins.
    var editingFieldWidth: CGFloat {
        let font = valueLabel.font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)
        let texts = [range.lowerBound, range.upperBound, value].map(format)
        let widest = texts.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return ceil(widest) + 12
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(cancelOperation(_:)) else { return false }
        cancelsEdit = true
        window?.makeFirstResponder(slider)
        return true
    }

    /// Return, Tab or clicking elsewhere enters the typed value; Escape or text that isn't a number keeps the old one.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard isEditingValue else { return }
        isEditingValue = false
        let typed = valueLabel.stringValue
        valueLabel.isEditable = false
        valueLabel.isSelectable = false
        valueLabel.isBezeled = false
        valueLabel.drawsBackground = false
        editingWidth.isActive = false
        if !cancelsEdit, let entered = value(forDisplayed: typed) {
            value = entered
            onChange?(value, true)
        } else {
            showValue()
        }
    }

    /// The value a typed number stands for, in the units the label shows (so "50" on a ×100 percent row is 0.5),
    /// clamped to the slider's range. The label's units are taken from how `format` shows the range's ends,
    /// which works because every row's format is the value scaled and rounded.
    func value(forDisplayed text: String) -> Double? {
        guard let typed = Self.number(in: text),
              let low = Self.number(in: format(range.lowerBound)),
              let high = Self.number(in: format(range.upperBound)),
              high != low
        else { return nil }
        let entered = range.lowerBound + (typed - low) / (high - low) * (range.upperBound - range.lowerBound)
        return min(max(entered, range.lowerBound), range.upperBound)
    }

    /// The number in a label's text, ignoring units, thousands separators and a typographic minus ("−22", "5,500", "50%").
    nonisolated static func number(in text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: "\u{2212}", with: "-")
        let kept = normalized.filter { $0.isASCII && ($0.isNumber || "+-.".contains($0)) }
        return Double(kept.hasPrefix("+") ? String(kept.dropFirst()) : kept)
    }

    nonisolated static func signed(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == 0 ? "0.00" : String(format: "%+.2f", rounded)
    }

    nonisolated static func unsigned(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
