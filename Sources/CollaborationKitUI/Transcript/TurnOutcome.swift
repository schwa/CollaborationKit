import CollaborationKit
import Foundation

/// The way a conversation turn ended.
///
/// Delivered to ``ConversationStore/onTurnEnded`` once per turn, so hosts
/// can drive end-of-turn side effects (notifications, sounds, telemetry)
/// with enough context to differentiate the outcomes.
public enum TurnOutcome: Sendable {
    /// The assistant finished a turn naturally.
    ///
    /// - Parameters:
    ///   - text: The final assistant text for the turn.
    ///   - usage: Token usage aggregated across every model round-trip
    ///     the turn made.
    ///   - stopReason: The provider-specific stop reason (typically
    ///     `"end_turn"`); `nil` when the provider didn't report one.
    case completed(text: String, usage: TokenUsage, stopReason: String?)

    /// The turn was cancelled via ``ConversationStore/stop()`` (or a
    /// parent task cancellation) before the model finished.
    ///
    /// - Parameter partialText: Any assistant prose produced before the
    ///   cancellation took effect. Empty when the model had not yet
    ///   emitted text.
    case cancelled(partialText: String)

    /// The turn errored out — a provider transport error, an unhandled
    /// tool failure, or similar. The associated string is the
    /// human-readable message the store also surfaced as an overlay
    /// (``ConversationStore/lastError``).
    case failed(String)
}
