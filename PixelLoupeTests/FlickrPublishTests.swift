import AppKit
import CoreData
import Foundation
import Synchronization
import Testing
@testable import PixelLoupe

/// Flickr's answers, by what was asked: an upload, a replace, or a REST method.
private nonisolated struct FakeFlickr {
    let table = StubURLProtocol.Table()
    let account = FlickrCredentials(userID: "88581768@N00", username: "TheodoreWLee", fullName: "Theodore Lee", token: "token", tokenSecret: "token-secret")
    /// The waits between retries, in seconds.
    final class Delays: Sendable {
        let values = Mutex<[Double]>([])
    }

    let delays = Delays()

    init(answer: @escaping @Sendable (_ what: String, _ fields: [String: String]) -> StubURLProtocol.Response = { what, _ in
        switch what {
        case "upload": .init(status: 200, body: #"<?xml version="1.0"?><rsp stat="ok"><photoid>52419583421</photoid></rsp>"#)
        case "replace": .init(status: 200, body: #"<rsp stat="ok"><photoid secret="abc" originalsecret="def">52419583421</photoid></rsp>"#)
        default: .init(status: 200, body: #"{"stat":"ok"}"#)
        }
    }) {
        table.handler.withLock {
            $0 = { request, body in
                let path = request.url?.path() ?? ""
                let fields = Self.fields(body, contentType: request.value(forHTTPHeaderField: "Content-Type") ?? "")
                let what = path.hasSuffix("/upload/") ? "upload" : path.hasSuffix("/replace/") ? "replace" : fields["method"] ?? path
                return answer(what, fields)
            }
        }
    }

    var api: FlickrAPI {
        var api = FlickrAPI(credentials: account, session: StubURLProtocol.session(table), signer: OAuth1Signer(consumerKey: "key", consumerSecret: "secret"))
        let delays = delays
        api.sleep = { delay in delays.values.withLock { $0.append(delay) } }
        return api
    }

    /// What was asked, in order ("upload", "flickr.photos.setMeta"…), with the fields sent.
    var calls: [(what: String, fields: [String: String])] {
        table.requests.withLock { requests in
            requests.map { request, body in
                let fields = Self.fields(body, contentType: request.value(forHTTPHeaderField: "Content-Type") ?? "")
                let path = request.url?.path() ?? ""
                return (path.hasSuffix("/upload/") ? "upload" : path.hasSuffix("/replace/") ? "replace" : fields["method"] ?? path, fields)
            }
        }
    }

    /// A form's fields, from a urlencoded body or a multipart one (the photo's bytes as their length).
    static func fields(_ body: Data, contentType: String) -> [String: String] {
        guard let boundary = contentType.split(separator: "boundary=").last.map(String.init), contentType.hasPrefix("multipart") else {
            return OAuth1Signer.formFields(body)
        }
        var fields: [String: String] = [:]
        let text = String(decoding: body, as: UTF8.self)
        for part in text.components(separatedBy: "--\(boundary)") {
            guard let nameRange = part.range(of: #"name="([^"]+)""#, options: .regularExpression),
                  let split = part.range(of: "\r\n\r\n") else { continue }
            let name = String(part[nameRange].dropFirst(6).dropLast())
            fields[name] = name == "photo" ? "\(body.count) bytes" : String(part[split.upperBound...]).trimmingCharacters(in: .newlines)
        }
        return fields
    }
}

@Suite("Flickr publishing")
@MainActor
struct FlickrPublishTests {
    private func item(_ directory: TemporaryDirectory, title: String? = "Harbour", remote: RemotePhoto? = nil, hasEdits: Bool = true,
                      keywords: [String] = ["Boats", "New York"]) throws -> PublishItem {
        let url = try Fixtures.writeJPEG(to: directory.url.appending(path: "IMG_0001.JPG"))
        var metadata = PhotoMetadata()
        metadata[.caption] = "Morning light on the water"
        let export = ExportItem(source: url, adjustments: PhotoAdjustments(), metadata: metadata, keywords: keywords, rating: 3, captureDate: .now)
        return PublishItem(export: export, title: title, remote: remote, hasEdits: hasEdits, index: 0, total: 1)
    }

    private func publisher(_ flickr: FakeFlickr, _ change: (inout PublishSettings) -> Void = { _ in }) -> FlickrPublisher {
        var settings = PublishSettings(.flickr)
        change(&settings)
        return FlickrPublisher(api: flickr.api, settings: settings, watermark: nil)
    }

    @Test func tagsAreSpaceSeparatedWithPhrasesQuoted() {
        #expect(FlickrPublisher.tags(["Boats", "New York", " ", "Say \"cheese\""]) == #"Boats "New York" "Say cheese""#)
    }

    @Test func aNewPhotoIsUploadedWithItsDetailsAndPrivacy() async throws {
        let directory = try TemporaryDirectory()
        let flickr = FakeFlickr()
        let remote = try await publisher(flickr) {
            $0.isPublic = false
            $0.isVisibleToFamily = true
            $0.safety = .moderate
            $0.contentType = .screenshot
            $0.hidesFromPublicAreas = true
        }.publish(item(directory))
        #expect(remote == RemotePhoto(id: "52419583421", url: URL(string: "https://www.flickr.com/photos/88581768@N00/52419583421/")))
        let upload = try #require(flickr.calls.first)
        #expect(upload.what == "upload")
        let fields = upload.fields
        #expect(fields["title"] == "Harbour" && fields["description"] == "Morning light on the water")
        #expect(fields["tags"] == #"Boats "New York""#)
        #expect(fields["is_public"] == "0" && fields["is_family"] == "1" && fields["is_friend"] == "0")
        #expect(fields["safety_level"] == "2" && fields["content_type"] == "2" && fields["hidden"] == "2")
        #expect(fields["oauth_token"] == "token" && fields["oauth_signature"] != nil)
        #expect(fields["photo"]?.hasSuffix("bytes") == true, "the rendered JPEG")
    }

    @Test func anEditedPhotoIsReplacedAndItsDetailsUpdated() async throws {
        let directory = try TemporaryDirectory()
        let flickr = FakeFlickr()
        let earlier = RemotePhoto(id: "52419583421", url: nil)
        let remote = try await publisher(flickr).publish(item(directory, remote: earlier))
        #expect(remote.id == "52419583421" && remote.url != nil)
        #expect(flickr.calls.map(\.what) == ["replace", "flickr.photos.setMeta", "flickr.photos.setTags"])
        #expect(flickr.calls[0].fields["photo_id"] == "52419583421")
        #expect(flickr.calls[1].fields["title"] == "Harbour" && flickr.calls[1].fields["description"] == "Morning light on the water")
        #expect(flickr.calls[0].fields["is_public"] == nil, "privacy isn't changed after the first upload")
    }

    @Test func aMetadataChangeOnlyUpdatesTheDetails() async throws {
        let directory = try TemporaryDirectory()
        let flickr = FakeFlickr()
        _ = try await publisher(flickr) { $0.titleUpdate = .keep }
            .publish(item(directory, remote: RemotePhoto(id: "1", url: nil), hasEdits: false))
        #expect(flickr.calls.map(\.what) == ["flickr.photos.setMeta", "flickr.photos.setTags"])
        #expect(flickr.calls[0].fields["title"] == nil, "Leave Existing Title keeps Flickr's")
    }

    @Test func removingDeletesFromFlickrAndAPhotoAlreadyGoneIsFine() async throws {
        let flickr = FakeFlickr()
        try await publisher(flickr).remove(RemotePhoto(id: "7", url: nil))
        #expect(flickr.calls.map(\.what) == ["flickr.photos.delete"])
        #expect(flickr.calls[0].fields["photo_id"] == "7")

        let gone = FakeFlickr { _, _ in .init(status: 200, body: #"{"stat":"fail","code":1,"message":"Photo \"7\" not found (invalid ID)"}"#) }
        try await publisher(gone).remove(RemotePhoto(id: "7", url: nil))
    }

    @Test func busyFlickrIsRetriedWithBackoff() async throws {
        let attempts = Mutex(0)
        let flickr = FakeFlickr { _, _ in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            return attempt < 3 ? .init(status: 503, body: "") : .init(status: 200, body: #"{"stat":"ok"}"#)
        }
        try await flickr.api.call("flickr.test.login", [:])
        #expect(flickr.delays.values.withLock { $0 } == [2, 5])

        let throttled = FakeFlickr { _, _ in .init(status: 429, body: "", headers: ["Retry-After": "30"]) }
        await #expect(throws: FlickrAPI.APIError.self) { try await throttled.api.call("flickr.test.login", [:]) }
        #expect(throttled.delays.values.withLock { $0 } == [30, 30, 30], "Retry-After is respected")
    }

    @Test func flickrsErrorsAreRead() throws {
        #expect(throws: FlickrAPI.APIError.notAuthorized) {
            try FlickrAPI.photoID(fromUploadResponse: Data(#"<rsp stat="fail"><err code="98" msg="Invalid auth token" /></rsp>"#.utf8))
        }
        #expect(throws: FlickrAPI.APIError.failed(code: 5, message: "Filetype was not recognised")) {
            try FlickrAPI.photoID(fromUploadResponse: Data(#"<rsp stat="fail"><err code="5" msg="Filetype was not recognised" /></rsp>"#.utf8))
        }
    }

    @Test func aRevokedSignInStopsPublishOnce() async throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.create(at: directory.url.appending(path: "C.pixelloupe", directoryHint: .isDirectory), info: Fixtures.referencedInfo)
        let service = PublishService.make(.flickr, in: store.viewContext)
        let photos = try (0..<5).map { index in
            let url = try Fixtures.writeJPEG(to: directory.url.appending(path: "IMG_\(index).JPG"))
            let photo = Photo(context: store.viewContext)
            photo.id = UUID(); photo.fileName = url.lastPathComponent; photo.filePath = url.path(percentEncoded: false); photo.fileType = "JPG"
            photo.captureDate = .now; photo.importDate = .now; photo.editDate = Date(timeIntervalSince1970: 0)
            return photo
        }
        service.add(photos)
        store.save()
        let flickr = FakeFlickr { _, _ in .init(status: 200, body: #"<rsp stat="fail"><err code="98" msg="Invalid auth token" /></rsp>"#) }
        let result = await PublishRun.run(service, store: store, publisher: FlickrPublisher(api: flickr.api, settings: service.settings, watermark: nil))
        #expect(result.stopReason == FlickrAPI.APIError.notAuthorized.errorDescription)
        #expect(result.failures.isEmpty, "said once, not for every photo")
        #expect(flickr.calls.count <= PublishService.Kind.flickr.concurrency, "no photo is started after it")
        #expect(CatalogWindowController.publishSummary(result, service: "Flickr").messageText == "Publishing to Flickr stopped.")
    }

    @Test func albumsAreMadeFilledRenamedAndDeleted() async throws {
        let flickr = FakeFlickr { what, _ in
            what == "flickr.photosets.create"
                ? .init(status: 200, body: #"{"photoset":{"id":"72157720000000001","url":"https://www.flickr.com/photos/x/albums/72157720000000001"},"stat":"ok"}"#)
                : .init(status: 200, body: #"{"stat":"ok"}"#)
        }
        let publisher = publisher(flickr)
        let id = try await publisher.createAlbum(title: "Harbour", description: "Boats", coverID: "1")
        #expect(id == "72157720000000001")
        try await publisher.setAlbumPhotos(id, photoIDs: ["1", "2", "3"])
        try await publisher.editAlbum(id, title: "Harbours", description: "")
        try await publisher.deleteAlbum(id)
        #expect(flickr.calls.map(\.what) == ["flickr.photosets.create", "flickr.photosets.editPhotos", "flickr.photosets.editMeta", "flickr.photosets.delete"])
        #expect(flickr.calls[0].fields["title"] == "Harbour" && flickr.calls[0].fields["description"] == "Boats" && flickr.calls[0].fields["primary_photo_id"] == "1")
        #expect(flickr.calls[1].fields["photo_ids"] == "1,2,3" && flickr.calls[1].fields["primary_photo_id"] == "1")
        #expect(flickr.calls[2].fields["title"] == "Harbours" && flickr.calls[2].fields["photoset_id"] == id)

        let gone = FakeFlickr { _, _ in .init(status: 200, body: #"{"stat":"fail","code":1,"message":"Photoset not found"}"#) }
        try await self.publisher(gone).deleteAlbum("7")
    }

    @Test func aServiceWithoutASignInCantPublish() async throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let service = PublishService.make(.flickr, in: store.viewContext)
        let credentials = MemoryFlickrCredentialStore()
        let publisher = service.publisher(credentials: credentials)
        guard Secrets.hasFlickr else {
            #expect(publisher is UnavailablePublisher)
            return
        }
        await #expect(throws: UnavailablePublisher.StoppingUnavailable.self) { try await publisher.remove(RemotePhoto(id: "1", url: nil)) }
        try credentials.save(FakeFlickr().account, for: service.id)
        var settings = service.settings
        settings.export.format = .png
        service.settings = settings
        let flickr = try #require(service.publisher(credentials: credentials) as? FlickrPublisher)
        #expect(flickr.settings.export.format == .jpeg, "Flickr is always sent JPEGs")
        #expect(flickr.api.credentials.userID == "88581768@N00")
    }
}
