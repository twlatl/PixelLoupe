import AppKit

/// The contact sheet window's pages, one under another, drawn by ``ContactSheetRenderer`` from the
/// photos' cached thumbnails (edits applied). Only the pages scrolled into view are drawn, and a
/// thumbnail not yet in memory loads off the main thread and redraws its page when it arrives.
final class ContactSheetPreviewView: NSView {
    static let padding: CGFloat = 32
    static let pageSpacing: CGFloat = 24
    /// Pages never show larger than this many screen points per page point.
    static let maxScale: CGFloat = 1.5

    let photos: [ContactSheetPhoto]
    private let thumbnails: ThumbnailStore
    private(set) var settings: ContactSheetSettings
    private(set) var layout: ContactSheetLayout
    /// Thumbnails loading, and ones that couldn't be loaded (drawn as placeholders), so each is asked for once.
    private var loading: Set<UUID> = []
    private var unavailable: Set<UUID> = []

    init(photos: [ContactSheetPhoto], thumbnails: ThumbnailStore, settings: ContactSheetSettings) {
        self.photos = photos
        self.thumbnails = thumbnails
        self.settings = settings
        layout = ContactSheetLayout(settings: settings, photoCount: photos.count)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Contact Sheet Preview")
        setAccessibilityIdentifier("contactSheetPreview")
        updateAccessibilityValue()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func update(_ settings: ContactSheetSettings) {
        self.settings = settings
        layout = ContactSheetLayout(settings: settings, photoCount: photos.count)
        fitWidth()
        needsDisplay = true
        updateAccessibilityValue()
    }

    private func updateAccessibilityValue() {
        setAccessibilityValue("\(layout.pageCount) page\(layout.pageCount == 1 ? "" : "s")")
    }

    // MARK: Geometry

    /// Screen points per page point: the page fits the visible width.
    var scale: CGFloat {
        let width = (enclosingScrollView?.contentSize.width ?? bounds.width) - 2 * Self.padding
        return min(max(width, 100) / layout.pageSize.width, Self.maxScale)
    }

    func pageFrame(_ page: Int) -> CGRect {
        let scale = scale
        let size = CGSize(width: (layout.pageSize.width * scale).rounded(), height: (layout.pageSize.height * scale).rounded())
        let width = enclosingScrollView?.contentSize.width ?? bounds.width
        return CGRect(x: ((width - size.width) / 2).rounded(), y: Self.padding + CGFloat(page) * (size.height + Self.pageSpacing),
                      width: size.width, height: size.height)
    }

    /// Sizes the view to the scroll view's width and the pages' height.
    func fitWidth() {
        guard let scrollView = enclosingScrollView else { return }
        let last = pageFrame(layout.pageCount - 1)
        let size = NSSize(width: scrollView.contentSize.width, height: last.maxY + Self.padding)
        if frame.size != size { setFrameSize(size) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let first = pageFrame(0)
        let stride = first.height + Self.pageSpacing
        let start = max(0, Int(((dirtyRect.minY - Self.padding) / stride).rounded(.down)))
        let end = min(layout.pageCount - 1, Int(((dirtyRect.maxY - Self.padding) / stride).rounded(.down)))
        guard start <= end else { return }
        let scale = scale
        for page in start...end {
            let frame = pageFrame(page)
            guard frame.intersects(dirtyRect) else { continue }
            // A sheet of paper lifted off the window.
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: NSColor.black.withAlphaComponent(0.3).cgColor)
            context.setFillColor(settings.backgroundColor.cgColor)
            context.fill(frame)
            context.restoreGState()

            context.saveGState()
            context.clip(to: frame)
            // The renderer draws with the origin at the page's bottom-left, in page points.
            context.translateBy(x: frame.minX, y: frame.maxY)
            context.scaleBy(x: scale, y: -scale)
            ContactSheetRenderer.drawPage(page, layout: layout, settings: settings, in: context) { index in
                let photo = photos[index]
                return ContactSheetRenderer.Cell(image: thumbnail(for: index), aspect: photo.aspect,
                                                 name: photo.fileName, caption: photo.caption(settings.captionField))
            }
            context.restoreGState()
        }
    }

    /// The photo's thumbnail if it's in memory; otherwise asks for it and redraws once it's loaded.
    private func thumbnail(for index: Int) -> CGImage? {
        let id = photos[index].id
        if let image = thumbnails.cachedImage(for: id) { return image }
        guard !unavailable.contains(id), loading.insert(id).inserted else { return nil }
        Task { [weak self] in
            guard let self else { return }
            let image = await thumbnails.image(for: id)
            loading.remove(id)
            if image == nil { unavailable.insert(id) } else { redraw(photoAt: index) }
        }
        return nil
    }

    private func redraw(photoAt index: Int) {
        guard layout.photosPerPage > 0, index < photos.count else { return }
        setNeedsDisplay(pageFrame(index / layout.photosPerPage))
    }
}
