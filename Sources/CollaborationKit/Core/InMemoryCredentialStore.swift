import Foundation

/// An in-memory ``CredentialStore`` for tests, previews, and hosts that
/// deliberately don't want to persist credentials to disk.
///
/// Uses a lock so `@Sendable` closures can read/write freely from any
/// isolation domain. Everything lives in RAM — closing the process throws
/// the credentials away.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private struct State {
        var anthropicAPIKey: String?
        var openAIAPIKey: String?
        var anthropicOAuth: OAuthCredentials?
    }

    private let lock = NSLock()
    private var state = State()

    /// Creates an empty in-memory store.
    public init() {}

    /// Creates an in-memory store pre-populated with the given values.
    public init(
        anthropicAPIKey: String? = nil,
        openAIAPIKey: String? = nil,
        anthropicOAuth: OAuthCredentials? = nil
    ) {
        state.anthropicAPIKey = anthropicAPIKey
        state.openAIAPIKey = openAIAPIKey
        state.anthropicOAuth = anthropicOAuth
    }

    private func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    // MARK: - Anthropic API key

    public func anthropicAPIKey() -> CredentialReadResult {
        withLock { state in
            state.anthropicAPIKey.map { .found($0) } ?? .notFound
        }
    }

    @discardableResult
    public func saveAnthropicAPIKey(_ key: String) -> Bool {
        withLock { state in
            state.anthropicAPIKey = key.isEmpty ? nil : key
            return true
        }
    }

    @discardableResult
    public func clearAnthropicAPIKey() -> Bool {
        withLock { state in
            state.anthropicAPIKey = nil
            return true
        }
    }

    // MARK: - OpenAI API key

    public func openAIAPIKey() -> CredentialReadResult {
        withLock { state in
            state.openAIAPIKey.map { .found($0) } ?? .notFound
        }
    }

    @discardableResult
    public func saveOpenAIAPIKey(_ key: String) -> Bool {
        withLock { state in
            state.openAIAPIKey = key.isEmpty ? nil : key
            return true
        }
    }

    @discardableResult
    public func clearOpenAIAPIKey() -> Bool {
        withLock { state in
            state.openAIAPIKey = nil
            return true
        }
    }

    // MARK: - Anthropic OAuth

    public func anthropicOAuthCredentials() -> OAuthCredentials? {
        withLock { $0.anthropicOAuth }
    }

    @discardableResult
    public func saveAnthropicOAuthCredentials(_ credentials: OAuthCredentials) -> Bool {
        withLock { state in
            state.anthropicOAuth = credentials
            return true
        }
    }

    @discardableResult
    public func clearAnthropicOAuthCredentials() -> Bool {
        withLock { state in
            state.anthropicOAuth = nil
            return true
        }
    }
}
