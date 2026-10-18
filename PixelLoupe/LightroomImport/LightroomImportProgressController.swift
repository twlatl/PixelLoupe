import AppKit

/// The progress window of a Lightroom import, with a Cancel button.
final class LightroomImportProgressController: NSWindowController {
    var onCancel: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Importing Lightroom catalog…")
    private let detailLabel = NSTextField(labelWithString: " ")
    private let bar = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private weak var parentWindow: NSWindow?

    init(catalogName: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 130), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Importing “\(catalogName)”"
        super.init(window: window)
        window.contentView = makeContentView()
        window.setContentSize(window.contentView!.fittingSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(over parent: NSWindow?) {
        guard let window else { return }
        if let parent {
            parentWindow = parent
            parent.beginSheet(window)
        } else {
            window.center()
            showWindow(nil)
        }
    }

    func dismiss() {
        guard let window else { return }
        if let parentWindow, window.sheetParent != nil {
            parentWindow.endSheet(window)
        } else {
            window.orderOut(nil)
        }
    }

    func update(_ progress: LightroomImportProgress) {
        bar.isIndeterminate = false
        bar.doubleValue = progress.fraction
        guard progress.phaseIndex < progress.phaseCount else { return }
        titleLabel.stringValue = progress.phaseTitle
        let phase = "Step \(progress.phaseIndex + 1) of \(progress.phaseCount)"
        detailLabel.stringValue = progress.total > 0
            ? "\(phase) · \(progress.completed.formatted()) of \(progress.total.formatted())" : phase
    }

    private func makeContentView() -> NSView {
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        detailLabel.textColor = .secondaryLabelColor
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        bar.setAccessibilityLabel("Import progress")
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityIdentifier("lightroomImportCancelButton")

        let stack = NSStackView(views: [titleLabel, bar, detailLabel, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 420),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        return content
    }

    @objc private func cancel(_ sender: Any?) {
        cancelButton.isEnabled = false
        titleLabel.stringValue = "Cancelling…"
        detailLabel.stringValue = "The partly imported catalog will be deleted."
        onCancel?()
    }
}
