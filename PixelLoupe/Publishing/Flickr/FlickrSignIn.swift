import AppKit
import AuthenticationServices

/// Signs in to Flickr: asks Flickr for a request token, shows its approval page in a web
/// authentication session over `window`, and trades the approval for the account's access token.
@MainActor
final class FlickrSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: NSWindow
    private let client: FlickrAuthClient
    /// Kept while the approval page is up.
    private var session: ASWebAuthenticationSession?

    init(window: NSWindow, client: FlickrAuthClient = FlickrAuthClient()) {
        self.window = window
        self.client = client
    }

    /// The signed-in account. `anotherAccount` starts without flickr.com's cookies, so a different
    /// account can sign in. Throws `CancellationError` if the person closes the page.
    func signIn(anotherAccount: Bool = false) async throws -> FlickrCredentials {
        let request = try await client.requestToken()
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: client.authorizationURL(token: request.token), callback: .customScheme(FlickrAuthClient.callbackScheme),
                completionHandler: Self.completionHandler(resuming: continuation)
            )
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = anotherAccount
            self.session = session
            session.start()
        }
        session = nil
        let verifier = try FlickrAuthClient.verifier(from: callback, token: request.token)
        return try await client.accessToken(token: request.token, secret: request.secret, verifier: verifier)
    }

    /// The session's completion handler, resuming the sign-in with the URL Flickr sent the browser back to.
    ///
    /// Made outside the main actor on purpose: the session calls it on an XPC queue, and a closure written in
    /// this main-actor class would be checked to run on the main queue, which crashes the app.
    nonisolated static func completionHandler(resuming continuation: CheckedContinuation<URL, Error>)
        -> @Sendable (URL?, Error?) -> Void {
        { @Sendable url, error in
            if let url {
                continuation.resume(returning: url)
            } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: error ?? FlickrError.unexpectedResponse)
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { window }
    }
}
