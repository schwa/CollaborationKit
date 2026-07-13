@testable import CollaborationKit
import Foundation
import Testing

/// A scripted provider that replays a fixed sequence of responses, ignoring
/// input. Each call to `send` returns the next scripted response.
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

@Test
func plainTextTurnReturnsFinalText() async throws {
    let provider = ScriptedProvider([
        [.text("Hello there."), .messageComplete(stopReason: "end_turn")]
    ])
    let session = LLMSession(provider: provider)
    let reply = try await session.send("Hi")
    #expect(reply == "Hello there.")
}

@Test
func toolLoopRunsToolAndContinues() async throws {
    let doc = InMemoryDocument("line one\nline two\n")
    let provider = ScriptedProvider([
        [
            .toolUse(ToolUse(id: "t1", name: "read", input: .object([:]))),
            .messageComplete(stopReason: "tool_use")
        ],
        [.text("The document has two lines."), .messageComplete(stopReason: "end_turn")]
    ])
    let session = LLMSession(provider: provider, tools: .fileTools(for: doc))
    let reply = try await session.send("How many lines?")
    #expect(reply == "The document has two lines.")
    let history = await session.messages
    // Domain shape: user, assistant(toolCall+result), assistant(text).
    // The tool result lives inside the assistant message's ToolCall, so there
    // is no separate tool-result message.
    #expect(history.count == 3)
    #expect(history[1].toolCalls.count == 1)
    #expect(history[1].toolCalls[0].result?.content != nil)
}

@Test
func truncateHistoryRollsBackToEarlierTurn() async throws {
    let provider = ScriptedProvider([
        [.text("First reply."), .messageComplete(stopReason: "end_turn")],
        [.text("Second reply."), .messageComplete(stopReason: "end_turn")]
    ])
    let session = LLMSession(provider: provider)

    _ = try await session.send("One")
    let afterFirst = await session.messages.count
    #expect(afterFirst == 2)

    _ = try await session.send("Two")
    #expect(await session.messages.count == 4)

    // Roll the model's memory back to just after the first turn.
    await session.truncateHistory(keeping: afterFirst)
    #expect(await session.messages.count == afterFirst)

    // Out-of-range values are clamped, not crashing.
    await session.truncateHistory(keeping: 999)
    #expect(await session.messages.count == afterFirst)
    await session.truncateHistory(keeping: -5)
    #expect(await session.messages.isEmpty)
}

@Test
func editToolReplacesUniqueText() async throws {
    let doc = InMemoryDocument("The quick brown fox.")
    let provider = ScriptedProvider([
        [
            .toolUse(ToolUse(
                id: "e1",
                name: "edit",
                input: .object(["oldText": "quick brown", "newText": "slow red"])
            )),
            .messageComplete(stopReason: "tool_use")
        ],
        [.text("Done."), .messageComplete(stopReason: "end_turn")]
    ])
    let session = LLMSession(provider: provider, tools: .fileTools(for: doc))
    _ = try await session.send("Edit it")
    #expect(doc.contents == "The slow red fox.")
}

@Test
func editToolFailsBackToModelOnAmbiguousMatch() async throws {
    let doc = InMemoryDocument("ab ab ab")
    let provider = ScriptedProvider([
        [
            .toolUse(ToolUse(
                id: "e1",
                name: "edit",
                input: .object(["oldText": "ab", "newText": "cd"])
            )),
            .messageComplete(stopReason: "tool_use")
        ],
        [.text("Could not edit."), .messageComplete(stopReason: "end_turn")]
    ])
    let session = LLMSession(provider: provider, tools: .fileTools(for: doc))
    _ = try await session.send("Edit it")
    // Document unchanged; the failure was reported to the model, not thrown.
    #expect(doc.contents == "ab ab ab")
    let history = await session.messages
    let toolResults = history.flatMap(\.toolCalls).compactMap(\.result)
    // swiftlint:disable:next prefer_key_path - #expect macro mis-types throwing key-path closures
    #expect(toolResults.contains { $0.isError })
}

@Test
func unknownToolReportsErrorResult() async throws {
    let provider = ScriptedProvider([
        [
            .toolUse(ToolUse(id: "x1", name: "nonexistent", input: .object([:]))),
            .messageComplete(stopReason: "tool_use")
        ],
        [.text("ok"), .messageComplete(stopReason: "end_turn")]
    ])
    let session = LLMSession(provider: provider)
    _ = try await session.send("go")
    let history = await session.messages
    let hasError = history.flatMap(\.toolCalls).contains { $0.result?.isError == true }
    #expect(hasError)
}

// MARK: - Tool approval (#31)

private actor RecordingTool: Sendable {
    var callCount = 0
    func bump() { callCount += 1 }
}

private struct SpyingTool: Tool {
    struct Input: Decodable, Sendable {}
    let recorder: RecordingTool
    var name: String { "spy" }
    var description: String { "records a call" }
    var inputSchema: JSONValue { .object(["type": .string("object"), "properties": .object([:])]) }
    func call(_ input: Input) async throws -> String {
        await recorder.bump()
        return "ran"
    }
}

@Test
func allowAllApprovalIsDefault() async throws {
    let recorder = RecordingTool()
    let provider = ScriptedProvider([
        [
            .toolUse(ToolUse(id: "t1", name: "spy", input: .object([:]))),
            .messageComplete(stopReason: "tool_use")
        ],
        [.text("done"), .messageComplete(stopReason: "end_turn")]
    ])
    let session = LLMSession(
        provider: provider,
        tools: [SpyingTool(recorder: recorder).eraseToAnyTool()]
    )
    _ = try await session.send("go")
    #expect(await recorder.callCount == 1)
}

@Test
func denyReasonReachesTheModelAsErrorResultAndToolDoesNotRun() async throws {
    let recorder = RecordingTool()
    let provider = ScriptedProvider([
        [
            .toolUse(ToolUse(id: "t1", name: "spy", input: .object([:]))),
            .messageComplete(stopReason: "tool_use")
        ],
        [.text("acked"), .messageComplete(stopReason: "end_turn")]
    ])
    let session = LLMSession(
        provider: provider,
        tools: [SpyingTool(recorder: recorder).eraseToAnyTool()],
        approval: { _ in .deny(reason: "policy: no side effects during dry run") }
    )
    _ = try await session.send("go")

    // The tool never ran.
    #expect(await recorder.callCount == 0)

    // The model saw an is_error tool result with the denial reason.
    let history = await session.messages
    let deniedCall = history.flatMap(\.toolCalls).first { $0.use.id == "t1" }
    #expect(deniedCall?.result?.isError == true)
    #expect(deniedCall?.result?.content.contains("policy: no side effects") == true)
}

@Test
func emptyDenyReasonUsesFallbackMessage() async throws {
    let recorder = RecordingTool()
    let provider = ScriptedProvider([
        [
            .toolUse(ToolUse(id: "t2", name: "spy", input: .object([:]))),
            .messageComplete(stopReason: "tool_use")
        ],
        [.text("ok"), .messageComplete(stopReason: "end_turn")]
    ])
    let session = LLMSession(
        provider: provider,
        tools: [SpyingTool(recorder: recorder).eraseToAnyTool()],
        approval: { _ in .deny }
    )
    _ = try await session.send("go")
    let history = await session.messages
    let deniedCall = history.flatMap(\.toolCalls).first { $0.use.id == "t2" }
    #expect(deniedCall?.result?.content == "Denied by the host.")
}

@Test
func perToolApprovalCanAllowSomeAndDenyOthers() async throws {
    let recorder = RecordingTool()
    let provider = ScriptedProvider([
        [
            .toolUse(ToolUse(id: "a", name: "spy", input: .object(["safe": .bool(true)]))),
            .toolUse(ToolUse(id: "b", name: "spy", input: .object(["safe": .bool(false)]))),
            .messageComplete(stopReason: "tool_use")
        ],
        [.text("end"), .messageComplete(stopReason: "end_turn")]
    ])
    let session = LLMSession(
        provider: provider,
        tools: [SpyingTool(recorder: recorder).eraseToAnyTool()],
        approval: { use in
            if case .object(let fields) = use.input,
               case .bool(true)? = fields["safe"] {
                return .allow
            }
            return .deny(reason: "unsafe")
        }
    )
    _ = try await session.send("go")

    #expect(await recorder.callCount == 1)
    let history = await session.messages
    let allowed = history.flatMap(\.toolCalls).first { $0.use.id == "a" }
    let denied = history.flatMap(\.toolCalls).first { $0.use.id == "b" }
    #expect(allowed?.result?.isError == false)
    #expect(denied?.result?.isError == true)
}
