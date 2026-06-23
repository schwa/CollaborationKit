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
    // user, assistant(tool_use), user(tool_result), assistant(text)
    #expect(history.count == 4)
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
    let toolResults = history.flatMap(\.content).compactMap { block -> ToolResult? in
        if case .toolResult(let result) = block { return result }
        return nil
    }
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
    let hasError = history.flatMap(\.content).contains { block in
        if case .toolResult(let result) = block { return result.isError }
        return false
    }
    #expect(hasError)
}
