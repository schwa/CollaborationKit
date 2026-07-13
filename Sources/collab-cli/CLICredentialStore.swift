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
/// The UI target (`CollaborationKitUI`) uses ``KeychainCredentialStore``
/// instead. Both conform to ``CredentialStore``, so the shared
/// ``anthropicOAuthTokenProvider(store:oauth:)`` handles refresh for either.
///
/// OpenAI is currently unimplemented for the CLI: the API-key slot is stored
/// under the Anthropic key today (see ``Login``), so the `openAIAPIKey` slot
/// here always reports `.notFound`.
struct CLICredentialStore: CredentialStore, @unchecked Sendable {
    private static let apiKeyKey = "collab.anthropic.apiKey"
    private static let oauthKey = "collab.anthropic.oauth"

    // UserDefaults itself isn't Sendable, but .standard is thread-safe for
    // this workload. Marking @unchecked so the `@Sendable` token provider
    // closure can capture `self` cleanly.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    /// Persist an API key (throws are legacy; the underlying slot never
    /// fails, but Login's call site catches for symmetry with `save(oauth:)`).
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

    // MARK: - CredentialStore

    func anthropicAPIKey() -> CredentialReadResult {
        let value = defaults.string(forKey: Self.apiKeyKey)
        guard let value, !value.isEmpty else { return .notFound }
        return .found(value)
    }

    @discardableResult
    func saveAnthropicAPIKey(_ key: String) -> Bool {
        if key.isEmpty {
            defaults.removeObject(forKey: Self.apiKeyKey)
        } else {
            defaults.set(key, forKey: Self.apiKeyKey)
        }
        return true
    }

    @discardableResult
    func clearAnthropicAPIKey() -> Bool {
        defaults.removeObject(forKey: Self.apiKeyKey)
        return true
    }

    // OpenAI slot: unused by the CLI today; report notFound and no-op writes.
    // Kept present so `CLICredentialStore` satisfies `CredentialStore` in
    // full and can be swapped in wherever the protocol is expected.
    func openAIAPIKey() -> CredentialReadResult { .notFound }
    @discardableResult
    func saveOpenAIAPIKey(_: String) -> Bool { false }
    @discardableResult
    func clearOpenAIAPIKey() -> Bool { true }

    func anthropicOAuthCredentials() -> OAuthCredentials? {
        guard let json = defaults.string(forKey: Self.oauthKey),
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(OAuthCredentials.self, from: data)
    }

    @discardableResult
    func saveAnthropicOAuthCredentials(_ credentials: OAuthCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials),
              let json = String(data: data, encoding: .utf8) else {
            return false
        }
        defaults.set(json, forKey: Self.oauthKey)
        return true
    }

    @discardableResult
    func clearAnthropicOAuthCredentials() -> Bool {
        defaults.removeObject(forKey: Self.oauthKey)
        return true
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
