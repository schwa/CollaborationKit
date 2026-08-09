@testable import CollaborationKit
@testable import CollaborationKitUI
import Foundation
import Testing

/// Pure-function tests for TranscriptProjection: mirror in, items out.
///
/// After #60, `messages` is populated exclusively by `.historyChanged`
/// snapshots, so tests that need finalized rows feed a snapshot in
/// alongside the streaming/timing events.
struct TranscriptProjectionTests {
    @Test
    func emptyMirrorProjectsToNoItems() {
        let (items, ids) = TranscriptProjection.project(MessageMirror())
        #expect(items.isEmpty)
        #expect(ids.isEmpty)
    }

    @Test
    func userPromptProjectsAsUserRow() {
        var mirror = MessageMirror()
        mirror.appendUser(.user("hello"))
        let (items, ids) = TranscriptProjection.project(mirror)
        #expect(items.count == 1)
        if case .user(let text, _) = items.first?.kind {
            #expect(text == "hello")
        } else {
            Issue.record("expected user kind")
        }
        #expect(ids.contains(items[0].id))
    }

    @Test
    func assistantTextProjectsAndCarriesTiming() {
        var mirror = MessageMirror()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let assistant = Message(role: .assistant, content: [.text("Hi there.")])
        mirror.handle(.textDelta("Hi"), at: t0)
        // Session commits the finalized message before the `.text` hand-off.
        mirror.handle(.historyChanged([assistant]), at: t0.addingTimeInterval(1.2))
        mirror.handle(.text("Hi there."), at: t0.addingTimeInterval(1.2))

        let (items, _) = TranscriptProjection.project(mirror)
        #expect(items.count == 1)
        let duration = items[0].duration ?? -1
        #expect(abs(duration - 1.2) < 0.001, "expected ≈1.2, got \(duration)")
        if case .assistant(let text) = items[0].kind {
            #expect(text == "Hi there.")
        } else {
            Issue.record("expected assistant kind")
        }
    }

    @Test
    func toolCallProjectsWithSummaryAndPendingResult() {
        var mirror = MessageMirror()
        let use = ToolUse(id: "t1", name: "list", input: .object([:]))
        let assistant = Message(role: .assistant, content: [.toolCall(ToolCall(use: use))])
        mirror.handle(.historyChanged([assistant]))
        mirror.handle(.toolCall(use)) { _ in "listing rows" }

        let (items, _) = TranscriptProjection.project(mirror)
        let tool = items.first { if case .tool = $0.kind { true } else { false } }
        if case let .tool(_, summary, result, isError) = tool?.kind {
            #expect(summary == "listing rows")
            #expect(result == nil)
            #expect(!isError)
        } else {
            Issue.record("expected tool row")
        }
    }

    @Test("a lone tool call carries no batch metadata")
    func singleToolCallIsNotBatched() {
        var mirror = MessageMirror()
        let use = ToolUse(id: "t1", name: "list", input: .object([:]))
        mirror.handle(.historyChanged([Message(role: .assistant, content: [.toolCall(ToolCall(use: use))])]))

        let (items, _) = TranscriptProjection.project(mirror)
        #expect(items.allSatisfy { $0.batch == nil })
    }

    @Test("tool calls emitted in one assistant message are stamped as a batch")
    func batchedToolCallsAreNumbered() {
        var mirror = MessageMirror()
        let uses = (1...3).map { ToolUse(id: "t\($0)", name: "read", input: .object([:])) }
        let assistant = Message(
            role: .assistant,
            content: [.text("Reading them.")] + uses.map { .toolCall(ToolCall(use: $0)) }
        )
        mirror.handle(.historyChanged([assistant]))

        let (items, _) = TranscriptProjection.project(mirror)
        let toolRows = items.filter { if case .tool = $0.kind { true } else { false } }
        #expect(toolRows.count == 3)
        #expect(toolRows.map(\.batch) == [
            ConversationItem.Batch(index: 0, count: 3),
            ConversationItem.Batch(index: 1, count: 3),
            ConversationItem.Batch(index: 2, count: 3)
        ])
        #expect(toolRows.first?.batch?.isFirst == true)
        #expect(toolRows.last?.batch?.isLast == true)
        // The prose row in the same message is not part of the batch.
        #expect(items.first?.batch == nil)
    }

    @Test("batches don't span assistant messages")
    func batchesDoNotSpanMessages() {
        var mirror = MessageMirror()
        let first = Message(
            role: .assistant,
            content: [.toolCall(ToolCall(use: ToolUse(id: "a", name: "read", input: .object([:]))))]
        )
        let second = Message(
            role: .assistant,
            content: [.toolCall(ToolCall(use: ToolUse(id: "b", name: "read", input: .object([:]))))]
        )
        mirror.handle(.historyChanged([first, second]))

        let (items, _) = TranscriptProjection.project(mirror)
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.batch == nil })
    }

    @Test
    func latencyIsGapBetweenConsecutiveItems() {
        var mirror = MessageMirror()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let userMsg = Message.user("go")
        mirror.appendUser(userMsg, at: t0)
        // Assistant reply starts 2s later; session emits historyChanged
        // once the assistant message is finalized.
        let assistant = Message(role: .assistant, content: [.text("ok")])
        mirror.handle(.textDelta("ok"), at: t0.addingTimeInterval(2.0))
        mirror.handle(.historyChanged([userMsg, assistant]), at: t0.addingTimeInterval(2.1))
        mirror.handle(.text("ok"), at: t0.addingTimeInterval(2.1))

        let (items, _) = TranscriptProjection.project(mirror)
        #expect(items.count == 2)
        // First row has no prior end, so no latency.
        #expect(items[0].latency == nil)
        // Second row's latency is the 2s gap after the user row (user has
        // no duration, so its end is its timestamp).
        #expect(items[1].latency == 2.0)
    }

    @Test
    func streamingOverlayProjectsAsAssistant() {
        var mirror = MessageMirror()
        mirror.handle(.textDelta("still writing…"))
        let (items, ids) = TranscriptProjection.project(mirror)
        #expect(items.count == 1)
        if case .assistant(let text) = items.first?.kind {
            #expect(text == "still writing…")
        } else {
            Issue.record("expected assistant kind")
        }
        #expect(ids.contains(.streamingAssistant))
    }

    @Test
    func errorOverlayProjectsAtEnd() {
        var mirror = MessageMirror()
        mirror.appendUser(.user("hi"))
        mirror.appendError("Stopped.")
        let (items, _) = TranscriptProjection.project(mirror)
        #expect(items.count == 2)
        if case .error(let msg) = items.last?.kind {
            #expect(msg == "Stopped.")
        } else {
            Issue.record("expected error kind")
        }
    }
}
