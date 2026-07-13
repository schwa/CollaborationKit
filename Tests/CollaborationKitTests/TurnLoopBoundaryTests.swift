@testable import CollaborationKit
import Foundation
import os
import Testing

/// Boundary tests for the ``LLMSession`` turn loop after the runLoop
/// decomposition (#10). The extracted seams — `runTurn` /
/// `streamAssistantMessage` / `runPendingTools` — are actor-private, so
/// these tests assert their invariants through the public `events` stream
/// and `messages` history: event ordering across a multi-tool turn, the
/// terminate-vs-continue split between `TurnOutcome.complete` and
/// `.needsMoreTurns`, and the `maxIterations` guard when a provider never
/// stops calling tools.
///
/// End-to-end coverage (final text, tool results attached in place, error
/// mapping, approval) lives in `SessionTests`; this file focuses on the
/// invariants the decomposition is meant to preserve.
private actor ScriptedProvider: ModelProvider {
    private var responses: [[ProviderStreamEvent]]
    private var index = 0

    init(_ responses: [[ProviderStreamEvent]]) {
        self.responses = responses
    }

    private func next() -> [ProviderStreamEvent] {
        defer { index += 1 }
        guard index < responses.count else { return [.messageComplete(stopReason: "end_turn")] }
        return responses[index]
    }

    nonisolated func send(
        messages _: [Message],
        system _: String?,
        tools _: [ToolSpec]
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let events = await self.next()
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}

/// A no-op tool that records every input it was called with. Used to observe
/// tool dispatch order from the outside.
private final class RecordingTool: Tool, @unchecked Sendable {
    struct Input: Decodable, Sendable {
        let tag: String
    }

    let toolName: String
    private let lock = OSAllocatedUnfairLock(initialState: [String]())

    var tags: [String] {
        lock.withLock { $0 }
    }

    init(name: String) {
        self.toolName = name
    }

    var name: String { toolName }
    var description: String { "recording tool" }
    var inputSchema: JSONValue {
        .object([
            "type": "object",
            "properties": .object(["tag": .object(["type": "string"])]),
            "required": .array(["tag"])
        ])
    }

    // Conformance to the Tool protocol dictates `async throws`; this body
    // doesn't need either but the signature must match the requirement.
    // swiftlint:disable:next async_without_await unneeded_throws_rethrows
    func call(_ input: Input) async throws -> String {
        lock.withLock { $0.append(input.tag) }
        return "ok:\(input.tag)"
    }
}

@Test
func turnCompleteEventFiresExactlyOnceAtTheEndOfTheLoop() async throws {
    // Two-turn script: turn 1 calls a tool, turn 2 emits final text.
    let doc = InMemoryDocument("hi")
    let provider = ScriptedProvider([
        [
            .toolUse(ToolUse(id: "t1", name: "read", input: .object([:]))),
            .messageComplete(stopReason: "tool_use")
        ],
        [.text("final."), .messageComplete(stopReason: "end_turn")]
    ])
    let session = LLMSession(provider: provider, tools: .fileTools(for: doc))

    // Collect events in the order they arrive.
    let stream = session.events
    let collector = Task { () -> [SessionEvent] in
        var received: [SessionEvent] = []
        for await event in stream {
            received.append(event)
            if case .turnComplete = event { break }
        }
        return received
    }

    _ = try await session.send("hi")
    let received = await collector.value

    // Exactly one turnComplete, and it's the last event.
    let turnCompletes = received.filter { if case .turnComplete = $0 { true } else { false } }
    #expect(turnCompletes.count == 1)
    #expect({ if case .turnComplete = received.last { true } else { false } }())
}

@Test
func multiToolTurnEmitsAllToolCallsBeforeAnyToolResults() async throws {
    // One turn returns two tool calls in a row; the extracted
    // streamAssistantMessage must yield both .toolCall events before
    // runPendingTools yields any .toolResult events.
    let toolA = RecordingTool(name: "a")
    let toolB = RecordingTool(name: "b")
    let provider = ScriptedProvider([
        [
            .toolUse(ToolUse(id: "a1", name: "a", input: .object(["tag": .string("A")]))),
            .toolUse(ToolUse(id: "b1", name: "b", input: .object(["tag": .string("B")]))),
            .messageComplete(stopReason: "tool_use")
        ],
        [.text("done."), .messageComplete(stopReason: "end_turn")]
    ])
    let session = LLMSession(
        provider: provider,
        tools: [toolA.eraseToAnyTool(), toolB.eraseToAnyTool()]
    )

    let stream = session.events
    let collector = Task { () -> [SessionEvent] in
        var received: [SessionEvent] = []
        for await event in stream {
            received.append(event)
            if case .turnComplete = event { break }
        }
        return received
    }

    _ = try await session.send("go")
    let received = await collector.value

    // Every .toolCall must appear before every .toolResult in the stream.
    let firstResultIndex = received.firstIndex { if case .toolResult = $0 { true } else { false } }
    let lastCallIndex = received.lastIndex { if case .toolCall = $0 { true } else { false } }
    #expect(firstResultIndex != nil)
    #expect(lastCallIndex != nil)
    if let firstResultIndex, let lastCallIndex {
        #expect(lastCallIndex < firstResultIndex)
    }
    // And the tools were dispatched in emitted order.
    #expect(toolA.tags == ["A"])
    #expect(toolB.tags == ["B"])
}

/// A provider that always returns the same single tool call — the
/// canonical "never completes" case for the maxIterations guard test.
private actor LoopingToolProvider: ModelProvider {
    private let use: ToolUse
    init(use: ToolUse) { self.use = use }

    nonisolated func send(
        messages _: [Message],
        system _: String?,
        tools _: [ToolSpec]
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        let use = use
        return AsyncThrowingStream { continuation in
            continuation.yield(.toolUse(use))
            continuation.yield(.messageComplete(stopReason: "tool_use"))
            continuation.finish()
        }
    }
}

@Test
func maxIterationsExceededWhenProviderNeverCompletes() async {
    // The provider yields a tool call every turn, so the extracted
    // TurnOutcome.needsMoreTurns branch fires on every iteration until the
    // runLoop guard trips.
    let toolA = RecordingTool(name: "a")
    let provider = LoopingToolProvider(
        use: ToolUse(id: "x", name: "a", input: .object(["tag": .string("t")]))
    )
    let session = LLMSession(
        provider: provider,
        tools: [toolA.eraseToAnyTool()],
        maxIterations: 3
    )
    await #expect(throws: SessionError.self) {
        _ = try await session.send("loop forever")
    }
}
