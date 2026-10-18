import AppKit

/// Toolbar under the grid: the view buttons, import progress, sort order and thumbnail size. (The
/// photo count is in the filmstrip's info line.)
final class BottomBarViewController: NSViewController {
    private let state: LibraryState

    private lazy var viewModes = ViewModeControl(state: state)
    private let progressIndicator = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private let cancelExportButton = NSButton()
    private let sortPopUp = NSPopUpButton()
    private let directionButton = NSButton()
    private let sizeSlider = NSSlider()

    init(state: LibraryState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.controlSize = .small
        progressIndicator.widthAnchor.constraint(equalToConstant: 140).isActive = true
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

        cancelExportButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel Export")
        cancelExportButton.isBordered = false
        cancelExportButton.imagePosition = .imageOnly
        cancelExportButton.contentTintColor = .secondaryLabelColor
        cancelExportButton.action = #selector(PixelLoupeActions.cancelExport(_:))
        cancelExportButton.toolTip = "Cancel Export"
        cancelExportButton.setAccessibilityIdentifier("cancelExportButton")

        let sortLabel = NSTextField(labelWithString: "Sort:")
        sortLabel.textColor = .secondaryLabelColor
        sortPopUp.controlSize = .small
        sortPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for key in PhotoSortKey.allCases {
            sortPopUp.addItem(withTitle: key.title)
            sortPopUp.lastItem?.representedObject = key.rawValue
        }
        sortPopUp.target = self
        sortPopUp.action = #selector(sortChanged(_:))
        sortPopUp.setAccessibilityIdentifier("sortPopUp")

        directionButton.bezelStyle = .toolbar
        directionButton.isBordered = false
        directionButton.imagePosition = .imageOnly
        directionButton.target = self
        directionButton.action = #selector(toggleDirection(_:))
        directionButton.setAccessibilityIdentifier("sortDirectionButton")

        sizeSlider.minValue = LibraryState.thumbnailSizeRange.lowerBound
        sizeSlider.maxValue = LibraryState.thumbnailSizeRange.upperBound
        sizeSlider.controlSize = .small
        sizeSlider.isContinuous = true
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged(_:))
        sizeSlider.toolTip = "Thumbnail size"
        sizeSlider.setAccessibilityIdentifier("thumbnailSizeSlider")
        sizeSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let small = symbol("photo", size: 9)
        let large = symbol("photo", size: 15)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [
            viewModes, progressIndicator, progressLabel, cancelExportButton, spacer,
            sortLabel, sortPopUp, directionButton, small, sizeSlider, large,
        ])
        stack.spacing = 8
        stack.setCustomSpacing(16, after: viewModes)
        stack.setCustomSpacing(2, after: sortPopUp)
        stack.setCustomSpacing(16, after: directionButton)
        stack.setCustomSpacing(4, after: small)
        stack.setCustomSpacing(4, after: sizeSlider)
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        view = stack
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        update()
        state.addObserver(self) { [weak self] _ in self?.update() }
    }

    private func symbol(_ name: String, size: CGFloat) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        let view = NSImageView(image: image ?? NSImage())
        view.contentTintColor = .secondaryLabelColor
        return view
    }

    private func update() {
        let filter = state.filter

        let exporting = state.exportStatus
        let merging = state.mergeStatus
        let editingIn = state.editInStatus
        if let status = exporting ?? merging ?? editingIn ?? state.importStatus {
            progressIndicator.isHidden = false
            progressLabel.isHidden = false
            progressIndicator.maxValue = Double(max(status.total, 1))
            progressIndicator.doubleValue = Double(status.completed)
            progressLabel.stringValue = if exporting != nil {
                "Exporting \(status.completed.formatted()) of \(status.total.formatted())"
            } else if merging != nil {
                "Merging HDR"
            } else if editingIn != nil {
                "Preparing \(status.total.formatted()) photo\(status.total == 1 ? "" : "s") for \(state.editInApplicationName)"
            } else {
                "Importing \(status.completed.formatted()) of \(status.total.formatted())"
            }
        } else {
            progressIndicator.isHidden = true
            progressLabel.isHidden = true
        }
        cancelExportButton.isHidden = exporting == nil && merging == nil
        let cancelTitle = exporting == nil ? "Cancel HDR Merge" : "Cancel Export"
        cancelExportButton.action = exporting == nil
            ? #selector(PixelLoupeActions.cancelPhotoMerge(_:)) : #selector(PixelLoupeActions.cancelExport(_:))
        cancelExportButton.toolTip = cancelTitle
        cancelExportButton.image?.accessibilityDescription = cancelTitle

        sortPopUp.selectItem(at: PhotoSortKey.allCases.firstIndex(of: filter.sortKey) ?? 0)
        directionButton.image = NSImage(
            systemSymbolName: filter.ascending ? "arrow.up" : "arrow.down",
            accessibilityDescription: filter.ascending ? "Ascending" : "Descending"
        )
        directionButton.toolTip = filter.ascending ? "Ascending — click for descending" : "Descending — click for ascending"
        if sizeSlider.doubleValue != state.thumbnailSize {
            sizeSlider.doubleValue = state.thumbnailSize
        }
    }

    @objc private func sortChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let key = PhotoSortKey(rawValue: raw) else { return }
        state.filter.sortKey = key
    }

    @objc private func toggleDirection(_ sender: Any?) {
        state.filter.ascending.toggle()
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        state.thumbnailSize = sender.doubleValue
    }
}
