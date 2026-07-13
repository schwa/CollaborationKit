import Foundation
import Observation
import CollaborationKit

/// Owns an ``LLMSession`` and projects its live event stream into an
/// observable transcript.
///
/// The transcript is a *pure projection* of the session's ``Message`` history
/// plus two overlays that genuinely live outside that history: the in-flight
/// streaming assistant bubble, and harness/transport errors. The store mirrors
/// the session's finalized messages as events arrive, records presentation
/// metadata (timestamps, durations, latency, tool summaries) in a side-table,
/// and recomputes ``items`` from those.
///
/// Adapted from Phosphor's `ConversationStore` — the proven implementation.
@MainActor
@Observable
public final class ConversationStore {
    /// The model's finalized message history, mirrored from the session as
    /// events arrive. The single source of truth the transcript projects from.
    public private(set) var messages: [Message] = []

    /// The projected transcript, oldest first. Recomputed from ``messages``
    /// plus the streaming/error overlays whenever either changes.
    public private(set) var items: [ConversationItem] = []

    /// True while a turn is in flight.
    public private(set) var isGenerating: Bool = false

    /// Cumulative token usage across the session.
    public private(set) var usage: TokenUsage = TokenUsage()

    /// The last harness error surfaced to the user (not a tool error).
    public private(set) var lastError: String?

    /// True when the transcript is empty (no items projected yet).
    public var isEmpty: Bool { items.isEmpty }

    // MARK: - Projection inputs

    /// Live assistant prose for the current streaming bubble, before it is
    /// finalized into ``messages``. `nil` when not streaming.
    private var streamingAssistantText: String?

    /// Harness/transport errors, which have no place in the model history.
    private var errorOverlays: [(seq: Int, message: String)] = []
    private var errorSeq: Int = 0

    /// Presentation metadata (per-row timing + tool summary) keyed by
    /// ``ItemID``. Holds only what the model history can't carry; identity is
    /// derived, not cached.
    private var presentation: [ItemID: Presentation] = [:]

    // MARK: - Wiring

    private let session: LLMSession
    private let summarizeTool: @Sendable (ToolUse) -> String
    private var eventTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?

    /// Creates a store around an existing ``LLMSession``.
    ///
    /// - Parameters:
    ///   - session: The session to observe. The store subscribes to its
    ///     ``LLMSession/events`` stream immediately.
    ///   - summarizeTool: Optional customization for the per-tool argument
    ///     summary shown on a tool row. Defaults to
    ///     ``ConversationStore/defaultSummarize(for:)``, which handles the
    ///     built-in `read`/`write`/`edit` file tools.
    public init(
        session: LLMSession,
        summarizeTool: @escaping @Sendable (ToolUse) -> String = ConversationStore.defaultSummarize(for:)
    ) {
        self.session = session
        self.summarizeTool = summarizeTool
        startPump()
    }

    /// Cancels the event pump and any in-flight send. Call from the host when
    /// tearing down the view that owns the store — Swift's nonisolated deinit
    /// can't reach `@MainActor` state, so cleanup is explicit.
    public func cancel() {
        eventTask?.cancel()
        sendTask?.cancel()
    }

    // MARK: - Sending

    /// Starts a turn: appends the user message to the mirror, runs the
    /// agentic tool loop in a cancellable task, and streams events into
    /// ``items`` as they arrive.
    public func send(_ prompt: String, images: [ImageContent] = []) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(trimmed.isEmpty && images.isEmpty), !isGenerating else { return }

        lastError = nil
        let userMessage: Message = images.isEmpty
            ? .user(trimmed)
            : .user(text: trimmed, images: images)
        messages.append(userMessage)
        presentation[.message(userMessage.id)] = Presentation(timestamp: Date())
        isGenerating = true
        reproject()

        sendTask = Task { [weak self] in
            await self?.run(trimmed, images: images)
        }
    }

    /// Cancels the in-flight turn, if any. The tool loop stops at its next
    /// cooperative cancellation point; the transcript keeps whatever has
    /// already been produced.
    public func stop() {
        guard isGenerating else { return }
        sendTask?.cancel()
    }

    private func run(_ trimmed: String, images: [ImageContent]) async {
        defer {
            isGenerating = false
            sendTask = nil
            reproject()
        }

        do {
            _ = try await session.send(text: trimmed, images: images)
        } catch is CancellationError {
            appendError("Stopped.")
        } catch {
            if Task.isCancelled {
                appendError("Stopped.")
            } else {
                appendError("\(error)")
                lastError = "\(error)"
            }
        }
        streamingAssistantText = nil
        usage = await session.totalUsage
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
        switch event {
        case .textDelta(let chunk):
            appendAssistantDelta(chunk)

        case .text(let block):
            finalizeAssistantProse(block)

        case .toolCall(let use):
            finishStreamingAssistant()
            let id = ItemID.tool(use.id)
            var meta = Presentation(timestamp: Date())
            meta.latency = latencyForNextRow()
            meta.summary = summarizeTool(use)
            presentation[id] = meta
            appendToolUseToMirror(use)
            reproject()

        case .toolResult(let result):
            let id = ItemID.tool(result.toolUseID)
            if let start = presentation[id]?.timestamp {
                presentation[id]?.duration = Date().timeIntervalSince(start)
            }
            attachResultToMirror(result)
            reproject()

        case .usage(let turnUsage):
            usage += turnUsage

        case .turnComplete:
            finishStreamingAssistant()
        }
    }

    // MARK: - Assistant prose plumbing

    private func appendAssistantDelta(_ chunk: String) {
        if streamingAssistantText == nil {
            var meta = Presentation(timestamp: Date())
            meta.latency = latencyForNextRow()
            presentation[.streamingAssistant] = meta
            streamingAssistantText = chunk
        } else {
            streamingAssistantText? += chunk
        }
        reproject()
    }

    /// Finalizes a completed assistant prose block into the message mirror,
    /// keyed by its message id, and clears the streaming overlay — carrying
    /// the overlay's timing (start / latency / freshly stamped duration) onto
    /// the finalized row so visible timing survives the hand-off.
    private func finalizeAssistantProse(_ block: String) {
        let destID = appendAssistantProseToMirror(block)
        if var meta = presentation[.streamingAssistant] {
            meta.duration = Date().timeIntervalSince(meta.timestamp)
            presentation[destID] = meta
        }
        presentation[.streamingAssistant] = nil
        streamingAssistantText = nil
        reproject()
    }

    /// Clears the streaming overlay without finalizing (turn end / tool break
    /// where no `.text` block arrived). Stamps duration for completeness.
    private func finishStreamingAssistant() {
        if streamingAssistantText != nil, let start = presentation[.streamingAssistant]?.timestamp {
            presentation[.streamingAssistant]?.duration = Date().timeIntervalSince(start)
        }
        streamingAssistantText = nil
        reproject()
    }

    /// Appends a finalized assistant prose block to the mirror, merging into
    /// the trailing assistant message when it doesn't yet have prose.
    /// Returns the ``ItemID`` of the assistant message holding it.
    private func appendAssistantProseToMirror(_ block: String) -> ItemID {
        if let last = messages.indices.last,
           messages[last].role == .assistant,
           !messages[last].content.contains(where: { if case .text = $0 { return true } else { return false } }) {
            messages[last].content.insert(.text(block), at: 0)
            return .message(messages[last].id)
        }
        let message = Message(role: .assistant, content: [.text(block)])
        messages.append(message)
        return .message(message.id)
    }

    // MARK: - Tool mirroring

    /// Appends a pending tool call to the mirror so its row projects live.
    private func appendToolUseToMirror(_ use: ToolUse) {
        let call = ToolCall(use: use)
        if let last = messages.indices.last, messages[last].role == .assistant {
            messages[last].content.append(.toolCall(call))
        } else {
            messages.append(Message(role: .assistant, content: [.toolCall(call)]))
        }
    }

    /// Fills in a pending tool call's result in the mirror, matched by
    /// tool-use id, so the existing tool row updates in place.
    private func attachResultToMirror(_ result: ToolResult) {
        for messageIndex in messages.indices.reversed() {
            for blockIndex in messages[messageIndex].content.indices {
                if case .toolCall(var call) = messages[messageIndex].content[blockIndex],
                   call.use.id == result.toolUseID {
                    call.result = result
                    messages[messageIndex].content[blockIndex] = .toolCall(call)
                    return
                }
            }
        }
    }

    // MARK: - Errors

    private func appendError(_ message: String) {
        errorSeq += 1
        let seq = errorSeq
        errorOverlays.append((seq: seq, message: message))
        presentation[.error(seq)] = Presentation(timestamp: Date())
        reproject()
    }

    // MARK: - Projection

    /// Recomputes ``items`` from ``messages`` plus the streaming and error
    /// overlays. The only place that builds the transcript — there is no
    /// hand-accumulation, so the UI cannot structurally drift from the model.
    private func reproject() {
        var rows: [ConversationItem] = []
        var liveIDs: Set<ItemID> = []

        for message in messages {
            switch message.role {
            case .user:
                if let (text, images) = userPrompt(message) {
                    let id = ItemID.message(message.id)
                    liveIDs.insert(id)
                    rows.append(makeRow(id: id, fallbackTimestamp: message.timestamp,
                                        kind: .user(text, images: images)))
                }

            case .assistant:
                appendAssistantRows(message, into: &rows, liveIDs: &liveIDs)
            }
        }

        if let streaming = streamingAssistantText {
            let id = ItemID.streamingAssistant
            liveIDs.insert(id)
            rows.append(makeRow(id: id, fallbackTimestamp: Date(), kind: .assistant(streaming)))
        }

        for error in errorOverlays {
            let id = ItemID.error(error.seq)
            liveIDs.insert(id)
            rows.append(makeRow(id: id, fallbackTimestamp: Date(), kind: .error(error.message)))
        }

        // Drop presentation entries that no longer project (e.g. after a
        // future rollback) so the side-table doesn't grow without bound.
        for id in Set(presentation.keys).subtracting(liveIDs) {
            presentation[id] = nil
        }
        items = rows
    }

    /// Extracts a user prompt (text + images) from a user message, or `nil`
    /// when the message only carries tool results.
    private func userPrompt(_ message: Message) -> (String, [ImageContent])? {
        var text = ""
        var images: [ImageContent] = []
        var sawPromptContent = false
        for block in message.content {
            switch block {
            case .text(let value):
                text = value
                sawPromptContent = true

            case .image(let image):
                images.append(image)
                sawPromptContent = true

            case .toolCall:
                break
            }
        }
        return sawPromptContent ? (text, images) : nil
    }

    /// Projects an assistant message into one prose row (if it has text) plus
    /// one row per tool call. Each ``ToolCall`` owns its result, so the tool
    /// row updates in place — no separate result message.
    private func appendAssistantRows(
        _ message: Message,
        into rows: inout [ConversationItem],
        liveIDs: inout Set<ItemID>
    ) {
        var prose = ""
        for block in message.content {
            if case .text(let value) = block { prose += value }
        }
        if !prose.isEmpty {
            let id = ItemID.message(message.id)
            liveIDs.insert(id)
            rows.append(makeRow(id: id, fallbackTimestamp: message.timestamp, kind: .assistant(prose)))
        }
        for block in message.content {
            guard case .toolCall(let call) = block else { continue }
            let id = ItemID.tool(call.use.id)
            liveIDs.insert(id)
            let summary = presentation[id]?.summary ?? summarizeTool(call.use)
            rows.append(makeRow(id: id, fallbackTimestamp: message.timestamp, kind: .tool(
                name: call.use.name,
                summary: summary,
                result: call.result?.content,
                isError: call.result?.isError ?? false
            )))
        }
    }

    /// Builds one projected row, merging its presentation metadata. Identity
    /// is the supplied ``ItemID`` (derived from the source); timing comes
    /// from the side-table, falling back to the message's own timestamp.
    private func makeRow(id: ItemID, fallbackTimestamp: Date, kind: ConversationItem.Kind) -> ConversationItem {
        let meta = presentation[id]
        return ConversationItem(
            id: id,
            kind: kind,
            timestamp: meta?.timestamp ?? fallbackTimestamp,
            duration: meta?.duration,
            latency: meta?.latency
        )
    }

    /// The wall-clock gap between the last projected row completing and now,
    /// used as the round-trip latency for the row about to appear. `nil`
    /// when there is no prior row.
    private func latencyForNextRow() -> TimeInterval? {
        guard let last = items.last else { return nil }
        let lastEnd = last.timestamp.addingTimeInterval(last.duration ?? 0)
        return Date().timeIntervalSince(lastEnd)
    }
}

// MARK: - Presentation side-table

/// Presentation-only metadata for one projected row, kept in a side-table
/// keyed by ``ItemID``. Data the model history does not carry: per-row timing
/// and the tool-argument summary.
private struct Presentation {
    var timestamp: Date
    var duration: TimeInterval?
    var latency: TimeInterval?
    /// Tool rows only: a short human-readable argument summary.
    var summary: String?
}

// MARK: - Default tool summarizer

extension ConversationStore {
    /// Default summary for a tool row's argument line.
    ///
    /// Handles the built-in `read`/`write`/`edit` file tools shipped in
    /// ``CollaborationKit``. Falls back to the tool's name for unknown tools;
    /// hosts can override by supplying their own `summarizeTool` closure.
    public nonisolated static func defaultSummarize(for use: ToolUse) -> String {
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
