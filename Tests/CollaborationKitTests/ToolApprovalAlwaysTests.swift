@testable import CollaborationKit
import Foundation
import Testing

/// Tests for ``ToolApprovalDecision/allowAlways`` and the session-scoped
/// allowlist it feeds (#118). The rest of the approval surface lives in
/// `SessionTests`.
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

private actor CallCounter {
    var count = 0
    func bump() { count += 1 }
}

/// An approval-gated tool that records how often it actually ran.
private struct GatedTool: Tool {
    struct Input: Decodable, Sendable {}
    let toolName: String
    let recorder: CallCounter
    var name: String { toolName }
    var description: String { "records a call" }
    var inputSchema: JSONValue { .object(["type": .string("object"), "properties": .object([:])]) }
    var requiresApproval: Bool { true }
    func call(_: Input) async -> String {
        await recorder.bump()
        return "ran"
    }
}

@Suite("allowAlways approvals (#118)")
struct ToolApprovalAlwaysTests {
    @Test("a tool approved with allowAlways isn't asked about again")
    func allowAlwaysSkipsLaterApprovals() async throws {
        let recorder = CallCounter()
        let approvals = CallCounter()
        let provider = ScriptedProvider([
            [
                .toolUse(ToolUse(id: "a1", name: "spy", input: .object([:]))),
                .toolUse(ToolUse(id: "a2", name: "spy", input: .object([:]))),
                .messageComplete(stopReason: "tool_use")
            ],
            [
                .toolUse(ToolUse(id: "a3", name: "spy", input: .object([:]))),
                .messageComplete(stopReason: "tool_use")
            ],
            [.text("done"), .messageComplete(stopReason: "end_turn")]
        ])
        let session = LLMSession(
            provider: provider,
            tools: [GatedTool(toolName: "spy", recorder: recorder)]
        ) { _ in
            await approvals.bump()
            return .allowAlways
        }
        _ = try await session.send("go")

        // Three calls to the same tool, one trip through the approval closure.
        #expect(await recorder.count == 3)
        #expect(await approvals.count == 1)
        #expect(await session.alwaysAllowedToolNames == ["spy"])
    }

    @Test("the allowance covers only the tool it was given for")
    func allowAlwaysIsPerTool() async throws {
        let recorder = CallCounter()
        let approvals = CallCounter()
        let provider = ScriptedProvider([
            [
                .toolUse(ToolUse(id: "b1", name: "spy", input: .object([:]))),
                .toolUse(ToolUse(id: "b2", name: "other", input: .object([:]))),
                .messageComplete(stopReason: "tool_use")
            ],
            [.text("done"), .messageComplete(stopReason: "end_turn")]
        ])
        let session = LLMSession(
            provider: provider,
            tools: [
                GatedTool(toolName: "spy", recorder: recorder),
                GatedTool(toolName: "other", recorder: recorder)
            ]
        ) { _ in
            await approvals.bump()
            return .allowAlways
        }
        _ = try await session.send("go")

        #expect(await approvals.count == 2)
        #expect(await session.alwaysAllowedToolNames == ["spy", "other"])
    }

    @Test("forgetAlwaysAllowedTools() resumes asking")
    func forgettingResumesAsking() async throws {
        let recorder = CallCounter()
        let approvals = CallCounter()
        let provider = ScriptedProvider([
            [
                .toolUse(ToolUse(id: "c1", name: "spy", input: .object([:]))),
                .messageComplete(stopReason: "tool_use")
            ],
            [.text("first"), .messageComplete(stopReason: "end_turn")],
            [
                .toolUse(ToolUse(id: "c2", name: "spy", input: .object([:]))),
                .messageComplete(stopReason: "tool_use")
            ],
            [.text("second"), .messageComplete(stopReason: "end_turn")]
        ])
        let session = LLMSession(
            provider: provider,
            tools: [GatedTool(toolName: "spy", recorder: recorder)]
        ) { _ in
            await approvals.bump()
            return .allowAlways
        }
        _ = try await session.send("go")
        await session.forgetAlwaysAllowedTools()
        #expect(await session.alwaysAllowedToolNames.isEmpty)

        _ = try await session.send("go again")
        #expect(await approvals.count == 2)
    }
}
