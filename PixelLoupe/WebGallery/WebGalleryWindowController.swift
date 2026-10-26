import AppKit
import SwiftUI
import WebKit

/// Window ▸ Web Gallery (⌃⌥⌘W): the gallery's pages as a browser shows them in the middle, the
/// gallery's options on the right. Generate writes it into a folder.
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
    /// What Export needs to render each photo, by the photo's ID (from the catalog when the window opens).
    private let exportItems: [UUID: ExportItem]
    private let thumbnails: ThumbnailStore
    private(set) var generateTask: Task<Void, Never>?
    /// The settings the preview last showed: Output changes don't reload it.
    private var shownSettings: WebGallerySettings
    var onClose: (() -> Void)?

    init(photos: [ContactSheetPhoto], exportItems: [UUID: ExportItem] = [:], thumbnails: ThumbnailStore, sourceName: String,
         defaults: UserDefaults = Defaults.store) {
        self.photos = photos
        self.exportItems = exportItems
        self.thumbnails = thumbnails
        self.sourceName = sourceName
        model = WebGalleryModel(photoCount: photos.count, defaults: defaults)
        source = WebGalleryPreviewSource(photos: photos, thumbnails: thumbnails, sourceName: sourceName, settings: model.settings)
        shownSettings = Self.previewed(model.settings)

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
        model.onGenerate = { [weak self] in self?.generate() }
        model.onCancel = { [weak self] in self?.generateTask?.cancel() }
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
        let previewed = Self.previewed(model.settings)
        guard previewed != shownSettings else { return }
        shownSettings = previewed
        let last = model.pages.count - 1
        if currentPage > last {
            webView.load(URLRequest(url: WebGalleryPreviewSource.url(ofPage: last)))
        } else {
            webView.reload()
        }
    }

    /// The settings without the ones the preview ignores (the generated images' quality and
    /// watermark, and the Head and Body text).
    private static func previewed(_ settings: WebGallerySettings) -> WebGallerySettings {
        var settings = settings
        settings.jpegQuality = WebGallerySettings().jpegQuality
        settings.watermarkName = nil
        settings.headHTML = ""
        settings.bodyHTML = ""
        return settings
    }

    // MARK: Generate

    /// Asks for the folder to write the gallery into (checking before replacing a gallery already
    /// there), then writes it.
    func generate() {
        guard generateTask == nil, let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Generate"
        panel.message = "Choose a folder for the web gallery. Its pages and images go inside it."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            self?.confirmReplacing(folder)
        }
    }

    private func confirmReplacing(_ folder: URL) {
        guard FileManager.default.fileExists(atPath: folder.appending(path: "index.html").path(percentEncoded: false)),
              let window else { return write(to: folder) }
        let alert = NSAlert()
        alert.messageText = "“\(folder.lastPathComponent)” already has a web page. Replace it with this gallery?"
        alert.informativeText = "Its index.html and the gallery’s pages and images are replaced. Other files in the folder are left alone."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.write(to: folder) }
        }
    }

    /// The photos with what's needed to write them: the catalog's export item (or one made from the
    /// snapshot) and the cached thumbnail to fall back on.
    var writerPhotos: [WebGalleryWriter.Photo] {
        photos.map { WebGalleryWriter.Photo(photo: $0, item: exportItems[$0.id], fallback: thumbnails.url(for: $0.id)) }
    }

    /// Writes the gallery into a temporary folder next to `folder`, then moves it in, so a cancelled
    /// or failed run leaves `folder` as it was. Shows it in the Finder when it's done.
    func write(to folder: URL) {
        let photos = writerPhotos, settings = model.settings, sourceName = sourceName
        let watermark = settings.watermarkName.flatMap { WatermarkPresets.shared.preset(named: $0) }.map {
            PhotoExporter.Watermark(settings: $0.settings, imageURL: $0.settings.imageName.map(WatermarkPresets.shared.imageURL(named:)))
        }
        model.progress = 0
        generateTask = Task { [weak self] in
            let fileManager = FileManager.default
            var temporaryFolder: URL?
            do {
                let temporary = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
                temporaryFolder = temporary
                let result = try await WebGalleryWriter.write(photos, settings: settings, sourceName: sourceName, watermark: watermark,
                                                              to: temporary) { done in
                    self?.model.progress = done
                }
                try Task.checkCancellation()
                try await WebGalleryWriter.install(from: temporary, into: folder)
                if !AppDelegate.isRunningUnitTests {
                    NSWorkspace.shared.activateFileViewerSelecting([folder.appending(path: "index.html")])
                }
                if !result.failures.isEmpty { self?.showUnreadable(result.failures) }
            } catch is CancellationError {
            } catch {
                self?.showError(error)
            }
            if let temporaryFolder { try? fileManager.removeItem(at: temporaryFolder) }
            self?.model.progress = nil
            self?.generateTask = nil
        }
    }

    private func showUnreadable(_ names: [String]) {
        let alert = NSAlert()
        alert.messageText = names.count == 1
            ? "“\(names[0])” couldn’t be read, so the gallery has no image for it."
            : "\(names.count) photos couldn’t be read, so the gallery has no images for them."
        if names.count > 1 { alert.informativeText = names.prefix(10).joined(separator: "\n") + (names.count > 10 ? "\n…" : "") }
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "The web gallery couldn't be saved."
        alert.informativeText = error.localizedDescription
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: WKNavigationDelegate

    /// The preview stays on the gallery's own pages.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.scheme == WebGalleryPreviewSource.scheme ? .allow : .cancel
    }

    func windowWillClose(_ notification: Notification) {
        generateTask?.cancel()
        webView.stopLoading()
        onClose?()
    }
}
