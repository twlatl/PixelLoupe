import AppKit

/// The Lighting tool's panel (RAW-212): lighting effects stacked as sections in one scrolling column. Each section is
/// its own view controller with its own switch, status and changes; the Develop view controller talks to them directly.
final class LightingPanelViewController: NSViewController {
    let rimLight = RimLightPanelViewController()

    /// The sections, top to bottom.
    private var sections: [NSViewController] { [rimLight] }

    var isEditingEnabled = false {
        didSet { rimLight.isEditingEnabled = isEditingEnabled }
    }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for (index, section) in sections.enumerated() {
            addChild(section)
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            }
            stack.addArrangedSubview(section.view)
            section.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let document = FlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        let scrollView = NSScrollView()
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.setAccessibilityIdentifier("lightingPanel")
        document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true
        document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor).isActive = true
        view = scrollView
    }
}
