import AppKit

/// The report shown when a Lightroom import finishes, and again from Library ▸ Lightroom Import
/// Report. Each group of photos whose settings were only partly imported has a Show Photos button
/// that filters the grid to them.
final class LightroomImportReportWindowController: NSWindowController {
    /// Called with a group's key to show its photos (or `nil` for all photos with differences).
    var onShowPhotos: ((String?) -> Void)?

    private let report: LightroomImportReport

    init(report: LightroomImportReport) {
        self.report = report
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Lightroom Import Report"
        window.identifier = NSUserInterfaceItemIdentifier("lightroomImportReport")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 320)
        super.init(window: window)
        window.contentView = makeContentView()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        let document = NSStackView()
        document.orientation = .vertical
        document.alignment = .leading
        document.spacing = 6
        document.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        document.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "Imported “\(report.sourceName)”")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.lineBreakMode = .byTruncatingMiddle
        document.addArrangedSubview(heading)
        let subtitle = NSTextField(labelWithString:
            "\(report.lightroomVersion) · \(report.importedAt.formatted(date: .abbreviated, time: .shortened)) · took \(Self.format(report.duration))")
        subtitle.textColor = .secondaryLabelColor
        document.addArrangedSubview(subtitle)
        document.setCustomSpacing(16, after: subtitle)

        if !report.imported.isEmpty {
            document.addArrangedSubview(sectionTitle("Imported"))
            let grid = NSGridView(views: report.imported.map { line in
                let value = NSTextField(labelWithString: line.count.formatted())
                value.alignment = .right
                return [NSTextField(labelWithString: line.title), value]
            })
            grid.column(at: 1).xPlacement = .trailing
            grid.columnSpacing = 24
            grid.rowSpacing = 3
            document.addArrangedSubview(grid)
            document.setCustomSpacing(16, after: grid)
        }

        document.addArrangedSubview(sectionTitle("Not fully imported"))
        if report.groups.isEmpty {
            let none = NSTextField(wrappingLabelWithString: "Every Lightroom setting was carried over.")
            none.textColor = .secondaryLabelColor
            document.addArrangedSubview(none)
        } else {
            for group in report.groups {
                document.addArrangedSubview(groupRow(group))
            }
            let all = NSButton(title: "Show All Photos with Differences", target: self, action: #selector(showAll(_:)))
            all.setAccessibilityIdentifier("lightroomReportShowAll")
            document.addArrangedSubview(all)
            document.setCustomSpacing(12, after: document.arrangedSubviews[document.arrangedSubviews.count - 2])
        }

        if !report.warnings.isEmpty {
            document.addArrangedSubview(sectionTitle("Warnings"))
            for warning in report.warnings.prefix(50) {
                let label = NSTextField(wrappingLabelWithString: "• " + warning)
                label.textColor = .secondaryLabelColor
                document.addArrangedSubview(label)
            }
            if report.warnings.count > 50 {
                document.addArrangedSubview(NSTextField(labelWithString: "…and \(report.warnings.count - 50) more"))
            }
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let clip = FlippedView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(document)
        scroll.documentView = clip
        NSLayoutConstraint.activate([
            clip.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])

        let close = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        close.keyEquivalent = "\r"
        close.setAccessibilityIdentifier("lightroomReportDone")
        close.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(close)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -12),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        return content
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return label
    }

    private func groupRow(_ group: LightroomImportReport.Group) -> NSView {
        let title = NSTextField(labelWithString: "\(group.title) (\(group.photoCount.formatted()) \(group.photoCount == 1 ? "photo" : "photos"))")
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let button = NSButton(title: "Show Photos", target: self, action: #selector(showPhotos(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(group.key)
        button.controlSize = .small
        button.setAccessibilityLabel("Show photos: \(group.title)")
        let row = NSStackView(views: [title, button])
        row.distribution = .fill
        row.spacing = 12
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private static func format(_ duration: TimeInterval) -> String {
        Duration.seconds(duration.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }

    // MARK: - Actions

    @objc private func showPhotos(_ sender: NSButton) {
        onShowPhotos?(sender.identifier?.rawValue)
    }

    @objc private func showAll(_ sender: Any?) {
        onShowPhotos?(nil)
    }

    @objc private func done(_ sender: Any?) {
        window?.close()
    }
}
