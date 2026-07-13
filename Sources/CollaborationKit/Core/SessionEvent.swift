import Foundation

/// An event emitted by an ``LLMSession`` as a turn progresses.
///
/// Observe these via ``LLMSession/events`` to drive a UI, log activity, or watch
/// tool execution live. A single call to ``LLMSession/send(_:)`` may emit many
/// events before completing.
public enum SessionEvent: Sendable {
    /// An incremental chunk of assistant text, as it streams in.
    case textDelta(String)

    /// A complete block of assistant text within the current turn.
    case text(String)

    /// The model requested a tool invocation.
    case toolCall(ToolUse)

    /// A tool invocation completed (successfully or with an error result).
    case toolResult(ToolResult)

    /// Token usage reported for one model response within the turn.
    case usage(TokenUsage)

    /// The authoritative message history after any mutation.
    ///
    /// Emitted after every change to the session's history — user append,
    /// each streamed assistant block, each tool result attachment,
    /// compaction, and rollback. Consumers that need to mirror the
    /// history (e.g. ``CollaborationKitUI``'s ``MessageMirror``) should
    /// replace their local copy with the snapshot rather than reducing
    /// individual `.text` / `.toolCall` / `.toolResult` events into
    /// messages themselves — that path is a divergence seam. The other
    /// events remain for streaming UI (`.textDelta`) and per-row timing
    /// hooks (`.toolCall` / `.toolResult`).
    case historyChanged([Message])

    /// The turn finished.
    ///
    /// - Parameters:
    ///   - text: The final assistant text for the turn.
    ///   - usage: Token usage aggregated across every model round-trip in
    ///     this turn (i.e. the sum of every ``usage(_:)`` event since the
    ///     current ``LLMSession/send(_:)`` began). Providers that omit
    ///     usage contribute zero.
    ///   - stopReason: The provider-specific stop reason reported by the
    ///     final model round (typically `"end_turn"` for a natural stop
    ///     or `"tool_use"` if the loop is interrupted). `nil` when the
    ///     provider didn't report one.
    case turnComplete(text: String, usage: TokenUsage, stopReason: String?)

    /// The turn was cancelled via task cancellation before it could
    /// complete. Emitted on the events stream just before ``LLMSession/send(_:)``
    /// rethrows `CancellationError`.
    ///
    /// - Parameter partialText: All assistant prose produced across every
    ///   round-trip of the cancelled turn, concatenated in order. Empty
    ///   when the model had not yet emitted any text.
    case turnCancelled(partialText: String)
}
