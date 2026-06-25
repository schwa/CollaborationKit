import Foundation

/// Configuration for the OpenAI-compatible provider.
///
/// Works with the OpenAI API, LM Studio, Ollama, and other servers that speak the
/// `/v1/chat/completions` protocol. For LM Studio the base URL is typically
/// `http://localhost:1234` and the API key is ignored (pass any non-empty value).
public struct OpenAIConfig: Sendable {
    /// The API key. Ignored by most local servers; pass any value there.
    public var apiKey: String
    /// The model identifier to request (server-specific).
    public var model: String
    /// The maximum number of tokens to generate. `nil` lets the server decide.
    public var maxTokens: Int?
    /// The API base URL (no trailing `/v1`). Defaults to OpenAI's endpoint.
    public var baseURL: URL
    /// Whether the server may emit multiple tool calls in a single turn.
    ///
    /// `nil` (the default) lets the server decide. Set to `false` to serialize
    /// tool calls, which is useful for agentic edit/read/compile loops where a
    /// blind tool call alongside another can operate on stale state.
    public var parallelToolCalls: Bool?

    public init(
        apiKey: String,
        model: String,
        maxTokens: Int? = nil,
        baseURL: URL = URL(string: "https://api.openai.com")!,
        parallelToolCalls: Bool? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.baseURL = baseURL
        self.parallelToolCalls = parallelToolCalls
    }

    /// A configuration pointed at a local LM Studio server.
    ///
    /// - Parameters:
    ///   - model: The model identifier loaded in LM Studio.
    ///   - baseURL: The server URL. Defaults to `http://localhost:1234`.
    ///   - maxTokens: An optional generation cap.
    public static func lmStudio(
        model: String,
        baseURL: URL = URL(string: "http://localhost:1234")!,
        maxTokens: Int? = nil,
        parallelToolCalls: Bool? = nil
    ) -> Self {
        Self(apiKey: "lm-studio", model: model, maxTokens: maxTokens, baseURL: baseURL, parallelToolCalls: parallelToolCalls)
    }
}

/// An error raised by the OpenAI-compatible provider's transport or decoding.
public enum OpenAIError: Error, Sendable {
    /// The HTTP response was non-2xx. Carries the status and body text.
    case httpError(status: Int, body: String)
    /// A server-sent event could not be decoded.
    case decodingError(String)
    /// The API returned an explicit error payload.
    case apiError(message: String)
}
