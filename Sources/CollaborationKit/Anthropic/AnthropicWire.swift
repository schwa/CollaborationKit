import Foundation

/// The set of values Anthropic's OAuth (Claude subscription) endpoint
/// expects requests to carry so it treats them as coming from the official
/// Claude Code CLI.
///
/// These are the fragile bits of the unofficial OAuth contract: the system
/// identity block, the `anthropic-beta` list, the `user-agent`, and the
/// `x-app` tag. Keep them together so a single edit updates every callsite
/// (previously they were duplicated across ``AnthropicWire`` and
/// ``AnthropicProvider``).
enum ClaudeCodeIdentity {
    /// The identity block Claude Code's OAuth endpoint requires as the first
    /// system block; the subscription endpoint rejects requests without it.
    static let systemPrompt = "You are Claude Code, Anthropic's official CLI for Claude."

    /// Beta features Claude Code's OAuth endpoint expects on requests.
    static let betas = [
        "claude-code-20250219",
        "oauth-2025-04-20",
        "fine-grained-tool-streaming-2025-05-14",
        "interleaved-thinking-2025-05-14"
    ].joined(separator: ",")

    /// The `user-agent` value Claude Code sends on OAuth-authenticated calls.
    static let userAgent = "claude-code/2.1.311"

    /// The `x-app` value Claude Code sends on OAuth-authenticated calls.
    static let app = "cli"
}

/// Encodes ``Message`` values into the Anthropic Messages API request body.
enum AnthropicWire {
    /// Deprecated alias for ``ClaudeCodeIdentity/systemPrompt``. Kept because
    /// tests reference it under the old name.
    static var claudeCodeIdentity: String { ClaudeCodeIdentity.systemPrompt }

    /// A `cache_control` marker for an ephemeral (5-minute) cache breakpoint.
    private static let ephemeralCacheControl: JSONValue =
        .object(["type": .string("ephemeral")])

    static func requestBody(
        model: String,
        maxTokens: Int,
        system: String?,
        messages: [Message],
        tools: [ToolSpec],
        oauth: Bool = false,
        cacheControl: Bool = false
    ) -> JSONValue {
        var root: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(maxTokens)),
            "stream": .bool(true),
            "messages": .array(messages.flatMap(encode))
        ]
        if oauth {
            // OAuth requires the identity block first, as structured system blocks.
            var blocks: [JSONValue] = [
                .object(["type": "text", "text": .string(ClaudeCodeIdentity.systemPrompt)])
            ]
            if let system, !system.isEmpty {
                blocks.append(.object(["type": "text", "text": .string(system)]))
            }
            if cacheControl, !blocks.isEmpty {
                blocks[blocks.count - 1] = withCacheControl(blocks[blocks.count - 1])
            }
            root["system"] = .array(blocks)
        } else if let system {
            if cacheControl {
                root["system"] = .array([
                    withCacheControl(.object(["type": "text", "text": .string(system)]))
                ])
            } else {
                root["system"] = .string(system)
            }
        }
        if !tools.isEmpty {
            var encoded = tools.map(encode)
            // Mark the last tool: the breakpoint caches the whole tools array.
            if cacheControl {
                encoded[encoded.count - 1] = withCacheControl(encoded[encoded.count - 1])
            }
            root["tools"] = .array(encoded)
        }
        return .object(root)
    }

    /// Returns `block` with an ephemeral `cache_control` marker added. Expects
    /// `block` to be a JSON object; returns it unchanged otherwise.
    private static func withCacheControl(_ block: JSONValue) -> JSONValue {
        guard case .object(var object) = block else { return block }
        object["cache_control"] = ephemeralCacheControl
        return .object(object)
    }

    private static func encode(_ tool: ToolSpec) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "input_schema": tool.inputSchema
        ])
    }

    /// Expands one domain message into one or more Anthropic wire messages.
    ///
    /// A ``ToolCall`` is a single domain block, but Anthropic requires the
    /// `tool_use` in the assistant turn and the `tool_result` in a *following*
    /// user turn. So an assistant message that carries tool calls encodes as the
    /// assistant message (text + tool_use blocks) followed by a user message of
    /// tool_result blocks.
    private static func encode(_ message: Message) -> [JSONValue] {
        var primary: [JSONValue] = []
        var toolResults: [JSONValue] = []
        for block in message.content {
            switch block {
            case .text(let text):
                primary.append(.object(["type": .string("text"), "text": .string(text)]))

            case .image(let image):
                primary.append(.object([
                    "type": .string("image"),
                    "source": .object([
                        "type": .string("base64"),
                        "media_type": .string(image.mediaType),
                        "data": .string(image.base64Data)
                    ])
                ]))

            case .toolCall(let call):
                primary.append(.object([
                    "type": .string("tool_use"),
                    "id": .string(call.use.id),
                    "name": .string(call.use.name),
                    "input": call.use.input
                ]))
                if let result = call.result {
                    var object: [String: JSONValue] = [
                        "type": .string("tool_result"),
                        "tool_use_id": .string(result.toolUseID),
                        "content": .string(result.content)
                    ]
                    if result.isError {
                        object["is_error"] = .bool(true)
                    }
                    toolResults.append(.object(object))
                }
            }
        }

        var out: [JSONValue] = []
        if !primary.isEmpty {
            out.append(.object(["role": .string(message.role.rawValue), "content": .array(primary)]))
        }
        if !toolResults.isEmpty {
            // Tool results always go back to the model as a user turn.
            out.append(.object(["role": .string("user"), "content": .array(toolResults)]))
        }
        return out
    }

    /// Accumulates Anthropic SSE event payloads into ``ProviderStreamEvent`` values.
    ///
    /// Anthropic streams a sequence of JSON events. Text arrives as `text_delta`
    /// chunks within a `content_block`; tool use arrives as a `tool_use` block whose
    /// `input` is streamed as concatenated `input_json_delta` fragments. This type
    /// reassembles those fragments and emits completed blocks on `content_block_stop`.
    /// One in-flight content block being reassembled by ``Accumulator``.
    private struct Block {
        var type: String
        var toolID: String?
        var toolName: String?
        var partialJSON: String = ""
        var text: String = ""
    }

    struct Accumulator: ServerSentEventSink {
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
}
