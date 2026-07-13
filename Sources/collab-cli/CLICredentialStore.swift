#if os(macOS)

import Foundation
import CollaborationKit

/// A tiny credential store for the `collab-cli` executable.
///
/// The CLI has to persist an Anthropic API key and/or a Claude subscription's
/// OAuth token across invocations. UserDefaults gives us that persistence for
/// free — the values land in the standard preferences plist for this
/// executable's bundle id, which is preserved across launches on macOS.
///
/// The UI target (`CollaborationKitUI`) uses the Keychain instead
/// (`KeychainCredentialStore`); Core doesn't ship any credential persistence
/// of its own — it's a host concern.
struct CLICredentialStore: @unchecked Sendable {
    private static let apiKeyKey = "collab.anthropic.apiKey"
    private static let oauthKey = "collab.anthropic.oauth"

    // UserDefaults itself isn't Sendable, but .standard is thread-safe for
    // this workload. Marking @unchecked so the closure returned by
    // anthropicOAuthTokenProvider(oauth:) can capture `self` cleanly.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - API key

    func apiKey() -> String? {
        let value = defaults.string(forKey: Self.apiKeyKey)
        return (value?.isEmpty ?? true) ? nil : value
    }

    func save(apiKey: String) {
        defaults.set(apiKey, forKey: Self.apiKeyKey)
    }

    // MARK: - OAuth credentials

    func oauthCredentials() -> OAuthCredentials? {
        guard let json = defaults.string(forKey: Self.oauthKey),
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(OAuthCredentials.self, from: data)
    }

    func save(oauth: OAuthCredentials) throws {
        let data = try JSONEncoder().encode(oauth)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CLICredentialError.encodingFailed
        }
        defaults.set(json, forKey: Self.oauthKey)
    }

    func clearOAuth() {
        defaults.removeObject(forKey: Self.oauthKey)
    }

    // MARK: - Token provider

    /// A `@Sendable` closure that returns a currently-valid OAuth access
    /// token, refreshing via the stored refresh token when expired and
    /// re-persisting the new tokens.
    ///
    /// Suitable for ``AnthropicAuth/oauth(_:)``. Throws
    /// ``CLICredentialError/notAuthenticated`` when nothing is stored.
    func anthropicOAuthTokenProvider(
        oauth: AnthropicOAuth = AnthropicOAuth()
    ) -> @Sendable () async throws -> String {
        let store = self
        return {
            guard let credentials = store.oauthCredentials() else {
                throw CLICredentialError.notAuthenticated
            }
            guard credentials.isExpired() else {
                return credentials.access
            }
            let refreshed = try await oauth.refresh(credentials)
            try store.save(oauth: refreshed)
            return refreshed.access
        }
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
