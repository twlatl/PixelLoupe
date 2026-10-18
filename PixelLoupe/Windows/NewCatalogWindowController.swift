import AppKit

struct NewCatalogRequest {
    var packageURL: URL
    var info: CatalogInfo
}

/// Collects the name, location and storage mode for a new catalog.
final class NewCatalogWindowController: NSWindowController, NSTextFieldDelegate {
    private let completion: (NewCatalogRequest?) -> Void
    private weak var parentWindow: NSWindow?

    private let nameField = NSTextField(string: "My Photos")
    private let locationLabel = NSPathControl()
    private let managedRadio = NSButton(radioButtonWithTitle: "Copy imported photos into a folder", target: nil, action: nil)
    private let referencedRadio = NSButton(radioButtonWithTitle: "Reference photos in their current location", target: nil, action: nil)
    private let storageLabel = NSPathControl()
    private let storageButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let createButton = NSButton(title: "Create", target: nil, action: nil)

    private var locationURL: URL
    private var storageURL: URL

    init(completion: @escaping (NewCatalogRequest?) -> Void) {
        self.completion = completion
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        locationURL = pictures.appending(path: "PixelLoupe", directoryHint: .isDirectory)
        storageURL = pictures.appending(path: "PixelLoupe Photos", directoryHint: .isDirectory)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "New Catalog"
        super.init(window: window)
        let content = makeContentView()
        window.contentView = content
        // Size the sheet to its content so nothing is clipped.
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

    static let width: CGFloat = 560

    private func makeContentView() -> NSView {
        nameField.delegate = self
        nameField.setAccessibilityIdentifier("catalogNameField")
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for control in [locationLabel, storageLabel] {
            control.pathStyle = .standard
            control.isEditable = false
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let locationButton = NSButton(title: "Choose…", target: self, action: #selector(chooseLocation(_:)))
        storageButton.target = self
        storageButton.action = #selector(chooseStorage(_:))
        managedRadio.target = self
        managedRadio.action = #selector(modeChanged(_:))
        managedRadio.state = .on
        referencedRadio.target = self
        referencedRadio.action = #selector(modeChanged(_:))

        let storageRow = NSStackView(views: [storageLabel, storageButton])
        storageRow.spacing = 8
        storageRow.distribution = .fill
        let locationRow = NSStackView(views: [locationLabel, locationButton])
        locationRow.spacing = 8
        locationRow.distribution = .fill

        let labels = [label("Name:"), label("Save in:"), label("Photos:")]
        let grid = NSGridView(views: [
            [labels[0], nameField],
            [labels[1], locationRow],
            [labels[2], managedRadio],
            [NSGridCell.emptyContentView, storageRow],
            [NSGridCell.emptyContentView, referencedRadio],
        ])
        grid.column(at: 0).xPlacement = .trailing
        // NSGridView gives spare width to the first column; keep it to the longest label so the
        // controls column gets the rest.
        grid.column(at: 0).width = labels.map(\.fittingSize.width).max() ?? 0
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 10
        grid.row(at: 3).topPadding = -4
        grid.column(at: 1).xPlacement = .fill

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        createButton.target = self
        createButton.action = #selector(create(_:))
        createButton.keyEquivalent = "\r"
        createButton.setAccessibilityIdentifier("createCatalogButton")
        let buttons = NSStackView(views: [cancel, createButton])
        buttons.spacing = 12

        // Pin the form to the sheet's edges with fixed margins and a fixed width; long paths
        // truncate in the path controls instead of widening the form.
        let content = NSView()
        content.setAccessibilityIdentifier("newCatalogSheet")
        for view in [grid, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.width),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        return content
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        // Labels keep their natural width; the controls column takes the rest.
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private var storageMode: CatalogInfo.StorageMode {
        managedRadio.state == .on ? .managed : .referenced
    }

    private var trimmedName: String {
        nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateControls() {
        locationLabel.url = locationURL
        storageLabel.url = storageURL
        storageLabel.isEnabled = storageMode == .managed
        storageButton.isEnabled = storageMode == .managed
        createButton.isEnabled = !trimmedName.isEmpty && !trimmedName.contains("/")
    }

    func controlTextDidChange(_ obj: Notification) {
        updateControls()
    }

    @objc private func modeChanged(_ sender: NSButton) {
        updateControls()
    }

    @objc private func chooseLocation(_ sender: Any?) {
        if let url = chooseFolder(prompt: "Choose where to save the catalog", startingAt: locationURL) {
            locationURL = url
            updateControls()
        }
    }

    @objc private func chooseStorage(_ sender: Any?) {
        if let url = chooseFolder(prompt: "Choose where imported photos will be copied", startingAt: storageURL) {
            storageURL = url
            updateControls()
        }
    }

    private func chooseFolder(prompt: String, startingAt url: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.message = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = url.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    @objc private func cancel(_ sender: Any?) {
        finish(with: nil)
    }

    @objc private func create(_ sender: Any?) {
        let name = trimmedName
        let packageURL = locationURL.appending(path: "\(name).\(CatalogPackage.fileExtension)", directoryHint: .isDirectory)
        let info = CatalogInfo(
            name: name,
            storageMode: storageMode,
            storagePath: storageMode == .managed ? storageURL.path(percentEncoded: false) : nil
        )
        finish(with: NewCatalogRequest(packageURL: packageURL, info: info))
    }

    private func finish(with request: NewCatalogRequest?) {
        if let window, let parentWindow {
            parentWindow.endSheet(window)
        } else {
            window?.orderOut(nil)
        }
        completion(request)
    }
}
