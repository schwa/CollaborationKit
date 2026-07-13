import Foundation
import CollaborationKit

/// A pure state machine that mirrors an ``LLMSession``'s event stream into
/// a projectable form.
///
/// ``MessageMirror`` is a value type with no SwiftUI or actor coupling. It
/// consumes ``SessionEvent``s and maintains:
///
/// - The finalized message history (``messages``).
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
        summary: (ToolUse) -> String = { $0.name }
    ) {
        switch event {
        case .textDelta(let chunk):
            appendAssistantDelta(chunk, at: date)

        case .text(let block):
            finalizeAssistantProse(block, at: date)

        case .toolCall(let use):
            finishStreamingAssistant(at: date)
            presentation[.tool(use.id)] = Presentation(timestamp: date, summary: summary(use))
            appendToolUseToMirror(use)

        case .toolResult(let result):
            let id = ItemID.tool(result.toolUseID)
            if let start = presentation[id]?.timestamp {
                presentation[id]?.duration = date.timeIntervalSince(start)
            }
            attachResultToMirror(result)

        case .usage:
            // Usage lives on the session; the mirror doesn't need it.
            return

        case .turnComplete:
            finishStreamingAssistant(at: date)
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

    // MARK: - Assistant prose plumbing

    private mutating func appendAssistantDelta(_ chunk: String, at date: Date) {
        if streamingAssistantText == nil {
            presentation[.streamingAssistant] = Presentation(timestamp: date)
            streamingAssistantText = chunk
        } else {
            streamingAssistantText? += chunk
        }
    }

    /// Finalizes a completed assistant prose block into the mirror, keyed by
    /// its message id, and carries the streaming overlay's timing (start,
    /// freshly stamped duration) onto the finalized row so visible timing
    /// survives the hand-off.
    private mutating func finalizeAssistantProse(_ block: String, at date: Date) {
        let destID = appendAssistantProseToMirror(block)
        if var meta = presentation[.streamingAssistant] {
            meta.duration = date.timeIntervalSince(meta.timestamp)
            presentation[destID] = meta
        }
        presentation[.streamingAssistant] = nil
        streamingAssistantText = nil
    }

    /// Clears the streaming overlay without finalizing (turn end / tool
    /// break where no `.text` block arrived). Stamps duration for completeness.
    private mutating func finishStreamingAssistant(at date: Date) {
        if streamingAssistantText != nil, let start = presentation[.streamingAssistant]?.timestamp {
            presentation[.streamingAssistant]?.duration = date.timeIntervalSince(start)
        }
        streamingAssistantText = nil
    }

    /// Appends a finalized assistant prose block, merging into the trailing
    /// assistant message when it doesn't yet have prose. Returns the
    /// ``ItemID`` of the assistant message holding it.
    private mutating func appendAssistantProseToMirror(_ block: String) -> ItemID {
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

    private mutating func appendToolUseToMirror(_ use: ToolUse) {
        let call = ToolCall(use: use)
        if let last = messages.indices.last, messages[last].role == .assistant {
            messages[last].content.append(.toolCall(call))
        } else {
            messages.append(Message(role: .assistant, content: [.toolCall(call)]))
        }
    }

    private mutating func attachResultToMirror(_ result: ToolResult) {
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
}
