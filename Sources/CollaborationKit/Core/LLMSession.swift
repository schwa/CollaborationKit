import Foundation

/// An error raised by the session harness itself, distinct from tool failures.
///
/// Tool failures are fed back to the model as error results; harness errors
/// throw out of ``LLMSession/send(_:)`` to the caller.
public enum SessionError: Error, Sendable {
    /// The model referenced a tool name that is not registered.
    case unknownTool(String)

    /// The tool loop exceeded ``LLMSession/maxIterations`` without completing.
    ///
    /// - Parameters:
    ///   - iterations: The cap that was hit (equal to
    ///     ``LLMSession/maxIterations`` at the time of the call).
    ///   - partialText: All assistant prose produced across the exhausted
    ///     turns, concatenated in order. Empty when the model only ever
    ///     emitted tool calls and no text. The full domain history — every
    ///     assistant message, tool call, and tool result the loop managed to
    ///     produce before hitting the cap — remains available on
    ///     ``LLMSession/messages``.
    case maxIterationsExceeded(iterations: Int, partialText: String)

    /// A second ``LLMSession/send(_:)`` call arrived while another turn was
    /// still in flight on the same session.
    ///
    /// Two concurrent turns would interleave onto the same event stream and
    /// the same message history, so the session refuses the second call.
    /// Well-behaved hosts (e.g. ``CollaborationKitUI``'s ConversationStore)
    /// already serialize their sends and won't see this; direct API callers
    /// should await one turn before starting the next.
    case turnAlreadyInProgress
}

/// A provider-agnostic conversation that runs an agentic tool-use loop.
///
/// A session owns the conversation history, the registered tools, and the loop
/// that round-trips between the model and tool execution. Drive it with
/// ``send(_:)`` for the final text, and observe live activity via ``events``.
///
/// Sessions are actors; their history is mutated only on the actor.
public actor LLMSession {
    private let provider: ModelProvider
    /// The system prompt this session was created with, if any. Exposed so
    /// hosts (e.g. debug-export bundles) can record the instructions the
    /// model was given alongside the transcript. Immutable for the life of
    /// the session.
    nonisolated public let system: String?
    private let tools: [String: any Tool]
    private let toolSpecs: [ToolSpec]
    private let approval: @Sendable (ToolUse) async -> ToolApprovalDecision

    /// The strategy consulted at the top of every model round-trip to trim
    /// the conversation history before it is sent to the provider. Exposed
    /// so hosts (e.g. ``CollaborationKitUI/ConversationStore``) can ask the
    /// strategy for its ``CompactionProgress`` to render a
    /// tokens-until-compaction indicator.
    nonisolated public let compactionStrategy: any CompactionStrategy

    /// The maximum number of model/tool round-trips per ``send(_:)`` call.
    public let maxIterations: Int

    private var history: [Message] = []

    private let eventContinuation: AsyncStream<SessionEvent>.Continuation
    /// A stream of events describing turn progress: text, tool calls, results.
    nonisolated public let events: AsyncStream<SessionEvent>

    /// Creates a session.
    ///
    /// - Parameters:
    ///   - provider: The backend used to run model turns.
    ///   - system: An optional system prompt.
    ///   - tools: The tools the model may invoke. Names must be unique.
    ///   - approval: An async gate consulted before each tool invocation.
    ///     Return ``ToolApprovalDecision/deny(reason:)`` to block a call —
    ///     the model receives an `is_error` tool result carrying the reason
    ///     and can adapt. Defaults to allow-all.
    ///   - maxIterations: A cap on model/tool round-trips per turn.
    ///   - compactionStrategy: The strategy consulted at the top of every
    ///     model round-trip to trim the conversation history before it is
    ///     sent to the provider. Defaults to ``NoCompactionStrategy``
    ///     (never compacts) so existing callers are unaffected. Supply a
    ///     ``KeepRecentCompactionStrategy`` or a custom ``CompactionStrategy``
    ///     to bound the request size on long-running sessions.
    @preconcurrency
    public init(
        provider: ModelProvider,
        system: String? = nil,
        tools: [any Tool] = [],
        approval: @escaping @Sendable (ToolUse) async -> ToolApprovalDecision = { _ in .allow },
        maxIterations: Int = 32,
        compactionStrategy: any CompactionStrategy = NoCompactionStrategy()
    ) {
        self.provider = provider
        self.system = system
        self.tools = Dictionary(tools.map { ($0.name, $0) }) { _, new in new }
        self.toolSpecs = tools.map { ToolSpec(name: $0.name, description: $0.description, inputSchema: $0.inputSchema) }
        self.approval = approval
        self.maxIterations = maxIterations
        self.compactionStrategy = compactionStrategy

        var continuation: AsyncStream<SessionEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    /// The conversation so far, read-only. Serialize this if you need to persist.
    public var messages: [Message] {
        history
    }

    /// Truncates the conversation history to the first `count` messages,
    /// discarding everything after.
    ///
    /// Use this to "roll back" the model's memory to an earlier point: the next
    /// ``send(_:)`` continues as if the discarded turns never happened. `count`
    /// is clamped to the current history length, so values larger than
    /// ``messages``.count leave the history unchanged and negative values clear
    /// it.
    ///
    /// - Parameter count: The number of leading messages to keep.
    public func truncateHistory(keeping count: Int) {
        let clamped = max(0, min(count, history.count))
        history.removeLast(history.count - clamped)
        yieldHistory()
    }

    /// Replaces the conversation history with a previously persisted one.
    ///
    /// Use this to reopen a saved session: the next ``send(_:)`` continues
    /// as though the restored turns had happened in this process. Emits a
    /// ``SessionEvent/historyChanged(_:)`` so any mirror stays in step.
    ///
    /// Accumulated usage is *not* restored — ``totalUsage`` reports what this
    /// session object has seen, and a host that persists usage should carry
    /// it in its own snapshot (``SessionExport`` does).
    ///
    /// Call between turns. Restoring mid-turn leaves the in-flight request
    /// running against a history it no longer matches.
    ///
    /// - Parameter messages: The history to adopt, oldest first.
    public func restoreHistory(_ messages: [Message]) {
        history = messages
        yieldHistory()
    }

    private var accumulatedUsage = TokenUsage()
    private var isRunning = false
    /// Assistant prose accumulated across every round-trip of the current
    /// turn. Reset at the start of each ``send(text:images:)`` call and
    /// used to populate ``SessionEvent/turnCancelled(partialText:)`` and
    /// ``SessionError/maxIterationsExceeded(iterations:partialText:)``
    /// without threading the buffer through every helper.
    private var currentTurnText = ""

    /// Cumulative token usage across all turns in this session.
    ///
    /// Providers that do not report usage contribute zero. This is per-session
    /// accounting, not the model's remaining context window.
    public var totalUsage: TokenUsage {
        accumulatedUsage
    }

    /// Sends a user message and runs the tool loop until the model stops.
    ///
    /// - Parameter text: The user's message.
    /// - Returns: The model's final assistant text for the turn.
    /// - Throws: ``SessionError`` or any provider/transport error. Tool failures
    ///   are not thrown; they are fed back to the model as error results.
    public func send(_ text: String) async throws -> String {
        try await send(text: text)
    }

    /// Sends a user message with optional image attachments and runs the tool
    /// loop until the model stops.
    ///
    /// - Parameters:
    ///   - text: The user's message.
    ///   - images: Image attachments to include alongside the text.
    /// - Returns: The model's final assistant text for the turn.
    /// - Throws: ``SessionError`` or any provider/transport error. Tool failures
    ///   are not thrown; they are fed back to the model as error results.
    public func send(text: String, images: [ImageContent] = []) async throws -> String {
        let message: Message = images.isEmpty
            ? .user(text)
            : .user(text: text, images: images)
        return try await send(message)
    }

    /// Sends a pre-constructed user message and runs the tool loop until
    /// the model stops. Preserves the caller's message id so hosts that
    /// keyed UI state on it (e.g. rollback snapshots in
    /// ``CollaborationKitUI``'s ConversationStore) stay in sync with the
    /// session's history after the next ``SessionEvent/historyChanged(_:)``.
    public func send(_ message: Message) async throws -> String {
        guard !isRunning else { throw SessionError.turnAlreadyInProgress }
        isRunning = true
        currentTurnText = ""
        defer {
            isRunning = false
            currentTurnText = ""
            // Sentinel: always the turn's final event, after any
            // `.turnComplete` / `.turnCancelled`. Lets consumers wait for
            // the stream to drain without counting yields.
            eventContinuation.yield(.turnEnded)
        }
        history.append(message)
        yieldHistory()
        do {
            return try await runLoop()
        } catch is CancellationError {
            eventContinuation.yield(.turnCancelled(partialText: currentTurnText))
            throw CancellationError()
        }
    }

    /// Finishes the ``events`` stream so long-lived observers can exit
    /// their `for await` loops. History and token accounting are preserved
    /// but no further events fire. Call once when the host is done with
    /// the session.
    public func close() {
        eventContinuation.finish()
    }

    // MARK: - Turn loop

    /// The outcome of running one model round-trip.
    ///
    /// Distinguishing the two states lets ``runLoop()`` be a plain
    /// terminate-or-continue driver over ``runTurn()`` — no interleaved
    /// bookkeeping, no shared mutable state to reason about. Compaction hooks
    /// (see #7) plug in at the top of ``runTurn`` without touching this loop.
    private enum TurnOutcome {
        /// The model produced final text with no more tool calls to run.
        case complete(text: String, roundUsage: TokenUsage, stopReason: String?)
        /// The model requested tools; they've been executed and appended to
        /// the history. `text` is the assistant prose so far this turn.
        case needsMoreTurns(text: String, roundUsage: TokenUsage)
    }

    /// The turn-loop driver: repeatedly runs one ``runTurn()`` until either
    /// the model completes or ``maxIterations`` is exceeded. Every side
    /// effect — event fan-out, history mutation, tool dispatch — lives
    /// inside the helpers below; this method is pure control flow.
    private func runLoop() async throws -> String {
        // Every round's assistant text lands on `currentTurnText` so a
        // maxIterations failure or mid-turn cancellation can hand back
        // whatever prose was produced before we bailed. The success
        // path still returns only the final turn's text; the domain
        // history on `messages` retains every earlier block.
        var turnUsage = TokenUsage()
        for _ in 0..<maxIterations {
            try Task.checkCancellation()
            switch try await runTurn() {
            case .complete(let text, let roundUsage, let stopReason):
                turnUsage += roundUsage
                eventContinuation.yield(
                    .turnComplete(text: text, usage: turnUsage, stopReason: stopReason)
                )
                return text

            case .needsMoreTurns(_, let roundUsage):
                turnUsage += roundUsage
                continue
            }
        }

        throw SessionError.maxIterationsExceeded(
            iterations: maxIterations,
            partialText: currentTurnText
        )
    }

    /// The parts of an assistant message produced by one provider stream:
    /// the aggregated final prose for the turn, any pending tool uses the
    /// model asked for, the round's usage, and the stop reason. The
    /// message itself is already committed to ``history`` by the time
    /// this is returned — see ``streamAssistantMessage()``.
    private struct AssistantMessageParts {
        var text: String
        var pendingToolUses: [ToolUse]
        /// Aggregated token usage the provider reported for this single
        /// round-trip. Zero when the provider omits usage.
        var roundUsage: TokenUsage
        /// The provider's stop reason for this round, if any.
        var stopReason: String?
    }

    /// Runs a single model round-trip: streams provider events into the
    /// session's event continuation, appends the assistant message to the
    /// history, and dispatches any pending tools.
    ///
    /// Extension seam: a future compaction pass (#7) can trim ``history``
    /// here — before the provider is called — without disturbing the
    /// turn-loop control flow above.
    private func runTurn() async throws -> TurnOutcome {
        // Compaction pass (#7): the strategy sees the current history and
        // may return a trimmed version to replace it. Runs before the
        // provider stream so the wire request reflects the compacted
        // shape. NoCompactionStrategy is a passthrough.
        history = await compactionStrategy.compact(history: history, usage: accumulatedUsage)
        yieldHistory()

        let parts = try await streamAssistantMessage()
        // streamAssistantMessage appended the assistant message to
        // `history` before returning; the last index is where its tool
        // results will land.
        let assistantIndex = history.count - 1

        guard !parts.pendingToolUses.isEmpty else {
            return .complete(text: parts.text, roundUsage: parts.roundUsage, stopReason: parts.stopReason)
        }

        await runPendingTools(parts.pendingToolUses, inMessageAt: assistantIndex)
        return .needsMoreTurns(text: parts.text, roundUsage: parts.roundUsage)
    }

    /// Consumes one full provider stream and produces the components of the
    /// assistant message: content blocks, aggregated prose, and any pending
    /// tool uses. Fans each provider event out onto ``events`` in order.
    ///
    /// The event-fan-out concern lives entirely here, so the turn loop and
    /// tool dispatcher don't touch ``eventContinuation`` for stream events.
    private func streamAssistantMessage() async throws -> AssistantMessageParts {
        // Reserve the assistant message's identity up front so every
        // in-flight `.historyChanged` snapshot and the final committed
        // message share the same row id — consumers keyed on it (e.g.
        // ``MessageMirror``'s presentation side-table) see one stable id.
        let inFlightID = UUID()
        let inFlightTimestamp = Date()
        var assistantBlocks: [ContentBlock] = []
        var turnText = ""
        var pendingToolUses: [ToolUse] = []
        var roundUsage = TokenUsage()
        var stopReason: String?

        // The provider sees `history` without any placeholder — the
        // in-flight snapshots only appear on the `events` stream.
        let stream = provider.send(messages: history, system: system, tools: toolSpecs)
        for try await event in stream {
            switch event {
            case .textDelta(let chunk):
                eventContinuation.yield(.textDelta(chunk))

            case .text(let block):
                turnText += block
                currentTurnText += block
                assistantBlocks.append(.text(block))
                yieldInFlightHistory(id: inFlightID, timestamp: inFlightTimestamp, blocks: assistantBlocks)
                eventContinuation.yield(.text(block))

            case .toolUse(let use):
                // Domain shape: the call lands in the assistant message now,
                // with a pending (nil) result that fills in after execution.
                assistantBlocks.append(.toolCall(ToolCall(use: use)))
                pendingToolUses.append(use)
                yieldInFlightHistory(id: inFlightID, timestamp: inFlightTimestamp, blocks: assistantBlocks)
                eventContinuation.yield(.toolCall(use))

            case .usage(let usage):
                accumulatedUsage += usage
                roundUsage += usage
                eventContinuation.yield(.usage(usage))

            case .messageComplete(let reason):
                stopReason = reason
            }
        }

        // On cancellation the provider stream ends cleanly (next()
        // returns nil); turn that into CancellationError so `send()`
        // emits `turnCancelled` instead of appending an empty message.
        try Task.checkCancellation()

        // Commit the completed assistant message to authoritative history
        // with the same id used in every in-flight snapshot.
        history.append(Message(
            id: inFlightID,
            timestamp: inFlightTimestamp,
            role: .assistant,
            content: assistantBlocks
        ))
        yieldHistory()

        return AssistantMessageParts(
            text: turnText,
            pendingToolUses: pendingToolUses,
            roundUsage: roundUsage,
            stopReason: stopReason
        )
    }

    /// Runs each pending tool in order, attaches its result to the matching
    /// ``ToolCall`` inside the assistant message at `messageIndex` (keeping
    /// the history domain-shaped: one assistant message owns its tool calls
    /// and their results), and emits a `.toolResult` event.
    private func runPendingTools(_ uses: [ToolUse], inMessageAt messageIndex: Int) async {
        for use in uses {
            let result = await execute(use)
            attachResult(result, toUse: use.id, inMessageAt: messageIndex)
            yieldHistory()
            eventContinuation.yield(.toolResult(result))
        }
    }

    /// Emits `.historyChanged` with the current authoritative history so
    /// consumers replace their local copy rather than reducing per-block
    /// events — the reducer lives here, not in every mirror.
    private func yieldHistory() {
        eventContinuation.yield(.historyChanged(history))
    }

    /// Emits an in-flight snapshot: `history` plus a synthetic assistant
    /// message with a stable id representing the still-streaming turn.
    /// The provider was called with the pre-placeholder `history`, so
    /// no empty assistant message escapes to the wire.
    private func yieldInFlightHistory(id: UUID, timestamp: Date, blocks: [ContentBlock]) {
        var snapshot = history
        snapshot.append(Message(id: id, timestamp: timestamp, role: .assistant, content: blocks))
        eventContinuation.yield(.historyChanged(snapshot))
    }

    /// Attaches a tool result to its pending ``ToolCall`` within the message at
    /// `index`, matched by tool-use id. Keeps the history domain-shaped.
    private func attachResult(_ result: ToolResult, toUse useID: String, inMessageAt index: Int) {
        guard history.indices.contains(index) else { return }
        for blockIndex in history[index].content.indices {
            if case .toolCall(var call) = history[index].content[blockIndex], call.use.id == useID {
                call.result = result
                history[index].content[blockIndex] = .toolCall(call)
                return
            }
        }
    }

    private func execute(_ use: ToolUse) async -> ToolResult {
        guard let tool = tools[use.name] else {
            return ToolResult(
                toolUseID: use.id,
                content: "Unknown tool: \(use.name)",
                isError: true
            )
        }
        // Only tools that opted in via `requiresApproval` consult the host.
        // Everything else runs unattended — the approval closure would
        // otherwise fire for every read/list/search call the model made.
        // A denial is reported to the model as an error result so it can
        // pivot to a different plan on the next turn.
        if tool.requiresApproval {
            switch await approval(use) {
            case .allow:
                break

            case .deny(let reason):
                let message = reason.isEmpty ? "Denied by the host." : "Denied: \(reason)"
                return ToolResult(toolUseID: use.id, content: message, isError: true)
            }
        }
        do {
            let output = try await tool.call(json: use.input)
            return ToolResult(toolUseID: use.id, content: output)
        } catch let error as ToolError {
            return ToolResult(toolUseID: use.id, content: error.message, isError: true)
        } catch {
            return ToolResult(toolUseID: use.id, content: "\(error)", isError: true)
        }
    }
}

/// The host's decision for whether a specific tool invocation may proceed.
///
/// Returned from the approval closure supplied to
/// ``LLMSession/init(provider:system:tools:approval:maxIterations:)``.
public enum ToolApprovalDecision: Sendable, Equatable {
    /// Allow the call to run.
    case allow
    /// Deny the call. The model receives an `is_error` tool result carrying
    /// `reason`. Empty reason falls back to "Denied by the host."
    case deny(reason: String)

    /// Convenience: deny with no explanation.
    public static let deny: ToolApprovalDecision = .deny(reason: "")
}
