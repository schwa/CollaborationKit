@testable import CollaborationKit
import Foundation
import Testing

/// Tests for the pluggable ``CompactionStrategy`` added in #7.
///
/// Covers the two shipped strategies (`NoCompactionStrategy`,
/// `KeepRecentCompactionStrategy`) and the session-level integration:
/// compaction runs at the top of every model round-trip, and a custom
/// strategy is honored.
@Suite("Compaction strategy (#7)")
struct CompactionStrategyTests {
    // MARK: - Strategy unit tests

    @Test("NoCompactionStrategy returns the input unchanged")
    func noCompactionIsIdentity() async {
        let history: [Message] = [.user("a"), .assistant("b"), .user("c")]
        let strategy = NoCompactionStrategy()
        let out = await strategy.compact(history: history, usage: TokenUsage())
        #expect(out == history)
    }

    @Test("KeepRecentCompactionStrategy no-ops when there are fewer messages than the minimum")
    func keepRecentBelowThresholdIsNoOp() async {
        let history: [Message] = [.user("a"), .assistant("b")]
        let strategy = KeepRecentCompactionStrategy(keepLastTurns: 2)
        let out = await strategy.compact(history: history, usage: TokenUsage())
        #expect(out == history)
    }

    @Test("KeepRecentCompactionStrategy keeps only the last N whole turns")
    func keepRecentKeepsTrailingTurns() async {
        // Four full turns; keep only the last two.
        let history: [Message] = [
            .user("t1"), .assistant("r1"),
            .user("t2"), .assistant("r2"),
            .user("t3"), .assistant("r3"),
            .user("t4"), .assistant("r4")
        ]
        let strategy = KeepRecentCompactionStrategy(keepLastTurns: 2, minMessagesBeforeCompacting: 0)
        let out = await strategy.compact(history: history, usage: TokenUsage())
        #expect(out.count == 4)
        // The kept slice starts at the third user turn.
        if case .text(let firstText) = out.first?.content.first ?? .text("") {
            #expect(firstText == "t3")
        } else {
            Issue.record("expected first kept message to be a user text block")
        }
        #expect(out.first?.role == .user)
        #expect(out.last?.role == .assistant)
    }

    @Test("KeepRecentCompactionStrategy can pin the first user message")
    func keepRecentCanPinFirstUserMessage() async {
        let history: [Message] = [
            .user("task-setup"), .assistant("ack"),
            .user("t2"), .assistant("r2"),
            .user("t3"), .assistant("r3")
        ]
        let strategy = KeepRecentCompactionStrategy(
            keepLastTurns: 1,
            keepFirstUserMessage: true,
            minMessagesBeforeCompacting: 0
        )
        let out = await strategy.compact(history: history, usage: TokenUsage())
        // 1 pinned + 2 in the trailing turn = 3 messages.
        #expect(out.count == 3)
        #expect(out.first?.role == .user)
        if case .text(let firstText) = out.first?.content.first ?? .text("") {
            #expect(firstText == "task-setup")
        }
    }

    @Test("Grouping bundles trailing assistant messages with their opening user turn")
    func multiRoundTurnsGroupTogether() async {
        // Simulate a two-round tool turn: user + assistant(tool_use) +
        // assistant(final text). All three belong to the same turn and
        // must not be split by compaction.
        let history: [Message] = [
            .user("prev1"), .assistant("r1"),
            .user("prev2"), .assistant("r2"),
            .user("do it"),
            .assistant("running tool…"),
            .assistant("done")
        ]
        let strategy = KeepRecentCompactionStrategy(
            keepLastTurns: 1,
            minMessagesBeforeCompacting: 0
        )
        let out = await strategy.compact(history: history, usage: TokenUsage())
        // Three messages of the last turn stay together.
        #expect(out.count == 3)
        #expect(out.map(\.role) == [.user, .assistant, .assistant])
    }

    @Test("Compaction preserves domain tool_use/tool_result pairing inside kept messages")
    func compactionKeepsToolCallResultPairingIntact() async {
        let toolUse = ToolUse(id: "u1", name: "edit", input: .object([:]))
        let toolResult = ToolResult(toolUseID: "u1", content: "ok")
        let toolCall = ToolCall(use: toolUse, result: toolResult)
        let assistantWithTool = Message(role: .assistant, content: [
            .text("calling…"),
            .toolCall(toolCall)
        ])

        let history: [Message] = [
            .user("older1"), .assistant("r1"),
            .user("older2"), .assistant("r2"),
            .user("do it"),
            assistantWithTool
        ]
        let strategy = KeepRecentCompactionStrategy(
            keepLastTurns: 1,
            minMessagesBeforeCompacting: 0
        )
        let out = await strategy.compact(history: history, usage: TokenUsage())
        #expect(out.count == 2)
        let kept = out.last
        // The tool_call block (and its embedded result) is preserved.
        guard case .toolCall(let call) = kept?.content.last ?? .text("") else {
            Issue.record("expected a toolCall block in the kept assistant message")
            return
        }
        #expect(call.use.id == "u1")
        #expect(call.result?.content == "ok")
    }

    // MARK: - Session integration

    @Test("LLMSession invokes a custom compaction strategy at the top of runTurn")
    func sessionInvokesCustomStrategy() async throws {
        // A strategy that records the histories it was asked to compact.
        actor RecordingStrategy: CompactionStrategy {
            private(set) var recorded: [[Message]] = []
            func compact(history: [Message], usage _: TokenUsage) async -> [Message] {
                recorded.append(history)
                return history
            }
        }
        let strategy = RecordingStrategy()
        let provider = SingleTextProvider(text: "ok")
        let session = LLMSession(
            provider: provider,
            compactionStrategy: strategy
        )
        _ = try await session.send("hi")
        // One turn = one runTurn = one compact() call.
        let recorded = await strategy.recorded
        #expect(recorded.count == 1)
        // The first invocation sees the user message the caller just appended.
        #expect(recorded.first?.count == 1)
        #expect(recorded.first?.first?.role == .user)
    }

    @Test("KeepRecentCompactionStrategy actually shrinks LLMSession history")
    func sessionKeepRecentTrimsHistory() async throws {
        // Build up ten turns of history, then send an eleventh turn with a
        // keep-last-two strategy: after runTurn compaction the pre-turn
        // history should have been trimmed to just the last two turns
        // before the new user message + assistant reply were appended.
        let provider = SingleTextProvider(text: "ack")
        let session = LLMSession(
            provider: provider,
            compactionStrategy: KeepRecentCompactionStrategy(
                keepLastTurns: 2,
                minMessagesBeforeCompacting: 0
            )
        )
        for i in 0..<10 {
            _ = try await session.send("q\(i)")
        }
        // Sanity: no compaction happened yet? Actually compaction has run at
        // the top of every turn. Baseline: history should be bounded by the
        // strategy after each send.
        let sizeBefore = await session.messages.count
        #expect(sizeBefore <= 2 * 2 + 2, "history stayed bounded across sends")

        // One more send: the compaction pass trims to 2*2 = 4 messages
        // before appending the new user + assistant.
        _ = try await session.send("qfinal")
        let sizeAfter = await session.messages.count
        // Expected: 4 (kept trailing turns) + 2 (new user + assistant) = 6.
        #expect(sizeAfter <= 6)
    }
}

// MARK: - Test doubles

/// A ModelProvider that emits one text block plus messageComplete and stops.
/// Duplicated here rather than imported from another test file to keep this
/// suite self-contained.
private actor SingleTextProvider: ModelProvider {
    let text: String
    init(text: String) { self.text = text }
    nonisolated func send(
        messages _: [Message],
        system _: String?,
        tools _: [ToolSpec]
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        let text = text
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(text))
            continuation.yield(.messageComplete(stopReason: "end_turn"))
            continuation.finish()
        }
    }
}
