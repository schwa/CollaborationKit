import Foundation

/// Translates between the neutral ``Message`` model and the OpenAI
/// `/v1/chat/completions` wire format.
///
/// The neutral message model (text / tool-use / tool-result blocks within a
/// message) is flattened into OpenAI's shape: assistant tool calls live in a
/// `tool_calls` array, and each tool result becomes its own `role: "tool"`
/// message. A single neutral message may therefore expand into several.
///
/// Both directions live here: ``requestBody(model:maxTokens:system:messages:tools:parallelToolCalls:usesMaxCompletionTokens:)``
/// encodes into the request body, and ``Accumulator`` reassembles streaming
/// chunks back into ``ProviderStreamEvent`` values.
enum OpenAIWire {
    static func requestBody(
        model: String,
        maxTokens: Int?,
        system: String?,
        messages: [Message],
        tools: [ToolSpec],
        parallelToolCalls: Bool? = nil,
        usesMaxCompletionTokens: Bool = false
    ) -> JSONValue {
        var wire: [JSONValue] = []
        if let system {
            wire.append(.object(["role": "system", "content": .string(system)]))
        }
        for message in messages {
            wire.append(contentsOf: encode(message))
        }

        var root: [String: JSONValue] = [
            "model": .string(model),
            "stream": .bool(true),
            "stream_options": .object(["include_usage": .bool(true)]),
            "messages": .array(wire)
        ]
        if let maxTokens {
            let key = usesMaxCompletionTokens ? "max_completion_tokens" : "max_tokens"
            root[key] = .number(Double(maxTokens))
        }
        if !tools.isEmpty {
            root["tools"] = .array(tools.map(encode))
        }
        if let parallelToolCalls {
            root["parallel_tool_calls"] = .bool(parallelToolCalls)
        }
        return .object(root)
    }

    private static func encode(_ tool: ToolSpec) -> JSONValue {
        .object([
            "type": "function",
            "function": .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": tool.inputSchema
            ])
        ])
    }

    /// Expands one neutral message into one or more OpenAI wire messages.
    private static func encode(_ message: Message) -> [JSONValue] {
        switch message.role {
        case .user:
            return encodeUser(message.content)

        case .assistant:
            return encodeAssistant(message.content)
        }
    }

    private static func encodeUser(_ blocks: [ContentBlock]) -> [JSONValue] {
        var out: [JSONValue] = []
        var text = ""
        var imageParts: [JSONValue] = []
        for block in blocks {
            switch block {
            case .text(let value):
                text += value

            case .image(let image):
                imageParts.append(.object([
                    "type": "image_url",
                    "image_url": .object([
                        "url": .string("data:\(image.mediaType);base64,\(image.base64Data)")
                    ])
                ]))

            case .toolCall:
                // Tool calls never appear in a user message.
                break
            }
        }
        // With images present, user content must be a multi-part array.
        if !imageParts.isEmpty {
            var parts: [JSONValue] = []
            if !text.isEmpty {
                parts.append(.object(["type": "text", "text": .string(text)]))
            }
            parts.append(contentsOf: imageParts)
            out.insert(.object(["role": "user", "content": .array(parts)]), at: 0)
        } else if !text.isEmpty {
            out.insert(.object(["role": "user", "content": .string(text)]), at: 0)
        }
        return out
    }

    /// Encodes an assistant domain message into the assistant wire message plus
    /// any trailing `role: "tool"` result messages (OpenAI carries tool results
    /// as their own messages, not inside the assistant turn).
    private static func encodeAssistant(_ blocks: [ContentBlock]) -> [JSONValue] {
        var text = ""
        var toolCalls: [JSONValue] = []
        var toolResults: [JSONValue] = []
        for block in blocks {
            switch block {
            case .text(let value):
                text += value

            case .toolCall(let call):
                let arguments = encodeArguments(call.use.input)
                toolCalls.append(.object([
                    "id": .string(call.use.id),
                    "type": "function",
                    "function": .object([
                        "name": .string(call.use.name),
                        "arguments": .string(arguments)
                    ])
                ]))
                if let result = call.result {
                    toolResults.append(.object([
                        "role": "tool",
                        "tool_call_id": .string(result.toolUseID),
                        "content": .string(result.content)
                    ]))
                }

            case .image:
                // Images never appear in an assistant message.
                break
            }
        }
        var object: [String: JSONValue] = ["role": "assistant"]
        object["content"] = text.isEmpty ? .null : .string(text)
        if !toolCalls.isEmpty {
            object["tool_calls"] = .array(toolCalls)
        }
        return [.object(object)] + toolResults
    }

    /// OpenAI tool arguments are a JSON *string*, not a nested object.
    private static func encodeArguments(_ input: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(input),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// Accumulates OpenAI streaming chunks into ``ProviderStreamEvent`` values.
    /// One in-flight tool call being reassembled by ``Accumulator``.
    private struct PartialCall {
        var id: String?
        var name: String?
        var arguments: String = ""
    }

    struct Accumulator: ServerSentEventSink {
        let doneSentinel: String? = "[DONE]"

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
            // OpenAI reports server-side prompt-cache hits under
            // `prompt_tokens_details.cached_tokens`. Surface it as
            // `cacheReadInputTokens` so hosts can verify caching is engaging
            // without having to know each provider's shape.
            if case .object(let details)? = object["prompt_tokens_details"],
               case .number(let cached)? = details["cached_tokens"] {
                usage.cacheReadInputTokens = Int(cached)
            }
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
}
