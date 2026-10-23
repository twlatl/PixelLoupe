import Foundation

/// An error that means nothing more can be published to the service until the person acts (signs in
/// again): Publish stops instead of failing every remaining photo the same way.
nonisolated protocol PublishStoppingError: Error {}

/// Flickr's API for a signed-in account: REST methods, uploads and replacements, each signed with the
/// account's token. Busy and failing responses (HTTP 429 and 5xx, timeouts) are retried with backoff.
nonisolated struct FlickrAPI: Sendable {
    static let restURL = URL(string: "https://api.flickr.com/services/rest/")!
    static let uploadURL = URL(string: "https://up.flickr.com/services/upload/")!
    static let replaceURL = URL(string: "https://up.flickr.com/services/replace/")!

    /// Flickr's own error codes (https://www.flickr.com/services/api/).
    nonisolated enum APIError: LocalizedError, Equatable, PublishStoppingError {
        /// The account's sign-in was revoked or has lost its permissions (codes 98 and 99).
        case notAuthorized
        /// The photo isn't on Flickr (code 1 for most photo methods).
        case photoNotFound
        case failed(code: Int, message: String)
        case unexpectedResponse

        var errorDescription: String? {
            switch self {
            case .notAuthorized: "Flickr no longer accepts PixelLoupe’s sign-in. Authorize again in the Publishing Manager."
            case .photoNotFound: "The photo isn’t on Flickr any more."
            case .failed(_, let message): "Flickr: \(message)"
            case .unexpectedResponse: "Flickr sent an unexpected response."
            }
        }

        init(code: Int, message: String) {
            self = switch code {
            case 98, 99: .notAuthorized
            case 1 where message.localizedCaseInsensitiveContains("not found"): .photoNotFound
            default: .failed(code: code, message: message)
            }
        }
    }

    let signer: OAuth1Signer
    let credentials: FlickrCredentials
    let session: URLSession
    /// How long to wait before each retry, in seconds; the last failure is thrown after them.
    var retryDelays: [Double] = [2, 5, 15]
    /// Waits between retries (tests don't).
    var sleep: @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }

    init(credentials: FlickrCredentials, session: URLSession = .shared,
         signer: OAuth1Signer = OAuth1Signer(consumerKey: Secrets.flickrKey, consumerSecret: Secrets.flickrSecret)) {
        self.credentials = credentials
        self.session = session
        self.signer = signer
    }

    // MARK: - REST

    /// Calls a REST method (`flickr.photos.setMeta`…) and returns its JSON.
    @discardableResult
    func call(_ method: String, _ parameters: [String: String]) async throws -> [String: Any] {
        var parameters = parameters
        parameters["method"] = method
        parameters["format"] = "json"
        parameters["nojsoncallback"] = "1"
        let data = try await send {
            let signed = signer.sign(method: "POST", url: Self.restURL, parameters: parameters,
                                     token: credentials.token, tokenSecret: credentials.tokenSecret)
            var request = URLRequest(url: Self.restURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(OAuth1Signer.url(Self.restURL, query: signed).query(percentEncoded: true)!.utf8)
            return request
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.unexpectedResponse }
        guard json["stat"] as? String == "ok" else {
            throw APIError(code: json["code"] as? Int ?? 0, message: json["message"] as? String ?? "Unknown error")
        }
        return json
    }

    // MARK: - Uploading

    /// Uploads a photo file with its title, description, tags and privacy, and returns its photo ID.
    func upload(_ file: URL, _ parameters: [String: String]) async throws -> String {
        try await post(file, to: Self.uploadURL, parameters)
    }

    /// Replaces a photo's file, keeping its ID, page, comments and favourites.
    func replace(_ photoID: String, with file: URL) async throws {
        _ = try await post(file, to: Self.replaceURL, ["photo_id": photoID])
    }

    /// Posts a file as `photo` in a multipart form; every other field is signed (the file isn't).
    private func post(_ file: URL, to url: URL, _ parameters: [String: String]) async throws -> String {
        let photo = try Data(contentsOf: file)
        let data = try await send {
            let signed = signer.sign(method: "POST", url: url, parameters: parameters, token: credentials.token, tokenSecret: credentials.tokenSecret)
            let boundary = "PixelLoupe-\(UUID().uuidString)"
            var body = Data()
            for (name, value) in signed.sorted(by: { $0.key < $1.key }) {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"\(file.lastPathComponent)\"\r\n".utf8))
            body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
            body.append(photo)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = 300
            return request
        }
        return try Self.photoID(fromUploadResponse: data)
    }

    /// The photo ID in an upload or replace response (`<rsp stat="ok"><photoid>123</photoid></rsp>`), or
    /// its error (`<rsp stat="fail"><err code="98" msg="Invalid auth token"/></rsp>`).
    static func photoID(fromUploadResponse data: Data) throws -> String {
        let text = String(decoding: data, as: UTF8.self)
        if let match = text.firstMatch(of: /<photoid[^>]*>\s*([0-9]+)\s*<\/photoid>/) { return String(match.1) }
        if let error = text.firstMatch(of: /<err\s+code="([0-9]+)"\s+msg="([^"]*)"/) {
            throw APIError(code: Int(error.1) ?? 0, message: String(error.2))
        }
        throw APIError.unexpectedResponse
    }

    // MARK: - Sending

    /// Sends a request (made afresh each time, so each try has its own nonce), retrying when Flickr is busy
    /// or failing, and returns the body of a successful response.
    private func send(_ makeRequest: () -> URLRequest) async throws -> Data {
        var delays = retryDelays.makeIterator()
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: makeRequest())
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 || status == 403 { throw APIError.notAuthorized }
                guard status == 429 || status >= 500 else {
                    guard (200..<300).contains(status) else { throw APIError.failed(code: status, message: "HTTP \(status)") }
                    return data
                }
                let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                guard let delay = delays.next() else { throw APIError.failed(code: status, message: "Flickr is busy (HTTP \(status)). Try again later.") }
                try await sleep(max(delay, retryAfter ?? 0))
            } catch let error as URLError where [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) {
                guard let delay = delays.next() else { throw error }
                try await sleep(delay)
            }
        }
    }
}
