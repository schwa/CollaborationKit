import Foundation

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

    /// Builds a ``ModelProvider`` from the store, model id, max-token budget,
    /// and optional base-URL override. Throws when credentials are missing or
    /// unreadable. `baseURL` is provider-specific; ignore it if it does not
    /// apply.
    public let makeProvider: @Sendable (any CredentialStore, String, Int, URL?) throws -> any ModelProvider

    /// Whether a model id is worth showing in the picker. Called with
    /// lowercased ids; drop non-chat families (embeddings, audio…) here.
    public let modelFilter: @Sendable (String) -> Bool

    @preconcurrency
    public init(
        id: String,
        displayName: String,
        defaultModel: String,
        hasCredentials: @escaping @Sendable (any CredentialStore) -> Bool,
        makeProvider: @escaping @Sendable (any CredentialStore, String, Int, URL?) throws -> any ModelProvider,
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

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: - UserDefaults keys

    /// UserDefaults key for the persisted model id of this backend.
    public var modelDefaultsKey: String { "collaborationkit.model.\(id)" }

    /// UserDefaults key for the persisted base-URL override of this
    /// backend. Only local backends read it today, but the key exists for
    /// every ``Backend`` so hosts can override an endpoint uniformly.
    public var baseURLDefaultsKey: String { "collaborationkit.baseURL.\(id)" }
}

// MARK: - Built-in backends

extension Backend {
    /// Stable id / display-name pairs for the three built-in backends.
    ///
    /// The built-in `Backend` values need to embed their own id in both the
    /// public `id` property and inside the `makeProvider` closure's error
    /// payload, because the closure is constructed before `self` exists.
    /// Naming both spellings once here keeps them from drifting.
    private enum Builtin {
        static let claudeSubscription = (id: "claudeSubscription", displayName: "Claude Subscription")
        static let anthropicAPI = (id: "anthropicAPI", displayName: "Anthropic API")
        static let openAI = (id: "openAI", displayName: "OpenAI")
        static let lmStudio = (id: "lmStudio", displayName: "LM Studio")
        static let ollama = (id: "ollama", displayName: "Ollama")
    }

    /// Claude via a Claude subscription (unofficial OAuth).
    public static let claudeSubscription = Backend(
        id: Builtin.claudeSubscription.id,
        displayName: Builtin.claudeSubscription.displayName,
        defaultModel: "claude-sonnet-4-5",
        hasCredentials: { store in
            store.anthropicOAuthCredentials() != nil
        },
        makeProvider: { store, model, maxTokens, baseURL in
            guard store.anthropicOAuthCredentials() != nil else {
                throw CollaborationCredentialsError.missingCredentials(
                    id: Builtin.claudeSubscription.id,
                    displayName: Builtin.claudeSubscription.displayName
                )
            }
            let tokenProvider = anthropicOAuthTokenProvider(store: store)
            let auth = AnthropicAuth.oauth { try await tokenProvider() }
            var config = AnthropicConfig(auth: auth, model: model, maxTokens: maxTokens)
            if let baseURL { config.baseURL = baseURL }
            return AnthropicProvider(config: config)
        },
        modelFilter: Backend.claudePrefixFilter
    )

    /// Anthropic Claude via a billed API key.
    public static let anthropicAPI = Backend(
        id: Builtin.anthropicAPI.id,
        displayName: Builtin.anthropicAPI.displayName,
        defaultModel: "claude-sonnet-4-5",
        hasCredentials: { store in
            if case .found(let v) = store.anthropicAPIKey(), !v.isEmpty { return true }
            return false
        },
        makeProvider: { store, model, maxTokens, baseURL in
            let key = try Backend.readAPIKey(
                store.anthropicAPIKey(),
                id: Builtin.anthropicAPI.id,
                displayName: Builtin.anthropicAPI.displayName
            )
            var config = AnthropicConfig(apiKey: key, model: model, maxTokens: maxTokens)
            if let baseURL { config.baseURL = baseURL }
            return AnthropicProvider(config: config)
        },
        modelFilter: Backend.claudePrefixFilter
    )

    /// The OpenAI API (or an OpenAI-compatible server) via an API key.
    ///
    /// Uses the server's default for parallel tool calls. Hosts running
    /// agentic loops that need sequential tool calls should use
    /// ``openAI(parallelToolCalls:)`` instead.
    public static let openAI = Backend.openAI()

    /// The OpenAI API (or an OpenAI-compatible server) via an API key,
    /// with control over parallel tool calls.
    ///
    /// - Parameter parallelToolCalls: Passed straight to
    ///   ``OpenAIConfig/parallelToolCalls``. `nil` (the default) lets the
    ///   server decide — the same behavior as the ``openAI`` static value.
    ///   Set to `false` to serialize tool calls, which is useful for
    ///   agentic edit/read/compile loops where a blind tool call alongside
    ///   another can operate on stale state.
    public static func openAI(parallelToolCalls: Bool? = nil) -> Backend {
        Backend(
            id: Builtin.openAI.id,
            displayName: Builtin.openAI.displayName,
            defaultModel: "gpt-4o",
            hasCredentials: { store in
                if case .found(let v) = store.openAIAPIKey(), !v.isEmpty { return true }
                return false
            },
            makeProvider: { store, model, maxTokens, baseURL in
                let key = try Backend.readAPIKey(
                    store.openAIAPIKey(),
                    id: Builtin.openAI.id,
                    displayName: Builtin.openAI.displayName
                )
                var config = OpenAIConfig(
                    apiKey: key,
                    model: model,
                    maxTokens: maxTokens,
                    parallelToolCalls: parallelToolCalls
                )
                if let baseURL { config.baseURL = baseURL }
                return OpenAIProvider(config: config)
            },
            modelFilter: Backend.openAIChatFilter
        )
    }

    /// The three built-in backends. Suitable as the default
    /// ``CollaborationSettingsView`` picker source.
    public static let allBuiltin: [Backend] = [.claudeSubscription, .anthropicAPI, .openAI]

    /// A local LM Studio server. Speaks the OpenAI-compatible
    /// `/v1/chat/completions` protocol; no credentials required.
    ///
    /// - Parameters:
    ///   - defaultBaseURL: The URL used when no per-user override is
    ///     supplied. Defaults to `http://localhost:1234`.
    ///   - defaultModel: The model id to request until the user picks one.
    ///     LM Studio ignores the field but a non-empty value is required.
    public static func lmStudio(
        defaultBaseURL: URL = URL(string: "http://localhost:1234")!,
        defaultModel: String = "local-model"
    ) -> Backend {
        Backend(
            id: Builtin.lmStudio.id,
            displayName: Builtin.lmStudio.displayName,
            defaultModel: defaultModel,
            hasCredentials: { _ in true },
            makeProvider: { _, model, maxTokens, baseURL in
                let config = OpenAIConfig.lmStudio(
                    model: model,
                    baseURL: baseURL ?? defaultBaseURL,
                    maxTokens: maxTokens
                )
                return OpenAIProvider(config: config)
            },
            modelFilter: Backend.localChatFilter
        )
    }

    /// A local Ollama server. Speaks the OpenAI-compatible
    /// `/v1/chat/completions` protocol; no credentials required.
    ///
    /// - Parameters:
    ///   - defaultBaseURL: The URL used when no per-user override is
    ///     supplied. Defaults to `http://localhost:11434`.
    ///   - defaultModel: The model id to request until the user picks one.
    public static func ollama(
        defaultBaseURL: URL = URL(string: "http://localhost:11434")!,
        defaultModel: String = "llama3.2"
    ) -> Backend {
        Backend(
            id: Builtin.ollama.id,
            displayName: Builtin.ollama.displayName,
            defaultModel: defaultModel,
            hasCredentials: { _ in true },
            makeProvider: { _, model, maxTokens, baseURL in
                var config = OpenAIConfig(
                    apiKey: "ollama",
                    model: model,
                    maxTokens: maxTokens,
                    baseURL: baseURL ?? defaultBaseURL
                )
                // Ollama's OpenAI shim rejects unknown fields on some
                // versions; keep the field opt-in via the shared config.
                config.usesMaxCompletionTokens = false
                return OpenAIProvider(config: config)
            },
            modelFilter: Backend.localChatFilter
        )
    }

    // MARK: - Shared helpers

    /// Keeps `claude-*` model ids, drops dated snapshots (`…-2025-12-11`).
    static let claudePrefixFilter: @Sendable (String) -> Bool = { id in
        if Backend.hasDatedSnapshotSuffix(id) { return false }
        return id.hasPrefix("claude-")
    }

    /// Keeps every model id offered by a local server that isn't obviously
    /// non-chat. Local catalogs are user-curated so there's no whitelist to
    /// match — the filter just drops embeddings, audio, image, and vision-
    /// only surfaces.
    static let localChatFilter: @Sendable (String) -> Bool = { id in
        let excluded = [
            "embed", "embedding",
            "whisper", "audio", "tts",
            "dall-e", "image", "clip",
            "moderation", "rerank"
        ]
        return !excluded.contains(where: id.contains)
    }

    /// Keeps `gpt-*`, `chatgpt`, `o1`, `o3`, `o4` families; drops embeddings,
    /// audio, image, and other non-chat surfaces.
    static let openAIChatFilter: @Sendable (String) -> Bool = { id in
        if Backend.hasDatedSnapshotSuffix(id) { return false }
        let excluded = [
            "audio", "image", "realtime", "transcribe", "tts",
            "whisper", "embedding", "moderation", "search",
            "dall-e", "codex", "computer-use"
        ]
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
