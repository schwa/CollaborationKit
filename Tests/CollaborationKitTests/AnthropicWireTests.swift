@testable import CollaborationKit
import Foundation
import Testing

// Both halves of the Anthropic wire — encode (`requestBody`) and decode
// (`Accumulator`) — live in `AnthropicWire.swift`, so their tests live here.

// MARK: - Encode

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

// MARK: - Decode (Accumulator)

@Test
func accumulatorAssemblesTextBlock() throws {
    var acc = AnthropicWire.Accumulator()
    var events: [ProviderStreamEvent] = []
    events += try acc.consume(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
    events += try acc.consume(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#)
    events += try acc.consume(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#)
    events += try acc.consume(#"{"type":"content_block_stop","index":0}"#)

    var deltas = ""
    var finalText: String?
    for event in events {
        if case .textDelta(let d) = event { deltas += d }
        if case .text(let t) = event { finalText = t }
    }
    #expect(deltas == "Hello")
    #expect(finalText == "Hello")
}

@Test
func accumulatorAssemblesToolUseFromJSONFragments() throws {
    var acc = AnthropicWire.Accumulator()
    var events: [ProviderStreamEvent] = []
    events += try acc.consume(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_1","name":"edit","input":{}}}"#)
    events += try acc.consume(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"oldText\":\"a\","}}"#)
    events += try acc.consume(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"newText\":\"b\"}"}}"#)
    events += try acc.consume(#"{"type":"content_block_stop","index":0}"#)

    var toolUse: ToolUse?
    for event in events {
        if case .toolUse(let use) = event { toolUse = use }
    }
    let use = try #require(toolUse)
    #expect(use.id == "tu_1")
    #expect(use.name == "edit")
    #expect(use.input == .object(["oldText": "a", "newText": "b"]))
}

@Test
func accumulatorEmitsUsage() throws {
    var acc = AnthropicWire.Accumulator()
    var events: [ProviderStreamEvent] = []
    events += try acc.consume(#"{"type":"message_start","message":{"usage":{"input_tokens":42,"output_tokens":1}}}"#)
    events += try acc.consume(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":99}}"#)

    var usage: TokenUsage?
    for event in events {
        if case .usage(let u) = event { usage = u }
    }
    #expect(usage == TokenUsage(inputTokens: 42, outputTokens: 99))
}

@Test
func accumulatorThrowsOnAPIError() {
    var acc = AnthropicWire.Accumulator()
    #expect(throws: AnthropicError.self) {
        _ = try acc.consume(#"{"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#)
    }
}

// MARK: - Round-trip

/// Decode a simulated Anthropic stream into events, thread the resulting text +
/// tool_use into the next assistant turn, then encode that turn back to the
/// wire and check the pieces survive. Only possible now that encode and decode
/// live in the same place.
@Test
func anthropicWireRoundTripsAssistantTurn() throws {
    var acc = AnthropicWire.Accumulator()
    var events: [ProviderStreamEvent] = []
    events += try acc.consume(#"{"type":"message_start","message":{"usage":{"input_tokens":1,"output_tokens":0}}}"#)
    events += try acc.consume(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
    events += try acc.consume(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Reading."}}"#)
    events += try acc.consume(#"{"type":"content_block_stop","index":0}"#)
    events += try acc.consume(#"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu_1","name":"read","input":{}}}"#)
    events += try acc.consume(#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"a\"}"}}"#)
    events += try acc.consume(#"{"type":"content_block_stop","index":1}"#)

    // Reconstruct the assistant Message the model just produced.
    var assistantBlocks: [ContentBlock] = []
    for event in events {
        switch event {
        case .text(let text):
            assistantBlocks.append(.text(text))
        case .toolUse(let use):
            assistantBlocks.append(.toolCall(ToolCall(
                use: use,
                result: ToolResult(toolUseID: use.id, content: "ok")
            )))
        default:
            break
        }
    }
    let assistant = Message(role: .assistant, content: assistantBlocks)

    // Re-encode into the next request. The round-trip: decoded stream ->
    // Message -> wire request body.
    let body = AnthropicWire.requestBody(
        model: "m", maxTokens: 100, system: nil, messages: [.user("hi"), assistant], tools: []
    )
    guard case .object(let root) = body,
          case .array(let wire)? = root["messages"] else {
        Issue.record("unexpected body shape")
        return
    }
    // user, assistant(text+tool_use), user(tool_result)
    #expect(wire.count == 3)
    guard case .object(let assistantTurn) = wire[1],
          case .array(let blocks)? = assistantTurn["content"] else {
        Issue.record("unexpected assistant turn")
        return
    }
    let types = blocks.compactMap { block -> String? in
        guard case .object(let object) = block, case .string(let t)? = object["type"] else { return nil }
        return t
    }
    #expect(types == ["text", "tool_use"])
}
