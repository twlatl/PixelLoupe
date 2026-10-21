import AppKit
import CoreData
import MapKit

/// The Map module (RAW-165): the photos the grid shows that have a location, as pins on Apple Maps.
///
/// Pins come from the catalog's location fields (see `PhotoLocation.swift`), fetched with the grid's
/// filter, so the map always agrees with the grid and filmstrip and never reads files. Nearby pins
/// cluster. Clicking a pin or cluster selects its photos; the selection's pins are highlighted.
final class MapViewController: NSViewController, MKMapViewDelegate {
    private let store: CatalogStore
    private let state: LibraryState
    let mapView = PhotoMapView()
    private lazy var filterBar = FilterBarViewController(store: store, state: state)
    private let topSeparator = NSBox()
    private var mapBelowFilterBar: NSLayoutConstraint!
    private var mapAtTop: NSLayoutConstraint!
    let zoomSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let styleControl = NSSegmentedControl(labels: ["Standard", "Satellite", "Hybrid"], trackingMode: .selectOne, target: nil, action: nil)
    let countLabel = NSTextField(labelWithString: "")
    let emptyLabel = NSTextField(labelWithString: "No photos in this source have a location")
    private let hoverPopover = NSPopover()

    /// The pins shown, by photo.
    private(set) var annotations: [NSManagedObjectID: PhotoAnnotation] = [:]
    /// Pins of photos the filter shows, in the grid's order (for selecting a cluster's photos in order).
    private var pinOrder: [NSManagedObjectID] = []
    private let context: NSManagedObjectContext
    private var generation = 0
    private var pendingReload: DispatchWorkItem?
    /// Whether pins have to be fetched again when the module next shows (they changed while hidden).
    private var isStale = true
    /// The map's position in each source, so coming back to one shows it where it was left.
    private var cameras: [String: MKMapCamera] = [:]
    /// The source the pins were last fetched for; a different one is fitted to its pins.
    private var shownScope: String?
    private var isUpdatingSlider = false

    /// The zoom slider's range, as the camera's distance in metres (on a log scale): Earth to a street.
    static let farthest = 40_000_000.0, nearest = 300.0
    private static let styleKey = "MapStyle"

    init(store: CatalogStore, state: LibraryState) {
        self.store = store
        self.state = state
        context = store.newBackgroundContext()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var preferredFirstResponder: NSResponder? { mapView }

    // MARK: - Building

    override func loadView() {
        let root = NSView()
        view = root

        mapView.delegate = self
        mapView.showsZoomControls = true
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.register(PhotoMarkerView.self, forAnnotationViewWithReuseIdentifier: PhotoMarkerView.reuseIdentifier)
        mapView.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        mapView.setAccessibilityLabel("Map of photos")
        mapView.setAccessibilityIdentifier("photoMap")
        mapView.onDoubleClick = { [weak self] view in self?.doubleClicked(view) }

        zoomSlider.target = self
        zoomSlider.action = #selector(zoomChanged(_:))
        zoomSlider.isContinuous = true
        zoomSlider.controlSize = .small
        zoomSlider.setAccessibilityLabel("Zoom")
        zoomSlider.setAccessibilityIdentifier("mapZoom")
        zoomSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true

        styleControl.controlSize = .small
        styleControl.selectedSegment = (Defaults.store.object(forKey: Self.styleKey) as? Int ?? 0).clamped(to: 0...2)
        styleControl.target = self
        styleControl.action = #selector(styleChanged(_:))
        styleControl.setAccessibilityLabel("Map style")
        styleControl.setAccessibilityIdentifier("mapStyle")
        applyStyle()

        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.setAccessibilityIdentifier("mapCount")

        func icon(_ name: String, _ description: String) -> NSImageView {
            let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: description)!)
            view.contentTintColor = .secondaryLabelColor
            return view
        }
        let controls = NSStackView(views: [
            styleControl, countLabel, icon("minus.magnifyingglass", "Zoomed out"), zoomSlider, icon("plus.magnifyingglass", "Zoomed in"),
        ])
        controls.spacing = 10
        controls.setCustomSpacing(18, after: styleControl)
        controls.setCustomSpacing(18, after: countLabel)
        controls.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        // Floats over the map, in Liquid Glass.
        let glass = NSGlassEffectView()
        glass.contentView = controls
        glass.cornerRadius = 18

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.isHidden = true
        emptyLabel.setAccessibilityIdentifier("mapEmpty")

        topSeparator.boxType = .separator
        addChild(filterBar)
        for subview in [filterBar.view, topSeparator, mapView, glass, emptyLabel] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        mapBelowFilterBar = mapView.topAnchor.constraint(equalTo: topSeparator.bottomAnchor)
        mapAtTop = mapView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor)
        NSLayoutConstraint.activate([
            filterBar.view.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            filterBar.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            filterBar.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topSeparator.topAnchor.constraint(equalTo: filterBar.view.bottomAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mapView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mapView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            glass.centerXAnchor.constraint(equalTo: mapView.centerXAnchor),
            glass.bottomAnchor.constraint(equalTo: mapView.bottomAnchor, constant: -14),
            emptyLabel.centerXAnchor.constraint(equalTo: mapView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: mapView.centerYAnchor),
        ])
        filterBar.onEndSearch = { [weak self] in
            guard let self else { return }
            view.window?.makeFirstResponder(mapView)
        }
        updateFilterBar()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        state.addObserver(self) { [weak self] change in
            guard let self else { return }
            switch change {
            case .filter: scheduleReload()
            case .filterBar: updateFilterBar()
            case .mode:
                guard state.mode == .map else { break }
                if isStale { scheduleReload() } else { updateSelection(reveal: true) }
            case .selection: if state.mode == .map { updateSelection(reveal: true) }
            default: break
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(contextObjectsDidChange(_:)),
                                               name: .NSManagedObjectContextObjectsDidChange, object: store.viewContext)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if isStale { reload() }
    }

    private func updateFilterBar() {
        let visible = state.isFilterBarVisible
        filterBar.view.isHidden = !visible
        topSeparator.isHidden = !visible
        NSLayoutConstraint.deactivate(visible ? [mapAtTop] : [mapBelowFilterBar])
        NSLayoutConstraint.activate(visible ? [mapBelowFilterBar] : [mapAtTop])
    }

    /// ⌘F in Map: the Library Filter's text field, as in the Library.
    @objc func focusSearch(_ sender: Any?) {
        filterBar.focusSearch()
    }

    // MARK: - Pins

    /// Fetches the pins shortly, coalescing a burst of changes into one; only while Map is showing.
    private func scheduleReload() {
        isStale = true
        guard state.mode == .map else { return }
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Fetches the pins for the grid's filter off the main thread, then shows them.
    func reload() {
        pendingReload = nil
        isStale = false
        generation += 1
        let generation = generation, filter = state.filter, context = context
        context.perform { [weak self] in
            let pins = MapPins.fetch(filter, in: context)
            context.reset()
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.show(pins, scope: String(describing: filter.scope))
            }
        }
    }

    /// Waits for pins being fetched to be shown; used by tests.
    func waitUntilLoaded() async {
        await withCheckedContinuation { continuation in
            context.perform { DispatchQueue.main.async { continuation.resume() } }
        }
    }

    private func show(_ pins: [MapPin], scope: String) {
        let byID = Dictionary(pins.map { ($0.objectID, $0) }) { first, _ in first }
        let removed = annotations.filter { byID[$0.key] == nil }
        mapView.removeAnnotations(Array(removed.values))
        for id in removed.keys { annotations[id] = nil }
        var added: [PhotoAnnotation] = []
        for pin in pins {
            let coordinate = CLLocationCoordinate2D(latitude: pin.coordinate.latitude, longitude: pin.coordinate.longitude)
            if let existing = annotations[pin.objectID] {
                if existing.coordinate.latitude != coordinate.latitude || existing.coordinate.longitude != coordinate.longitude {
                    existing.coordinate = coordinate
                }
            } else {
                let annotation = PhotoAnnotation(pin, coordinate: coordinate)
                annotations[pin.objectID] = annotation
                added.append(annotation)
            }
        }
        mapView.addAnnotations(added)
        pinOrder = pins.map(\.objectID)

        countLabel.stringValue = pins.count == 1 ? "1 photo with a location" : "\(pins.count.formatted()) photos with a location"
        emptyLabel.isHidden = !pins.isEmpty
        if scope != shownScope {
            // A source shown before goes back to where it was left; a new one is fitted to its pins.
            shownScope = scope
            if let camera = cameras[scope] {
                mapView.setCamera(camera, animated: false)
            } else if !pins.isEmpty {
                fit(Array(annotations.values), animated: false)
            }
        }
        updateSelection(reveal: false)
    }

    private func fit(_ pins: [any MKAnnotation], animated: Bool) {
        mapView.showAnnotations(pins, animated: animated)
        // One pin (or several in one place) would zoom to the street; a neighbourhood reads better.
        if mapView.camera.centerCoordinateDistance < 2_000 {
            let camera = mapView.camera.copy() as! MKMapCamera
            camera.centerCoordinateDistance = 2_000
            mapView.setCamera(camera, animated: animated)
        }
    }

    /// Refetches when a photo's location changes, or photos come and go (a backfill pass, an edit
    /// in the Location palette, an import).
    @objc private func contextObjectsDidChange(_ notification: Notification) {
        let info = notification.userInfo ?? [:]
        let photos = [NSInsertedObjectsKey, NSDeletedObjectsKey, NSUpdatedObjectsKey, NSRefreshedObjectsKey]
            .flatMap { (info[$0] as? Set<NSManagedObject>) ?? [] }
            .compactMap { $0 as? Photo }
        let relevant = photos.contains { photo in
            photo.isInserted || photo.isDeleted || photo.changedValuesForCurrentEvent().keys.contains { Self.locationKeys.contains($0) }
                || (info[NSRefreshedObjectsKey] as? Set<NSManagedObject>)?.contains(photo) == true
        }
        if relevant { scheduleReload() }
    }

    private static let locationKeys: Set<String> = [
        "hasGPS", "fileLatitude", "fileLongitude", "locationOverride", "overrideLatitude", "overrideLongitude", "fileName",
    ]

    // MARK: - Selection

    /// Highlights the selected photos' pins. With `reveal`, brings them into view when none is showing
    /// (selecting in the filmstrip), without moving the map while any is already in view.
    private func updateSelection(reveal: Bool) {
        let selected = Set(state.selectedPhotoIDs)
        for annotation in annotations.values {
            annotation.isSelectedPhoto = selected.contains(annotation.objectID)
            (mapView.view(for: annotation) as? PhotoMarkerView)?.isPhotoSelected = annotation.isSelectedPhoto
        }
        for case let cluster as MKClusterAnnotation in mapView.annotations {
            (mapView.view(for: cluster) as? MKMarkerAnnotationView)?.markerTintColor = clusterTint(cluster)
        }
        guard reveal else { return }
        let pins = selected.compactMap { annotations[$0] }
        guard !pins.isEmpty else { return }
        let visible = mapView.visibleMapRect
        if !pins.contains(where: { visible.contains(MKMapPoint($0.coordinate)) }) {
            fit(pins, animated: true)
        }
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        guard let annotation = view.annotation else { return }
        // Selecting is the filmstrip's; the map only shows it.
        mapView.deselectAnnotation(annotation, animated: false)
        let ids = Set(Self.photos(in: annotation))
        guard !ids.isEmpty else { return }
        // In the grid's order, so the first is the active photo.
        state.selectedPhotoIDs = pinOrder.filter { ids.contains($0) }
    }

    private static func photos(in annotation: any MKAnnotation) -> [NSManagedObjectID] {
        switch annotation {
        case let photo as PhotoAnnotation: [photo.objectID]
        case let cluster as MKClusterAnnotation: cluster.memberAnnotations.compactMap { ($0 as? PhotoAnnotation)?.objectID }
        default: []
        }
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        switch annotation {
        case let photo as PhotoAnnotation:
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: PhotoMarkerView.reuseIdentifier, for: photo) as! PhotoMarkerView
            view.isPhotoSelected = photo.isSelectedPhoto
            view.onHover = { [weak self] view, isInside in self?.hover(view, isInside: isInside) }
            return view
        case let cluster as MKClusterAnnotation:
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier, for: cluster)
            (view as? MKMarkerAnnotationView)?.markerTintColor = clusterTint(cluster)
            view.setAccessibilityLabel("\(cluster.memberAnnotations.count) photos")
            return view
        default:
            return nil
        }
    }

    /// A cluster is highlighted when any of its photos is selected.
    private func clusterTint(_ cluster: MKClusterAnnotation) -> NSColor {
        cluster.memberAnnotations.contains { ($0 as? PhotoAnnotation)?.isSelectedPhoto == true } ? .controlAccentColor : .systemIndigo
    }

    /// Double-click: a photo opens enlarged in the Library; a cluster zooms in to its photos.
    private func doubleClicked(_ view: MKAnnotationView) {
        hoverPopover.close()
        switch view.annotation {
        case let photo as PhotoAnnotation:
            state.selectedPhotoIDs = [photo.objectID]
            state.mode = .library
            state.presentation = .loupe
        case let cluster as MKClusterAnnotation:
            fit(cluster.memberAnnotations, animated: true)
        default:
            break
        }
    }

    // MARK: - Hover

    /// Hovering over a pin shows its photo's thumbnail.
    private func hover(_ view: PhotoMarkerView, isInside: Bool) {
        guard isInside, let annotation = view.annotation as? PhotoAnnotation else {
            hoverPopover.close()
            return
        }
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = store.thumbnails.cachedImage(for: annotation.photoID).map { NSImage(cgImage: $0, size: .zero) }
        let name = NSTextField(labelWithString: annotation.title ?? "")
        name.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        name.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [imageView, name])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 180), imageView.heightAnchor.constraint(equalToConstant: 135),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
        ])
        let content = NSViewController()
        content.view = stack
        hoverPopover.contentViewController = content
        hoverPopover.behavior = .semitransient
        hoverPopover.animates = false
        hoverPopover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        if imageView.image == nil {
            let id = annotation.photoID, thumbnails = store.thumbnails
            Task { [weak imageView] in
                if let image = await thumbnails.image(for: id) { imageView?.image = NSImage(cgImage: image, size: .zero) }
            }
        }
    }

    // MARK: - Toolbar

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        if let shownScope { cameras[shownScope] = mapView.camera.copy() as? MKMapCamera }
        isUpdatingSlider = true
        zoomSlider.doubleValue = Self.sliderValue(forDistance: mapView.camera.centerCoordinateDistance)
        isUpdatingSlider = false
    }

    @objc private func zoomChanged(_ sender: NSSlider) {
        guard !isUpdatingSlider else { return }
        let camera = mapView.camera.copy() as! MKMapCamera
        camera.centerCoordinateDistance = Self.distance(forSliderValue: sender.doubleValue)
        mapView.setCamera(camera, animated: false)
    }

    /// The slider's position (0 farthest, 1 nearest) for a camera distance, on a log scale.
    static func sliderValue(forDistance distance: Double) -> Double {
        log(farthest / distance.clamped(to: nearest...farthest)) / log(farthest / nearest)
    }

    static func distance(forSliderValue value: Double) -> Double {
        farthest * pow(nearest / farthest, value.clamped(to: 0...1))
    }

    @objc private func styleChanged(_ sender: NSSegmentedControl) {
        Defaults.store.set(sender.selectedSegment, forKey: Self.styleKey)
        applyStyle()
    }

    private func applyStyle() {
        mapView.preferredConfiguration = switch styleControl.selectedSegment {
        case 1: MKImageryMapConfiguration()
        case 2: MKHybridMapConfiguration()
        default: MKStandardMapConfiguration()
        }
    }
}

/// The map view, handling double-clicks on pins itself so MapKit doesn't also zoom in under them.
final class PhotoMapView: MKMapView {
    var onDoubleClick: ((MKAnnotationView) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let view = annotationView(at: convert(event.locationInWindow, from: nil)) {
            onDoubleClick?(view)
            return
        }
        super.mouseDown(with: event)
    }

    private func annotationView(at point: NSPoint) -> MKAnnotationView? {
        var view = hitTest(convert(point, to: superview))
        while let current = view, !(current is MKAnnotationView) { view = current.superview }
        return view as? MKAnnotationView
    }
}

/// A photo's pin.
final class PhotoAnnotation: NSObject, MKAnnotation {
    let objectID: NSManagedObjectID
    let photoID: UUID
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let title: String?
    var isSelectedPhoto = false

    init(_ pin: MapPin, coordinate: CLLocationCoordinate2D) {
        objectID = pin.objectID
        photoID = pin.photoID
        self.coordinate = coordinate
        title = pin.fileName
    }
}

/// A photo's marker: clusters with its neighbours, in the accent color while the photo is selected.
final class PhotoMarkerView: MKMarkerAnnotationView {
    static let reuseIdentifier = "photo"
    var onHover: ((PhotoMarkerView, Bool) -> Void)?
    var isPhotoSelected = false {
        didSet {
            markerTintColor = isPhotoSelected ? .controlAccentColor : .systemRed
            displayPriority = isPhotoSelected ? .required : .defaultHigh
        }
    }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clusteringIdentifier = "photos"
        glyphImage = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        markerTintColor = .systemRed
        canShowCallout = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var annotation: (any MKAnnotation)? {
        didSet { setAccessibilityLabel(annotation?.title ?? nil) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onHover = nil
        isPhotoSelected = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(self, true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(self, false)
    }
}
