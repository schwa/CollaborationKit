import Foundation

/// How the Anthropic provider authenticates.
public enum AnthropicAuth: Sendable {
    /// A standard, billed API key sent via `x-api-key`.
    case apiKey(String)

    /// A Claude subscription OAuth token sent via `Authorization: Bearer`.
    ///
    /// The associated closure returns a currently-valid access token, refreshing
    /// it as needed; the provider calls it before each request. Using OAuth also
    /// engages the Claude Code beta headers and identity system block.
    ///
    /// > Important: OAuth uses the Claude Code client and is unofficial; it may
    /// > violate Anthropic's terms and may break without notice.
    case oauth(@Sendable () async throws -> String)
}

/// Configuration for the Anthropic provider.
///
/// The package never reads the environment or keychain itself; callers supply
/// credentials here, sourced however they prefer.
public struct AnthropicConfig: Sendable {
    /// How to authenticate (API key or subscription OAuth).
    public var auth: AnthropicAuth
    /// The model identifier to request (e.g. `"claude-sonnet-4-5"`).
    public var model: String
    /// The maximum number of tokens to generate per response.
    public var maxTokens: Int
    /// The API base URL. Override for proxies or compatible gateways.
    public var baseURL: URL
    /// The Anthropic API version header value.
    public var apiVersion: String
    /// Whether to add `cache_control` breakpoints to the stable request prefix
    /// (system prompt and tools) so Anthropic caches and reuses it across
    /// requests. Cache hits cost ~10% of normal input price; writes cost ~25%
    /// more. Defaults to `true`.
    public var promptCaching: Bool

    public init(
        auth: AnthropicAuth,
        model: String = "claude-sonnet-4-5",
        maxTokens: Int = 4_096,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        apiVersion: String = "2023-06-01",
        promptCaching: Bool = true
    ) {
        self.auth = auth
        self.model = model
        self.maxTokens = maxTokens
        self.baseURL = baseURL
        self.apiVersion = apiVersion
        self.promptCaching = promptCaching
    }

    /// Convenience initializer for API-key authentication.
    public init(
        apiKey: String,
        model: String = "claude-sonnet-4-5",
        maxTokens: Int = 4_096,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        apiVersion: String = "2023-06-01",
        promptCaching: Bool = true
    ) {
        self.init(auth: .apiKey(apiKey), model: model, maxTokens: maxTokens, baseURL: baseURL, apiVersion: apiVersion, promptCaching: promptCaching)
    }

    var isOAuth: Bool {
        if case .oauth = auth { return true }
        return false
    }
}

/// An error raised by the Anthropic provider's transport or decoding.
public enum AnthropicError: Error, Sendable {
    /// The HTTP response was non-2xx. Carries the status and body text.
    case httpError(status: Int, body: String)
    /// A server-sent event could not be decoded.
    case decodingError(String)
    /// The API returned an explicit error event.
    case apiError(type: String, message: String)
}
