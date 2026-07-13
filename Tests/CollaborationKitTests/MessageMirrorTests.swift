@testable import CollaborationKit
@testable import CollaborationKitUI
import Foundation
import Testing

/// Pure state-machine tests for MessageMirror — no SwiftUI, no @MainActor,
/// no ConversationStore. Exercises the event handling in isolation.
///
/// After the reducer-consolidation in #60, `messages` is only mutated by
/// `.historyChanged` snapshots (and `appendUser` / `truncate`), so most
/// tests feed a `.historyChanged` before the correlated `.text` /
/// `.toolCall` / `.toolResult` event — mirroring what ``LLMSession``
/// emits on the wire.
struct MessageMirrorTests {
    // MARK: - User + streaming basics

    @Test
    func appendUserAddsMessageAndStampsPresentation() {
        var mirror = MessageMirror()
        let msg = Message.user("hi")
        mirror.appendUser(msg, at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(mirror.messages == [msg])
        #expect(mirror.presentation[.message(msg.id)]?.timestamp == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test
    func textDeltaAccumulatesInStreamingOverlay() {
        var mirror = MessageMirror()
        mirror.handle(.textDelta("Hel"))
        mirror.handle(.textDelta("lo!"))
        #expect(mirror.streamingAssistantText == "Hello!")
        #expect(mirror.messages.isEmpty)
    }

    @Test
    func historyChangedIsAuthoritative() {
        var mirror = MessageMirror()
        let assistant = Message(role: .assistant, content: [.text("Hi there.")])
        mirror.handle(.historyChanged([assistant]))
        #expect(mirror.messages == [assistant])
    }

    @Test
    func textEventClearsStreamingOverlayWithoutTouchingMessages() {
        var mirror = MessageMirror()
        let assistant = Message(role: .assistant, content: [.text("Hi there.")])
        // Session mutates history then emits historyChanged before the
        // `.text` event: mirror sees the snapshot first, then the
        // hand-off event that finalizes the streaming overlay.
        mirror.handle(.textDelta("Hi"))
        mirror.handle(.historyChanged([assistant]))
        mirror.handle(.text("Hi there."))
        #expect(mirror.streamingAssistantText == nil)
        #expect(mirror.messages == [assistant])
    }

    // MARK: - Tool call + result

    @Test
    func toolCallStampsPresentationButDoesNotMutateMessages() {
        var mirror = MessageMirror()
        let use = ToolUse(id: "t1", name: "list", input: .object([:]))
        // The session's historyChanged snapshot is what puts the tool
        // call into `messages`; the mirror only stamps presentation for
        // it on the `.toolCall` event.
        let assistant = Message(role: .assistant, content: [.toolCall(ToolCall(use: use))])
        mirror.handle(.historyChanged([assistant]))
        mirror.handle(.toolCall(use)) { _ in "listing" }
        if case .toolCall(let call) = mirror.messages.first?.content.first {
            #expect(call.use.id == "t1")
            #expect(call.result == nil)
        } else {
            Issue.record("expected tool call in mirror.messages")
        }
        #expect(mirror.presentation[.tool("t1")]?.summary == "listing")
    }

    @Test
    func toolResultAttachesInSessionSnapshotAndMirrorStampsDuration() {
        var mirror = MessageMirror()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let use = ToolUse(id: "t1", name: "list", input: .object([:]))
        let pending = Message(role: .assistant, content: [.toolCall(ToolCall(use: use))])
        mirror.handle(.historyChanged([pending]))
        mirror.handle(.toolCall(use), at: start)

        // Session attaches the result and re-emits history.
        let result = ToolResult(toolUseID: "t1", content: "ok")
        let attached = Message(
            id: pending.id,
            timestamp: pending.timestamp,
            role: .assistant,
            content: [.toolCall(ToolCall(use: use, result: result))]
        )
        mirror.handle(.historyChanged([attached]))
        mirror.handle(.toolResult(result), at: start.addingTimeInterval(0.5))

        if case .toolCall(let call) = mirror.messages.first?.content.first {
            #expect(call.result?.content == "ok")
        } else {
            Issue.record("expected tool call with result")
        }
        #expect(mirror.presentation[.tool("t1")]?.duration == 0.5)
    }

    // MARK: - Overlay lifecycle

    @Test
    func errorOverlaysAreOrderedAndDropOnCompact() {
        var mirror = MessageMirror()
        mirror.appendError("first")
        mirror.appendError("second")
        #expect(mirror.errorOverlays.map(\.message) == ["first", "second"])
        #expect(mirror.errorOverlays.map(\.seq) == [1, 2])

        // Compact should drop presentation entries not in livingIDs — the
        // errors themselves stay in `errorOverlays` (that's the source of
        // truth) but their presentation side-table entries get cleaned.
        mirror.compact(livingIDs: [])
        #expect(mirror.presentation[.error(1)] == nil)
        #expect(mirror.presentation[.error(2)] == nil)
        #expect(mirror.errorOverlays.count == 2)
    }

    // MARK: - Streaming lifecycle around tool calls

    @Test
    func toolCallFinishesStreamingOverlay() {
        var mirror = MessageMirror()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        mirror.handle(.textDelta("Working"), at: start)
        // A tool call arrives mid-stream: the overlay should close.
        mirror.handle(
            .toolCall(ToolUse(id: "t1", name: "read", input: .object([:]))),
            at: start.addingTimeInterval(0.3)
        ) { $0.name }
        #expect(mirror.streamingAssistantText == nil)
    }

    // MARK: - Reducer duplication regression (#60)

    /// Regression for issue #60: the mirror must not mutate `messages` in
    /// response to `.text` / `.toolCall` / `.toolResult`. The session
    /// owns the reducer; the mirror only replaces via `.historyChanged`.
    @Test
    func textEventsAloneDoNotBuildMessages() {
        var mirror = MessageMirror()
        mirror.handle(.text("stray"))
        mirror.handle(.toolCall(ToolUse(id: "t1", name: "x", input: .object([:]))))
        mirror.handle(.toolResult(ToolResult(toolUseID: "t1", content: "y")))
        #expect(mirror.messages.isEmpty)
    }
}
