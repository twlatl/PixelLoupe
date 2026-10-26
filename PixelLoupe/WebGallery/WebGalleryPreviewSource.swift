import Foundation
import WebKit

/// Serves the web gallery to the window's preview from memory, under `pixelloupe-gallery://gallery/`:
/// the pages and stylesheet as ``WebGalleryHTML`` writes them for the current settings, and each
/// photo's cached thumbnail (edits applied) as its image. Nothing is written to disk, and a thumbnail
/// is read only when the page shows it (the images load lazily).
final class WebGalleryPreviewSource: NSObject, WKURLSchemeHandler {
    static let scheme = "pixelloupe-gallery"
    static let baseURL = URL(string: "\(scheme)://gallery/")!

    let photos: [ContactSheetPhoto]
    let sourceName: String
    var settings: WebGallerySettings
    private let thumbnails: ThumbnailStore
    /// Requests still wanted: one the web view stops mustn't be answered.
    private var running: Set<ObjectIdentifier> = []

    init(photos: [ContactSheetPhoto], thumbnails: ThumbnailStore, sourceName: String, settings: WebGallerySettings) {
        self.photos = photos
        self.thumbnails = thumbnails
        self.sourceName = sourceName
        self.settings = settings
    }

    static func url(ofPage page: Int) -> URL {
        baseURL.appending(path: WebGalleryPages.fileName(ofPage: page))
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let path = url.path(percentEncoded: false)
        let pages = WebGalleryPages(photoCount: photos.count, photosPerPage: settings.photosPerPage)
        let name = (path as NSString).lastPathComponent

        if path == "/\(WebGalleryHTML.stylesheetName)" {
            respond(to: task, data: Data(WebGalleryHTML.stylesheet(settings: settings).utf8), type: "text/css")
        } else if (path as NSString).deletingLastPathComponent == "/", let page = WebGalleryPages.page(named: name), page < pages.count {
            let html = WebGalleryHTML.page(page, photos: photos, settings: settings, sourceName: sourceName)
            respond(to: task, data: Data(html.utf8), type: "text/html")
        } else if (path as NSString).deletingLastPathComponent == "/\(WebGalleryHTML.thumbnailFolder)",
                  let index = WebGalleryHTML.index(ofImageNamed: name), photos.indices.contains(index) {
            let id = ObjectIdentifier(task)
            running.insert(id)
            let file = thumbnails.url(for: photos[index].id)
            Task {
                let data = await Self.read(file)
                guard running.remove(id) != nil else { return }
                if let data {
                    respond(to: task, data: data, type: "image/jpeg", cached: true)
                } else {
                    task.didFailWithError(URLError(.fileDoesNotExist))
                }
            }
        } else {
            task.didFailWithError(URLError(.fileDoesNotExist))
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        running.remove(ObjectIdentifier(task))
    }

    /// Pages and the stylesheet change with every setting, so they're never cached; thumbnails don't.
    private func respond(to task: any WKURLSchemeTask, data: Data, type: String, cached: Bool = false) {
        guard let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                  "Content-Type": type == "image/jpeg" ? type : "\(type); charset=utf-8",
                  "Content-Length": String(data.count),
                  "Cache-Control": cached ? "max-age=3600" : "no-store",
              ])
        else { return task.didFailWithError(URLError(.badServerResponse)) }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    @concurrent
    private static func read(_ url: URL) async -> Data? {
        try? Data(contentsOf: url, options: .mappedIfSafe)
    }
}
