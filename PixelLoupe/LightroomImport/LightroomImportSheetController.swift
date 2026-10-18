import AppKit

/// What the user chose on the import sheet.
struct LightroomImportRequest {
    var packageURL: URL
    var info: CatalogInfo
    /// Also bring in each photo's develop history and snapshots (off by default: there can be tens of thousands).
    var importsHistory = false
}

/// The sheet shown after a Lightroom catalog is opened: what it holds, and the name and location of
/// the new PixelLoupe catalog. Photos are always referenced in place, never copied or moved.
final class LightroomImportSheetController: NSWindowController, NSTextFieldDelegate {
    private let sourceURL: URL
    private let completion: (LightroomImportRequest?) -> Void
    private weak var parentWindow: NSWindow?

    private let nameField = NSTextField()
    private let locationControl = NSPathControl()
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private let historyCheckbox = NSButton(checkboxWithTitle: "Import develop history and snapshots", target: nil, action: nil)
    private let photosValue = NSTextField(labelWithString: "Reading catalog…")
    private var valueFields: [String: NSTextField] = [:]
    private var locationURL: URL

    static let width: CGFloat = 520

    init(sourceURL: URL, completion: @escaping (LightroomImportRequest?) -> Void) {
        self.sourceURL = sourceURL
        self.completion = completion
        locationURL = sourceURL.deletingLastPathComponent()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Import Lightroom Catalog"
        super.init(window: window)
        nameField.stringValue = sourceURL.deletingPathExtension().lastPathComponent
        let content = makeContentView()
        window.contentView = content
        window.setContentSize(content.fittingSize)
        updateControls()
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
        window.makeFirstResponder(nameField)
    }

    // MARK: - Summary

    private static let rows: [(key: String, title: String)] = [
        ("photos", "Photos"), ("folders", "Folders"), ("keywords", "Keywords"), ("collections", "Collections"),
        ("copies", "Virtual copies"), ("stacks", "Stacks"), ("edits", "Photos with edits"),
        ("masks", "Photos with masks or healing"), ("unsupported", "Files PixelLoupe can’t open"),
    ]

    /// Fills in the counts once the catalog has been read.
    func show(_ summary: LightroomCatalogSummary) {
        func number(_ value: Int) -> String { value.formatted() }
        valueFields["version"]?.stringValue = summary.lightroomVersion
        var photos = number(summary.photos)
        if let missing = summary.missingFiles {
            photos += missing == 0 ? " (none missing on disk)" : " (\(number(missing)) missing on disk)"
        } else {
            photos += " (checking files…)"
        }
        valueFields["photos"]?.stringValue = photos
        valueFields["folders"]?.stringValue = number(summary.folders)
        valueFields["keywords"]?.stringValue = number(summary.keywords)
        valueFields["collections"]?.stringValue =
            "\(number(summary.collections)) collections, \(number(summary.smartCollections)) smart collections, \(number(summary.collectionSets)) sets"
        valueFields["copies"]?.stringValue = number(summary.virtualCopies)
        valueFields["stacks"]?.stringValue = number(summary.stacks)
        valueFields["edits"]?.stringValue = number(summary.photosWithEdits)
        valueFields["masks"]?.stringValue = number(summary.photosWithMasksOrHealing)
        if summary.unsupportedFiles.isEmpty {
            valueFields["unsupported"]?.stringValue = "None"
        } else {
            valueFields["unsupported"]?.stringValue = summary.unsupportedFiles.sorted { $0.key < $1.key }
                .map { "\(number($0.value)) \($0.key)" }.joined(separator: ", ")
        }
        isReady = true
        updateControls()
    }

    private var isReady = false

    // MARK: - Layout

    private func makeContentView() -> NSView {
        let heading = NSTextField(labelWithString: sourceURL.lastPathComponent)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.lineBreakMode = .byTruncatingMiddle
        let versionValue = NSTextField(labelWithString: "")
        versionValue.textColor = .secondaryLabelColor
        valueFields["version"] = versionValue

        var gridRows: [[NSView]] = []
        for row in Self.rows {
            let field = row.key == "photos" ? photosValue : NSTextField(labelWithString: "—")
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.setAccessibilityIdentifier("lightroomSummary.\(row.key)")
            valueFields[row.key] = field
            let label = NSTextField(labelWithString: row.title + ":")
            label.textColor = .secondaryLabelColor
            gridRows.append([label, field])
        }
        let summaryGrid = NSGridView(views: gridRows)
        summaryGrid.column(at: 0).xPlacement = .trailing
        summaryGrid.rowSpacing = 4
        summaryGrid.columnSpacing = 8

        nameField.delegate = self
        nameField.setAccessibilityIdentifier("lightroomCatalogNameField")
        nameField.setAccessibilityLabel("New catalog name")
        locationControl.pathStyle = .standard
        locationControl.isEditable = false
        locationControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        locationControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chooseButton = NSButton(title: "Choose…", target: self, action: #selector(chooseLocation(_:)))
        let locationRow = NSStackView(views: [locationControl, chooseButton])
        locationRow.spacing = 8
        locationRow.distribution = .fill

        let nameLabel = NSTextField(labelWithString: "Name:")
        let locationLabel = NSTextField(labelWithString: "Save in:")
        let form = NSGridView(views: [[nameLabel, nameField], [locationLabel, locationRow]])
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .fill
        form.rowSpacing = 10
        form.columnSpacing = 8

        let note = NSTextField(wrappingLabelWithString:
            "Photos stay where they are — PixelLoupe never copies or moves them. The Lightroom catalog is only read, never changed.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        importButton.target = self
        importButton.action = #selector(importCatalog(_:))
        importButton.keyEquivalent = "\r"
        importButton.setAccessibilityIdentifier("lightroomImportButton")
        let buttons = NSStackView(views: [cancel, importButton])
        buttons.spacing = 12

        let separator = NSBox()
        separator.boxType = .separator
        historyCheckbox.setAccessibilityIdentifier("lightroomImportHistory")
        historyCheckbox.toolTip = "Adds Lightroom’s edit history and snapshots to each photo’s History panel. A big catalog can have tens of thousands of steps."
        let stack = NSStackView(views: [heading, versionValue, summaryGrid, separator, form, historyCheckbox, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: versionValue)
        stack.setCustomSpacing(14, after: summaryGrid)
        stack.setCustomSpacing(14, after: separator)
        stack.setCustomSpacing(20, after: note)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.setAccessibilityIdentifier("lightroomImportSheet")
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            form.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        return content
    }

    // MARK: - Actions

    private var trimmedName: String {
        nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateControls() {
        locationControl.url = locationURL
        importButton.isEnabled = isReady && !trimmedName.isEmpty && !trimmedName.contains("/") && !trimmedName.hasPrefix(".")
    }

    func controlTextDidChange(_ obj: Notification) {
        updateControls()
    }

    @objc private func chooseLocation(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Choose where to save the new catalog"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = locationURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        locationURL = url
        updateControls()
    }

    @objc private func cancel(_ sender: Any?) {
        finish(with: nil)
    }

    @objc private func importCatalog(_ sender: Any?) {
        let name = trimmedName
        let packageURL = locationURL.appending(path: "\(name).\(CatalogPackage.fileExtension)", directoryHint: .isDirectory)
        finish(with: LightroomImportRequest(
            packageURL: packageURL, info: CatalogInfo(name: name, storageMode: .referenced, storagePath: nil),
            importsHistory: historyCheckbox.state == .on))
    }

    private func finish(with request: LightroomImportRequest?) {
        if let window, let parentWindow {
            parentWindow.endSheet(window)
        } else {
            window?.orderOut(nil)
        }
        completion(request)
    }
}
