import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Window ▸ Contact Sheet (⌃⌥⌘C): the photos that were selected (or the whole grid) laid out on
/// pages in the middle, the sheet's options on the right. Generate saves it as a PDF.
///
/// The photos are fixed when the window opens; selecting others in the catalog doesn't change them.
final class ContactSheetWindowController: NSWindowController, NSWindowDelegate {
    static let sidebarWidth: CGFloat = 300

    let model: ContactSheetModel
    let photos: [ContactSheetPhoto]
    /// The grid's source ("All Photographs", a folder or collection's name), for the subtitle and file name.
    let sourceName: String
    let preview: ContactSheetPreviewView
    private let scrollView = NSScrollView()
    private(set) var generateTask: Task<Void, Never>?
    var onClose: (() -> Void)?

    init(photos: [ContactSheetPhoto], thumbnails: ThumbnailStore, sourceName: String, defaults: UserDefaults = Defaults.store) {
        self.photos = photos
        self.sourceName = sourceName
        model = ContactSheetModel(photoCount: photos.count, defaults: defaults)
        preview = ContactSheetPreviewView(photos: photos, thumbnails: thumbnails, settings: model.settings)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true
        )
        window.title = "Contact Sheet"
        window.subtitle = "\(photos.count.formatted()) photo\(photos.count == 1 ? "" : "s") · \(sourceName)"
        window.contentMinSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("contactSheet")
        window.setAccessibilityIdentifier("contactSheet")
        super.init(window: window)
        window.delegate = self

        window.contentView = makeContent()
        window.setContentSize(NSSize(width: 1100, height: 820))
        window.center()
        // Later sheets open where the last one was (not while unit tests run: they mustn't change the
        // user's preferences, and window frames are saved in the standard defaults).
        if !AppDelegate.isRunningUnitTests, window.setFrameAutosaveName("ContactSheetWindow") {
            window.setFrameUsingName("ContactSheetWindow")
        }

        model.onChange = { [weak self] in self?.settingsChanged() }
        model.onGenerate = { [weak self] in self?.generate() }
        model.onCancel = { [weak self] in self?.generateTask?.cancel() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func makeContent() -> NSView {
        scrollView.documentView = preview
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollViewResized(_:)),
                                               name: NSView.frameDidChangeNotification, object: scrollView.contentView)

        let hosting = NSHostingView(rootView: ContactSheetPanel(model: model))
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
        for view in [scrollView, divider, sidebar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor),
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

    @objc private func scrollViewResized(_ notification: Notification) {
        preview.fitWidth()
        preview.needsDisplay = true
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        preview.fitWidth()
    }

    private func settingsChanged() {
        preview.update(model.settings)
    }

    // MARK: Generate

    /// The suggested file name: the headline, else the grid's source, else "Contact Sheet".
    var suggestedFileName: String {
        let headline = model.settings.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = [headline, sourceName].first { !$0.isEmpty } ?? "Contact Sheet"
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(safe).pdf"
    }

    /// Asks where to save the PDF, then writes it.
    func generate() {
        guard generateTask == nil, let window, window.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedFileName
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.write(to: url)
        }
    }

    /// Writes the PDF next to `url` and moves it into place once it's complete, so a cancelled or
    /// failed run leaves nothing behind (and an existing file as it was).
    func write(to url: URL) {
        let photos = photos, settings = model.settings
        model.progress = 0
        generateTask = Task { [weak self] in
            let fileManager = FileManager.default
            var temporaryFolder: URL?
            do {
                let folder = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
                temporaryFolder = folder
                let temporary = folder.appending(path: url.lastPathComponent)
                try await ContactSheetPDF.write(photos, settings: settings, to: temporary) { done in
                    self?.model.progress = done
                }
                try Task.checkCancellation()
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } catch is CancellationError {
            } catch {
                self?.showError(error)
            }
            if let temporaryFolder { try? fileManager.removeItem(at: temporaryFolder) }
            self?.model.progress = nil
            self?.generateTask = nil
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "The contact sheet couldn't be saved."
        alert.informativeText = error.localizedDescription
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    func windowWillClose(_ notification: Notification) {
        generateTask?.cancel()
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        onClose?()
    }
}
