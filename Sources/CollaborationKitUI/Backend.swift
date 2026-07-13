import Foundation
import CollaborationKit

/// A provider the app can talk to.
///
/// `Backend` is a value type that owns everything backend-specific: how to
/// tell whether credentials are stored, how to construct a ``ModelProvider``
/// from those credentials, what a "chat-capable model id" looks like on that
/// backend, the default model, and the display name shown in pickers. Adding
/// a new backend is one value declaration — no library edits, no enum case,
/// no scattered switches.
///
/// The three built-in backends (``claudeSubscription``, ``anthropicAPI``,
/// ``openAI``) are exposed as static factories so hosts get the common cases
/// for free. Custom backends compose the same way.
public struct Backend: Sendable, Identifiable, Hashable {
    /// Stable identifier used for equality, model-selection persistence, and
    /// registry keying. Should be a short, filesystem-safe token
    /// (`"claudeSubscription"`, `"ollama"`).
    public let id: String

    /// User-visible label shown in the provider picker.
    public let displayName: String

    /// Model identifier used until the host (or user) picks something else.
    public let defaultModel: String

    /// Returns `true` if the store has usable credentials for this backend.
    ///
    /// Transient store failures should be treated as "not present" so a
    /// caller never falsely reports "signed in" when the item can't be read.
    public let hasCredentials: @Sendable (any CredentialStore) -> Bool

    /// Builds a ``ModelProvider`` from the store, model id, and max-token
    /// budget. Throws when credentials are missing or unreadable.
    public let makeProvider: @Sendable (any CredentialStore, String, Int) throws -> any ModelProvider

    /// Whether a model id is worth showing in the picker. Called with
    /// lowercased ids; drop non-chat families (embeddings, audio…) here.
    public let modelFilter: @Sendable (String) -> Bool

    public init(
        id: String,
        displayName: String,
        defaultModel: String,
        hasCredentials: @escaping @Sendable (any CredentialStore) -> Bool,
        makeProvider: @escaping @Sendable (any CredentialStore, String, Int) throws -> any ModelProvider,
        modelFilter: @escaping @Sendable (String) -> Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.defaultModel = defaultModel
        self.hasCredentials = hasCredentials
        self.makeProvider = makeProvider
        self.modelFilter = modelFilter
    }

    // MARK: - Hashable

    public static func == (lhs: Backend, rhs: Backend) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: - UserDefaults keys

    /// UserDefaults key for the persisted model id of this backend.
    public var modelDefaultsKey: String { "collaborationkit.model.\(id)" }
}

// MARK: - Built-in backends

extension Backend {
    /// Claude via a Claude subscription (unofficial OAuth).
    public static let claudeSubscription = Backend(
        id: "claudeSubscription",
        displayName: "Claude Subscription",
        defaultModel: "claude-sonnet-4-5",
        hasCredentials: { store in
            store.anthropicOAuthCredentials() != nil
        },
        makeProvider: { store, model, maxTokens in
            guard store.anthropicOAuthCredentials() != nil else {
                throw CollaborationCredentialsError.missingCredentials(id: "claudeSubscription", displayName: "Claude Subscription")
            }
            let tokenProvider = anthropicOAuthTokenProvider(store: store)
            let auth = AnthropicAuth.oauth { try await tokenProvider() }
            return AnthropicProvider(config: AnthropicConfig(auth: auth, model: model, maxTokens: maxTokens))
        },
        modelFilter: Backend.claudePrefixFilter
    )

    /// Anthropic Claude via a billed API key.
    public static let anthropicAPI = Backend(
        id: "anthropicAPI",
        displayName: "Anthropic API",
        defaultModel: "claude-sonnet-4-5",
        hasCredentials: { store in
            if case .found(let v) = store.anthropicAPIKey(), !v.isEmpty { return true }
            return false
        },
        makeProvider: { store, model, maxTokens in
            let key = try Backend.readAPIKey(store.anthropicAPIKey(), id: "anthropicAPI", displayName: "Anthropic API")
            return AnthropicProvider(config: AnthropicConfig(apiKey: key, model: model, maxTokens: maxTokens))
        },
        modelFilter: Backend.claudePrefixFilter
    )

    /// The OpenAI API (or an OpenAI-compatible server) via an API key.
    public static let openAI = Backend(
        id: "openAI",
        displayName: "OpenAI",
        defaultModel: "gpt-4o",
        hasCredentials: { store in
            if case .found(let v) = store.openAIAPIKey(), !v.isEmpty { return true }
            return false
        },
        makeProvider: { store, model, maxTokens in
            let key = try Backend.readAPIKey(store.openAIAPIKey(), id: "openAI", displayName: "OpenAI")
            return OpenAIProvider(config: OpenAIConfig(apiKey: key, model: model, maxTokens: maxTokens))
        },
        modelFilter: Backend.openAIChatFilter
    )

    /// The three built-in backends. Suitable as the default
    /// ``CollaborationSettingsView`` picker source.
    public static let allBuiltin: [Backend] = [.claudeSubscription, .anthropicAPI, .openAI]

    // MARK: - Shared helpers

    /// Keeps `claude-*` model ids, drops dated snapshots (`…-2025-12-11`).
    static let claudePrefixFilter: @Sendable (String) -> Bool = { id in
        if Backend.hasDatedSnapshotSuffix(id) { return false }
        return id.hasPrefix("claude-")
    }

    /// Keeps `gpt-*`, `chatgpt`, `o1`, `o3`, `o4` families; drops embeddings,
    /// audio, image, and other non-chat surfaces.
    static let openAIChatFilter: @Sendable (String) -> Bool = { id in
        if Backend.hasDatedSnapshotSuffix(id) { return false }
        let excluded = ["audio", "image", "realtime", "transcribe", "tts",
                        "whisper", "embedding", "moderation", "search",
                        "dall-e", "codex", "computer-use"]
        if excluded.contains(where: id.contains) { return false }
        return id.hasPrefix("gpt-") || id.hasPrefix("chatgpt")
            || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4")
    }

    /// True if `id` ends in a `-YYYY-MM-DD` snapshot date.
    static func hasDatedSnapshotSuffix(_ id: String) -> Bool {
        id.wholeMatch(of: /.*-\d{4}-\d{2}-\d{2}/) != nil
    }

    static func readAPIKey(
        _ result: CredentialReadResult,
        id: String,
        displayName: String
    ) throws -> String {
        switch result {
        case .found(let value) where !value.isEmpty:
            return value
        case .found, .notFound:
            throw CollaborationCredentialsError.missingCredentials(id: id, displayName: displayName)
        case .failed(let status):
            throw CollaborationCredentialsError.keychainReadFailed(status)
        }
    }
}

// MARK: - Error

/// Errors surfaced when building a ``ModelProvider`` for a ``Backend``.
public enum CollaborationCredentialsError: Error, LocalizedError, Sendable {
    /// No credentials are stored for the selected backend.
    ///
    /// Carries the backend's `id` and `displayName` rather than the full
    /// ``Backend`` value so the error stays hashable/decodable-shaped and
    /// doesn't tug the whole registry along with it.
    case missingCredentials(id: String, displayName: String)
    /// The Keychain returned a transient failure while reading credentials.
    case keychainReadFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials(_, let displayName):
            return "No credentials for \(displayName). Add an API key (or sign in) in Settings."
        case .keychainReadFailed(let status):
            return "Couldn't read the credential from the Keychain: \(CredentialReadResult.message(for: status)) (status \(status))."
        }
    }
}
