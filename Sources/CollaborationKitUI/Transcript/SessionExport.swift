import Foundation
import CollaborationKit

/// A serialisable snapshot of one ``ConversationStore`` session, suitable for
/// dumping to disk as JSON for debugging / bug-reporting.
///
/// Built by ``ConversationStore/buildExport(model:userInfo:)``. Shape is
/// deliberately a shadow of the domain types so wire-level `Codable` doesn't
/// leak onto ``Message`` / ``ConversationItem`` / ``TokenUsage`` themselves.
public struct SessionExport: Codable, Sendable {
    public var exportedAt: Date
    public var model: String?
    public var system: String?
    public var usage: UsageExport
    public var messages: [MessageExport]
    public var transcript: [ItemExport]
    public var lastError: String?
    /// Free-form host-supplied payload (e.g. Phosphor's current shader
    /// source, an app version string, a build id).
    public var userInfo: [String: String]

    public init(
        exportedAt: Date,
        model: String?,
        system: String?,
        usage: UsageExport,
        messages: [MessageExport],
        transcript: [ItemExport],
        lastError: String?,
        userInfo: [String: String]
    ) {
        self.exportedAt = exportedAt
        self.model = model
        self.system = system
        self.usage = usage
        self.messages = messages
        self.transcript = transcript
        self.lastError = lastError
        self.userInfo = userInfo
    }

    // MARK: - Message shadow

    public struct MessageExport: Codable, Sendable {
        public var id: UUID
        public var timestamp: Date
        public var role: String
        public var blocks: [ContentBlockExport]
    }

    public enum ContentBlockExport: Codable, Sendable {
        case text(String)
        case image(mediaType: String, base64: String)
        case toolCall(ToolCallExport)
    }

    public struct ToolCallExport: Codable, Sendable {
        public var id: String
        public var name: String
        /// The model's input, as a JSON string.
        public var inputJSON: String
        public var result: ToolResultExport?
    }

    public struct ToolResultExport: Codable, Sendable {
        public var content: String
        public var isError: Bool
    }

    // MARK: - Transcript shadow

    public struct ItemExport: Codable, Sendable {
        public var id: String
        public var kind: String
        public var text: String?
        public var toolName: String?
        public var summary: String?
        public var isError: Bool?
        public var timestamp: Date
        public var duration: TimeInterval?
        public var latency: TimeInterval?
    }

    // MARK: - Usage shadow

    public struct UsageExport: Codable, Sendable {
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheCreationInputTokens: Int
        public var cacheReadInputTokens: Int
    }

    // MARK: - Encoding

    /// Encodes to pretty-printed JSON with sorted keys and ISO8601 dates.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Encodes to a UTF-8 JSON string.
    public func jsonString() throws -> String {
        String(decoding: try jsonData(), as: UTF8.self)
    }

    /// Decodes a previously-encoded ``SessionExport`` payload. Uses the same
    /// ISO8601 date strategy ``jsonData()`` writes.
    public static func decode(_ data: Data) throws -> SessionExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionExport.self, from: data)
    }
}

// MARK: - Building the export from a ConversationStore

extension ConversationStore {
    /// Gathers a serialisable snapshot of the current session: transcript,
    /// projected items, usage, last harness error, plus optional host
    /// metadata.
    ///
    /// - Parameters:
    ///   - model: The model id used for the session, if known. Not tracked
    ///     by the store itself since the LLMSession doesn't expose it;
    ///     supply the value the host used to build the provider.
    ///   - userInfo: Free-form host-specific payload (e.g. shader source,
    ///     app version, build id).
    public func buildExport(
        model: String? = nil,
        userInfo: [String: String] = [:]
    ) -> SessionExport {
        SessionExport(
            exportedAt: Date(),
            model: model,
            system: nil,
            usage: SessionExport.UsageExport(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheCreationInputTokens: usage.cacheCreationInputTokens,
                cacheReadInputTokens: usage.cacheReadInputTokens
            ),
            messages: messages.map { SessionExport.MessageExport(from: $0) },
            transcript: items.map { SessionExport.ItemExport(from: $0) },
            lastError: lastError,
            userInfo: userInfo
        )
    }
}

private extension SessionExport.MessageExport {
    init(from message: Message) {
        self.init(
            id: message.id,
            timestamp: message.timestamp,
            role: message.role.rawValue,
            blocks: message.content.map(SessionExport.ContentBlockExport.init)
        )
    }
}

private extension SessionExport.ContentBlockExport {
    init(from block: ContentBlock) {
        switch block {
        case .text(let text):
            self = .text(text)
        case .image(let image):
            self = .image(mediaType: image.mediaType, base64: image.base64Data)
        case .toolCall(let call):
            self = .toolCall(SessionExport.ToolCallExport(from: call))
        }
    }
}

private extension SessionExport.ToolCallExport {
    init(from call: ToolCall) {
        // Encode the JSONValue input as JSON text so the export is a plain
        // Codable object (JSONValue is itself Codable, but nesting it as a
        // dynamic payload makes the schema harder to consume).
        let inputJSON: String
        if let data = try? JSONEncoder().encode(call.use.input),
           let text = String(data: data, encoding: .utf8) {
            inputJSON = text
        } else {
            inputJSON = "null"
        }
        self.init(
            id: call.use.id,
            name: call.use.name,
            inputJSON: inputJSON,
            result: call.result.map { SessionExport.ToolResultExport(content: $0.content, isError: $0.isError) }
        )
    }
}

private extension SessionExport.ItemExport {
    init(from item: ConversationItem) {
        let kind: String
        var text: String?
        var toolName: String?
        var summary: String?
        var isError: Bool?
        switch item.kind {
        case .user(let userText, _):
            kind = "user"
            text = userText
        case .assistant(let assistantText):
            kind = "assistant"
            text = assistantText
        case .tool(let name, let ruleSummary, let result, let error):
            kind = "tool"
            toolName = name
            summary = ruleSummary
            text = result
            isError = error
        case .error(let message):
            kind = "error"
            text = message
        }
        self.init(
            id: String(describing: item.id),
            kind: kind,
            text: text,
            toolName: toolName,
            summary: summary,
            isError: isError,
            timestamp: item.timestamp,
            duration: item.duration,
            latency: item.latency
        )
    }
}
