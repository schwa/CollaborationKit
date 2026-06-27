@testable import CollaborationKit
import Foundation
import Testing

@Test
func anthropicWireSplitsDomainToolCallIntoUserResultTurn() {
    // Domain shape: one assistant message whose tool call owns its result.
    let messages: [Message] = [
        .user("hi"),
        Message(role: .assistant, content: [
            .text("Reading."),
            .toolCall(ToolCall(
                use: ToolUse(id: "tu_1", name: "read", input: .object([:])),
                result: ToolResult(toolUseID: "tu_1", content: "file contents")
            ))
        ])
    ]
    let body = AnthropicWire.requestBody(
        model: "m", maxTokens: 100, system: "sys", messages: messages, tools: []
    )
    guard case .object(let root) = body,
          case .array(let wire)? = root["messages"] else {
        Issue.record("unexpected body shape")
        return
    }
    // The single assistant domain message expands into assistant(text+tool_use)
    // plus a following user(tool_result): user, assistant, user.
    #expect(wire.count == 3)

    // wire[1] is the assistant turn carrying text + tool_use.
    guard case .object(let assistant) = wire[1],
          case .string("assistant")? = assistant["role"],
          case .array(let assistantBlocks)? = assistant["content"] else {
        Issue.record("unexpected assistant shape")
        return
    }
    let types = assistantBlocks.compactMap { block -> String? in
        guard case .object(let object) = block, case .string(let type)? = object["type"] else { return nil }
        return type
    }
    #expect(types == ["text", "tool_use"])

    // wire[2] is a user turn carrying the tool_result with the matching id.
    guard case .object(let userTurn) = wire[2],
          case .string("user")? = userTurn["role"],
          case .array(let resultBlocks)? = userTurn["content"],
          case .object(let result)? = resultBlocks.first,
          case .string("tool_result")? = result["type"],
          case .string(let useID)? = result["tool_use_id"] else {
        Issue.record("unexpected tool_result shape")
        return
    }
    #expect(useID == "tu_1")
}
