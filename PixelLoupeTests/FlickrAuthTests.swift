import AppKit
import AuthenticationServices
import CoreData
import Foundation
import Synchronization
import Testing
@testable import PixelLoupe

/// Keeps Flickr sign-ins in memory, so tests never touch the Keychain.
final class MemoryFlickrCredentialStore: FlickrCredentialStore {
    var stored: [UUID: FlickrCredentials] = [:]

    func credentials(for serviceID: UUID) -> FlickrCredentials? { stored[serviceID] }
    func save(_ credentials: FlickrCredentials, for serviceID: UUID) throws { stored[serviceID] = credentials }
    func remove(for serviceID: UUID) { stored[serviceID] = nil }
}

/// Answers requests instead of the network, and records them. Each session gets its own `Table`, tied to it
/// by a header, so suites running at once don't see each other's requests.
nonisolated final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    final class Table: Sendable {
        /// Answers a request (with its body); by default from `responses`, by URL path.
        let handler = Mutex<(@Sendable (URLRequest, Data) -> Response)?>(nil)
        let responses = Mutex<[String: Response]>([:])
        let requests = Mutex<[(request: URLRequest, body: Data)]>([])

        func respond(_ path: String, _ status: Int, _ body: String) {
            responses.withLock { $0[path] = Response(status: status, body: body) }
        }
    }

    private static let tables = Mutex<[String: Table]>([:])
    private static let tableHeader = "X-Stub-Table"

    /// A session whose requests `table` answers.
    static func session(_ table: Table = Table()) -> URLSession {
        let id = UUID().uuidString
        tables.withLock { $0[id] = table }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [tableHeader: id]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let table = request.value(forHTTPHeaderField: Self.tableHeader).flatMap { id in Self.tables.withLock { $0[id] } }
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        table?.requests.withLock { $0.append((request, body)) }
        let response = table?.handler.withLock { $0 }?(request, body)
            ?? table?.responses.withLock { $0[request.url?.path() ?? ""] }
            ?? Response(status: 404, body: "")
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite("OAuth 1.0a signing")
struct OAuth1SignerTests {
    /// Flickr's example request (https://www.flickr.com/services/api/auth.oauth.html).
    private let parameters = [
        "oauth_nonce": "95613465", "oauth_timestamp": "1305586162", "oauth_consumer_key": "653e7a6ecc1d528c516cc8f92cf98611",
        "oauth_signature_method": "HMAC-SHA1", "oauth_version": "1.0", "oauth_callback": "http://www.example.com",
    ]

    @Test func theBaseStringIsFlickrsExample() {
        let base = OAuth1Signer.baseString(method: "GET", url: FlickrAuthClient.requestTokenURL, parameters: parameters)
        #expect(base == "GET&https%3A%2F%2Fwww.flickr.com%2Fservices%2Foauth%2Frequest_token"
            + "&oauth_callback%3Dhttp%253A%252F%252Fwww.example.com%26oauth_consumer_key%3D653e7a6ecc1d528c516cc8f92cf98611"
            + "%26oauth_nonce%3D95613465%26oauth_signature_method%3DHMAC-SHA1%26oauth_timestamp%3D1305586162%26oauth_version%3D1.0")
    }

    /// Expected values from `openssl dgst -sha1 -hmac <key> -binary | base64` over Flickr's base string (the
    /// page doesn't give the secret behind its own signature).
    @Test func signaturesMatchOpenSSLs() {
        let signer = OAuth1Signer(consumerKey: "653e7a6ecc1d528c516cc8f92cf98611", consumerSecret: "test-consumer-secret")
        let base = OAuth1Signer.baseString(method: "GET", url: FlickrAuthClient.requestTokenURL, parameters: parameters)
        #expect(signer.signature(of: base, tokenSecret: nil) == "c2G66NOg3zxBye4dDl6tHPecclM=")
        #expect(signer.signature(of: base, tokenSecret: "token-secret") == "OtH1deyhsxu2cAaeAMSiD3hsH48=")
    }

    @Test func signingAddsOAuthsParameters() {
        let signer = OAuth1Signer(consumerKey: "653e7a6ecc1d528c516cc8f92cf98611", consumerSecret: "test-consumer-secret")
        let signed = signer.sign(url: FlickrAuthClient.requestTokenURL, parameters: ["oauth_callback": "http://www.example.com"],
                                 nonce: "95613465", timestamp: 1305586162)
        #expect(signed["oauth_signature"] == "c2G66NOg3zxBye4dDl6tHPecclM=")
        #expect(signed["oauth_token"] == nil)
        let withToken = signer.sign(url: FlickrAuthClient.requestTokenURL, token: "t", tokenSecret: "s")
        #expect(withToken["oauth_token"] == "t" && withToken["oauth_signature"] != nil)
    }

    @Test func percentEncodingIsRFC3986s() {
        #expect(OAuth1Signer.percentEncode("Ladies + Gentlemen, a signed request!~-._") == "Ladies%20%2B%20Gentlemen%2C%20a%20signed%20request%21~-._")
        #expect(OAuth1Signer.percentEncode("é") == "%C3%A9")
        #expect(OAuth1Signer.formFields(Data("fullname=Jamal%20Fanaian&user_nsid=21207597%40N07&empty=".utf8))
            == ["fullname": "Jamal Fanaian", "user_nsid": "21207597@N07", "empty": ""])
    }
}

@Suite("Flickr sign-in")
struct FlickrAuthClientTests {
    private let table = StubURLProtocol.Table()
    private var client: FlickrAuthClient {
        FlickrAuthClient(signer: OAuth1Signer(consumerKey: "key", consumerSecret: "secret"), session: StubURLProtocol.session(table))
    }

    private func respond(_ path: String, _ status: Int, _ body: String) {
        table.respond(path, status, body)
    }

    private func lastQuery() -> [String: String] {
        let url = table.requests.withLock { $0.last?.request.url }
        return Dictionary(uniqueKeysWithValues: (URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func theRequestTokenAsksToComeBackToPixelLoupe() async throws {
        respond("/services/oauth/request_token", 200, "oauth_callback_confirmed=true&oauth_token=72157626737672178-022bbd2f4c2f3432&oauth_token_secret=fccb68c4e6103197")
        let token = try await client.requestToken()
        #expect(token.token == "72157626737672178-022bbd2f4c2f3432" && token.secret == "fccb68c4e6103197")
        let query = lastQuery()
        #expect(query["oauth_callback"] == "pixelloupe://flickr-auth")
        #expect(query["oauth_consumer_key"] == "key" && query["oauth_signature"] != nil)
    }

    @Test func flickrsRefusalsSayWhy() async throws {
        respond("/services/oauth/request_token", 401, "oauth_problem=signature_invalid&debug_sbs=GET")
        await #expect(throws: FlickrError.refused("signature_invalid")) { try await client.requestToken() }
        let unconfigured = FlickrAuthClient(signer: OAuth1Signer(consumerKey: "", consumerSecret: ""), session: StubURLProtocol.session())
        await #expect(throws: FlickrError.notConfigured) { try await unconfigured.requestToken() }
    }

    @Test func theApprovalPageAsksToDelete() {
        let url = client.authorizationURL(token: "abc")
        #expect(url.absoluteString == "https://www.flickr.com/services/oauth/authorize?oauth_token=abc&perms=delete")
    }

    @Test func theCallbackGivesTheVerifierForItsToken() throws {
        let callback = URL(string: "pixelloupe://flickr-auth?oauth_token=abc&oauth_verifier=5d1b96a26b494074")!
        #expect(try FlickrAuthClient.verifier(from: callback, token: "abc") == "5d1b96a26b494074")
        #expect(throws: FlickrError.unexpectedResponse) { try FlickrAuthClient.verifier(from: callback, token: "other") }
    }

    @Test func theAccessTokenIsTheAccount() async throws {
        respond("/services/oauth/access_token", 200,
                "fullname=Jamal%20Fanaian&oauth_token=72157626318069415-087bfc7b5816092c&oauth_token_secret=a202d1f853ec69de&user_nsid=21207597%40N07&username=jamalfanaian")
        let account = try await client.accessToken(token: "request", secret: "request-secret", verifier: "5d1b96a26b494074")
        #expect(account == FlickrCredentials(userID: "21207597@N07", username: "jamalfanaian", fullName: "Jamal Fanaian",
                                             token: "72157626318069415-087bfc7b5816092c", tokenSecret: "a202d1f853ec69de"))
        #expect(account.displayName == "Jamal Fanaian")
        let query = lastQuery()
        #expect(query["oauth_token"] == "request" && query["oauth_verifier"] == "5d1b96a26b494074")
    }
}

@Suite("Flickr sign-in session")
struct FlickrSignInSessionTests {
    /// What the handler resumes the sign-in with when the session calls it from another queue, as
    /// AuthenticationServices does (an XPC queue): it must not assume the main actor.
    private func outcome(_ url: URL?, _ error: Error?) async -> Result<URL, Error> {
        do {
            return .success(try await withCheckedThrowingContinuation { continuation in
                let handler = FlickrSignIn.completionHandler(resuming: continuation)
                DispatchQueue.global().async { handler(url, error) }
            })
        } catch {
            return .failure(error)
        }
    }

    @Test func theHandlerRunsOffTheMainThread() async throws {
        let callback = URL(string: "pixelloupe://flickr-auth?oauth_token=a&oauth_verifier=b")!
        #expect(try await outcome(callback, nil).get() == callback)
        let cancelled = ASWebAuthenticationSessionError(.canceledLogin)
        await #expect(throws: CancellationError.self) { try await outcome(nil, cancelled).get() }
        await #expect(throws: FlickrError.unexpectedResponse) { try await outcome(nil, nil).get() }
    }
}

@Suite("Flickr account in the Publishing Manager")
@MainActor
struct FlickrAccountTests {
    private let account = FlickrCredentials(userID: "88581768@N00", username: "TheodoreWLee", fullName: "Theodore Lee", token: "t", tokenSecret: "s")

    private struct Setup {
        let directory: TemporaryDirectory
        let store: CatalogStore
        let credentials = MemoryFlickrCredentialStore()

        init() throws {
            directory = try TemporaryDirectory()
            store = try CatalogStore.create(at: directory.url.appending(path: "C.pixelloupe", directoryHint: .isDirectory), info: Fixtures.referencedInfo)
        }

        func controller(signingInAs account: FlickrCredentials?) -> PublishingManagerWindowController {
            let controller = PublishingManagerWindowController(model: PublishingManagerModel(context: store.viewContext, credentials: credentials),
                                                               watermarks: WatermarkPresets(directory: directory.url.appending(path: "Watermarks")))
            controller.canSignIn = true
            controller.signIn = { _, _ in
                guard let account else { throw CancellationError() }
                return account
            }
            return controller
        }
    }

    /// Lets the sign-in task finish.
    private func settle(_ controller: PublishingManagerWindowController) async {
        for _ in 0..<20 where controller.signingIn != nil { await Task.yield() }
        await Task.yield()
    }

    @Test func authorizingSignsInAndSaveKeepsIt() async throws {
        let setup = try Setup()
        let controller = setup.controller(signingInAs: account)
        controller.add(.flickr)
        #expect(controller.authorizeButton.isEnabled && !controller.removeAuthorizationButton.isEnabled)
        controller.authorize(nil)
        await settle(controller)
        #expect(controller.accountLabel.stringValue == "Authorized as Theodore Lee")
        #expect(!controller.authorizeButton.isEnabled && controller.changeAccountButton.isEnabled && controller.removeAuthorizationButton.isEnabled)
        #expect(setup.credentials.stored.isEmpty, "nothing is kept before Save")
        controller.save(nil)
        let service = try #require(PublishService.all(in: setup.store.viewContext).first)
        #expect(service.accountName == "Theodore Lee")
        #expect(setup.credentials.stored[service.id] == account)
    }

    @Test func closingFlickrsPageChangesNothing() async throws {
        let setup = try Setup()
        let controller = setup.controller(signingInAs: nil)
        controller.add(.flickr)
        controller.authorize(nil)
        await settle(controller)
        #expect(controller.authorizeButton.isEnabled)
        #expect(controller.model.drafts[0].accountName == nil && controller.model.signIns.isEmpty)
    }

    @Test func removingAuthorizationOrTheServiceForgetsTheSignIn() throws {
        let setup = try Setup()
        let service = PublishService.make(.flickr, in: setup.store.viewContext)
        service.accountName = "Theodore Lee"
        setup.store.save()
        try setup.credentials.save(account, for: service.id)

        let controller = setup.controller(signingInAs: account)
        controller.removeAuthorization(nil)
        #expect(controller.accountLabel.stringValue.hasPrefix("Not signed in"))
        #expect(setup.credentials.stored[service.id] != nil, "kept until Save")
        controller.save(nil)
        #expect(service.accountName == nil && setup.credentials.stored[service.id] == nil)

        try setup.credentials.save(account, for: service.id)
        let model = PublishingManagerModel(context: setup.store.viewContext, credentials: setup.credentials)
        model.remove(at: 0)
        try model.save()
        #expect(setup.credentials.stored.isEmpty)
    }

    @Test func anAccountWithPublishedPhotosCantChange() throws {
        let setup = try Setup()
        let context = setup.store.viewContext
        let service = PublishService.make(.flickr, in: context)
        service.accountName = "Theodore Lee"
        let photo = Photo(context: context)
        photo.id = UUID(); photo.fileName = "A.jpg"; photo.captureDate = .now; photo.importDate = .now; photo.editDate = .now
        service.add([photo])
        service.entry(for: photo)?.publishedDate = .now
        setup.store.save()
        let controller = setup.controller(signingInAs: account)
        #expect(!controller.changeAccountButton.isEnabled && controller.changeAccountButton.toolTip != nil)
        #expect(controller.removeAuthorizationButton.isEnabled)
    }

    @Test func aBuildWithoutAKeyCantSignIn() throws {
        let setup = try Setup()
        let controller = setup.controller(signingInAs: account)
        controller.canSignIn = false
        controller.add(.flickr)
        #expect(!controller.authorizeButton.isEnabled)
        #expect(controller.accountLabel.stringValue == "This copy of PixelLoupe can’t sign in to Flickr.")
    }
}
