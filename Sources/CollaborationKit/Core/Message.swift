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
}
