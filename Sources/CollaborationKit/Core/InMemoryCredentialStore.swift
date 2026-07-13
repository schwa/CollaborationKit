import Foundation

/// An in-memory ``CredentialStore`` for tests, previews, and hosts that
/// deliberately don't want to persist credentials to disk.
///
/// Backed by a plain `[String: String]` under a lock, so it supports any key
/// a ``Backend`` needs — the built-in slots are just three well-known
/// entries in the same map.
///
/// Everything lives in RAM — closing the process throws the credentials away.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    /// Creates an empty in-memory store.
    public init() {}

    /// Creates an in-memory store pre-populated with the standard built-in
    /// slots. Convenience for tests; equivalent to constructing an empty
    /// store and calling the corresponding `save…` extension methods.
    public init(
        anthropicAPIKey: String? = nil,
        openAIAPIKey: String? = nil,
        anthropicOAuth: OAuthCredentials? = nil
    ) {
        if let anthropicAPIKey {
            saveAnthropicAPIKey(anthropicAPIKey)
        }
        if let openAIAPIKey {
            saveOpenAIAPIKey(openAIAPIKey)
        }
        if let anthropicOAuth {
            saveAnthropicOAuthCredentials(anthropicOAuth)
        }
    }

    public func readCredential(forKey key: String) -> CredentialReadResult {
        lock.lock()
        defer { lock.unlock() }
        if let value = storage[key] {
            return .found(value)
        }
        return .notFound
    }

    @discardableResult
    public func writeCredential(_ value: String, forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value.isEmpty {
            storage[key] = nil
        } else {
            storage[key] = value
        }
        return true
    }

    @discardableResult
    public func deleteCredential(forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = nil
        return true
    }
}
