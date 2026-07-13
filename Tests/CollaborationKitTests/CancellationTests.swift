@testable import CollaborationKit
import Foundation
import Testing

/// A provider whose stream never emits anything until the underlying task
/// is cancelled. Simulates a long-running network turn that gets stopped
/// mid-flight.
private struct HangingProvider: ModelProvider {
    /// Optional prose to yield before hanging, so tests can verify that
    /// partial text captured before cancellation flows into
    /// ``SessionEvent/turnCancelled(partialText:)``.
    let preamble: String?

    init(preamble: String? = nil) {
        self.preamble = preamble
    }

    func send(
        messages _: [Message],
        system _: String?,
        tools _: [ToolSpec]
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        let preamble = preamble
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let preamble {
                    continuation.yield(.text(preamble))
                    // Yield the runtime so the reader observes the text
                    // event before we suspend.
                    await Task.yield()
                }
                // Suspend forever; the reader task's cancellation lets
                // AsyncThrowingStream return nil from `next()`, which
                // fires `onTermination` and cancels this Task.
                try? await Task.sleep(for: .seconds(3_600))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Test
func cancellingInFlightSendThrowsCancellationErrorAndEmitsTurnCancelled() async throws {
    let provider = HangingProvider(preamble: "half-thought")
    let session = LLMSession(provider: provider)

    // Collect events on a separate task so we can observe turnCancelled
    // without racing the send. The events stream is finished via close()
    // after the send unwinds, so this loop terminates.
    let events = session.events
    let collector = Task { () -> [SessionEvent] in
        var collected: [SessionEvent] = []
        for await event in events {
            collected.append(event)
        }
        return collected
    }

    let sendTask = Task { try await session.send("hi") }

    // Give the send time to enter the provider stream and yield the
    // preamble text event.
    try await Task.sleep(for: .milliseconds(100))

    sendTask.cancel()

    await #expect(throws: CancellationError.self) {
        _ = try await sendTask.value
    }

    // Finish the events stream so the collector loop can exit.
    await session.close()
    let collected = await collector.value

    // The turnCancelled event carries the assistant prose captured
    // before cancellation.
    let cancelledPayload = collected.compactMap { event -> String? in
        if case .turnCancelled(let text) = event { return text }
        return nil
    }
    #expect(cancelledPayload == ["half-thought"])

    // No turnComplete event was emitted for the cancelled turn.
    let completed = collected.contains { event in
        if case .turnComplete = event { return true }
        return false
    }
    #expect(!completed)
}

@Test
func cancellingBeforeAnyTextEmitsTurnCancelledWithEmptyPartialText() async throws {
    let provider = HangingProvider()
    let session = LLMSession(provider: provider)

    let events = session.events
    let collector = Task { () -> [SessionEvent] in
        var collected: [SessionEvent] = []
        for await event in events {
            collected.append(event)
        }
        return collected
    }

    let sendTask = Task { try await session.send("hi") }
    try await Task.sleep(for: .milliseconds(50))
    sendTask.cancel()

    await #expect(throws: CancellationError.self) {
        _ = try await sendTask.value
    }

    await session.close()
    let collected = await collector.value

    let cancelledPayload = collected.compactMap { event -> String? in
        if case .turnCancelled(let text) = event { return text }
        return nil
    }
    #expect(cancelledPayload == [""])
}

@Test
func closeFinishesTheEventsStreamForObservers() async {
    // A minimal provider that never gets called. We only need the
    // session's events stream.
    let provider = HangingProvider()
    let session = LLMSession(provider: provider)

    let events = session.events
    let collector = Task { () -> Int in
        var count = 0
        for await _ in events { count += 1 }
        return count
    }

    // close() must terminate the events AsyncStream so long-lived
    // observers can exit their `for await` loops (issue #4).
    await session.close()

    // The collector completes because the stream finished. Await it
    // with a small timeout via Task.sleep to avoid hanging tests if
    // the bug regresses.
    let value = await withTaskGroup(of: Int?.self) { group in
        group.addTask { await collector.value }
        group.addTask {
            try? await Task.sleep(for: .seconds(1))
            return nil
        }
        let first = await group.next()!
        group.cancelAll()
        return first
    }

    #expect(value != nil)
}

@Test
func sessionRemainsUsableAfterAcancelledTurn() async throws {
    // A provider that hangs on the first call and answers normally on
    // the second, so we can prove the session recovers from cancellation
    // and can serve a follow-up turn.
    actor TwoPhaseProvider: ModelProvider {
        private var callIndex = 0

        nonisolated func send(
            messages _: [Message],
            system _: String?,
            tools _: [ToolSpec]
        ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    let index = await self.nextIndex()
                    if index == 0 {
                        // First call hangs until cancelled.
                        try? await Task.sleep(for: .seconds(3_600))
                        continuation.finish()
                    } else {
                        continuation.yield(.text("second reply"))
                        continuation.yield(.messageComplete(stopReason: "end_turn"))
                        continuation.finish()
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        private func nextIndex() -> Int {
            defer { callIndex += 1 }
            return callIndex
        }
    }

    let session = LLMSession(provider: TwoPhaseProvider())

    let sendTask = Task { try await session.send("first") }
    try await Task.sleep(for: .milliseconds(50))
    sendTask.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await sendTask.value
    }

    // The session must not be stuck with isRunning=true; a fresh send
    // succeeds.
    let reply = try await session.send("second")
    #expect(reply == "second reply")
}
