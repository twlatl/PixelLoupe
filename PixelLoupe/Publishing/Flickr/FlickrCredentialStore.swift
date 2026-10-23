import Foundation
import Security

/// Where Flickr services keep their accounts' credentials, by service ID.
protocol FlickrCredentialStore: AnyObject {
    func credentials(for serviceID: UUID) -> FlickrCredentials?
    func save(_ credentials: FlickrCredentials, for serviceID: UUID) throws
    func remove(for serviceID: UUID)
}

/// The login Keychain: one generic password per service, its credentials as JSON.
final class KeychainFlickrCredentialStore: FlickrCredentialStore {
    static let shared = KeychainFlickrCredentialStore()

    struct KeychainError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            "The Flickr sign-in couldn’t be saved in the Keychain (\(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"))."
        }
    }

    private let service: String

    init(service: String = "net.pixegen.PixelLoupe.Flickr") {
        self.service = service
    }

    private func query(_ serviceID: UUID) -> [CFString: Any] {
        // The login keychain: the data protection keychain needs an access group entitlement that
        // ad-hoc signed builds (CI's) don't have.
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: serviceID.uuidString]
    }

    func credentials(for serviceID: UUID) -> FlickrCredentials? {
        var query = query(serviceID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(FlickrCredentials.self, from: data)
    }

    func save(_ credentials: FlickrCredentials, for serviceID: UUID) throws {
        let data = try JSONEncoder().encode(credentials)
        let status = SecItemUpdate(query(serviceID) as CFDictionary, [kSecValueData: data] as CFDictionary)
        guard status == errSecItemNotFound else {
            if status != errSecSuccess { throw KeychainError(status: status) }
            return
        }
        var add = query(serviceID)
        add[kSecValueData] = data
        add[kSecAttrLabel] = "PixelLoupe Flickr (\(credentials.username))"
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(add as CFDictionary, nil)
        if added != errSecSuccess { throw KeychainError(status: added) }
    }

    func remove(for serviceID: UUID) {
        SecItemDelete(query(serviceID) as CFDictionary)
    }
}
