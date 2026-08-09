@testable import CollaborationKit
@testable import CollaborationKitUI
import Foundation
import Testing

/// Round-trip tests for ``ConversationStore/restore(from:)`` (#104).
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
@Suite("Session restore (#104)")
struct SessionRestoreTests {
    @Test("a restored store reproduces the exported transcript and usage")
    func restoreReproducesTranscript() async {
        let source = ConversationStore(session: LLMSession(provider: SilentProvider()))
        source.send("first")
        await drainGenerating(source)
        source.send("second")
        await drainGenerating(source)
        let export = source.buildExport(model: "test-model")

        let restored = ConversationStore(session: LLMSession(provider: SilentProvider()))
        restored.restore(from: export)

        #expect(export.transcript.count == 2)
        #expect(restored.messages == export.messages)
        #expect(restored.items == export.transcript)
        #expect(restored.usage == export.usage)
        #expect(restored.lastError == export.lastError)
    }

    @Test("restore survives a JSON round trip")
    func restoreFromDecodedJSON() async throws {
        let source = ConversationStore(session: LLMSession(provider: SilentProvider()))
        source.send("hello")
        await drainGenerating(source)
        let data = try source.buildExport().jsonData()

        let restored = ConversationStore(session: LLMSession(provider: SilentProvider()))
        restored.restore(from: try SessionExport.decode(data))

        let prompts = restored.items.compactMap { item -> String? in
            if case .user(let text, _) = item.kind { return text }
            return nil
        }
        #expect(prompts == ["hello"])
    }

    @Test("error overlays are restored")
    func restoreKeepsErrorOverlays() {
        let export = SessionExport(
            exportedAt: Date(),
            model: nil,
            system: nil,
            usage: TokenUsage(),
            messages: [],
            transcript: [ConversationItem(id: .error(1), kind: .error("Boom."), timestamp: Date())],
            lastError: "Boom.",
            userInfo: [:]
        )

        let restored = ConversationStore(session: LLMSession(provider: SilentProvider()))
        restored.restore(from: export)

        let errors = restored.items.compactMap { item -> String? in
            if case .error(let message) = item.kind { return message }
            return nil
        }
        #expect(errors == ["Boom."])
        #expect(restored.lastError == "Boom.")
    }

    @Test("the session's own history is restored too")
    func restoreRewritesSessionHistory() async {
        let source = ConversationStore(session: LLMSession(provider: SilentProvider()))
        source.send("remember this")
        await drainGenerating(source)
        let export = source.buildExport()

        let session = LLMSession(provider: SilentProvider())
        let restored = ConversationStore(session: session)
        restored.restore(from: export)
        // The rewrite is asynchronous; the next send awaits it, and so do we.
        restored.send("next")
        await drainGenerating(restored)

        let history = await session.messages
        #expect(history.count >= export.messages.count)
        #expect(history.first == export.messages.first)
    }

    @Test("restore is a no-op while a turn is in flight")
    func restoreIgnoredWhileGenerating() async {
        let source = ConversationStore(session: LLMSession(provider: SilentProvider()))
        source.send("exported")
        await drainGenerating(source)
        let export = source.buildExport()

        let busy = ConversationStore(session: LLMSession(provider: SilentProvider()))
        busy.send("in flight")
        #expect(busy.isGenerating)
        busy.restore(from: export)

        let prompts = busy.items.compactMap { item -> String? in
            if case .user(let text, _) = item.kind { return text }
            return nil
        }
        #expect(prompts == ["in flight"])
        await drainGenerating(busy)
    }

    private func drainGenerating(_ store: ConversationStore) async {
        while store.isGenerating {
            await Task.yield()
        }
    }
}
