import AppKit
import SwiftUI
import WebKit

/// Window ▸ Web Gallery (⌃⌥⌘W): the gallery's pages as a browser shows them in the middle, the
/// gallery's options on the right.
///
/// The photos are fixed when the window opens; selecting others in the catalog doesn't change them.
final class WebGalleryWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    static let sidebarWidth: CGFloat = 300

    let model: WebGalleryModel
    let photos: [ContactSheetPhoto]
    /// The grid's source ("All Photographs", a folder or collection's name), for the subtitle and title.
    let sourceName: String
    let webView: WKWebView
    private let source: WebGalleryPreviewSource
    var onClose: (() -> Void)?

    init(photos: [ContactSheetPhoto], thumbnails: ThumbnailStore, sourceName: String, defaults: UserDefaults = Defaults.store) {
        self.photos = photos
        self.sourceName = sourceName
        model = WebGalleryModel(photoCount: photos.count, defaults: defaults)
        source = WebGalleryPreviewSource(photos: photos, thumbnails: thumbnails, sourceName: sourceName, settings: model.settings)

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(source, forURLScheme: WebGalleryPreviewSource.scheme)
        // Nothing the preview shows needs to be kept between windows.
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.setAccessibilityIdentifier("webGalleryPreview")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true
        )
        window.title = "Web Gallery"
        window.subtitle = "\(photos.count.formatted()) photo\(photos.count == 1 ? "" : "s") · \(sourceName)"
        window.contentMinSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("webGallery")
        window.setAccessibilityIdentifier("webGallery")
        super.init(window: window)
        window.delegate = self
        webView.navigationDelegate = self

        window.contentView = makeContent()
        window.setContentSize(NSSize(width: 1100, height: 820))
        window.center()
        // Later galleries open where the last one was (not while unit tests run: they mustn't change the
        // user's preferences, and window frames are saved in the standard defaults).
        if !AppDelegate.isRunningUnitTests, window.setFrameAutosaveName("WebGalleryWindow") {
            window.setFrameUsingName("WebGalleryWindow")
        }

        model.onChange = { [weak self] in self?.settingsChanged() }
        webView.load(URLRequest(url: WebGalleryPreviewSource.url(ofPage: 0)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func makeContent() -> NSView {
        let hosting = NSHostingView(rootView: WebGalleryPanel(model: model))
        hosting.sizingOptions = []
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        hosting.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: sidebar.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
        ])

        let divider = NSBox()
        divider.boxType = .separator
        let content = NSView()
        for view in [webView, divider, sidebar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: webView.trailingAnchor),
            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            sidebar.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 760),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 560),
        ])
        return content
    }

    /// The page the preview shows (0 before it has loaded one).
    var currentPage: Int {
        webView.url.flatMap { WebGalleryPages.page(named: $0.lastPathComponent) } ?? 0
    }

    /// Reloads the page being viewed with the new settings; WebKit keeps its scroll position. When
    /// fewer photos per page leave it past the end, shows the last page instead.
    private func settingsChanged() {
        source.settings = model.settings
        let last = model.pages.count - 1
        if currentPage > last {
            webView.load(URLRequest(url: WebGalleryPreviewSource.url(ofPage: last)))
        } else {
            webView.reload()
        }
    }

    // MARK: WKNavigationDelegate

    /// The preview stays on the gallery's own pages.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.scheme == WebGalleryPreviewSource.scheme ? .allow : .cancel
    }

    func windowWillClose(_ notification: Notification) {
        webView.stopLoading()
        onClose?()
    }
}
