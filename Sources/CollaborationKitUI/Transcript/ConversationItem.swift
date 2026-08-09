import CollaborationKit
import Foundation

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

extension ItemID: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, uuid, id, seq
    }

    private enum Kind: String, Codable {
        case message
        case tool
        // swiftlint:disable:next raw_value_for_camel_cased_codable_enum
        case streamingAssistant
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .message:
            self = .message(try container.decode(UUID.self, forKey: .uuid))

        case .tool:
            self = .tool(try container.decode(String.self, forKey: .id))

        case .streamingAssistant:
            self = .streamingAssistant

        case .error:
            self = .error(try container.decode(Int.self, forKey: .seq))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let uuid):
            try container.encode(Kind.message, forKey: .type)
            try container.encode(uuid, forKey: .uuid)

        case .tool(let id):
            try container.encode(Kind.tool, forKey: .type)
            try container.encode(id, forKey: .id)

        case .streamingAssistant:
            try container.encode(Kind.streamingAssistant, forKey: .type)

        case .error(let seq):
            try container.encode(Kind.error, forKey: .type)
            try container.encode(seq, forKey: .seq)
        }
    }
}

/// One row in the projected transcript.
///
/// Rows are a projection of the session's ``Message`` history — the store
/// never accumulates them by hand. Identity comes straight from the source
/// (``Message/id`` / ``ToolUse/id``); only presentation-only timing the model
/// can't carry (durations, round-trip latency, and tool start times) is merged
/// in from a side-table keyed by ``ItemID``.
public struct ConversationItem: Identifiable, Sendable, Equatable, Codable {
    /// The kind of row plus its content.
    public enum Kind: Sendable, Equatable {
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
    /// Where this row sits in a batch of tool calls the model emitted in a
    /// single assistant message. `nil` for every non-tool row and for a
    /// tool call that arrived on its own.
    public var batch: Batch?

    /// A tool row's position within one assistant message's batch of tool
    /// calls. Lets the transcript group the run visually instead of
    /// rendering it as an undifferentiated column of rows.
    public struct Batch: Sendable, Equatable, Codable {
        /// Zero-based position within the batch.
        public var index: Int
        /// How many tool calls the assistant emitted in that message.
        public var count: Int
        /// True for the first row of the batch.
        public var isFirst: Bool { index == 0 }
        /// True for the last row of the batch.
        public var isLast: Bool { index == count - 1 }

        public init(index: Int, count: Int) {
            self.index = index
            self.count = count
        }
    }
}

extension ConversationItem.Kind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, images, name, summary, result, isError, message
    }

    private enum Tag: String, Codable {
        case user, assistant, tool, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Tag.self, forKey: .type) {
        case .user:
            let text = try container.decode(String.self, forKey: .text)
            let images = try container.decodeIfPresent([ImageContent].self, forKey: .images) ?? []
            self = .user(text, images: images)

        case .assistant:
            self = .assistant(try container.decode(String.self, forKey: .text))

        case .tool:
            self = .tool(
                name: try container.decode(String.self, forKey: .name),
                summary: try container.decode(String.self, forKey: .summary),
                result: try container.decodeIfPresent(String.self, forKey: .result),
                isError: try container.decode(Bool.self, forKey: .isError)
            )

        case .error:
            self = .error(try container.decode(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .user(text, images):
            try container.encode(Tag.user, forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode(images, forKey: .images)

        case .assistant(let text):
            try container.encode(Tag.assistant, forKey: .type)
            try container.encode(text, forKey: .text)

        case let .tool(name, summary, result, isError):
            try container.encode(Tag.tool, forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(summary, forKey: .summary)
            try container.encodeIfPresent(result, forKey: .result)
            try container.encode(isError, forKey: .isError)

        case .error(let message):
            try container.encode(Tag.error, forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }
}
