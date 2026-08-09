@testable import CollaborationKit
@testable import CollaborationKitUI
import Foundation
import Testing

/// Tests for the menu-command plumbing added in #37. The SwiftUI wiring
/// (`focusedSceneValue` publication) is exercised from the demo app; these
/// cover the pieces that don't need a view hierarchy: the store's
/// ``ConversationStore/lastRollbackTarget`` selection and the action values.
private actor SilentProvider: ModelProvider {
    nonisolated func send(
        messages _: [Message],
        system _: String?,
        tools _: [ToolSpec]
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
@Suite("Session commands (#37)")
struct SessionCommandsTests {
    @Test("lastRollbackTarget is nil without snapshots")
    func noTargetWithoutSnapshots() async {
        let store = ConversationStore(session: LLMSession(provider: SilentProvider()))
        store.send("hi")
        await drainGenerating(store)
        #expect(store.lastRollbackTarget == nil)
    }

    @Test("lastRollbackTarget is the most recent snapshotted prompt")
    func targetIsMostRecentPrompt() async {
        let store = ConversationStore(session: LLMSession(provider: SilentProvider()))
        store.send("first", snapshot: .empty)
        await drainGenerating(store)
        store.send("second", snapshot: .empty)
        await drainGenerating(store)

        let userRows = store.items.filter { item in
            guard case .user = item.kind else { return false }
            return true
        }
        #expect(userRows.count == 2)
        #expect(store.lastRollbackTarget == userRows.last?.id)
    }

    @Test("lastRollbackTarget is nil while a turn is generating")
    func noTargetWhileGenerating() {
        let store = ConversationStore(session: LLMSession(provider: SilentProvider()))
        store.send("hi", snapshot: .empty)
        #expect(store.isGenerating)
        #expect(store.lastRollbackTarget == nil)
    }

    @Test("rolling back through the last target truncates the transcript")
    func rollBackThroughLastTarget() async throws {
        let store = ConversationStore(session: LLMSession(provider: SilentProvider()))
        store.send("first", snapshot: .empty)
        await drainGenerating(store)
        store.send("second", snapshot: .empty)
        await drainGenerating(store)

        let target = try #require(store.lastRollbackTarget)
        let action = RollBackLastTurnAction { @MainActor in store.rollBack(through: target) }
        action()

        let prompts = store.items.compactMap { item -> String? in
            if case .user(let text, _) = item.kind { return text }
            return nil
        }
        #expect(prompts == ["first"])
    }

    @Test("stop action forwards to the store")
    func stopActionStopsGeneration() async {
        let store = ConversationStore(session: LLMSession(provider: SilentProvider()))
        store.send("hi")
        let action = StopGenerationAction { @MainActor in store.stop() }
        action()
        await drainGenerating(store)
        #expect(!store.isGenerating)
    }

    private func drainGenerating(_ store: ConversationStore) async {
        while store.isGenerating {
            await Task.yield()
        }
    }
}
