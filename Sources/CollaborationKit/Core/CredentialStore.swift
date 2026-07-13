import Foundation
#if canImport(Security)
import Security
#endif

/// A credential source for the backends CollaborationKit talks to.
///
/// The three named slots correspond to the built-in ``Backend`` values in
/// `CollaborationKitUI` — an Anthropic API key, an OpenAI API key, and the
/// JSON-encoded ``OAuthCredentials`` from a Claude subscription login. The
/// protocol exists so a `Backend` can be exercised against any store: the
/// production ``KeychainCredentialStore``, the CLI's `UserDefaults`-backed
/// store, or an ``InMemoryCredentialStore`` in tests.
///
/// Failure semantics are deliberately split from "not present": reads return
/// ``CredentialReadResult`` so a transient Keychain error (locked, permission
/// denied) doesn't look like a missing credential. Stores that can't fail
/// transiently simply never emit `.failed`.
public protocol CredentialStore: Sendable {
    /// Reads the Anthropic API key slot.
    func anthropicAPIKey() -> CredentialReadResult

    /// Writes the Anthropic API key. Empty string deletes the entry.
    /// Returns `true` on success.
    @discardableResult
    func saveAnthropicAPIKey(_ key: String) -> Bool

    /// Deletes the Anthropic API key. Returns `true` on success or absence.
    @discardableResult
    func clearAnthropicAPIKey() -> Bool

    /// Reads the OpenAI API key slot.
    func openAIAPIKey() -> CredentialReadResult

    /// Writes the OpenAI API key. Empty string deletes the entry.
    /// Returns `true` on success.
    @discardableResult
    func saveOpenAIAPIKey(_ key: String) -> Bool

    /// Deletes the OpenAI API key. Returns `true` on success or absence.
    @discardableResult
    func clearOpenAIAPIKey() -> Bool

    /// Reads and decodes stored Anthropic subscription credentials.
    ///
    /// Returns `nil` for both "nothing stored" and "stored value is
    /// unreadable/undecodable" so a broken slot doesn't wedge the caller.
    func anthropicOAuthCredentials() -> OAuthCredentials?

    /// Persists Anthropic subscription credentials.
    @discardableResult
    func saveAnthropicOAuthCredentials(_ credentials: OAuthCredentials) -> Bool

    /// Deletes stored Anthropic subscription credentials (logout).
    @discardableResult
    func clearAnthropicOAuthCredentials() -> Bool
}

// MARK: - Anthropic OAuth token provider

/// Errors surfaced by ``anthropicOAuthTokenProvider(store:oauth:)``.
public enum AnthropicOAuthTokenError: Error, LocalizedError, Sendable {
    /// No credentials are stored — the user was signed out (or never signed
    /// in) between requests.
    case notAuthenticated

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "No Claude subscription credentials are stored."
        }
    }
}

/// A `@Sendable` access-token provider suitable for ``AnthropicAuth/oauth(_:)``.
///
/// On each call it reads credentials from `store`, refreshes them via
/// ``AnthropicOAuth`` if the access token has expired, and re-persists the
/// refreshed credentials back into `store`. Persistence and OAuth refresh
/// orchestration are separated so a store only has to know how to hold bytes.
///
/// - Parameters:
///   - store: The credential source to read from and write refreshed
///     credentials back to.
///   - oauth: The OAuth client used to refresh expired tokens. Defaults to a
///     fresh ``AnthropicOAuth``.
/// - Throws: ``AnthropicOAuthTokenError/notAuthenticated`` if no credentials
///   are stored at call time.
@preconcurrency
public func anthropicOAuthTokenProvider(
    store: any CredentialStore,
    oauth: AnthropicOAuth = AnthropicOAuth()
) -> @Sendable () async throws -> String {
    {
        guard let credentials = store.anthropicOAuthCredentials() else {
            throw AnthropicOAuthTokenError.notAuthenticated
        }
        guard credentials.isExpired() else {
            return credentials.access
        }
        let refreshed = try await oauth.refresh(credentials)
        store.saveAnthropicOAuthCredentials(refreshed)
        return refreshed.access
    }
}

// MARK: - Credential read result

/// The outcome of reading a value from a ``CredentialStore``.
///
/// Distinguishes a genuinely missing item (`.notFound`) from a transient or
/// permission-related failure (`.failed`). Callers that collapse both into
/// `nil` risk treating a store that isn't currently readable (e.g. a Keychain
/// right after login, `errSecInteractionNotAllowed`) as an unset credential —
/// the user then sees a "no key" state that clears the field on the next save.
public enum CredentialReadResult: Equatable, Sendable {
    /// The item exists and its UTF-8 value was decoded successfully.
    case found(String)

    /// No item exists for the requested slot.
    case notFound

    /// The store returned an error other than "not found".
    ///
    /// For Keychain-backed stores the associated `OSStatus` is the raw code
    /// from `SecItemCopyMatching`. Non-Keychain stores use `0` when they need
    /// to surface a failure but have no meaningful code.
    case failed(OSStatus)

    /// Convenience: the string value, or `nil` for `.notFound` / `.failed`.
    ///
    /// Prefer switching on the case when you need to distinguish "no key" from
    /// "couldn't read the key right now".
    public var value: String? {
        if case .found(let value) = self { return value }
        return nil
    }

    /// A short human-readable description for a `.failed` status.
    public static func message(for status: OSStatus) -> String {
        #if canImport(Security)
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        #endif
        return "unknown credential-store error (status \(status))"
    }
}

/// Source-compat alias for the pre-refactor name.
///
/// Older code referred to this type as ``KeychainReadResult`` when it lived
/// in `CollaborationKitUI`. New code should use ``CredentialReadResult``.
public typealias KeychainReadResult = CredentialReadResult
