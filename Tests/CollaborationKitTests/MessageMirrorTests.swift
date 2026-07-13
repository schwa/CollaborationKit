@testable import CollaborationKit
@testable import CollaborationKitUI
import Foundation
import Testing

/// Pure state-machine tests for MessageMirror — no SwiftUI, no @MainActor,
/// no ConversationStore. Exercises the event handling in isolation.
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
    func completedTextBlockFinalizesStreamingIntoMessage() {
        var mirror = MessageMirror()
        mirror.handle(.textDelta("Hi"))
        mirror.handle(.text("Hi there."))
        #expect(mirror.streamingAssistantText == nil)
        #expect(mirror.messages.count == 1)
        #expect(mirror.messages[0].role == .assistant)
        if case .text(let value) = mirror.messages[0].content.first {
            #expect(value == "Hi there.")
        } else {
            Issue.record("expected text block")
        }
    }

    // MARK: - Tool call + result

    @Test
    func toolCallAppearsInMessagesAndStampsPresentation() {
        var mirror = MessageMirror()
        let use = ToolUse(id: "t1", name: "list", input: .object([:]))
        mirror.handle(.toolCall(use)) { _ in "listing" }
        let call = mirror.messages.first?.content.first
        if case .toolCall(let c) = call {
            #expect(c.use.id == "t1")
            #expect(c.result == nil)
        } else {
            Issue.record("expected tool call")
        }
        #expect(mirror.presentation[.tool("t1")]?.summary == "listing")
    }

    @Test
    func toolResultAttachesAndStampsDuration() {
        var mirror = MessageMirror()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let use = ToolUse(id: "t1", name: "list", input: .object([:]))
        mirror.handle(.toolCall(use), at: start)
        let result = ToolResult(toolUseID: "t1", content: "ok")
        mirror.handle(.toolResult(result), at: start.addingTimeInterval(0.5))

        if case .toolCall(let c) = mirror.messages.first?.content.first {
            #expect(c.result?.content == "ok")
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
}
