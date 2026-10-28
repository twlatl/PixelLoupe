import AppKit

/// The Library's Assisted Culling panel (RAW-71): the Select and Reject criteria, Review (Selects, Rejects or
/// All), Apply and Auto Stack. The inspector does the work; this shows the criteria and reports what's changed.
final class CullingPanelView: NSView {
    /// What the panel says about the source's photos.
    struct Counts: Equatable {
        var selects = 0
        var rejects = 0
        /// Photos (not videos) the analyzer hasn't scored yet.
        var unanalyzed = 0
    }

    var onCriteriaChange: ((CullingCriteria) -> Void)?
    /// Selects, Rejects, or nil for All.
    var onReview: ((CullingReview.Kind?) -> Void)?
    var onAnalyze: (() -> Void)?
    var onReanalyze: (() -> Void)?
    var onApply: (() -> Void)?
    var onAutoStack: (() -> Void)?

    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let progressIndicator = NSProgressIndicator()
    let analyzeButton = NSButton(title: "Analyze", target: nil, action: nil)
    /// The section header's menu: Re-analyze.
    let actionButton = NSPopUpButton(frame: .zero, pullsDown: true)

    let subjectFocusBox = NSButton(checkboxWithTitle: "Subject Focus", target: nil, action: nil)
    let subjectFocusSlider = MonochromeSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    let eyeFocusBox = NSButton(checkboxWithTitle: "Eye Focus", target: nil, action: nil)
    let eyeFocusSlider = MonochromeSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    let eyeFocusNeedsEyesBox = NSButton(checkboxWithTitle: "Only photos with eyes detected", target: nil, action: nil)
    let eyesOpenBox = NSButton(checkboxWithTitle: "Eyes Open", target: nil, action: nil)
    let eyesOpenNeedsEyesBox = NSButton(checkboxWithTitle: "Only photos with eyes detected", target: nil, action: nil)
    let ambiguousEyesBox = NSButton(checkboxWithTitle: "Select ambiguous photos", target: nil, action: nil)
    let exposureBox = NSButton(checkboxWithTitle: "Exposure Issues", target: nil, action: nil)
    let misfiresBox = NSButton(checkboxWithTitle: "Misfires", target: nil, action: nil)
    let documentsBox = NSButton(checkboxWithTitle: "Documents", target: nil, action: nil)

    let reviewControl = NSSegmentedControl(labels: ["Selects", "Rejects", "All"], trackingMode: .selectOne, target: nil, action: nil)
    let applyButton = NSButton(title: "Apply Flags", target: nil, action: nil)
    let autoStackButton = NSButton(title: "Auto Stack…", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityIdentifier("cullingStatus")
        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.isHidden = true

        analyzeButton.controlSize = .small
        analyzeButton.target = self
        analyzeButton.action = #selector(analyze(_:))
        analyzeButton.toolTip = "Score the source's photos for focus, eyes and technical problems"
        analyzeButton.setAccessibilityIdentifier("cullingAnalyze")

        actionButton.isBordered = false
        actionButton.controlSize = .small
        (actionButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        let actionTitle = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        actionTitle.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Assisted Culling actions")
        actionButton.menu?.addItem(actionTitle)
        let reanalyze = NSMenuItem(title: "Re-analyze Photos", action: #selector(reanalyze(_:)), keyEquivalent: "")
        reanalyze.target = self
        actionButton.menu?.addItem(reanalyze)
        actionButton.setAccessibilityLabel("Assisted Culling actions")
        actionButton.setAccessibilityIdentifier("cullingActions")

        for box in [subjectFocusBox, eyeFocusBox, eyeFocusNeedsEyesBox, eyesOpenBox, eyesOpenNeedsEyesBox, ambiguousEyesBox,
                    exposureBox, misfiresBox, documentsBox] {
            box.controlSize = .small
            box.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            box.target = self
            box.action = #selector(criteriaChanged(_:))
        }
        for (slider, name) in [(subjectFocusSlider, "Subject focus"), (eyeFocusSlider, "Eye focus")] {
            slider.controlSize = .small
            // Moving it refilters the grid; once, when it's let go.
            slider.isContinuous = false
            slider.target = self
            slider.action = #selector(criteriaChanged(_:))
            slider.setAccessibilityLabel("\(name), soft to sharp")
        }
        subjectFocusBox.toolTip = "Reject photos whose main subject is softer than the slider"
        eyeFocusBox.toolTip = "Reject photos whose sharpest eyes are softer than the slider"
        eyesOpenBox.toolTip = "Reject photos where someone's eyes are closed"
        ambiguousEyesBox.toolTip = "Keep photos where it's hard to tell whether eyes are open, or where only some people's are"
        exposureBox.toolTip = "Reject photos that are far too dark or bright, or badly clipped"
        misfiresBox.toolTip = "Reject black frames, lens-cap shots and frames with nothing in focus"
        documentsBox.toolTip = "Reject photos of documents, receipts and screens full of text"

        reviewControl.controlSize = .small
        reviewControl.selectedSegment = 2
        reviewControl.target = self
        reviewControl.action = #selector(reviewChanged(_:))
        reviewControl.setAccessibilityLabel("Review")
        reviewControl.setAccessibilityIdentifier("cullingReview")
        reviewControl.segmentDistribution = .fillEqually

        applyButton.controlSize = .small
        applyButton.target = self
        applyButton.action = #selector(apply(_:))
        applyButton.toolTip = "Flag the Selects as Picks and the Rejects as Rejected, leaving photos already flagged alone"
        applyButton.setAccessibilityIdentifier("cullingApply")
        autoStackButton.controlSize = .small
        autoStackButton.target = self
        autoStackButton.action = #selector(autoStack(_:))
        autoStackButton.toolTip = "Stack photos taken one after another, by capture time or by how alike they look"
        autoStackButton.setAccessibilityIdentifier("cullingAutoStack")
        let buttons = NSStackView(views: [applyButton, autoStackButton])

        let statusRow = NSStackView(views: [statusLabel, analyzeButton])
        statusRow.alignment = .firstBaseline
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let arranged: [NSView] = [
            statusRow, progressIndicator,
            Self.heading("Select"),
            subjectFocusBox, Self.indented(Self.sliderRow(subjectFocusSlider)),
            eyeFocusBox, Self.indented(Self.sliderRow(eyeFocusSlider)), Self.indented(eyeFocusNeedsEyesBox),
            eyesOpenBox, Self.indented(eyesOpenNeedsEyesBox), Self.indented(ambiguousEyesBox),
            Self.heading("Reject"),
            exposureBox, misfiresBox, documentsBox,
            Self.heading("Review"),
            reviewControl, buttons,
        ]
        let stack = NSStackView(views: arranged)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for heading in arranged where heading.identifier?.rawValue == "heading" {
            stack.setCustomSpacing(4, after: heading)
            if let index = arranged.firstIndex(of: heading), index > 0 { stack.setCustomSpacing(12, after: arranged[index - 1]) }
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for view in [statusRow, progressIndicator, reviewControl] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for view in arranged where view.identifier?.rawValue == "indented" {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        show(nil, progress: nil, review: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func heading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.identifier = .init("heading")
        return label
    }

    /// "Soft ——o—— Sharp".
    private static func sliderRow(_ slider: NSSlider) -> NSView {
        let soft = NSTextField(labelWithString: "Soft"), sharp = NSTextField(labelWithString: "Sharp")
        for label in [soft, sharp] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return NSStackView(views: [soft, slider, sharp])
    }

    /// Below its criterion's checkbox, lined up with its title.
    private static func indented(_ view: NSView) -> NSView {
        let container = NSView()
        container.identifier = .init("indented")
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        if view is NSStackView { view.trailingAnchor.constraint(equalTo: container.trailingAnchor).isActive = true }
        return container
    }

    // MARK: Showing

    /// The criteria the controls show.
    var criteria: CullingCriteria {
        get {
            var criteria = CullingCriteria()
            criteria.subjectFocus = subjectFocusBox.state == .on
            criteria.subjectFocusMinimum = subjectFocusSlider.doubleValue
            criteria.eyeFocus = eyeFocusBox.state == .on
            criteria.eyeFocusMinimum = eyeFocusSlider.doubleValue
            criteria.eyeFocusNeedsEyes = eyeFocusNeedsEyesBox.state == .on
            criteria.eyesOpen = eyesOpenBox.state == .on
            criteria.eyesOpenNeedsEyes = eyesOpenNeedsEyesBox.state == .on
            criteria.selectsAmbiguousEyes = ambiguousEyesBox.state == .on
            criteria.exposureIssues = exposureBox.state == .on
            criteria.misfires = misfiresBox.state == .on
            criteria.documents = documentsBox.state == .on
            return criteria
        }
        set {
            subjectFocusBox.state = newValue.subjectFocus ? .on : .off
            subjectFocusSlider.doubleValue = newValue.subjectFocusMinimum
            eyeFocusBox.state = newValue.eyeFocus ? .on : .off
            eyeFocusSlider.doubleValue = newValue.eyeFocusMinimum
            eyeFocusNeedsEyesBox.state = newValue.eyeFocusNeedsEyes ? .on : .off
            eyesOpenBox.state = newValue.eyesOpen ? .on : .off
            eyesOpenNeedsEyesBox.state = newValue.eyesOpenNeedsEyes ? .on : .off
            ambiguousEyesBox.state = newValue.selectsAmbiguousEyes ? .on : .off
            exposureBox.state = newValue.exposureIssues ? .on : .off
            misfiresBox.state = newValue.misfires ? .on : .off
            documentsBox.state = newValue.documents ? .on : .off
            updateEnabledControls()
        }
    }

    /// A criterion's options only apply while it's checked.
    private func updateEnabledControls() {
        subjectFocusSlider.isEnabled = subjectFocusBox.state == .on
        eyeFocusSlider.isEnabled = eyeFocusBox.state == .on
        eyeFocusNeedsEyesBox.isEnabled = eyeFocusBox.state == .on
        eyesOpenNeedsEyesBox.isEnabled = eyesOpenBox.state == .on
        ambiguousEyesBox.isEnabled = eyesOpenBox.state == .on
    }

    /// Shows the source's counts (nil with no photos), the analysis's progress (nil when idle) and the Review.
    func show(_ counts: Counts?, progress: LibraryState.ImportStatus?, review: CullingReview.Kind?) {
        reviewControl.selectedSegment = review?.rawValue ?? 2
        let analyzed = (counts?.selects ?? 0) + (counts?.rejects ?? 0)
        if let progress {
            statusLabel.stringValue = "Analyzing \((progress.completed + 1).clamped(to: 1...max(1, progress.total)).formatted()) of \(progress.total.formatted())…"
            progressIndicator.maxValue = Double(max(1, progress.total))
            progressIndicator.doubleValue = Double(progress.completed)
        } else if let counts, analyzed + counts.unanalyzed > 0 {
            var parts = ["\(counts.selects.formatted()) Selects", "\(counts.rejects.formatted()) Rejects"]
            if counts.unanalyzed > 0 { parts.append("\(counts.unanalyzed.formatted()) not analyzed") }
            statusLabel.stringValue = parts.joined(separator: " · ")
        } else {
            statusLabel.stringValue = "No photos to analyze"
        }
        progressIndicator.isHidden = progress == nil
        analyzeButton.isHidden = progress != nil || (counts?.unanalyzed ?? 0) == 0
        actionButton.isEnabled = progress == nil && analyzed + (counts?.unanalyzed ?? 0) > 0
        applyButton.isEnabled = progress == nil && analyzed > 0
    }

    // MARK: Actions

    @objc private func criteriaChanged(_ sender: Any?) {
        updateEnabledControls()
        onCriteriaChange?(criteria)
    }

    @objc private func reviewChanged(_ sender: NSSegmentedControl) {
        onReview?(CullingReview.Kind(rawValue: sender.selectedSegment))
    }

    @objc private func analyze(_ sender: Any?) { onAnalyze?() }
    @objc private func reanalyze(_ sender: Any?) { onReanalyze?() }
    @objc private func apply(_ sender: Any?) { onApply?() }
    @objc private func autoStack(_ sender: Any?) { onAutoStack?() }
}
