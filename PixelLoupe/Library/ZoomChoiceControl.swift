import AppKit

/// The secondary window loupe's zoom choices, along the bottom of the screen (Lightroom's): FIT or FILL
/// (a menu on the first segment), 100%, and a menu of the Navigator's other ratios. The same choices as
/// the Navigator's FIT / FILL / 1:1 / ratio menu, acting on a view state's `zoom`.
final class ZoomChoiceControl: NSSegmentedControl {
    enum Segment: Int { case fit, actualPixels, ratio }

    private let state: LibraryState

    init(state: LibraryState) {
        self.state = state
        super.init(frame: .zero)
        segmentCount = 3
        trackingMode = .selectOne
        controlSize = .small
        segmentStyle = .separated
        font = .systemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
        setMenu(fitMenu(), forSegment: Segment.fit.rawValue)
        setShowsMenuIndicator(true, forSegment: Segment.fit.rawValue)
        setLabel("100%", forSegment: Segment.actualPixels.rawValue)
        setMenu(ratioMenu(), forSegment: Segment.ratio.rawValue)
        setShowsMenuIndicator(true, forSegment: Segment.ratio.rawValue)
        setToolTip("Fit the whole photo, or fill the view (hold for the choice)", forSegment: Segment.fit.rawValue)
        setToolTip("Actual pixels", forSegment: Segment.actualPixels.rawValue)
        setToolTip("Other zoom ratios (hold for the choice)", forSegment: Segment.ratio.rawValue)
        target = self
        action = #selector(segmentChosen(_:))
        setAccessibilityLabel("Zoom")
        setAccessibilityIdentifier("secondaryLoupeZoom")
        state.addObserver(self) { [weak self] change in
            if change == .zoom { self?.update() }
        }
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A ratio as Lightroom's secondary window writes it: 1:1 is 100%, 3:1 is 300%, 1:8 is 12.5%.
    static func percent(_ ratio: ZoomRatio) -> String {
        (ratio.scale * 100).formatted(.number.grouping(.never).precision(.fractionLength(0...2))) + "%"
    }

    private func fitMenu() -> NSMenu {
        let menu = NSMenu()
        for fit in PhotoZoom.Fit.allCases {
            let item = NSMenuItem(title: fit.title, action: #selector(fitChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = fit.rawValue
            menu.addItem(item)
        }
        return menu
    }

    private func ratioMenu() -> NSMenu {
        let menu = NSMenu()
        for ratio in ZoomRatio.menu {
            let item = NSMenuItem(title: Self.percent(ratio), action: #selector(ratioChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ratio.rawValue
            menu.addItem(item)
        }
        return menu
    }

    func update() {
        let zoom = state.zoom
        setLabel(zoom.fit.title, forSegment: Segment.fit.rawValue)
        setLabel(Self.percent(zoom.menuRatio), forSegment: Segment.ratio.rawValue)
        for segment in 0..<segmentCount { setWidth(0, forSegment: segment) }
        let selected: Segment = zoom.isZoomed ? (zoom.ratio == .oneToOne ? .actualPixels : .ratio) : .fit
        selectedSegment = selected.rawValue
        for item in menu(forSegment: Segment.fit.rawValue)?.items ?? [] {
            item.state = item.representedObject as? String == zoom.fit.rawValue ? .on : .off
        }
        for item in menu(forSegment: Segment.ratio.rawValue)?.items ?? [] {
            item.state = item.representedObject as? String == zoom.menuRatio.rawValue ? .on : .off
        }
    }

    @objc private func segmentChosen(_ sender: NSSegmentedControl) {
        var zoom = state.zoom
        switch Segment(rawValue: sender.selectedSegment) {
        case .fit?: zoom.isZoomed = false
        case .actualPixels?: zoom.ratio = .oneToOne; zoom.isZoomed = true
        case .ratio?: zoom.ratio = zoom.menuRatio; zoom.isZoomed = true
        case nil: break
        }
        state.zoom = zoom
        update()
    }

    @objc private func fitChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let fit = PhotoZoom.Fit(rawValue: raw) else { return }
        var zoom = state.zoom
        zoom.fit = fit
        zoom.isZoomed = false
        state.zoom = zoom
        update()
    }

    @objc private func ratioChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let ratio = ZoomRatio(rawValue: raw) else { return }
        var zoom = state.zoom
        zoom.menuRatio = ratio
        zoom.ratio = ratio
        zoom.isZoomed = true
        state.zoom = zoom
        update()
    }
}

/// The secondary window's loupe (Normal, Live and Locked): the photo above, and the zoom choices along
/// the very bottom of the screen.
final class SecondaryLoupeViewController: NSViewController {
    let loupe: LoupeViewController
    let zoomControl: ZoomChoiceControl
    static let barHeight: CGFloat = 36

    init(store: CatalogStore, state: LibraryState) {
        loupe = LoupeViewController(store: store, state: state)
        zoomControl = ZoomChoiceControl(state: state)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var preferredFirstResponder: NSResponder? { loupe.preferredFirstResponder }

    override func loadView() {
        let container = MatteView()
        addChild(loupe)
        let bar = NSView()
        for view in [loupe.view, bar, zoomControl] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        container.addSubview(loupe.view)
        container.addSubview(bar)
        bar.addSubview(zoomControl)
        NSLayoutConstraint.activate([
            loupe.view.topAnchor.constraint(equalTo: container.topAnchor),
            loupe.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            loupe.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            loupe.view.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight),
            zoomControl.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            zoomControl.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
        ])
        view = container
    }
}
