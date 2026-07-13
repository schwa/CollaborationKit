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

    public func makeAccumulator() -> any ServerSentEventSink { OpenAIStreamAccumulator() }

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

/// Accumulates OpenAI streaming chunks into ``ProviderStreamEvent`` values.
struct OpenAIStreamAccumulator: ServerSentEventSink {
    let doneSentinel: String? = "[DONE]"

    private struct PartialCall {
        var id: String?
        var name: String?
        var arguments: String = ""
    }

    private var calls: [Int: PartialCall] = [:]
    private var sawText = false
    private var accumulatedText = ""
    private var usage: TokenUsage?

    mutating func consume(_ payload: String) throws -> [ProviderStreamEvent] {
        let data = Data(payload.utf8)
        let json: JSONValue
        do {
            json = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw OpenAIError.decodingError(payload)
        }
        guard case .object(let root) = json else { return [] }

        if case .object(let error)? = root["error"] {
            var message = "unknown error"
            if case .string(let m)? = error["message"] { message = m }
            throw OpenAIError.apiError(message: message)
        }

        if case .object(let usageObject)? = root["usage"] {
            captureUsage(usageObject)
        }

        guard case .array(let choices)? = root["choices"],
              case .object(let choice)? = choices.first,
              case .object(let delta)? = choice["delta"] else {
            return []
        }

        var events: [ProviderStreamEvent] = []

        if case .string(let content)? = delta["content"], !content.isEmpty {
            sawText = true
            accumulatedText += content
            events.append(.textDelta(content))
        }

        if case .array(let toolCalls)? = delta["tool_calls"] {
            for entry in toolCalls {
                accumulate(entry)
            }
        }

        return events
    }

    private mutating func captureUsage(_ object: [String: JSONValue]) {
        var usage = TokenUsage()
        if case .number(let prompt)? = object["prompt_tokens"] { usage.inputTokens = Int(prompt) }
        if case .number(let completion)? = object["completion_tokens"] { usage.outputTokens = Int(completion) }
        self.usage = usage
    }

    mutating func finish() -> [ProviderStreamEvent] {
        var events: [ProviderStreamEvent] = []
        if sawText {
            events.append(.text(accumulatedText))
        }
        if let usage {
            events.append(.usage(usage))
        }
        for index in calls.keys.sorted() {
            let call = calls[index]!
            guard let id = call.id, let name = call.name else { continue }
            let input = parseArguments(call.arguments)
            events.append(.toolUse(ToolUse(id: id, name: name, input: input)))
        }
        events.append(.messageComplete(stopReason: nil))
        return events
    }

    private mutating func accumulate(_ entry: JSONValue) {
        guard case .object(let object) = entry,
              case .number(let indexValue)? = object["index"] else { return }
        let index = Int(indexValue)
        var call = calls[index] ?? PartialCall()

        if case .string(let id)? = object["id"], !id.isEmpty {
            call.id = id
        }
        if case .object(let function)? = object["function"] {
            if case .string(let name)? = function["name"], !name.isEmpty {
                call.name = name
            }
            if case .string(let fragment)? = function["arguments"] {
                call.arguments += fragment
            }
        }
        calls[index] = call
    }

    private func parseArguments(_ arguments: String) -> JSONValue {
        let text = arguments.isEmpty ? "{}" : arguments
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
            return .object([:])
        }
        return value
    }
}
