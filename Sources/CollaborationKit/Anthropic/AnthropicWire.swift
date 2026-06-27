import Foundation

/// Encodes ``Message`` values into the Anthropic Messages API request body.
enum AnthropicWire {
    /// Builds the JSON request body for the Messages API streaming endpoint.
    /// The identity block Claude Code's OAuth endpoint requires as the first
    /// system block; the subscription endpoint rejects requests without it.
    static let claudeCodeIdentity = "You are Claude Code, Anthropic's official CLI for Claude."

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
                .object(["type": "text", "text": .string(claudeCodeIdentity)])
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
}
