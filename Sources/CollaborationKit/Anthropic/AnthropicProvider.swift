import Foundation

/// A ``ModelProvider`` backed by the Anthropic Messages API (streaming).
public struct AnthropicProvider: ModelProvider, ModelLister {
    private let config: AnthropicConfig
    private let urlSession: URLSession

    public init(config: AnthropicConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    public func send(
        messages: [Message],
        system: String?,
        tools: [ToolSpec]
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        StreamingTransport.stream(
            request: { try await makeRequest(messages: messages, system: system, tools: tools) },
            urlSession: urlSession,
            makeSink: { StreamAccumulator() },
            httpError: { status, body in AnthropicError.httpError(status: status, body: body) }
        )
    }

    /// Beta features Claude Code's OAuth endpoint expects.
    private static let oauthBetas = [
        "claude-code-20250219",
        "oauth-2025-04-20",
        "fine-grained-tool-streaming-2025-05-14",
        "interleaved-thinking-2025-05-14"
    ].joined(separator: ",")
    private static let oauthUserAgent = "claude-code/2.1.97"

    private func makeRequest(messages: [Message], system: String?, tools: [ToolSpec]) async throws -> URLRequest {
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
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Fetches available models from `GET /v1/models`.
    public func listModels() async throws -> [ModelInfo] {
        let mapError: @Sendable (Int, String) -> Error = { status, body in
            AnthropicError.httpError(status: status, body: body)
        }
        let json = try await StreamingTransport.fetchJSON(
            request: { try await makeModelsRequest() },
            urlSession: urlSession,
            httpError: mapError
        )
        guard case .object(let root) = json, case .array(let data)? = root["data"] else {
            return []
        }
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

    private func makeModelsRequest() async throws -> URLRequest {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("v1/models"))
        request.httpMethod = "GET"
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
        return request
    }
}

/// Accumulates Anthropic SSE event payloads into ``ProviderStreamEvent`` values.
///
/// Anthropic streams a sequence of JSON events. Text arrives as `text_delta`
/// chunks within a `content_block`; tool use arrives as a `tool_use` block whose
/// `input` is streamed as concatenated `input_json_delta` fragments. This type
/// reassembles those fragments and emits completed blocks on `content_block_stop`.
struct StreamAccumulator: ServerSentEventSink {
    private struct Block {
        var type: String
        var toolID: String?
        var toolName: String?
        var partialJSON: String = ""
        var text: String = ""
    }

    private var blocks: [Int: Block] = [:]
    private var inputTokens = 0
    private var cacheCreationInputTokens = 0
    private var cacheReadInputTokens = 0

    mutating func consume(_ payload: String) throws -> [ProviderStreamEvent] {
        let data = Data(payload.utf8)
        let json: JSONValue
        do {
            json = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw AnthropicError.decodingError(payload)
        }
        guard case .object(let root) = json,
              case .string(let type)? = root["type"] else {
            return []
        }

        switch type {
        case "error":
            let (errType, message) = errorFields(root["error"])
            throw AnthropicError.apiError(type: errType, message: message)

        case "content_block_start":
            handleBlockStart(root)
            return []

        case "content_block_delta":
            return handleBlockDelta(root)

        case "content_block_stop":
            return handleBlockStop(root)

        case "message_start":
            captureInputTokens(root)
            return []

        case "message_delta":
            return handleMessageDelta(root)

        case "message_stop":
            return [.messageComplete(stopReason: nil)]

        default:
            return []
        }
    }

    private mutating func handleBlockStart(_ root: [String: JSONValue]) {
        guard case .number(let indexValue)? = root["index"] else { return }
        let index = Int(indexValue)
        guard case .object(let block)? = root["content_block"],
              case .string(let blockType)? = block["type"] else { return }

        var newBlock = Block(type: blockType)
        if blockType == "tool_use" {
            if case .string(let id)? = block["id"] { newBlock.toolID = id }
            if case .string(let name)? = block["name"] { newBlock.toolName = name }
        }
        blocks[index] = newBlock
    }

    private mutating func handleBlockDelta(_ root: [String: JSONValue]) -> [ProviderStreamEvent] {
        guard case .number(let indexValue)? = root["index"] else { return [] }
        let index = Int(indexValue)
        guard case .object(let delta)? = root["delta"],
              case .string(let deltaType)? = delta["type"] else { return [] }

        switch deltaType {
        case "text_delta":
            guard case .string(let text)? = delta["text"] else { return [] }
            blocks[index]?.text += text
            return [.textDelta(text)]

        case "input_json_delta":
            guard case .string(let fragment)? = delta["partial_json"] else { return [] }
            blocks[index]?.partialJSON += fragment
            return []

        default:
            return []
        }
    }

    private mutating func handleBlockStop(_ root: [String: JSONValue]) -> [ProviderStreamEvent] {
        guard case .number(let indexValue)? = root["index"] else { return [] }
        let index = Int(indexValue)
        guard let block = blocks.removeValue(forKey: index) else { return [] }

        switch block.type {
        case "text":
            return [.text(block.text)]

        case "tool_use":
            guard let id = block.toolID, let name = block.toolName else { return [] }
            let input = parseToolInput(block.partialJSON)
            return [.toolUse(ToolUse(id: id, name: name, input: input))]

        default:
            return []
        }
    }

    private mutating func captureInputTokens(_ root: [String: JSONValue]) {
        guard case .object(let message)? = root["message"],
              case .object(let usage)? = message["usage"] else { return }
        if case .number(let input)? = usage["input_tokens"] {
            inputTokens = Int(input)
        }
        if case .number(let created)? = usage["cache_creation_input_tokens"] {
            cacheCreationInputTokens = Int(created)
        }
        if case .number(let read)? = usage["cache_read_input_tokens"] {
            cacheReadInputTokens = Int(read)
        }
    }

    private func handleMessageDelta(_ root: [String: JSONValue]) -> [ProviderStreamEvent] {
        var events: [ProviderStreamEvent] = []
        if case .object(let usage)? = root["usage"], case .number(let output)? = usage["output_tokens"] {
            events.append(.usage(TokenUsage(
                inputTokens: inputTokens,
                outputTokens: Int(output),
                cacheCreationInputTokens: cacheCreationInputTokens,
                cacheReadInputTokens: cacheReadInputTokens
            )))
        }
        if case .object(let delta)? = root["delta"], case .string(let stopReason)? = delta["stop_reason"] {
            events.append(.messageComplete(stopReason: stopReason))
        }
        return events
    }

    private func parseToolInput(_ partialJSON: String) -> JSONValue {
        let text = partialJSON.isEmpty ? "{}" : partialJSON
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
            return .object([:])
        }
        return value
    }

    private func errorFields(_ value: JSONValue?) -> (String, String) {
        guard case .object(let error)? = value else { return ("unknown", "unknown error") }
        var type = "unknown"
        var message = "unknown error"
        if case .string(let t)? = error["type"] { type = t }
        if case .string(let m)? = error["message"] { message = m }
        return (type, message)
    }
}
