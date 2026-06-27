import Foundation

/// Encodes ``Message`` values into the OpenAI `/v1/chat/completions` request body.
///
/// The neutral message model (text / tool-use / tool-result blocks within a
/// message) is flattened into OpenAI's shape: assistant tool calls live in a
/// `tool_calls` array, and each tool result becomes its own `role: "tool"`
/// message. A single neutral message may therefore expand into several.
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
                break // tool calls never appear in a user message
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
                break // never appears in an assistant message
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
}
