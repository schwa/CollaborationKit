import Foundation
import CollaborationKit

/// The provider a host application wants CollaborationKit to talk to.
///
/// Used both to drive the credentials UI (which sections are visible, which
/// slot the "signed in?" indicator reflects) and to construct a
/// ``ModelProvider`` from stored credentials.
public enum CollaborationBackend: String, CaseIterable, Identifiable, Sendable, Hashable {
    /// Claude via a Claude subscription (unofficial OAuth).
    case claudeSubscription
    /// Anthropic Claude via a billed API key.
    case anthropicAPI
    /// The OpenAI API (or any OpenAI-compatible server) via an API key.
    case openAI

    public var id: String { rawValue }

    /// A short label for pickers.
    public var displayName: String {
        switch self {
        case .claudeSubscription: "Claude Subscription"
        case .anthropicAPI: "Anthropic API"
        case .openAI: "OpenAI"
        }
    }

    /// The default model identifier for this backend, used until the host (or
    /// the user) picks something else.
    public var defaultModel: String {
        switch self {
        case .claudeSubscription, .anthropicAPI: "claude-sonnet-4-5"
        case .openAI: "gpt-4o"
        }
    }
}

/// Errors surfaced when building a ``ModelProvider`` from a
/// ``KeychainCredentialStore``.
public enum CollaborationCredentialsError: Error, LocalizedError, Sendable {
    /// No credentials are stored for the selected backend.
    case missingCredentials(CollaborationBackend)
    /// The Keychain returned a transient failure while reading credentials.
    case keychainReadFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials(let backend):
            return "No credentials for \(backend.displayName). Add an API key (or sign in) in Settings."
        case .keychainReadFailed(let status):
            return "Couldn't read the credential from the Keychain: \(KeychainReadResult.message(for: status)) (status \(status))."
        }
    }
}

extension KeychainCredentialStore {
    /// Whether usable credentials are stored for `backend`.
    ///
    /// Treats transient Keychain failures as "not present" so the caller never
    /// falsely reports "yes, signed in" when the item cannot actually be read.
    /// If distinguishing the transient case matters, use the slot-specific
    /// accessors and inspect the ``KeychainReadResult``.
    public func hasCredentials(for backend: CollaborationBackend) -> Bool {
        switch backend {
        case .claudeSubscription:
            return anthropicOAuthCredentials() != nil

        case .anthropicAPI:
            if case .found(let value) = anthropicAPIKey(), !value.isEmpty { return true }
            return false

        case .openAI:
            if case .found(let value) = openAIAPIKey(), !value.isEmpty { return true }
            return false
        }
    }

    /// Builds a ``ModelProvider`` for `backend` using stored credentials and
    /// the given model identifier.
    ///
    /// Throws ``CollaborationCredentialsError`` when credentials are missing or
    /// unreadable. The returned provider is ready to hand to ``LLMSession``.
    ///
    /// - Parameters:
    ///   - backend: Which provider to build.
    ///   - model: The model identifier. Defaults to ``CollaborationBackend/defaultModel``.
    ///   - maxTokens: Maximum tokens per response.
    public func makeProvider(
        for backend: CollaborationBackend,
        model: String? = nil,
        maxTokens: Int = 4_096
    ) throws -> any ModelProvider {
        let modelID = model ?? backend.defaultModel
        switch backend {
        case .claudeSubscription:
            guard anthropicOAuthCredentials() != nil else {
                throw CollaborationCredentialsError.missingCredentials(backend)
            }
            let tokenProvider = anthropicOAuthTokenProvider()
            let auth = AnthropicAuth.oauth { try await tokenProvider() }
            return AnthropicProvider(config: AnthropicConfig(auth: auth, model: modelID, maxTokens: maxTokens))

        case .anthropicAPI:
            let key = try readAPIKey(anthropicAPIKey(), backend: backend)
            return AnthropicProvider(config: AnthropicConfig(apiKey: key, model: modelID, maxTokens: maxTokens))

        case .openAI:
            let key = try readAPIKey(openAIAPIKey(), backend: backend)
            return OpenAIProvider(config: OpenAIConfig(apiKey: key, model: modelID, maxTokens: maxTokens))
        }
    }

    private func readAPIKey(_ result: KeychainReadResult, backend: CollaborationBackend) throws -> String {
        switch result {
        case .found(let value) where !value.isEmpty:
            return value

        case .found, .notFound:
            throw CollaborationCredentialsError.missingCredentials(backend)

        case .failed(let status):
            throw CollaborationCredentialsError.keychainReadFailed(status)
        }
    }
}
