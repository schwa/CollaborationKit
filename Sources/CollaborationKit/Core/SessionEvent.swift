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

    /// The turn finished; `text` is the final assistant text for the turn.
    case turnComplete(text: String)
}
