import Foundation

/// A ``ModelProvider`` backed by the Anthropic Messages API (streaming).
///
/// Everything cross-cutting — HTTP, SSE, retry, error mapping — comes from
/// the ``WireProvider`` extension. This type declares only the Anthropic
/// specifics: request encoding, auth headers, the streaming accumulator, and
/// the model-catalog endpoint.
public struct AnthropicProvider: WireProvider {
    public let config: AnthropicConfig
    public let urlSession: URLSession
    public let retryPolicy: RetryPolicy

    public init(
        config: AnthropicConfig,
        urlSession: URLSession = .shared,
        retryPolicy: RetryPolicy = .default
    ) {
        self.config = config
        self.urlSession = urlSession
        self.retryPolicy = retryPolicy
    }

    // MARK: - WireProvider

    public func makeChatRequest(
        messages: [Message],
        system: String?,
        tools: [ToolSpec]
    ) async throws -> URLRequest {
        let body = AnthropicWire.requestBody(
            model: config.model,
            maxTokens: config.maxTokens,
            system: system,
            messages: messages,
            tools: tools,
            oauth: config.isOAuth,
            cacheControl: config.promptCaching
        )
        var request = URLRequest(url: config.baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await applyAuthHeaders(to: &request)
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    public func makeAccumulator() -> any ServerSentEventSink { AnthropicWire.Accumulator() }

    public func httpError(status: Int, body: String) -> Error {
        AnthropicError.httpError(status: status, body: body)
    }

    public func makeModelsRequest() async throws -> URLRequest? {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("v1/models"))
        request.httpMethod = "GET"
        try await applyAuthHeaders(to: &request)
        return request
    }

    public func decodeModels(_ json: JSONValue) -> [ModelInfo] {
        guard case .object(let root) = json, case .array(let data)? = root["data"] else { return [] }
        let formatter = ISO8601DateFormatter()
        return data.compactMap { entry in
            guard case .object(let object) = entry,
                  case .string(let id)? = object["id"] else { return nil }
            var displayName: String?
            if case .string(let name)? = object["display_name"] { displayName = name }
            var created: Date?
            if case .string(let createdAt)? = object["created_at"] {
                created = formatter.date(from: createdAt)
            }
            return ModelInfo(id: id, displayName: displayName, created: created)
        }
    }

    // MARK: - Auth headers

    /// Beta features Claude Code's OAuth endpoint expects.
    private static let oauthBetas = [
        "claude-code-20250219",
        "oauth-2025-04-20",
        "fine-grained-tool-streaming-2025-05-14",
        "interleaved-thinking-2025-05-14"
    ].joined(separator: ",")
    private static let oauthUserAgent = "claude-code/2.1.97"

    private func applyAuthHeaders(to request: inout URLRequest) async throws {
        request.setValue(config.apiVersion, forHTTPHeaderField: "anthropic-version")
        switch config.auth {
        case .apiKey(let key):
            request.setValue(key, forHTTPHeaderField: "x-api-key")

        case .oauth(let tokenProvider):
            let token = try await tokenProvider()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(Self.oauthBetas, forHTTPHeaderField: "anthropic-beta")
            request.setValue(Self.oauthUserAgent, forHTTPHeaderField: "user-agent")
            request.setValue("cli", forHTTPHeaderField: "x-app")
            request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
        }
    }
}

