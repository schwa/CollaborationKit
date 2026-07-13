import Foundation
import CollaborationKit

/// Stable identity for a projected transcript row.
///
/// The transcript is a pure projection of the session's ``Message`` history
/// (plus two overlays that have no home in that history: live streaming and
/// harness errors). The id is *derived* from the source — a ``Message/id`` for
/// prompt/prose rows, a ``ToolUse/id`` for tool rows — so re-projecting the
/// same history yields the same row identity with no side-table cache. That
/// keeps SwiftUI `ForEach`, scroll position, and `.id()` stable across
/// updates.
public enum ItemID: Hashable, Sendable {
    /// A user prompt or assistant-prose row, identified by its source message.
    case message(UUID)
    /// A tool row, identified by the provider-assigned tool-use id.
    case tool(String)
    /// The in-flight assistant bubble streaming deltas for the current turn.
    case streamingAssistant
    /// A harness/transport error overlay (not part of the model history).
    case error(Int)
}

/// One row in the projected transcript.
///
/// Rows are a projection of the session's ``Message`` history — the store
/// never accumulates them by hand. Identity comes straight from the source
/// (``Message/id`` / ``ToolUse/id``); only presentation-only timing the model
/// can't carry (durations, round-trip latency, and tool start times) is merged
/// in from a side-table keyed by ``ItemID``.
public struct ConversationItem: Identifiable, Sendable {
    /// The kind of row plus its content.
    public enum Kind: Sendable {
        /// A user prompt, optionally with attached input images.
        case user(String, images: [ImageContent] = [])
        /// Assistant prose. While streaming, `text` grows as deltas arrive.
        case assistant(String)
        /// A tool invocation: name + a short argument summary + a result that
        /// fills in when the tool returns. `isError` flags a failed result.
        case tool(name: String, summary: String, result: String?, isError: Bool)
        /// A harness/transport error that ended the turn.
        case error(String)
    }

    /// Stable SwiftUI identity, derived from the source message / tool-use id.
    public let id: ItemID
    public var kind: Kind
    /// When this row first appeared (user sent it, assistant started replying,
    /// or a tool was invoked).
    public var timestamp: Date
    /// How long this row took to complete: assistant prose from first delta
    /// to the end of the block, a tool from invocation to result. `nil` until
    /// complete, and always `nil` for user prompts.
    public var duration: TimeInterval?
    /// The wall-clock gap before this row appeared: the time the
    /// model/network spent between the previous row completing and this one
    /// starting. `nil` for the first row of a turn. This is the number that
    /// reflects how long the user waited — unlike ``duration``, which only
    /// times the visible block.
    public var latency: TimeInterval?
}
