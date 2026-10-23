import Foundation

/// A Flickr account a publish service is signed in to: who it is, and the access token its requests are
/// signed with. Kept in the Keychain (``FlickrCredentialStore``), never in the catalog.
nonisolated struct FlickrCredentials: Codable, Equatable, Sendable {
    /// Flickr's ID for the account ("88581768@N00").
    var userID: String
    var username: String
    var fullName: String
    var token: String
    var tokenSecret: String

    /// How the account is shown: its full name, else its username.
    var displayName: String { fullName.isEmpty ? username : fullName }
}

nonisolated enum FlickrError: LocalizedError, Equatable {
    /// This build has no Flickr API key (see Scripts/generate-secrets.sh).
    case notConfigured
    /// Flickr refused, with its reason ("signature_invalid", "token_rejected"…).
    case refused(String)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: "This copy of PixelLoupe can’t sign in to Flickr."
        case .refused(let problem): "Flickr refused the request (\(problem.replacingOccurrences(of: "_", with: " ")))."
        case .unexpectedResponse: "Flickr sent an unexpected response."
        }
    }
}

/// Flickr's OAuth 1.0a sign-in: a request token, the person's approval on flickr.com, then the access
/// token (https://www.flickr.com/services/api/auth.oauth.html). The approval in between is the caller's
/// (``FlickrSignIn`` shows it in a web authentication session).
nonisolated struct FlickrAuthClient: Sendable {
    static let requestTokenURL = URL(string: "https://www.flickr.com/services/oauth/request_token")!
    static let authorizeURL = URL(string: "https://www.flickr.com/services/oauth/authorize")!
    static let accessTokenURL = URL(string: "https://www.flickr.com/services/oauth/access_token")!
    /// Where Flickr sends the browser back once the person approves.
    static let callbackScheme = "pixelloupe"
    static let callbackURL = URL(string: "\(callbackScheme)://flickr-auth")!

    let signer: OAuth1Signer
    let session: URLSession

    init(signer: OAuth1Signer = OAuth1Signer(consumerKey: Secrets.flickrKey, consumerSecret: Secrets.flickrSecret),
         session: URLSession = .shared) {
        self.signer = signer
        self.session = session
    }

    /// A temporary token to ask the person's approval with.
    func requestToken() async throws -> (token: String, secret: String) {
        let fields = try await get(Self.requestTokenURL, ["oauth_callback": Self.callbackURL.absoluteString], tokenSecret: nil)
        guard fields["oauth_callback_confirmed"] == "true", let token = fields["oauth_token"], let secret = fields["oauth_token_secret"]
        else { throw FlickrError.unexpectedResponse }
        return (token, secret)
    }

    /// The flickr.com page where the person approves PixelLoupe. It asks to delete as well as upload, so
    /// photos taken out of a service can be removed from Flickr.
    func authorizationURL(token: String) -> URL {
        OAuth1Signer.url(Self.authorizeURL, query: ["oauth_token": token, "perms": "delete"])
    }

    /// The approval's token and verifier, from the URL Flickr sent the browser back to.
    static func verifier(from callback: URL, token: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard value("oauth_token") == token, let verifier = value("oauth_verifier") else {
            throw value("oauth_problem").map(FlickrError.refused) ?? FlickrError.unexpectedResponse
        }
        return verifier
    }

    /// The account's access token, for the approved request token.
    func accessToken(token: String, secret: String, verifier: String) async throws -> FlickrCredentials {
        let fields = try await get(Self.accessTokenURL, ["oauth_token": token, "oauth_verifier": verifier], tokenSecret: secret)
        guard let accessToken = fields["oauth_token"], let accessSecret = fields["oauth_token_secret"], let userID = fields["user_nsid"]
        else { throw FlickrError.unexpectedResponse }
        return FlickrCredentials(userID: userID, username: fields["username"] ?? userID, fullName: fields["fullname"] ?? "",
                                 token: accessToken, tokenSecret: accessSecret)
    }

    private func get(_ url: URL, _ parameters: [String: String], tokenSecret: String?) async throws -> [String: String] {
        guard !signer.consumerKey.isEmpty, !signer.consumerSecret.isEmpty else { throw FlickrError.notConfigured }
        let signed = signer.sign(url: url, parameters: parameters, tokenSecret: tokenSecret)
        let (data, response) = try await session.data(from: OAuth1Signer.url(url, query: signed))
        let fields = OAuth1Signer.formFields(data)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw fields["oauth_problem"].map(FlickrError.refused) ?? FlickrError.unexpectedResponse
        }
        return fields
    }
}
