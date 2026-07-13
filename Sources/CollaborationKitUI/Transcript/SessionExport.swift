import Foundation
import CollaborationKit

/// A serialisable snapshot of one ``ConversationStore`` session, suitable for
/// dumping to disk as JSON for debugging / bug-reporting.
///
/// Built by ``ConversationStore/buildExport(model:userInfo:)``. Stores the
/// domain types (``Message``, ``ConversationItem``, ``TokenUsage``) directly
/// via their own `Codable` conformances — new fields on those types flow
/// through to the export automatically.
public struct SessionExport: Codable, Sendable {
    public var exportedAt: Date
    public var model: String?
    public var system: String?
    public var usage: TokenUsage
    public var messages: [Message]
    public var transcript: [ConversationItem]
    public var lastError: String?
    /// Free-form host-supplied payload (e.g. Phosphor's current shader
    /// source, an app version string, a build id).
    public var userInfo: [String: String]

    public init(
        exportedAt: Date,
        model: String?,
        system: String?,
        usage: TokenUsage,
        messages: [Message],
        transcript: [ConversationItem],
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
            usage: usage,
            messages: messages,
            transcript: items,
            lastError: lastError,
            userInfo: userInfo
        )
    }
}
