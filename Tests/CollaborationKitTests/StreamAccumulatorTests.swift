@testable import CollaborationKit
import Foundation
import Testing

@Test
func accumulatorAssemblesTextBlock() throws {
    var acc = StreamAccumulator()
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
    var acc = StreamAccumulator()
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
    var acc = StreamAccumulator()
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
    var acc = StreamAccumulator()
    #expect(throws: AnthropicError.self) {
        _ = try acc.consume(#"{"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#)
    }
}
