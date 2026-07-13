@testable import CollaborationKit
@testable import CollaborationKitUI
import Foundation
import Testing

/// Behaviour tests for the ``ConversationStore`` rollback API. Uses a
/// ``NullProvider`` so no turn actually runs; the tests drive the store's
/// mirror directly to simulate the shape a completed turn leaves behind
/// and then assert that ``ConversationStore/rollBack(through:)`` restores
/// host state, truncates history, and invalidates later snapshots.
///
/// The projection layer is exercised via ``ConversationStore/items`` so
/// these tests also cover the `canRollBack(to:)` filter.
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
@Suite("Rollback")
struct RollbackTests {
    // MARK: - canRollBack

    @Test("canRollBack is false for a store with no snapshots")
    func canRollBackIsFalseWithoutSnapshots() async {
        let store = ConversationStore(session: LLMSession(provider: NullProvider()))
        store.send("hi")
        await drainGenerating(store)
        let userItemID = store.items.first!.id
        #expect(!store.canRollBack(to: userItemID))
    }

    @Test("canRollBack is true for a user row that carries a snapshot")
    func canRollBackIsTrueForRowWithSnapshot() async {
        let store = ConversationStore(session: LLMSession(provider: NullProvider()))
        store.send("hi", snapshot: .empty)
        await drainGenerating(store)
        let userItemID = store.items.first!.id
        #expect(store.canRollBack(to: userItemID))
    }

    @Test("canRollBack is false while a turn is generating")
    func canRollBackIsFalseWhileGenerating() {
        let store = ConversationStore(session: LLMSession(provider: NullProvider()))
        store.send("hi", snapshot: .empty)
        // send() sets isGenerating = true until the run task completes.
        // The NullProvider run task hasn't been awaited yet, so we can
        // observe the mid-flight state as long as the check is synchronous.
        let userItemID = store.items.first!.id
        #expect(store.isGenerating)
        #expect(!store.canRollBack(to: userItemID))
    }

    @Test("canRollBack is false for a tool or assistant row even with snapshots elsewhere")
    func canRollBackRejectsNonUserRows() async {
        let store = ConversationStore(session: LLMSession(provider: NullProvider()))
        store.send("hi", snapshot: .empty)
        await drainGenerating(store)
        // Fake a tool row id: canRollBack must reject it even while a user
        // snapshot exists.
        #expect(!store.canRollBack(to: .tool("some-tool-id")))
        #expect(!store.canRollBack(to: .streamingAssistant))
    }

    // MARK: - rollBack

    @Test("rollBack calls the snapshot's apply closure exactly once")
    func rollBackInvokesApplyClosure() async {
        let counter = ApplyCounter()
        let store = ConversationStore(session: LLMSession(provider: NullProvider()))
        store.send("first", snapshot: RollbackSnapshot { counter.bump() })
        // Wait for the run task to finish so isGenerating drops back to false.
        await drainGenerating(store)
        let userItemID = store.items.first!.id
        store.rollBack(through: userItemID)
        #expect(counter.value == 1)
    }

    @Test("rollBack truncates the mirror's messages to the pre-turn count")
    func rollBackTruncatesMirror() async {
        let store = ConversationStore(session: LLMSession(provider: NullProvider()))
        // Two user turns with snapshots. NullProvider doesn't produce assistant
        // messages, so mirror.messages has just the two user prompts after both
        // sends complete.
        store.send("first", snapshot: .empty)
        await drainGenerating(store)
        store.send("second", snapshot: .empty)
        await drainGenerating(store)

        #expect(store.mirror.messages.count == 2)

        let firstUserID = store.items.first!.id
        store.rollBack(through: firstUserID)
        #expect(store.mirror.messages.isEmpty)
        #expect(store.items.isEmpty)
    }

    @Test("rollBack invalidates snapshots for turns after the rollback point")
    func rollBackInvalidatesLaterSnapshots() async {
        let store = ConversationStore(session: LLMSession(provider: NullProvider()))
        store.send("first", snapshot: .empty)
        await drainGenerating(store)
        store.send("second", snapshot: .empty)
        await drainGenerating(store)

        let firstUserID = store.items.first!.id
        // Capture the second user's item id before we roll back.
        let secondUserID = store.items[1].id
        store.rollBack(through: firstUserID)
        // The second turn's row is gone; canRollBack must report false even
        // when queried with its old id.
        #expect(!store.canRollBack(to: secondUserID))
    }

    @Test("rollBack is a no-op when a turn is generating")
    func rollBackIsNoopWhileGenerating() {
        let counter = ApplyCounter()
        let store = ConversationStore(session: LLMSession(provider: NullProvider()))
        store.send("hi", snapshot: RollbackSnapshot { counter.bump() })
        let userItemID = store.items.first!.id
        // isGenerating is still true here — the run task hasn't been awaited.
        #expect(store.isGenerating)
        store.rollBack(through: userItemID)
        #expect(counter.value == 0)
    }

    @Test("rollBack is a no-op for an id without a snapshot")
    func rollBackIsNoopWithoutSnapshot() async {
        let store = ConversationStore(session: LLMSession(provider: NullProvider()))
        store.send("hi")
        await drainGenerating(store)
        let userItemID = store.items.first!.id
        store.rollBack(through: userItemID)
        // Mirror is unchanged.
        #expect(store.mirror.messages.count == 1)
    }

    @Test("rollBack clears any surfaced lastError")
    func rollBackClearsLastError() async {
        let store = ConversationStore(session: LLMSession(provider: NullProvider()))
        store.send("hi", snapshot: .empty)
        await drainGenerating(store)
        let userItemID = store.items.first!.id
        store.rollBack(through: userItemID)
        #expect(store.lastError == nil)
        // rollBack also drops error overlays from the mirror.
        #expect(store.mirror.errorOverlays.isEmpty)
    }

    // MARK: - Helpers

    /// A tiny reference-typed counter for the apply-closure tests. `@MainActor`
    /// so the `Sendable` closure can bump it without further isolation.
    @MainActor
    private final class ApplyCounter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    /// Waits for the store's in-flight send task to finish so `isGenerating`
    /// returns to false. NullProvider produces no events, so this yields
    /// almost immediately.
    private func drainGenerating(_ store: ConversationStore) async {
        while store.isGenerating {
            await Task.yield()
        }
    }
}
