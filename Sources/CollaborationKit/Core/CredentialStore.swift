import Foundation
#if canImport(Security)
import Security
#endif

/// A generic UTF-8 credential store.
///
/// The protocol has three methods: read, write, delete — each parameterized
/// by an opaque `String` key. That's it. Everything backend-specific — the
/// Anthropic API key, the Claude subscription OAuth tokens, an OpenAI key,
/// or whatever a new custom ``Backend`` needs — is layered on as an
/// **extension** method on `CredentialStore` that reads/writes a well-known
/// key string. This is what lets the ``Backend`` docs' promise hold: adding
/// a new backend is one value declaration plus (optionally) a new key
/// constant, with **no protocol change and no conformer edits**.
///
/// Failure semantics are deliberately split from "not present": reads return
/// ``CredentialReadResult`` so a transient failure (Keychain locked,
/// permission denied) doesn't look like a missing credential. Stores that
/// can't fail transiently simply never emit `.failed`.
public protocol CredentialStore: Sendable {
    /// Reads the UTF-8 value stored under `key`.
    func readCredential(forKey key: String) -> CredentialReadResult

    /// Writes `value` under `key`. An empty string deletes the entry.
    /// Returns `true` on success.
    @discardableResult
    func writeCredential(_ value: String, forKey key: String) -> Bool

    /// Deletes the value stored under `key`. Returns `true` on success or
    /// when the value was already absent.
    @discardableResult
    func deleteCredential(forKey key: String) -> Bool
}

// MARK: - Standard keys

/// The well-known credential keys the built-in ``Backend`` values use.
///
/// Custom backends read/write their own credentials through the three
/// ``CredentialStore`` methods with any key string of their choice; adding
/// a `static let` here (in an extension) is optional and merely groups the
/// key names with the built-ins.
public enum CredentialStoreKey {
    /// A billed Anthropic API key.
    public static let anthropicAPIKey = "anthropic.apiKey"
    /// JSON-encoded ``OAuthCredentials`` for a Claude subscription login.
    public static let anthropicOAuth = "anthropic.oauth"
    /// A billed OpenAI API key.
    public static let openAIAPIKey = "openai.apiKey"
}

extension CredentialStore {
    /// Alias for ``CredentialStoreKey``; lets callers write
    /// `CredentialStore.StandardKey.anthropicAPIKey`.
    public typealias StandardKey = CredentialStoreKey
}

// MARK: - Named-slot accessors (built-in backends)

extension CredentialStore {
    /// Reads the Anthropic API key slot.
    public func anthropicAPIKey() -> CredentialReadResult {
        readCredential(forKey: CredentialStoreKey.anthropicAPIKey)
    }

    /// Writes the Anthropic API key. Empty string deletes the entry.
    @discardableResult
    public func saveAnthropicAPIKey(_ key: String) -> Bool {
        writeCredential(key, forKey: CredentialStoreKey.anthropicAPIKey)
    }

    /// Deletes the Anthropic API key.
    @discardableResult
    public func clearAnthropicAPIKey() -> Bool {
        deleteCredential(forKey: CredentialStoreKey.anthropicAPIKey)
    }

    /// Reads the OpenAI API key slot.
    public func openAIAPIKey() -> CredentialReadResult {
        readCredential(forKey: CredentialStoreKey.openAIAPIKey)
    }

    /// Writes the OpenAI API key. Empty string deletes the entry.
    @discardableResult
    public func saveOpenAIAPIKey(_ key: String) -> Bool {
        writeCredential(key, forKey: CredentialStoreKey.openAIAPIKey)
    }

    /// Deletes the OpenAI API key.
    @discardableResult
    public func clearOpenAIAPIKey() -> Bool {
        deleteCredential(forKey: CredentialStoreKey.openAIAPIKey)
    }

    /// Reads and decodes stored Anthropic subscription credentials.
    ///
    /// Returns `nil` for both "nothing stored" and "stored value is
    /// unreadable/undecodable" so a broken slot doesn't wedge the caller.
    public func anthropicOAuthCredentials() -> OAuthCredentials? {
        guard case .found(let json) = readCredential(forKey: CredentialStoreKey.anthropicOAuth),
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
            return false
        }
        return writeCredential(json, forKey: CredentialStoreKey.anthropicOAuth)
    }

    /// Deletes stored Anthropic subscription credentials (logout).
    @discardableResult
    public func clearAnthropicOAuthCredentials() -> Bool {
        deleteCredential(forKey: CredentialStoreKey.anthropicOAuth)
    }
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
