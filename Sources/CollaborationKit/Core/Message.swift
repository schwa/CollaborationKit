import Foundation

/// A role in a conversation.
public enum Role: String, Codable, Sendable {
    case user
    case assistant
}

/// A single block of content within a message.
///
/// Conversations are modeled as a sequence of ``Message`` values, each of which
/// contains one or more content blocks. Blocks may be plain text, a request from
/// the model to call a tool, or the result of having called a tool.
public enum ContentBlock: Sendable, Equatable {
    /// Plain text content.
    case text(String)

    /// A request from the model to invoke a tool.
    case toolUse(ToolUse)

    /// The result of invoking a tool, sent back to the model.
    case toolResult(ToolResult)

    /// Image content supplied as input to the model.
    case image(ImageContent)
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
public struct Message: Sendable, Equatable {
    /// Who authored the message.
    public let role: Role
    /// The content blocks comprising the message.
    public var content: [ContentBlock]

    public init(role: Role, content: [ContentBlock]) {
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
