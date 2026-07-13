import CollaborationKit
import Foundation
import os
import Security

/// A Keychain-backed ``CredentialStore`` for CollaborationKit credentials.
///
/// This is the default persistence CollaborationKitUI uses. Values are stored
/// as generic passwords under a caller-configurable service string, so a host
/// application can partition its Keychain namespace from other tools that also
/// use CollaborationKit.
///
/// Since ``CredentialStore``'s API is a plain key/value surface, this store
/// works for the three built-in ``Backend`` slots (``CredentialStore/StandardKey``)
/// and for any custom backend that reads or writes its own key strings — no
/// widening of this type required.
public struct KeychainCredentialStore: CredentialStore, Sendable {
    /// The Keychain `kSecAttrService` string. Defaults to
    /// `"io.collaborationkit.credentials"`; override to partition per app.
    public let service: String

    private static let logger = Logger(subsystem: "io.collaborationkit.ui", category: "keychain")

    public init(service: String = "io.collaborationkit.credentials") {
        self.service = service
    }

    /// Standard account names used by ``KeychainCredentialStore``.
    ///
    /// Retained for source compatibility with pre-refactor code. New code
    /// should use ``CredentialStoreKey`` (the values are the same).
    public enum Account {
        public static let anthropicAPIKey = CredentialStoreKey.anthropicAPIKey
        /// JSON-encoded ``OAuthCredentials`` for a Claude subscription login.
        public static let anthropicOAuth = CredentialStoreKey.anthropicOAuth
        public static let openAIAPIKey = CredentialStoreKey.openAIAPIKey
    }

    // MARK: - CredentialStore

    public func readCredential(forKey key: String) -> CredentialReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                Self.logger.error("Keychain read for '\(key, privacy: .public)' succeeded but the value was not decodable")
                return .failed(status)
            }
            return .found(string)

        case errSecItemNotFound:
            return .notFound

        default:
            Self.logger.error("Keychain read for '\(key, privacy: .public)' failed with OSStatus \(status)")
            return .failed(status)
        }
    }

    @discardableResult
    public func writeCredential(_ value: String, forKey key: String) -> Bool {
        if value.isEmpty {
            return deleteCredential(forKey: key)
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound {
            Self.logger.error("Keychain update for '\(key, privacy: .public)' failed with OSStatus \(updateStatus)")
            return false
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        // AfterFirstUnlock: readable from background/early launch after a
        // reboot's first unlock. Avoids intermittent "item unavailable" reads.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            Self.logger.error("Keychain add for '\(key, privacy: .public)' failed with OSStatus \(addStatus)")
        }
        return addStatus == errSecSuccess
    }

    @discardableResult
    public func deleteCredential(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Legacy raw accessors (pre-refactor names)

    /// Deprecated alias for ``readCredential(forKey:)``.
    @available(*, deprecated, renamed: "readCredential(forKey:)")
    public func readResult(account: String) -> CredentialReadResult {
        readCredential(forKey: account)
    }

    /// Deprecated alias for ``writeCredential(_:forKey:)``.
    @available(*, deprecated, renamed: "writeCredential(_:forKey:)")
    @discardableResult
    public func write(_ value: String, account: String) -> Bool {
        writeCredential(value, forKey: account)
    }

    /// Deprecated alias for ``deleteCredential(forKey:)``.
    @available(*, deprecated, renamed: "deleteCredential(forKey:)")
    @discardableResult
    public func delete(account: String) -> Bool {
        deleteCredential(forKey: account)
    }
}
