import Foundation

/// A role in a conversation.
public enum Role: String, Codable, Sendable {
    case user
    case assistant
}

/// A single block of content within a message.
///
/// Conversations are modeled as a sequence of ``Message`` values, each of which
/// contains one or more content blocks. Blocks may be plain text, image input,
/// or a tool call — a single object that pairs the model's request with the
/// result of running it.
///
/// This is the *domain* shape: a tool call and its result live together. On the
/// wire (Anthropic / OpenAI) a tool result must be sent as a separate following
/// message; the wire encoders split a ``ToolCall`` apart at encode time, and the
/// providers re-join the streamed `tool_use` with its later result here.
public enum ContentBlock: Sendable, Equatable {
    /// Plain text content.
    case text(String)

    /// Image content supplied as input to the model.
    case image(ImageContent)

    /// A tool call: the model's request plus (once it has run) its result.
    case toolCall(ToolCall)
}

/// A tool invocation paired with its result.
///
/// `result` is `nil` between the moment the model requests the call and the
/// moment the tool finishes. The session fills it in; the UI can show a pending
/// row until then. Keeping the request and result together is what lets callers
/// render one row per tool instead of correlating two separate messages by id.
public struct ToolCall: Sendable, Equatable {
    /// The model's request to invoke a tool.
    public var use: ToolUse
    /// The result of running it, or `nil` while still pending.
    public var result: ToolResult?

    public init(use: ToolUse, result: ToolResult? = nil) {
        self.use = use
        self.result = result
    }
}

/// Image content supplied as input to a model.
///
/// Images are carried as base64-encoded data together with their media type,
/// which both Anthropic and OpenAI accept natively. This representation stays
/// provider-agnostic; wire encoders translate it into each provider's shape.
public struct ImageContent: Sendable, Equatable {
    /// The IANA media type of the image, e.g. `"image/png"` or `"image/jpeg"`.
    public let mediaType: String
    /// The base64-encoded image data (without a data-URL prefix).
    public let base64Data: String

    public init(mediaType: String, base64Data: String) {
        self.mediaType = mediaType
        self.base64Data = base64Data
    }

    /// Creates image content from raw bytes, base64-encoding them.
    public init(mediaType: String, data: Data) {
        self.mediaType = mediaType
        self.base64Data = data.base64EncodedString()
    }
}

/// A request from the model to invoke a tool.
public struct ToolUse: Sendable, Equatable {
    /// A provider-assigned identifier correlating this call with its result.
    public let id: String
    /// The name of the tool the model wishes to invoke.
    public let name: String
    /// The decoded JSON input the model supplied for the tool.
    public let input: JSONValue

    public init(id: String, name: String, input: JSONValue) {
        self.id = id
        self.name = name
        self.input = input
    }
}

/// The result of invoking a tool, sent back to the model.
public struct ToolResult: Sendable, Equatable {
    /// The identifier of the ``ToolUse`` this result corresponds to.
    public let toolUseID: String
    /// The textual content of the result.
    public let content: String
    /// Whether the tool invocation failed. Error results let the model adapt.
    public let isError: Bool

    public init(toolUseID: String, content: String, isError: Bool = false) {
        self.toolUseID = toolUseID
        self.content = content
        self.isError = isError
    }
}

/// A single message in a conversation.
///
/// Carries a stable identity and a creation timestamp so UIs can key list rows
/// and show timing without maintaining a parallel side-table. Both are assigned
/// at construction and never change.
public struct Message: Identifiable, Sendable, Equatable {
    /// Stable identity for the lifetime of this message value.
    public let id: UUID
    /// When this message was created.
    public let timestamp: Date
    /// Who authored the message.
    public let role: Role
    /// The content blocks comprising the message.
    public var content: [ContentBlock]

    // id/timestamp are auto-assigned conveniences; role/content stay last to
    // match the common `Message(role:content:)` call site.
    // swiftlint:disable:next function_default_parameter_at_end
    public init(id: UUID = UUID(), timestamp: Date = Date(), role: Role, content: [ContentBlock]) {
        self.id = id
        self.timestamp = timestamp
        self.role = role
        self.content = content
    }

    /// Creates a user message containing a single text block.
    public static func user(_ text: String) -> Self {
        Self(role: .user, content: [.text(text)])
    }

    /// Creates an assistant message containing a single text block.
    public static func assistant(_ text: String) -> Self {
        Self(role: .assistant, content: [.text(text)])
    }

    /// Creates a user message containing text followed by one or more images.
    public static func user(text: String, images: [ImageContent]) -> Self {
        var content: [ContentBlock] = []
        if !text.isEmpty {
            content.append(.text(text))
        }
        content.append(contentsOf: images.map(ContentBlock.image))
        return Self(role: .user, content: content)
    }
}

extension Message {
    /// The tool calls in this message, in order. Convenience for callers that
    /// render or inspect tool activity without walking `content`.
    public var toolCalls: [ToolCall] {
        content.compactMap { block in
            guard case .toolCall(let call) = block else { return nil }
            return call
        }
    }
}
