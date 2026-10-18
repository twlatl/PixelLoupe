import AppKit
import CoreData

/// Full-width filter bar: rating filter, tag filter and camera/lens search.
final class FilterBarViewController: NSViewController, NSMenuDelegate, NSSearchFieldDelegate {
    private let store: CatalogStore
    private let state: LibraryState

    private let tagsPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let searchField = ClickToFocusSearchField()

    init(store: CatalogStore, state: LibraryState) {
        self.store = store
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let ratingLabel = NSTextField(labelWithString: "Rating")
        ratingLabel.textColor = .secondaryLabelColor

        let rating = RatingFilterControl(state: state)

        let labelLabel = NSTextField(labelWithString: "Label")
        labelLabel.textColor = .secondaryLabelColor
        let labels = ColorLabelFilterControl(state: state)

        let tagsLabel = NSTextField(labelWithString: "Tags")
        tagsLabel.textColor = .secondaryLabelColor
        tagsPopUp.controlSize = .small
        tagsPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tagsPopUp.menu?.delegate = self
        tagsPopUp.setAccessibilityIdentifier("tagFilter")
        tagsPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        searchField.placeholderString = "Search camera or lens"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.setAccessibilityIdentifier("metadataSearch")
        searchField.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [
            ratingLabel, rating, divider(), labelLabel, labels, divider(), tagsLabel, tagsPopUp, spacer, searchField,
        ])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view = stack
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        update()
        state.addObserver(self) { [weak self] change in
            if change == .filter { self?.update() }
        }
    }

    func focusSearch() {
        searchField.allowsFocusOnce = true
        defer { searchField.allowsFocusOnce = false }
        view.window?.makeFirstResponder(searchField)
    }

    private func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return box
    }

    private func update() {
        let filter = state.filter
        updateTagsTitle()
        if searchField.stringValue != filter.searchText {
            searchField.stringValue = filter.searchText
        }
    }

    private func updateTagsTitle() {
        let tags = state.filter.tags
        let title = switch tags.count {
        case 0: "Any"
        case 1: tags.first!.components(separatedBy: Tag.pathSeparator).last ?? tags.first!
        default: "\(tags.count) tags"
        }
        tagsPopUp.removeAllItems()
        tagsPopUp.addItem(withTitle: title)
    }

    // MARK: - Actions

    @objc private func searchChanged(_ sender: NSSearchField) {
        state.filter.searchText = sender.stringValue.trimmingCharacters(in: .whitespaces)
    }

    @objc private func toggleTag(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if state.filter.tags.contains(name) {
            state.filter.tags.remove(name)
        } else {
            state.filter.tags.insert(name)
        }
    }

    @objc private func clearTags(_ sender: Any?) {
        state.filter.tags = []
    }

    // MARK: - NSMenuDelegate

    /// Rebuilds the tag list each time the menu opens so it reflects newly imported keywords.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let title = menu.items.first?.title ?? "Any"
        menu.removeAllItems()
        // Pull-down menus use the first item as the button title.
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")

        // Keywords that have photos, and their parents (a parent matches everything below it).
        let request = Tag.fetchRequest()
        request.predicate = NSPredicate(format: "photos.@count > 0")
        var included = Set<Tag>()
        for tag in (try? store.viewContext.fetch(request)) ?? [] {
            var current: Tag? = tag
            while let tag = current, included.insert(tag).inserted { current = tag.parent }
        }
        let tags = included.sorted { $0.pathKey.localizedStandardCompare($1.pathKey) == .orderedAscending }

        if tags.isEmpty {
            let empty = NSMenuItem(title: "No Tags", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        let clear = NSMenuItem(title: "Any Tag", action: #selector(clearTags(_:)), keyEquivalent: "")
        clear.target = self
        clear.state = state.filter.tags.isEmpty ? .on : .off
        menu.addItem(clear)
        menu.addItem(.separator())
        for tag in tags {
            let item = NSMenuItem(title: tag.name, action: #selector(toggleTag(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tag.pathKey
            item.indentationLevel = tag.pathComponents.count - 1
            item.toolTip = tag.displayPath
            item.state = state.filter.tags.contains(tag.pathKey) ? .on : .off
            menu.addItem(item)
        }
    }
}
