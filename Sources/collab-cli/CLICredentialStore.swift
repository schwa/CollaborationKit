#if os(macOS)

import CollaborationKit
import Foundation

/// A tiny ``CredentialStore`` for the `collab-cli` executable.
///
/// The CLI has to persist an Anthropic API key and/or a Claude subscription's
/// OAuth token across invocations. UserDefaults gives us that persistence for
/// free — the values land in the standard preferences plist for this
/// executable's bundle id, which is preserved across launches on macOS.
///
/// Because ``CredentialStore`` is a plain key/value surface, this store
/// works with the three built-in ``Backend`` slots and any custom key a
/// new backend registers. The two historical UserDefaults keys
/// (`collab.anthropic.apiKey`, `collab.anthropic.oauth`) are aliased from
/// the new ``CredentialStore/StandardKey`` values so previously-signed-in
/// users keep their tokens across the refactor.
struct CLICredentialStore: CredentialStore, @unchecked Sendable {
    // UserDefaults itself isn't Sendable, but .standard is thread-safe for
    // this workload. Marking @unchecked so the `@Sendable` token provider
    // closure can capture `self` cleanly.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - CredentialStore

    func readCredential(forKey key: String) -> CredentialReadResult {
        let defaultsKey = Self.defaultsKey(for: key)
        guard let value = defaults.string(forKey: defaultsKey), !value.isEmpty else {
            return .notFound
        }
        return .found(value)
    }

    @discardableResult
    func writeCredential(_ value: String, forKey key: String) -> Bool {
        let defaultsKey = Self.defaultsKey(for: key)
        if value.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(value, forKey: defaultsKey)
        }
        return true
    }

    @discardableResult
    func deleteCredential(forKey key: String) -> Bool {
        defaults.removeObject(forKey: Self.defaultsKey(for: key))
        return true
    }

    /// Translates a generic ``CredentialStore`` key into the on-disk
    /// UserDefaults key. Preserves the historical keys for the two slots
    /// that existed before the ``CredentialStore`` refactor so already-
    /// signed-in users keep their credentials. Any other key round-trips
    /// verbatim under the `collab.` prefix.
    private static func defaultsKey(for key: String) -> String {
        switch key {
        case CredentialStoreKey.anthropicAPIKey:
            return "collab.anthropic.apiKey"

        case CredentialStoreKey.anthropicOAuth:
            return "collab.anthropic.oauth"

        default:
            return "collab.\(key)"
        }
    }

    // MARK: - Legacy convenience accessors (unwrapped strings)

    /// Convenience wrapper around ``anthropicAPIKey()`` for the CLI call
    /// sites that only care about "present or not".
    func apiKey() -> String? {
        anthropicAPIKey().value
    }

    /// Convenience wrapper around ``anthropicOAuthCredentials()``.
    func oauthCredentials() -> OAuthCredentials? {
        anthropicOAuthCredentials()
    }

    /// Persist an API key.
    func save(apiKey: String) {
        saveAnthropicAPIKey(apiKey)
    }

    /// Persist OAuth credentials. Throws if JSON encoding fails.
    func save(oauth: OAuthCredentials) throws {
        guard saveAnthropicOAuthCredentials(oauth) else {
            throw CLICredentialError.encodingFailed
        }
    }

    func clearOAuth() {
        clearAnthropicOAuthCredentials()
    }
}

enum CLICredentialError: Error, LocalizedError {
    case notAuthenticated
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "No Claude subscription credentials stored. Run `collab-cli login --oauth` first."

        case .encodingFailed:
            return "Couldn't encode credentials for storage."
        }
    }
}

#endif
