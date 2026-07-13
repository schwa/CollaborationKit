import CollaborationKit
import Foundation

/// A pure state machine that mirrors an ``LLMSession``'s event stream into
/// a projectable form.
///
/// ``MessageMirror`` is a value type with no SwiftUI or actor coupling. It
/// consumes ``SessionEvent``s and maintains:
///
/// - The finalized message history (``messages``), replaced whole from
///   the session's ``SessionEvent/historyChanged(_:)`` snapshots. The
///   mirror deliberately does not reduce individual `.text`/`.toolCall`/
///   `.toolResult` events into messages — that would duplicate the
///   session's reducer and create a divergence seam (see issue #60).
/// - The live assistant streaming overlay (``streamingAssistantText``).
/// - Harness/transport error overlays (``errorOverlays``).
/// - Presentation metadata keyed by ``ItemID`` — per-row timing plus tool
///   argument summaries (``presentation``).
///
/// ``ConversationStore`` owns one and re-projects it into
/// ``ConversationItem``s via ``TranscriptProjection``. The mirror itself has
/// no view / observation / actor dependencies, so it's fully unit-testable
/// with plain assertions.
public struct MessageMirror: Sendable {
    /// Finalized message history mirrored from the session.
    public private(set) var messages: [Message] = []

    /// Live assistant delta text for the current turn, before it's finalized
    /// into a `Message`. `nil` when no streaming is in progress.
    public private(set) var streamingAssistantText: String?

    /// Harness/transport error overlays, in arrival order.
    public private(set) var errorOverlays: [ErrorOverlay] = []

    /// Presentation metadata keyed by ``ItemID`` — data the model history
    /// can't carry (per-row timing, tool argument summaries).
    public private(set) var presentation: [ItemID: Presentation] = [:]

    private var errorSeq: Int = 0

    public init() {}

    // MARK: - Nested types

    public struct ErrorOverlay: Sendable, Equatable, Identifiable {
        public let seq: Int
        public var message: String
        public var id: Int { seq }
    }

    public struct Presentation: Sendable, Equatable {
        public var timestamp: Date
        public var duration: TimeInterval?
        public var summary: String?

        public init(timestamp: Date, duration: TimeInterval? = nil, summary: String? = nil) {
            self.timestamp = timestamp
            self.duration = duration
            self.summary = summary
        }
    }

    // MARK: - Mutations

    /// Records a user turn: appends the user message and stamps its
    /// presentation timestamp.
    public mutating func appendUser(_ message: Message, at date: Date = Date()) {
        messages.append(message)
        presentation[.message(message.id)] = Presentation(timestamp: date)
    }

    /// Applies a ``SessionEvent`` from ``LLMSession/events``.
    ///
    /// - Parameters:
    ///   - event: The event to apply.
    ///   - date: Wall-clock timestamp at which the event was received.
    ///   - summary: Called on `.toolCall` events to produce the tool-row
    ///     argument summary stamped into ``presentation``.
    public mutating func handle(
        _ event: SessionEvent,
        at date: Date = Date(),
        summary: (ToolUse) -> String = \.name
    ) {
        switch event {
        case .textDelta(let chunk):
            appendAssistantDelta(chunk, at: date)

        case .text:
            // History was replaced by the preceding `.historyChanged`;
            // here we just hand the streaming overlay's timing off to
            // the finalized assistant row.
            finalizeStreamingOverlay(at: date)

        case .toolCall(let use):
            finishStreamingAssistant(at: date)
            presentation[.tool(use.id)] = Presentation(timestamp: date, summary: summary(use))

        case .toolResult(let result):
            let id = ItemID.tool(result.toolUseID)
            if let start = presentation[id]?.timestamp {
                presentation[id]?.duration = date.timeIntervalSince(start)
            }

        case .usage:
            // Usage lives on the session; the mirror doesn't need it.
            return

        case .turnComplete:
            finishStreamingAssistant(at: date)

        case .turnCancelled:
            // Same visual shape as a natural turn completion: stop the
            // streaming assistant row so the mirror doesn't leave a
            // partial bubble open. The host layer above adds any
            // "Stopped." overlay via `appendError`.
            finishStreamingAssistant(at: date)

        case .historyChanged(let snapshot):
            // Authoritative history from the session. Replacing whole
            // (rather than reducing per-block) is the whole point of
            // this event — it keeps the reducer in one place.
            messages = snapshot
        }
    }

    /// Records a harness/transport error overlay (e.g. "Stopped.", a
    /// network failure). Distinct from tool-error results, which live on
    /// the message history's ``ToolCall``.
    public mutating func appendError(_ message: String, at date: Date = Date()) {
        errorSeq += 1
        errorOverlays.append(ErrorOverlay(seq: errorSeq, message: message))
        presentation[.error(errorSeq)] = Presentation(timestamp: date)
    }

    /// Drops presentation entries not present in `livingIDs`. Called by the
    /// store after projection so the side-table doesn't grow after rollback.
    public mutating func compact(livingIDs: Set<ItemID>) {
        for id in Set(presentation.keys).subtracting(livingIDs) {
            presentation[id] = nil
        }
    }

    /// Truncates the mirror to the first `messageCount` messages and drops
    /// every overlay that could refer to a truncated row. Used by
    /// ``ConversationStore/rollBack(through:)``.
    ///
    /// `messageCount` is clamped to the current message count; values larger
    /// than ``messages`` leave state unchanged, negative values clear it.
    /// The caller (``ConversationStore``) still needs to re-project after
    /// this, and separately truncate the underlying ``LLMSession`` to keep
    /// the two in sync.
    public mutating func truncate(keepingMessages messageCount: Int) {
        let clamped = max(0, min(messageCount, messages.count))
        messages.removeLast(messages.count - clamped)
        streamingAssistantText = nil
        errorOverlays.removeAll()
        errorSeq = 0
    }

    // MARK: - Streaming overlay plumbing

    private mutating func appendAssistantDelta(_ chunk: String, at date: Date) {
        if streamingAssistantText == nil {
            presentation[.streamingAssistant] = Presentation(timestamp: date)
            streamingAssistantText = chunk
        } else {
            streamingAssistantText? += chunk
        }
    }

    /// Finalizes the streaming overlay when a `.text` block arrives. The
    /// text is already in ``messages`` (the preceding `.historyChanged`
    /// put it there); this call just carries the overlay's timing onto
    /// the trailing assistant row so visible timing survives the
    /// hand-off.
    private mutating func finalizeStreamingOverlay(at date: Date) {
        defer {
            presentation[.streamingAssistant] = nil
            streamingAssistantText = nil
        }
        guard let last = messages.last, last.role == .assistant else { return }
        let destID = ItemID.message(last.id)
        if var meta = presentation[.streamingAssistant] {
            meta.duration = date.timeIntervalSince(meta.timestamp)
            presentation[destID] = meta
        }
    }

    /// Clears the streaming overlay without finalizing (turn end / tool
    /// break where no `.text` block arrived). Stamps duration for completeness.
    private mutating func finishStreamingAssistant(at date: Date) {
        if streamingAssistantText != nil, let start = presentation[.streamingAssistant]?.timestamp {
            presentation[.streamingAssistant]?.duration = date.timeIntervalSince(start)
        }
        streamingAssistantText = nil
    }
}
