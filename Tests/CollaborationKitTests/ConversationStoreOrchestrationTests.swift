@testable import CollaborationKit
@testable import CollaborationKitUI
import Foundation
import Testing

/// End-to-end orchestration tests for ``ConversationStore`` running
/// against a fake ``ModelProvider``. The rest of the suite either
/// exercises ``LLMSession`` directly (SessionTests) or feeds synthesized
/// events into ``MessageMirror`` (MessageMirrorTests, TranscriptProjectionTests).
/// This file lives at the seam the two meet, so it catches the ordering
/// bugs the pure-unit suites can't:
///
/// - The event pump serializes with the send task on @MainActor.
/// - ``LLMSession``'s ``SessionEvent/historyChanged(_:)`` snapshots are
///   the single source of truth for ``MessageMirror/messages`` (issue #60
///   — no reducer duplication).
/// - Token usage stays consistent between what the mirror sees and what
///   the session accumulated (no double-counting from the pump race).
/// - Cancellation surfaces as a `"Stopped."` overlay.
///
/// A ``ScriptedProvider`` returns a fixed sequence of ``ProviderStreamEvent``
/// arrays, one per model round-trip.
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

/// A gated provider whose stream stays open until the test resumes it.
/// Used to observe mid-flight state (cancellation, queueing).
private actor GatedProvider: ModelProvider {
    private var gate: CheckedContinuation<Void, Never>?

    func open() {
        gate?.resume()
        gate = nil
    }

    nonisolated func send(
        messages _: [Message],
        system _: String?,
        tools _: [ToolSpec]
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await withCheckedContinuation { c in
                    Task { await self.setGate(c) }
                }
                continuation.yield(.text("done"))
                continuation.yield(.messageComplete(stopReason: "end_turn"))
                continuation.finish()
            }
        }
    }

    private func setGate(_ c: CheckedContinuation<Void, Never>) {
        gate = c
    }
}

/// A minimal in-memory tool used to observe tool dispatch through the
/// store. Records inputs, returns a canned reply.
private struct EchoTool: Tool {
    struct Input: Decodable, Sendable {
        let tag: String?
    }

    var name: String { "echo" }
    var description: String { "echoes a tag back" }
    var inputSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(["tag": .object(["type": .string("string")])]),
            "required": .array([])
        ])
    }

    // Conformance is `async throws`, but the body doesn't need either.
    // swiftlint:disable:next async_without_await unneeded_throws_rethrows
    func call(_ input: Input) async throws -> String {
        input.tag ?? "ok"
    }
}

@MainActor
@Suite("ConversationStoreOrchestration")
struct ConversationStoreOrchestrationTests {
    // MARK: - Divergence-proofing (#60 core claim)

    /// Regression for issue #60: after any turn, `mirror.messages` must
    /// exactly equal the session's authoritative history. That's the
    /// property the reducer-consolidation is meant to guarantee.
    @Test("mirror.messages tracks session.messages after a plain-text turn")
    func mirrorAndSessionAgreeAfterPlainText() async {
        let provider = ScriptedProvider([
            [.text("Hello."), .messageComplete(stopReason: "end_turn")]
        ])
        let session = LLMSession(provider: provider)
        let store = ConversationStore(session: session)

        store.send("hi")
        await drainGenerating(store)

        let sessionMessages = await session.messages
        #expect(store.mirror.messages == sessionMessages)
        // Two rows in the transcript: user + assistant prose.
        #expect(store.items.count == 2)
    }

    /// Same invariant across a multi-turn tool loop — the harder case,
    /// because history mutates several times per turn (assistant append,
    /// tool result attach, next assistant append, etc.).
    @Test("mirror.messages tracks session.messages across a tool loop")
    func mirrorAndSessionAgreeAcrossToolLoop() async {
        let provider = ScriptedProvider([
            [
                .toolUse(ToolUse(id: "e1", name: "echo", input: .object(["tag": .string("A")]))),
                .messageComplete(stopReason: "tool_use")
            ],
            [.text("done."), .messageComplete(stopReason: "end_turn")]
        ])
        let session = LLMSession(provider: provider, tools: [EchoTool()])
        let store = ConversationStore(session: session)

        store.send("go")
        await drainGenerating(store)

        let sessionMessages = await session.messages
        #expect(store.mirror.messages == sessionMessages)
        // Verify the tool result is threaded into the assistant message,
        // not sitting somewhere else — that's the "different merge rules"
        // divergence the issue called out.
        let tools = store.mirror.messages.flatMap(\.toolCalls)
        #expect(tools.count == 1)
        #expect(tools.first?.result?.content == "A")
    }

    // MARK: - Usage accounting (#60 sub-claim)

    /// Regression for issue #60's double-count claim: after a turn with
    /// reported usage, `store.usage` must equal `session.totalUsage`
    /// exactly — no accumulation-plus-reassignment mismatch.
    @Test("store.usage equals session.totalUsage after a turn with usage")
    func storeUsageMatchesSessionUsage() async {
        let provider = ScriptedProvider([
            [
                .text("hi."),
                .usage(TokenUsage(inputTokens: 42, outputTokens: 17)),
                .messageComplete(stopReason: "end_turn")
            ]
        ])
        let session = LLMSession(provider: provider)
        let store = ConversationStore(session: session)
        store.send("hi")
        await drainGenerating(store)
        let sessionTotal = await session.totalUsage
        #expect(store.usage == sessionTotal)
        #expect(store.usage == TokenUsage(inputTokens: 42, outputTokens: 17))
    }

    /// Two back-to-back turns with usage on both: total should be the
    /// sum, never doubled. Catches the pump-race variant where the
    /// old `usage = await session.totalUsage` line could double-count
    /// events still buffered in the AsyncStream at return time.
    @Test("usage across two turns sums exactly once")
    func usageAcrossTwoTurnsSumsOnce() async {
        let provider = ScriptedProvider([
            [
                .text("first."),
                .usage(TokenUsage(inputTokens: 10, outputTokens: 5)),
                .messageComplete(stopReason: "end_turn")
            ],
            [
                .text("second."),
                .usage(TokenUsage(inputTokens: 20, outputTokens: 8)),
                .messageComplete(stopReason: "end_turn")
            ]
        ])
        let session = LLMSession(provider: provider)
        let store = ConversationStore(session: session)
        store.send("one")
        await drainGenerating(store)
        store.send("two")
        await drainGenerating(store)
        let sessionTotal = await session.totalUsage
        #expect(store.usage == sessionTotal)
        #expect(store.usage == TokenUsage(inputTokens: 30, outputTokens: 13))
    }

    // MARK: - Cancellation surface

    /// Cancellation must land as a `"Stopped."` overlay, not swallowed
    /// silently or surfaced as a spurious error.
    @Test("stop() surfaces Stopped. overlay and clears isGenerating")
    func stopSurfacesStoppedOverlay() async {
        let provider = GatedProvider()
        let session = LLMSession(provider: provider)
        let store = ConversationStore(session: session)

        store.send("hi")
        #expect(store.isGenerating)
        store.stop()
        // Let the send task observe cancellation and the pump run its
        // "Stopped." handler.
        await drainGenerating(store)
        #expect(!store.isGenerating)
        #expect(store.mirror.errorOverlays.contains { $0.message == "Stopped." })
        #expect(store.lastError == nil)
        // Open the gate so the provider's task doesn't leak.
        await provider.open()
    }

    // MARK: - Turn-ended callback (#95)

    /// Regression for issue #95: ``ConversationStore/onTurnEnded`` fires
    /// exactly once per turn with a `.completed` outcome carrying the
    /// turn's final text, usage, and stop reason.
    @Test("onTurnEnded fires with completed outcome after a plain-text turn")
    func onTurnEndedFiresOnCompletion() async {
        let provider = ScriptedProvider([
            [
                .text("done."),
                .usage(TokenUsage(inputTokens: 7, outputTokens: 3)),
                .messageComplete(stopReason: "end_turn")
            ]
        ])
        let session = LLMSession(provider: provider)
        let store = ConversationStore(session: session)

        var outcomes: [TurnOutcome] = []
        store.onTurnEnded = { outcomes.append($0) }

        store.send("hi")
        await drainGenerating(store)

        #expect(outcomes.count == 1)
        guard case .completed(let text, let usage, let stopReason) = outcomes.first else {
            Issue.record("expected .completed outcome, got \(outcomes)")
            return
        }
        #expect(text == "done.")
        #expect(usage == TokenUsage(inputTokens: 7, outputTokens: 3))
        #expect(stopReason == "end_turn")
    }

    /// Cancelling mid-turn delivers a `.cancelled` outcome, not
    /// `.completed`.
    @Test("onTurnEnded fires with cancelled outcome after stop()")
    func onTurnEndedFiresOnCancellation() async {
        let provider = GatedProvider()
        let session = LLMSession(provider: provider)
        let store = ConversationStore(session: session)

        var outcomes: [TurnOutcome] = []
        store.onTurnEnded = { outcomes.append($0) }

        store.send("hi")
        store.stop()
        await drainGenerating(store)
        await provider.open()

        #expect(outcomes.count == 1)
        if case .cancelled = outcomes.first { } else {
            Issue.record("expected .cancelled outcome, got \(outcomes)")
        }
    }

    // MARK: - Presentation stamping around historyChanged

    /// The presentation side-table keys off message ids the session
    /// emitted. If ConversationStore drifted from the session's ids
    /// (e.g. by re-constructing the user Message with a fresh UUID),
    /// the timestamp stamped on `send()` would get orphaned by the
    /// subsequent `.historyChanged` overwrite. The `send(_ message:)`
    /// overload prevents that; this test locks the invariant.
    @Test("user row's presentation timestamp survives historyChanged overwrite")
    func userPresentationSurvivesHistoryChanged() async {
        let provider = ScriptedProvider([
            [.text("ack."), .messageComplete(stopReason: "end_turn")]
        ])
        let session = LLMSession(provider: provider)
        let store = ConversationStore(session: session)
        store.send("hi")
        await drainGenerating(store)

        // The mirror's authoritative user message is the same instance
        // the session appended, so the presentation entry (keyed at
        // send-time) still points to something that exists.
        let userMessage = store.mirror.messages.first { $0.role == .user }
        #expect(userMessage != nil)
        if let userMessage {
            #expect(store.mirror.presentation[.message(userMessage.id)] != nil)
        }
    }

    // MARK: - Helpers

    /// Yields until the store's send task and queue have both settled.
    private func drainGenerating(_ store: ConversationStore) async {
        while store.isGenerating || store.pendingPromptCount > 0 {
            await Task.yield()
        }
    }
}
