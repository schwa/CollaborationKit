@testable import CollaborationKit
@testable import CollaborationKitUI
import Foundation
import Testing

/// Behaviour tests for prompt queueing in ``ConversationStore``.
///
/// Uses a ``NullProvider`` whose stream finishes immediately, matching
/// the pattern in ``RollbackTests``. Synchronous send calls stack up
/// while the first turn's send task hasn't yet been scheduled, which is
/// enough to observe the queue's shape. The full drain is verified by
/// yielding until both the run task and the queue settle.
private actor NullProvider: ModelProvider {
    nonisolated func send(
        messages _: [Message],
        system _: String?,
        tools _: [ToolSpec]
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
@Suite("QueuedPrompts")
struct QueuedPromptsTests {
    @Test("send() queues rather than drops when a turn is in flight")
    func queuesWhileGenerating() {
        let store = ConversationStore(session: LLMSession(provider: NullProvider()))
        store.send("first")
        // send() sets isGenerating = true synchronously; subsequent calls
        // observe the mid-flight state before the run task yields.
        #expect(store.isGenerating)
        #expect(store.pendingPromptCount == 0)

        store.send("second")
        store.send("third")
        #expect(store.pendingPromptCount == 2)
        // Only the first prompt is in the transcript so far.
        #expect(store.items.count == 1)
    }

    @Test("draining the current turn dequeues the next prompt automatically")
    func drainsNextPromptWhenTurnFinishes() async {
        let store = ConversationStore(session: LLMSession(provider: NullProvider()))
        store.send("first")
        store.send("second")
        store.send("third")
        #expect(store.pendingPromptCount == 2)

        await drainQueue(store)
        #expect(store.pendingPromptCount == 0)
        #expect(!store.isGenerating)

        let userTexts = store.items.compactMap { item -> String? in
            if case .user(let text, _) = item.kind { return text }
            return nil
        }
        #expect(userTexts == ["first", "second", "third"])
    }

    @Test("clearPendingPrompts() drops queued prompts without touching the running turn")
    func clearPendingPromptsDropsQueueOnly() async {
        let store = ConversationStore(session: LLMSession(provider: NullProvider()))
        store.send("first")
        store.send("second")
        store.send("third")
        #expect(store.pendingPromptCount == 2)
        #expect(store.isGenerating)

        store.clearPendingPrompts()
        #expect(store.pendingPromptCount == 0)
        // The current turn is untouched.
        #expect(store.isGenerating)

        await drainQueue(store)
        // No follow-up turns ran — only the first prompt is in the transcript.
        #expect(store.items.count == 1)
    }

    @Test("empty prompts are still dropped even while a turn is running")
    func emptyPromptsAreDropped() {
        let store = ConversationStore(session: LLMSession(provider: NullProvider()))
        store.send("first")
        store.send("   ")
        store.send("")
        #expect(store.pendingPromptCount == 0)
    }

    /// Yields until both the send task finishes and the queue empties.
    /// Because draining a prompt synchronously re-enters ``send``, a plain
    /// `while store.isGenerating` loop would race with each dequeue.
    private func drainQueue(_ store: ConversationStore) async {
        while store.isGenerating || store.pendingPromptCount > 0 {
            await Task.yield()
        }
    }
}
