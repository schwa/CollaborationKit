import Foundation

/// Encodes ``Message`` values into the Anthropic Messages API request body.
enum AnthropicWire {
    /// Builds the JSON request body for the Messages API streaming endpoint.
    /// The identity block Claude Code's OAuth endpoint requires as the first
    /// system block; the subscription endpoint rejects requests without it.
    static let claudeCodeIdentity = "You are Claude Code, Anthropic's official CLI for Claude."

    static func requestBody(
        model: String,
        maxTokens: Int,
        system: String?,
        messages: [Message],
        tools: [ToolSpec],
        oauth: Bool = false
    ) -> JSONValue {
        var root: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(maxTokens)),
            "stream": .bool(true),
            "messages": .array(messages.map(encode))
        ]
        if oauth {
            // OAuth requires the identity block first, as structured system blocks.
            var blocks: [JSONValue] = [
                .object(["type": "text", "text": .string(claudeCodeIdentity)])
            ]
            if let system, !system.isEmpty {
                blocks.append(.object(["type": "text", "text": .string(system)]))
            }
            root["system"] = .array(blocks)
        } else if let system {
            root["system"] = .string(system)
        }
        if !tools.isEmpty {
            root["tools"] = .array(tools.map(encode))
        }
        return .object(root)
    }

    private static func encode(_ tool: ToolSpec) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "input_schema": tool.inputSchema
        ])
    }

    private static func encode(_ message: Message) -> JSONValue {
        .object([
            "role": .string(message.role.rawValue),
            "content": .array(message.content.map(encode))
        ])
    }

    private static func encode(_ block: ContentBlock) -> JSONValue {
        switch block {
        case .text(let text):
            return .object([
                "type": .string("text"),
                "text": .string(text)
            ])

        case .toolUse(let use):
            return .object([
                "type": .string("tool_use"),
                "id": .string(use.id),
                "name": .string(use.name),
                "input": use.input
            ])

        case .toolResult(let result):
            var object: [String: JSONValue] = [
                "type": .string("tool_result"),
                "tool_use_id": .string(result.toolUseID),
                "content": .string(result.content)
            ]
            if result.isError {
                object["is_error"] = .bool(true)
            }
            return .object(object)
        }
    }
}
