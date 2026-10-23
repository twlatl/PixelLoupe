import CryptoKit
import Foundation

/// Signs requests with OAuth 1.0a's HMAC-SHA1 (RFC 5849), which every Flickr API call needs. The
/// signature covers the method, the URL without its query, and every parameter, OAuth's included.
nonisolated struct OAuth1Signer: Sendable {
    let consumerKey: String
    let consumerSecret: String

    /// RFC 3986 percent-encoding: everything but letters, digits and `-._~`.
    static func percentEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(.init(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    /// `METHOD&url&parameters`, each part percent-encoded, the parameters sorted by name then value.
    static func baseString(method: String, url: URL, parameters: [String: String]) -> String {
        var base = url.absoluteString
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let (scheme, host) = (components.scheme?.lowercased(), components.host?.lowercased())
            components.query = nil
            components.fragment = nil
            components.scheme = scheme
            components.host = host
            base = components.string ?? base
        }
        let encoded: [(name: String, value: String)] = parameters.map { (percentEncode($0.key), percentEncode($0.value)) }
        let sorted = encoded.sorted { $0.name == $1.name ? $0.value < $1.value : $0.name < $1.name }
        let normalized = sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
        return [method.uppercased(), percentEncode(base), percentEncode(normalized)].joined(separator: "&")
    }

    /// The base64 HMAC-SHA1 of the base string, keyed with the consumer secret and the token secret.
    func signature(of baseString: String, tokenSecret: String?) -> String {
        let key = SymmetricKey(data: Data("\(Self.percentEncode(consumerSecret))&\(Self.percentEncode(tokenSecret ?? ""))".utf8))
        let code = HMAC<Insecure.SHA1>.authenticationCode(for: Data(baseString.utf8), using: key)
        return Data(code).base64EncodedString()
    }

    /// `parameters` with OAuth's added and signed, to send in the query (or the form, for uploads).
    func sign(method: String = "GET", url: URL, parameters: [String: String] = [:], token: String? = nil, tokenSecret: String? = nil,
              nonce: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
              timestamp: Int = Int(Date().timeIntervalSince1970)) -> [String: String] {
        var signed = parameters
        signed["oauth_consumer_key"] = consumerKey
        signed["oauth_nonce"] = nonce
        signed["oauth_signature_method"] = "HMAC-SHA1"
        signed["oauth_timestamp"] = String(timestamp)
        signed["oauth_version"] = "1.0"
        if let token { signed["oauth_token"] = token }
        signed["oauth_signature"] = signature(of: Self.baseString(method: method, url: url, parameters: signed), tokenSecret: tokenSecret)
        return signed
    }

    /// `url` with `parameters` as its percent-encoded query.
    static func url(_ url: URL, query parameters: [String: String]) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = parameters.sorted { $0.key < $1.key }
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")
        return components.url!
    }

    /// The fields of a form-encoded response (`a=1&b=two`).
    static func formFields(_ data: Data) -> [String: String] {
        let text = String(decoding: data, as: UTF8.self)
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let name = parts.first?.removingPercentEncoding else { continue }
            fields[name] = parts.count > 1 ? (parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? parts[1]) : ""
        }
        return fields
    }
}
