import Foundation
import os
import Security
import CollaborationKit

/// A Keychain-backed store for CollaborationKit credentials.
///
/// This is the default persistence CollaborationKitUI uses, in preference to
/// the file-based ``CollaborationKit/CredentialStore``. Values are stored as
/// generic passwords under a caller-configurable service string, so a host
/// application can partition its Keychain namespace from other tools that also
/// use CollaborationKit.
///
/// Three slots are exposed as first-class API:
///
/// - Anthropic API key
/// - Anthropic subscription OAuth credentials (JSON-encoded ``OAuthCredentials``)
/// - OpenAI API key
///
/// Additional slots can be read/written through ``read(account:)`` /
/// ``write(_:account:)``.
public struct KeychainCredentialStore: Sendable {
    /// The Keychain `kSecAttrService` string. Defaults to
    /// `"io.collaborationkit.credentials"`; override to partition per app.
    public let service: String

    private static let logger = Logger(subsystem: "io.collaborationkit.ui", category: "keychain")

    public init(service: String = "io.collaborationkit.credentials") {
        self.service = service
    }

    // MARK: - Named slots

    /// Standard account names used by ``KeychainCredentialStore``.
    public enum Account {
        public static let anthropicAPIKey = "anthropic.apiKey"
        /// JSON-encoded ``OAuthCredentials`` for a Claude subscription login.
        public static let anthropicOAuth = "anthropic.oauth"
        public static let openAIAPIKey = "openai.apiKey"
    }

    /// Reads the Anthropic API key.
    public func anthropicAPIKey() -> KeychainReadResult {
        readResult(account: Account.anthropicAPIKey)
    }

    /// Writes the Anthropic API key. Empty string deletes the entry.
    @discardableResult
    public func saveAnthropicAPIKey(_ key: String) -> Bool {
        write(key, account: Account.anthropicAPIKey)
    }

    /// Deletes the Anthropic API key.
    @discardableResult
    public func clearAnthropicAPIKey() -> Bool {
        delete(account: Account.anthropicAPIKey)
    }

    /// Reads the OpenAI API key.
    public func openAIAPIKey() -> KeychainReadResult {
        readResult(account: Account.openAIAPIKey)
    }

    /// Writes the OpenAI API key. Empty string deletes the entry.
    @discardableResult
    public func saveOpenAIAPIKey(_ key: String) -> Bool {
        write(key, account: Account.openAIAPIKey)
    }

    /// Deletes the OpenAI API key.
    @discardableResult
    public func clearOpenAIAPIKey() -> Bool {
        delete(account: Account.openAIAPIKey)
    }

    /// Reads and decodes stored Anthropic subscription credentials.
    ///
    /// Returns `nil` if none are stored, or if the stored JSON is unreadable
    /// (which is treated as "missing" so a broken slot doesn't wedge the UI).
    public func anthropicOAuthCredentials() -> OAuthCredentials? {
        guard case .found(let json) = readResult(account: Account.anthropicOAuth),
              let data = json.data(using: .utf8),
              let credentials = try? JSONDecoder().decode(OAuthCredentials.self, from: data) else {
            return nil
        }
        return credentials
    }

    /// Persists Anthropic subscription credentials.
    @discardableResult
    public func saveAnthropicOAuthCredentials(_ credentials: OAuthCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials),
              let json = String(data: data, encoding: .utf8) else {
            Self.logger.error("Failed to encode OAuthCredentials before saving to Keychain")
            return false
        }
        return write(json, account: Account.anthropicOAuth)
    }

    /// Deletes the stored Anthropic subscription credentials (logout).
    @discardableResult
    public func clearAnthropicOAuthCredentials() -> Bool {
        delete(account: Account.anthropicOAuth)
    }

    /// A `@Sendable` access-token provider suitable for
    /// ``AnthropicAuth/oauth(_:)``.
    ///
    /// On each call it reads the stored credentials, refreshes them via
    /// ``AnthropicOAuth`` if the access token has expired, and re-persists the
    /// refreshed credentials to this store. Throws
    /// ``KeychainCredentialStore/NotAuthenticated`` if no credentials are
    /// stored.
    public func anthropicOAuthTokenProvider(
        oauth: AnthropicOAuth = AnthropicOAuth()
    ) -> @Sendable () async throws -> String {
        let store = self
        return {
            guard let credentials = store.anthropicOAuthCredentials() else {
                throw NotAuthenticated()
            }
            guard credentials.isExpired() else {
                return credentials.access
            }
            let refreshed = try await oauth.refresh(credentials)
            store.saveAnthropicOAuthCredentials(refreshed)
            return refreshed.access
        }
    }

    /// Thrown by ``anthropicOAuthTokenProvider(oauth:)`` when no credentials
    /// are stored (the user was signed out between requests).
    public struct NotAuthenticated: Error, LocalizedError, Sendable {
        public init() {}
        public var errorDescription: String? { "No Claude subscription credentials are stored." }
    }

    // MARK: - Raw read/write (any account)

    /// Reads a raw value from the Keychain.
    ///
    /// Prefer the named-slot accessors above; use this for custom slots.
    public func readResult(account: String) -> KeychainReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                Self.logger.error("Keychain read for '\(account, privacy: .public)' succeeded but the value was not decodable")
                return .failed(status)
            }
            return .found(string)

        case errSecItemNotFound:
            return .notFound

        default:
            Self.logger.error("Keychain read for '\(account, privacy: .public)' failed with OSStatus \(status)")
            return .failed(status)
        }
    }

    /// Writes a raw value. Replaces any existing value for the same account.
    ///
    /// Empty `value` deletes the entry (call ``delete(account:)`` if that is
    /// the intent, so failures at the call site are less ambiguous).
    @discardableResult
    public func write(_ value: String, account: String) -> Bool {
        if value.isEmpty {
            return delete(account: account)
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound {
            Self.logger.error("Keychain update for '\(account, privacy: .public)' failed with OSStatus \(updateStatus)")
            return false
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        // AfterFirstUnlock: readable from background/early launch after a
        // reboot's first unlock. Avoids intermittent "item unavailable" reads.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            Self.logger.error("Keychain add for '\(account, privacy: .public)' failed with OSStatus \(addStatus)")
        }
        return addStatus == errSecSuccess
    }

    /// Deletes a value. Returns `true` if it was deleted or already absent.
    @discardableResult
    public func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
