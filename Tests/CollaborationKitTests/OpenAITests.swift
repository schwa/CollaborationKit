@testable import CollaborationKit
import Foundation
import Testing

@Test
func openAIAccumulatorAssemblesText() throws {
    var acc = OpenAIStreamAccumulator()
    var events: [ProviderStreamEvent] = []
    events += try acc.consume(#"{"choices":[{"delta":{"content":"Hel"}}]}"#)
    events += try acc.consume(#"{"choices":[{"delta":{"content":"lo"}}]}"#)
    events += acc.finish()

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
func openAIAccumulatorAssemblesToolCallFromFragments() throws {
    var acc = OpenAIStreamAccumulator()
    _ = try acc.consume(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"edit","arguments":""}}]}}]}"#)
    _ = try acc.consume(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"oldText\":\"a\","}}]}}]}"#)
    _ = try acc.consume(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"newText\":\"b\"}"}}]}}]}"#)
    let events = acc.finish()

    var toolUse: ToolUse?
    for event in events {
        if case .toolUse(let use) = event { toolUse = use }
    }
    let use = try #require(toolUse)
    #expect(use.id == "call_1")
    #expect(use.name == "edit")
    #expect(use.input == .object(["oldText": "a", "newText": "b"]))
}

@Test
func openAIAccumulatorEmitsUsage() throws {
    var acc = OpenAIStreamAccumulator()
    _ = try acc.consume(#"{"choices":[{"delta":{"content":"hi"}}]}"#)
    _ = try acc.consume(#"{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3,"total_tokens":15}}"#)
    let events = acc.finish()

    var usage: TokenUsage?
    for event in events {
        if case .usage(let u) = event { usage = u }
    }
    #expect(usage == TokenUsage(inputTokens: 12, outputTokens: 3))
}

@Test
func openAIAccumulatorThrowsOnError() {
    var acc = OpenAIStreamAccumulator()
    #expect(throws: OpenAIError.self) {
        _ = try acc.consume(#"{"error":{"message":"model not found"}}"#)
    }
}

@Test
func openAIWireFlattensToolResultIntoToolMessage() {
    let messages: [Message] = [
        .user("hi"),
        // Domain shape: one assistant message whose tool call owns its result.
        Message(role: .assistant, content: [
            .toolCall(ToolCall(
                use: ToolUse(id: "call_1", name: "read", input: .object([:])),
                result: ToolResult(toolUseID: "call_1", content: "file contents")
            ))
        ])
    ]
    let body = OpenAIWire.requestBody(
        model: "m", maxTokens: nil, system: "sys", messages: messages, tools: []
    )
    guard case .object(let root) = body,
          case .array(let wire)? = root["messages"] else {
        Issue.record("unexpected body shape")
        return
    }
    // system, user, assistant(tool_calls), tool
    #expect(wire.count == 4)

    // Last message is a tool result with the correct id.
    guard case .object(let toolMessage) = wire[3],
          case .string(let role)? = toolMessage["role"],
          case .string(let callID)? = toolMessage["tool_call_id"] else {
        Issue.record("unexpected tool message shape")
        return
    }
    #expect(role == "tool")
    #expect(callID == "call_1")
}

@Test
func openAIRequestBodyOmitsParallelToolCallsByDefault() throws {
    let body = OpenAIWire.requestBody(
        model: "m", maxTokens: nil, system: nil, messages: [], tools: []
    )
    guard case .object(let root) = body else {
        Issue.record("unexpected body shape")
        return
    }
    #expect(root["parallel_tool_calls"] == nil)
}

@Test
func openAIRequestBodyEmitsParallelToolCallsWhenSet() throws {
    let body = OpenAIWire.requestBody(
        model: "m", maxTokens: nil, system: nil, messages: [], tools: [],
        parallelToolCalls: false
    )
    guard case .object(let root) = body,
          case .bool(let value)? = root["parallel_tool_calls"] else {
        Issue.record("expected parallel_tool_calls bool")
        return
    }
    #expect(value == false)
}

@Test
func openAIRequestBodyUsesMaxTokensByDefault() throws {
    let body = OpenAIWire.requestBody(
        model: "m", maxTokens: 100, system: nil, messages: [], tools: []
    )
    guard case .object(let root) = body else { Issue.record("bad shape"); return }
    #expect(root["max_tokens"] == .number(100))
    #expect(root["max_completion_tokens"] == nil)
}

@Test
func openAIRequestBodyUsesMaxCompletionTokensWhenSet() throws {
    let body = OpenAIWire.requestBody(
        model: "m", maxTokens: 100, system: nil, messages: [], tools: [],
        usesMaxCompletionTokens: true
    )
    guard case .object(let root) = body else { Issue.record("bad shape"); return }
    #expect(root["max_completion_tokens"] == .number(100))
    #expect(root["max_tokens"] == nil)
}

@Test
func openAIModelTokenParamHeuristic() throws {
    // Newer models require max_completion_tokens.
    for model in ["gpt-5", "gpt-5.5", "gpt-6", "o1", "o1-mini", "o3", "o4-mini"] {
        #expect(OpenAIConfig.modelRequiresMaxCompletionTokens(model), "\(model) should require max_completion_tokens")
    }
    // Older / local models keep max_tokens.
    for model in ["gpt-4o", "gpt-4.1", "gpt-3.5-turbo", "llama-3", "openhermes", ""] {
        #expect(!OpenAIConfig.modelRequiresMaxCompletionTokens(model), "\(model) should keep max_tokens")
    }
}

@Test
func openAIConfigOverrideBeatsHeuristic() throws {
    // gpt-5 would auto-detect true, but explicit false wins.
    let config = OpenAIConfig(apiKey: "k", model: "gpt-5", usesMaxCompletionTokens: false)
    #expect(config.resolvedUsesMaxCompletionTokens == false)
    // gpt-4o would auto-detect false, but explicit true wins.
    let other = OpenAIConfig(apiKey: "k", model: "gpt-4o", usesMaxCompletionTokens: true)
    #expect(other.resolvedUsesMaxCompletionTokens == true)
}

@Test
func openAIRequestBodyEncodesImageAsMultiPartUserContent() throws {
    let messages = [
        Message.user(text: "what is this?", images: [
            ImageContent(mediaType: "image/png", base64Data: "QUJD")
        ])
    ]
    let body = OpenAIWire.requestBody(
        model: "m", maxTokens: nil, system: nil, messages: messages, tools: []
    )
    guard case .object(let root) = body,
          case .array(let wire)? = root["messages"],
          case .object(let userMessage) = wire[0],
          case .array(let parts)? = userMessage["content"] else {
        Issue.record("unexpected body shape")
        return
    }
    #expect(wire.count == 1)
    #expect(userMessage["role"] == .string("user"))
    #expect(parts.count == 2)
    #expect(parts[0] == .object(["type": "text", "text": .string("what is this?")]))
    #expect(parts[1] == .object([
        "type": "image_url",
        "image_url": .object(["url": .string("data:image/png;base64,QUJD")])
    ]))
}
