import CollaborationKit
import Foundation
import Observation

/// Owns an ``LLMSession`` and its ``MessageMirror``, and republishes the
/// projected transcript as observable ``items``.
///
/// The heavy lifting lives elsewhere:
///
/// - ``MessageMirror`` is a pure value type that consumes ``SessionEvent``s
///   and maintains the message history, streaming overlay, error overlays,
///   and presentation metadata. Unit-testable without SwiftUI.
/// - ``TranscriptProjection`` is a pure function that turns the mirror into
///   `[ConversationItem]` for rendering.
///
/// This store is the thin @Observable @MainActor shell that wires them
/// together with the session's event pump. See `#54` for the rationale.
@preconcurrency
@MainActor
@Observable
public final class ConversationStore {
    /// The current mirror. Publicly readable so hosts can inspect the raw
    /// message history + overlays without going through the projection.
    public private(set) var mirror: MessageMirror

    /// The projected transcript rows, oldest first. Rebuilt after every
    /// mutation via ``TranscriptProjection/project(_:)``.
    public private(set) var items: [ConversationItem] = []

    /// True while a turn is in flight.
    public private(set) var isGenerating: Bool = false

    /// Number of prompts queued while the current turn is running. When the
    /// active turn finishes, the next queued prompt starts automatically.
    /// UIs can surface this so users know the queue depth.
    public var pendingPromptCount: Int { pendingPrompts.count }

    /// Cumulative token usage across the session.
    public private(set) var usage = TokenUsage()

    /// Progress toward the next compaction event, as reported by the
    /// session's ``CompactionStrategy``. `nil` when the strategy does not
    /// expose a token budget (e.g. ``NoCompactionStrategy``); hosts should
    /// hide any "tokens until compaction" affordance in that case.
    public var compactionProgress: CompactionProgress? {
        session.compactionStrategy.compactionProgress(usage: usage)
    }

    /// The last harness error surfaced to the user (not a tool error).
    public private(set) var lastError: String?

    /// True when the transcript has no items.
    public var isEmpty: Bool { items.isEmpty }

    /// The finalized message history. Convenience over `mirror.messages`.
    public var messages: [Message] { mirror.messages }

    // MARK: - Wiring

    /// The session driving this store. Read-only outside the store — only
    ///  hosts inside `CollaborationKitUI` (e.g. `SessionExport.buildExport`)
    ///  reach in to read immutable session facts like ``LLMSession/system``.
    let session: LLMSession
    private let summarizeTool: @Sendable (ToolUse) -> String
    private var eventTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?

    /// In-flight session-history truncation started by ``rollBack(through:)``.
    /// Awaited by ``run(_:)`` before the next send so a prompt issued right
    /// after a rollback can't reach the session before the truncation does.
    @ObservationIgnored
    private var truncationTask: Task<Void, Never>?

    /// Set when the pump sees the current turn's `.turnEnded` sentinel.
    @ObservationIgnored
    private var turnEnded = false

    /// Suspended ``waitForTurnEnd()`` caller, resumed by the pump on
    /// `.turnEnded` (or by ``cancel()`` during teardown).
    @ObservationIgnored
    private var turnEndContinuation: CheckedContinuation<Void, Never>?

    /// Rollback snapshots keyed by the user message's id. Each entry pairs
    /// the host's restore closure with the mirror's message count *before*
    /// the user prompt was appended — the point ``rollBack(through:)`` will
    /// truncate to. Populated by ``send(_:images:snapshot:)`` and pruned
    /// after each rollback so entries for turns that no longer exist are
    /// released.
    private var rollbackSnapshots: [Message.ID: (messageCount: Int, snapshot: RollbackSnapshot)] = [:]

    /// FIFO queue of prompts submitted while a turn was already running.
    /// Drained automatically after each turn completes.
    @ObservationIgnored
    private var pendingPrompts: [PendingPrompt] = []

    /// Optional host hook consulted by ``send(_:images:snapshot:)`` when the
    /// caller doesn't supply a snapshot explicitly. Lets a host wire
    /// rollback into the built-in composer (which has no snapshot argument)
    /// by capturing whatever document state should be restorable at the
    /// moment each prompt is submitted. Return `nil` to skip the snapshot
    /// for a particular turn.
    @ObservationIgnored
    public var snapshotProvider: (@MainActor @Sendable () -> RollbackSnapshot?)?

    /// Optional host hook invoked whenever a turn ends, for any reason.
    ///
    /// Fires once per ``send(_:images:snapshot:)`` call: after a natural
    /// completion, after cancellation via ``stop()``, or after a provider
    /// or tool error. Hosts can use this to post a user notification,
    /// play a sound, or drive any other end-of-turn side effect. The
    /// callback runs on the main actor.
    ///
    /// The hook does not gate on window focus — the host decides whether
    /// to act on any given outcome (e.g. only notify when the window is
    /// unfocused).
    @ObservationIgnored
    public var onTurnEnded: (@MainActor (TurnOutcome) -> Void)?

    private struct PendingPrompt {
        var text: String
        var images: [ImageContent]
        var snapshot: RollbackSnapshot?
    }

    @preconcurrency
    public init(
        session: LLMSession,
        summarizeTool: @escaping @Sendable (ToolUse) -> String = ConversationStore.defaultSummarize(for:)
    ) {
        self.session = session
        self.summarizeTool = summarizeTool
        self.mirror = MessageMirror()
        startPump()
    }

    /// Cancels the event pump and any in-flight send. Call when tearing
    /// down — @MainActor state can't be reached from a nonisolated deinit.
    public func cancel() {
        eventTask?.cancel()
        sendTask?.cancel()
        // The pump is dead after this; release any turn-end waiter so a
        // send task blocked in waitForTurnEnd() doesn't hang forever.
        turnEndContinuation?.resume()
        turnEndContinuation = nil
    }

    // MARK: - Sending

    /// Starts a turn: appends the user message to the mirror, runs the
    /// agentic tool loop in a cancellable task, and streams events into
    /// ``items`` as they arrive.
    ///
    /// Pass a ``RollbackSnapshot`` to make the turn rewindable: hosts can
    /// then call ``rollBack(through:)`` on any earlier user prompt and the
    /// snapshot's apply closure restores whatever host state was captured.
    public func send(
        _ prompt: String,
        images: [ImageContent] = [],
        snapshot: RollbackSnapshot? = nil
    ) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(trimmed.isEmpty && images.isEmpty) else { return }

        // Fall back to the host-configured provider when no explicit
        // snapshot was passed. Captured now so the state reflects the
        // moment of send, not whenever the queued turn eventually runs.
        let effectiveSnapshot = snapshot ?? snapshotProvider?()

        // Queue rather than drop when a turn is already running; the next
        // prompt starts automatically once the current one finishes.
        if isGenerating {
            pendingPrompts.append(PendingPrompt(text: trimmed, images: images, snapshot: effectiveSnapshot))
            return
        }

        lastError = nil
        // Message count captured *before* the user message is appended, so
        // rolling back truncates to just before this turn ran.
        let preTurnCount = mirror.messages.count
        let userMessage: Message = images.isEmpty
            ? .user(trimmed)
            : .user(text: trimmed, images: images)
        mirror.appendUser(userMessage)
        if let effectiveSnapshot {
            rollbackSnapshots[userMessage.id] = (preTurnCount, effectiveSnapshot)
        }
        isGenerating = true
        reproject()

        sendTask = Task { [weak self] in
            await self?.run(userMessage)
        }
    }

    /// Cancels the in-flight turn, if any. The tool loop stops at its next
    /// cooperative cancellation point; the transcript keeps whatever has
    /// already been produced. Queued prompts are left in place — call
    /// ``clearPendingPrompts()`` to drop them as well.
    public func stop() {
        guard isGenerating else { return }
        sendTask?.cancel()
    }

    /// Discards any prompts queued behind the current turn without
    /// affecting the in-flight turn itself.
    public func clearPendingPrompts() {
        pendingPrompts.removeAll()
    }

    private func run(_ userMessage: Message) async {
        // A rollback may still be truncating the session's history; let it
        // land before this turn's history is sent to the provider.
        await truncationTask?.value
        turnEnded = false
        defer {
            isGenerating = false
            sendTask = nil
            reproject()
            drainNextPendingPrompt()
        }

        do {
            // Pass the pre-constructed Message so its id matches the one
            // the mirror already stamped for presentation and rollback
            // — the subsequent `.historyChanged` snapshot overwrites
            // `mirror.messages` and the ids need to line up.
            _ = try await session.send(userMessage)
            // A cancelled `AsyncThrowingStream` returns end-of-stream
            // rather than throwing, so session.send may complete
            // "normally" from a cancellation. Surface that as a
            // Stopped. overlay too, or `stop()` would look like a
            // silent no-op.
            if Task.isCancelled {
                mirror.appendError("Stopped.")
            }
        } catch is CancellationError {
            mirror.appendError("Stopped.")
        } catch {
            if Task.isCancelled {
                mirror.appendError("Stopped.")
            } else {
                mirror.appendError("\(error)")
                lastError = "\(error)"
                onTurnEnded?(.failed("\(error)"))
            }
        }
        // Wait for the event pump to drain the turn's remaining buffered
        // events. session.send returns as soon as its final event is
        // yielded onto the AsyncStream; a `.historyChanged` or `.usage`
        // event may still be waiting on the pump task's `await next()`.
        // The session emits a `.turnEnded` sentinel as the turn's very
        // last event, so once the pump has seen it every earlier event
        // has been handled and observers who read state right after
        // `isGenerating` flips see up-to-date mirror / usage values.
        //
        // Usage was accumulated live in `handle` from `.usage` events.
        // Re-reading `session.totalUsage` here would race the pump: any
        // `.usage` event still buffered would be added on top of a value
        // that already included it. Trust the pump — just wait for it.
        await waitForTurnEnd()
    }

    /// Suspends until the pump handles the current turn's `.turnEnded`
    /// sentinel. Returns immediately if it already arrived. Resumed by
    /// ``cancel()`` during teardown so the send task can't leak.
    private func waitForTurnEnd() async {
        if turnEnded { return }
        await withCheckedContinuation { continuation in
            // Re-check after suspension was requested: the pump runs on
            // the same actor and may have handled `.turnEnded` between
            // the guard above and this closure executing.
            if turnEnded {
                continuation.resume()
            } else {
                turnEndContinuation = continuation
            }
        }
    }

    /// Pops the next queued prompt (if any) and re-enters ``send`` so the
    /// standard flow — rollback snapshot bookkeeping, event pump, error
    /// handling — stays in one place.
    private func drainNextPendingPrompt() {
        guard !pendingPrompts.isEmpty else { return }
        let next = pendingPrompts.removeFirst()
        send(next.text, images: next.images, snapshot: next.snapshot)
    }

    // MARK: - Rollback

    /// True if the item at `id` is a user prompt with a rollback snapshot
    /// attached and no turn is in flight. UI affordances ("Roll Back to
    /// Here") should hide themselves when this returns `false`.
    public func canRollBack(to id: ItemID) -> Bool {
        guard !isGenerating, case .message(let uuid) = id else { return false }
        return rollbackSnapshots[uuid] != nil
    }

    /// The most recent user prompt that can be rolled back to, if any.
    ///
    /// Menu commands (`Edit → Roll Back Last Turn`) act on the last turn
    /// rather than a selected row, so they need this rather than a per-row
    /// ``canRollBack(to:)`` check. `nil` while a turn is in flight or when
    /// no prompt carries a snapshot.
    public var lastRollbackTarget: ItemID? {
        guard !isGenerating else { return nil }
        return items.reversed().first { item in
            guard case .user = item.kind else { return false }
            return canRollBack(to: item.id)
        }?.id
    }

    /// Rolls the whole session back to just before the user prompt at `id`:
    /// applies the host's restore closure, truncates the mirror + session
    /// history to the recorded pre-turn count, drops error overlays and
    /// streaming state, and reprojects. A no-op if the id has no snapshot
    /// or a turn is currently in flight.
    ///
    /// Later turns' snapshots are discarded too — rolling back past a turn
    /// implicitly invalidates every turn after it.
    public func rollBack(through id: ItemID) {
        guard !isGenerating,
              case .message(let uuid) = id,
              let entry = rollbackSnapshots[uuid] else { return }

        // Host state first, so any UI observers of the host's state see it
        // return to the pre-turn value before the transcript rows fall away.
        entry.snapshot.apply()

        // Truncate the projection's source of truth (mirror) and the
        // session's own history to the same pre-turn count.
        let keep = entry.messageCount
        mirror.truncate(keepingMessages: keep)
        // Tracked so the next turn's `run(_:)` awaits it — a send issued
        // right after this call must not race the truncation to the actor.
        let previous = truncationTask
        truncationTask = Task { [session] in
            await previous?.value
            await session.truncateHistory(keeping: keep)
        }

        // Any snapshot whose pre-turn count is >= the rollback point
        // referred to a turn that no longer exists.
        rollbackSnapshots = rollbackSnapshots.filter { _, entry in entry.messageCount < keep }

        lastError = nil
        reproject()
    }

    // MARK: - Event pump

    private func startPump() {
        eventTask?.cancel()
        let events = session.events
        eventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                handle(event)
            }
        }
    }

    private func handle(_ event: SessionEvent) {
        if case .usage(let turnUsage) = event {
            usage += turnUsage
        }
        if case .turnEnded = event {
            turnEnded = true
            turnEndContinuation?.resume()
            turnEndContinuation = nil
        }
        mirror.handle(event, summary: summarizeTool)
        reproject()
        switch event {
        case .turnComplete(let text, let usage, let stopReason):
            onTurnEnded?(.completed(text: text, usage: usage, stopReason: stopReason))
        case .turnCancelled(let partialText):
            onTurnEnded?(.cancelled(partialText: partialText))
        default:
            break
        }
    }

    // MARK: - Projection

    private func reproject() {
        let (rows, livingIDs) = TranscriptProjection.project(mirror)
        mirror.compact(livingIDs: livingIDs)
        items = rows
    }
}

// MARK: - Default tool summarizer

extension ConversationStore {
    /// Default summary for a tool row's argument line.
    ///
    /// Handles the built-in `read`/`write`/`edit` file tools shipped in
    /// ``CollaborationKit``. Falls back to the tool's name for unknown
    /// tools; hosts override via `summarizeTool`.
    nonisolated public static func defaultSummarize(for use: ToolUse) -> String {
        switch use.name {
        case "read":
            return "reading the file"

        case "write":
            return "writing the file"

        case "edit":
            if case .object(let fields) = use.input,
               case .string(let old)? = fields["oldText"] {
                let snippet = old.prefix(40)
                return "replacing “\(snippet)…”"
            }
            return "editing the file"

        default:
            return use.name
        }
    }
}
