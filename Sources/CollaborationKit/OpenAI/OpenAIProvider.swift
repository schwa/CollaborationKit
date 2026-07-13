import Foundation

/// A ``ModelProvider`` backed by the OpenAI-compatible
/// `/v1/chat/completions` streaming API.
///
/// Everything cross-cutting — HTTP, SSE, retry, error mapping — comes from
/// the ``WireProvider`` extension. This type declares only the OpenAI
/// specifics: request encoding, the streaming accumulator, and the
/// model-catalog endpoint. Works with the OpenAI API and local servers such
/// as LM Studio and Ollama.
public struct OpenAIProvider: WireProvider {
    public let config: OpenAIConfig
    public let urlSession: URLSession
    public let retryPolicy: RetryPolicy

    public init(
        config: OpenAIConfig,
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
        let body = OpenAIWire.requestBody(
            model: config.model,
            maxTokens: config.maxTokens,
            system: system,
            messages: messages,
            tools: tools,
            parallelToolCalls: config.parallelToolCalls,
            usesMaxCompletionTokens: config.resolvedUsesMaxCompletionTokens
        )
        var request = URLRequest(url: config.baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    public func makeAccumulator() -> any ServerSentEventSink { OpenAIWire.Accumulator() }

    public func httpError(status: Int, body: String) -> Error {
        OpenAIError.httpError(status: status, body: body)
    }

    public func makeModelsRequest() async throws -> URLRequest? {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("v1/models"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func decodeModels(_ json: JSONValue) -> [ModelInfo] {
        guard case .object(let root) = json, case .array(let data)? = root["data"] else { return [] }
        return data.compactMap { entry in
            guard case .object(let object) = entry,
                  case .string(let id)? = object["id"] else { return nil }
            var ownedBy: String?
            if case .string(let owner)? = object["owned_by"] { ownedBy = owner }
            var created: Date?
            if case .number(let seconds)? = object["created"] {
                created = Date(timeIntervalSince1970: seconds)
            }
            return ModelInfo(id: id, ownedBy: ownedBy, created: created)
        }
    }
}

