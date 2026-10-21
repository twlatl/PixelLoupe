import AppKit
import MapKit

/// The Library's Location panel (RAW-166): a small map of the selected photos' location, and a field
/// that finds a place (or takes "lat, lon") to give them. Locations are saved in the catalog only.
final class LocationPanelView: NSView, MKMapViewDelegate, MKLocalSearchCompleterDelegate, NSSearchFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate
{
    /// Gives the photos `location`: only those without one, or all of them (`replace`).
    var onApply: ((GPSCoordinate, _ replace: Bool) -> Void)?
    /// Removes the photos' location.
    var onRemove: (() -> Void)?

    let mapView = MKMapView()
    /// Takes focus only when clicked (like the sidebar's other fields), so AppKit never hands it focus
    /// on its own when the view changes.
    let searchField = ClickToFocusSearchField()
    /// The photos' location, or the place found.
    let locationLabel = NSTextField(labelWithString: "")
    /// Why a search found nothing, or that it needs the internet.
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    let results = NSTableView()
    private let resultsScroll = NSScrollView()
    private let completer = MKLocalSearchCompleter()
    private(set) var completions: [MKLocalSearchCompletion] = []
    private let pin = MKPointAnnotation()
    private var search: MKLocalSearch?
    /// The place found or dragged to, not yet given to the photos.
    private(set) var pending: GPSCoordinate? {
        didSet {
            updateButtons()
            (mapView.view(for: pin) as? PinView)?.tint = pinTint
        }
    }

    /// The Map module's pin: red for the photos' location, the accent colour for a place found but
    /// not given to them yet.
    var pinTint: NSColor { pending == nil ? .systemRed : .controlAccentColor }
    private var hasPhotos = false
    private var hasLocation = false
    /// Watches for clicks while the field is being typed in (see `endEditingIfClickedOutside`).
    private var clickMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)

        mapView.delegate = self
        mapView.showsZoomControls = false
        mapView.setAccessibilityLabel("Location map")
        mapView.heightAnchor.constraint(equalToConstant: 170).isActive = true
        mapView.wantsLayer = true
        mapView.layer?.cornerRadius = 6

        locationLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        locationLabel.textColor = .secondaryLabelColor
        locationLabel.lineBreakMode = .byTruncatingTail
        locationLabel.setAccessibilityIdentifier("locationValue")

        searchField.placeholderString = "Find an address or place, or “lat, lon”"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction(_:))
        searchField.sendsWholeSearchString = true
        searchField.setAccessibilityLabel("Find a location")
        searchField.setAccessibilityIdentifier("locationSearch")

        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]

        results.addTableColumn(NSTableColumn(identifier: .init("place")))
        results.headerView = nil
        results.dataSource = self
        results.delegate = self
        results.rowHeight = 34
        results.style = .plain
        results.target = self
        results.action = #selector(resultClicked(_:))
        results.setAccessibilityLabel("Places found")
        resultsScroll.documentView = results
        resultsScroll.hasVerticalScroller = true
        resultsScroll.autohidesScrollers = true
        resultsScroll.isHidden = true
        resultsScroll.heightAnchor.constraint(equalToConstant: 34 * 4 + 4).isActive = true

        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.isHidden = true

        for (button, action) in [(applyButton, #selector(apply(_:))), (replaceButton, #selector(replace(_:))), (removeButton, #selector(remove(_:)))] {
            button.controlSize = .small
            button.bezelStyle = .push
            button.target = self
            button.action = action
        }
        applyButton.toolTip = "Give the place found to the photos that don't have a location"
        replaceButton.toolTip = "Give the place found to every photo, replacing their locations"
        removeButton.toolTip = "Remove the photos' location (the original files aren't changed)"
        applyButton.setAccessibilityIdentifier("locationApply")
        replaceButton.setAccessibilityIdentifier("locationReplace")
        removeButton.setAccessibilityIdentifier("locationRemove")
        let buttons = NSStackView(views: [applyButton, replaceButton, NSView(), removeButton])

        let arranged: [NSView] = [mapView, locationLabel, searchField, resultsScroll, messageLabel, buttons]
        let stack = NSStackView(views: arranged)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for view in arranged { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        show(nil, isMixed: false, hasPhotos: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Showing

    /// Shows the photos' location: one place, several (`isMixed`), or none. Forgets a place found.
    func show(_ location: GPSCoordinate?, isMixed: Bool, hasPhotos: Bool) {
        self.hasPhotos = hasPhotos
        hasLocation = location != nil || isMixed
        pending = nil
        messageLabel.isHidden = true
        locationLabel.stringValue = if isMixed { "Multiple locations" }
            else if let location { location.formatted }
            else { hasPhotos ? "No location" : "" }
        place(isMixed ? nil : location)
    }

    private func place(_ location: GPSCoordinate?) {
        mapView.removeAnnotation(pin)
        guard let location else { return }
        let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        pin.coordinate = coordinate
        mapView.addAnnotation(pin)
        mapView.setRegion(MKCoordinateRegion(center: coordinate, latitudinalMeters: 2_000, longitudinalMeters: 2_000), animated: false)
    }

    private func updateButtons() {
        applyButton.isEnabled = hasPhotos && pending != nil
        replaceButton.isEnabled = hasPhotos && pending != nil
        removeButton.isEnabled = hasPhotos && hasLocation
    }

    // MARK: - Focus

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.endEditingIfClickedOutside(event) ?? event
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        stopWatchingClicks()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { stopWatchingClicks() }
    }

    private func stopWatchingClicks() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// A click anywhere outside the field and its list of places (the grid, the map, another part of
    /// the sidebar) takes the cursor out of it; the click then goes on to what was clicked.
    func endEditingIfClickedOutside(_ event: NSEvent) -> NSEvent {
        guard let window, event.window === window, searchField.currentEditor() != nil else { return event }
        let inside = [searchField, resultsScroll].contains { view in
            !view.isHidden && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }
        if !inside {
            window.makeFirstResponder(nil)
            showCompletions([])
        }
        return event
    }

    // MARK: - Finding a place

    func controlTextDidChange(_ notification: Notification) {
        let text = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        messageLabel.isHidden = true
        if text.isEmpty || GPSCoordinate(parsing: text) != nil {
            showCompletions([])
        } else {
            completer.queryFragment = text
        }
    }

    /// ↑ ↓ move through the places found, Return picks one (or looks the text up), Esc closes the list.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(moveDown(_:)), #selector(moveUp(_:)):
            guard !completions.isEmpty else { return false }
            let step = selector == #selector(moveDown(_:)) ? 1 : -1
            let row = (results.selectedRow + step).clamped(to: 0...(completions.count - 1))
            results.selectRowIndexes([row], byExtendingSelection: false)
            results.scrollRowToVisible(row)
            return true
        case #selector(insertNewline(_:)):
            if completions.indices.contains(results.selectedRow) {
                choose(completions[results.selectedRow])
            } else {
                lookUp(searchField.stringValue)
            }
            return true
        case #selector(cancelOperation(_:)):
            guard !completions.isEmpty else { return false }
            showCompletions([])
            return true
        default:
            return false
        }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        showCompletions(Array(completer.results.prefix(8)))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        showCompletions([])
        showError(error)
    }

    private func showCompletions(_ completions: [MKLocalSearchCompletion]) {
        self.completions = completions
        results.reloadData()
        resultsScroll.isHidden = completions.isEmpty
    }

    /// The search field's action (Return, or the search being cleared).
    @objc private func searchFieldAction(_ sender: NSSearchField) {
        if sender.stringValue.isEmpty { showCompletions([]) }
    }

    /// "lat, lon" (or the Metadata panel's form) is used as it is, which works offline; anything else
    /// is looked up.
    func lookUp(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if let typed = GPSCoordinate(parsing: text) {
            found(typed, name: nil)
            return
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        start(request)
    }

    @objc private func resultClicked(_ sender: NSTableView) {
        guard completions.indices.contains(sender.clickedRow) else { return }
        choose(completions[sender.clickedRow])
    }

    private func choose(_ completion: MKLocalSearchCompletion) {
        searchField.stringValue = [completion.title, completion.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
        start(MKLocalSearch.Request(completion: completion))
    }

    private func start(_ request: MKLocalSearch.Request) {
        search?.cancel()
        let search = MKLocalSearch(request: request)
        self.search = search
        Task { [weak self] in
            do {
                let response = try await search.start()
                guard let self, self.search === search else { return }
                guard let item = response.mapItems.first,
                      let location = GPSCoordinate(latitude: item.location.coordinate.latitude, longitude: item.location.coordinate.longitude)
                else {
                    showMessage("No place found.")
                    return
                }
                found(location, name: item.name)
            } catch {
                guard let self, self.search === search else { return }
                showError(error)
            }
        }
    }

    /// A place to give the photos: shown on the map, waiting for Apply or Replace.
    func found(_ location: GPSCoordinate, name: String?) {
        showCompletions([])
        messageLabel.isHidden = true
        place(location)
        pending = location
        locationLabel.stringValue = name.map { "\($0) · \(location.formatted)" } ?? location.formatted
    }

    private func showError(_ error: any Error) {
        let error = error as NSError
        let offline = error.domain == NSURLErrorDomain
            || (error.domain == MKErrorDomain && UInt(error.code) == MKError.Code.serverFailure.rawValue)
        showMessage(offline ? "Finding places needs an internet connection. You can type “lat, lon” instead."
                    : error.domain == MKErrorDomain ? "No place found." : error.localizedDescription)
    }

    private func showMessage(_ text: String) {
        messageLabel.stringValue = text
        messageLabel.isHidden = false
    }

    // MARK: - Pin

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: "pin") as? PinView
            ?? PinView(annotation: annotation, reuseIdentifier: "pin")
        view.annotation = annotation
        view.tint = pinTint
        view.isDraggable = true
        view.setAccessibilityLabel("Location pin")
        return view
    }

    /// Dragging the pin fine-tunes the place, which then waits for Apply or Replace.
    func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState,
                 fromOldState oldState: MKAnnotationView.DragState)
    {
        guard newState == .ending || newState == .canceling else { return }
        view.dragState = .none
        guard newState == .ending, hasPhotos,
              let location = GPSCoordinate(latitude: pin.coordinate.latitude, longitude: pin.coordinate.longitude) else { return }
        found(location, name: nil)
    }

    // MARK: - Places found

    func numberOfRows(in tableView: NSTableView) -> Int { completions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let completion = completions[row]
        let title = NSTextField(labelWithString: completion.title)
        let subtitle = NSTextField(labelWithString: completion.subtitle)
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor
        for label in [title, subtitle] { label.lineBreakMode = .byTruncatingTail }
        let cell = NSStackView(views: [title, subtitle])
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 0
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.staticText)
        cell.setAccessibilityLabel([completion.title, completion.subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
        return cell
    }

    // MARK: - Actions

    @objc func apply(_ sender: Any?) {
        if let pending { onApply?(pending, false) }
    }

    @objc func replace(_ sender: Any?) {
        if let pending { onApply?(pending, true) }
    }

    @objc func remove(_ sender: Any?) {
        onRemove?()
    }
}
