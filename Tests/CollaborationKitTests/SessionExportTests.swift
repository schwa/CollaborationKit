@testable import CollaborationKit
@testable import CollaborationKitUI
import Foundation
import Testing

/// A minimal ModelProvider that yields exactly what the test scripts,
/// duplicated here (not imported from SessionTests) so this suite doesn't
/// spider across test files.
private actor NullProvider: ModelProvider {
    nonisolated func send(
        messages _: [Message],
        system _: String?,
        tools _: [ToolSpec]
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
struct SessionExportTests {
    @Test
    func emptyStoreExportRoundTripsAsJSON() throws {
        let store = ConversationStore(session: LLMSession(provider: NullProvider()))
        let export = store.buildExport(model: "test-model", userInfo: ["build": "42"])

        let data = try export.jsonData()
        let decoded = try SessionExport.decode(data)

        #expect(decoded.model == "test-model")
        #expect(decoded.userInfo == ["build": "42"])
        #expect(decoded.messages.isEmpty)
        #expect(decoded.transcript.isEmpty)
    }

    @Test
    func exportCarriesSessionSystemPrompt() {
        let session = LLMSession(provider: NullProvider(), system: "You are a helpful assistant.")
        let store = ConversationStore(session: session)
        let export = store.buildExport()
        #expect(export.system == "You are a helpful assistant.")
    }

    @Test
    func exportSystemIsNilWhenSessionHasNoSystemPrompt() {
        let store = ConversationStore(session: LLMSession(provider: NullProvider()))
        let export = store.buildExport()
        #expect(export.system == nil)
    }

    @Test
    func exportCapturesLastError() {
        let store = ConversationStore(session: LLMSession(provider: NullProvider()))
        store.send("hi")
        // No turn runs against NullProvider, so lastError stays nil and the
        // field encodes as null.
        let export = store.buildExport()
        #expect(export.lastError == nil)
    }

    @Test
    func exportJSONContainsKeyFields() throws {
        let store = ConversationStore(session: LLMSession(provider: NullProvider()))
        let json = try store.buildExport(model: "abc").jsonString()
        #expect(json.contains("\"exportedAt\""))
        #expect(json.contains("\"messages\""))
        #expect(json.contains("\"transcript\""))
        #expect(json.contains("\"model\" : \"abc\""))
        #expect(json.contains("\"usage\""))
    }

    // MARK: - Round-trip coverage

    /// Full round-trip through a populated `SessionExport`. Fails the day a
    /// new field is added to any domain type without wiring it into
    /// `Codable`.
    @Test
    // swiftlint:disable:next function_body_length
    func populatedExportRoundTripsPreservingEveryField() throws {
        let messageID = UUID()
        let messageDate = Date(timeIntervalSince1970: 1_700_000_000)
        let toolUse = ToolUse(id: "t1", name: "edit", input: .object([
            "oldText": .string("foo"),
            "newText": .string("bar")
        ]))
        let toolResult = ToolResult(toolUseID: "t1", content: "Edit applied.", isError: false)
        let image = ImageContent(mediaType: "image/png", base64Data: "AAAA")
        let message = Message(
            id: messageID,
            timestamp: messageDate,
            role: .assistant,
            content: [
                .text("Here you go."),
                .image(image),
                .toolCall(ToolCall(use: toolUse, result: toolResult))
            ]
        )
        let items: [ConversationItem] = [
            ConversationItem(
                id: .message(messageID),
                kind: .user("hi", images: [image]),
                timestamp: messageDate,
                duration: nil,
                latency: nil
            ),
            ConversationItem(
                id: .streamingAssistant,
                kind: .assistant("streaming…"),
                timestamp: messageDate,
                duration: 0.5,
                latency: 0.1
            ),
            ConversationItem(
                id: .tool("t1"),
                kind: .tool(name: "edit", summary: "editing", result: "Edit applied.", isError: false),
                timestamp: messageDate,
                duration: 0.25,
                latency: nil
            ),
            ConversationItem(
                id: .error(3),
                kind: .error("Stopped."),
                timestamp: messageDate,
                duration: nil,
                latency: nil
            )
        ]
        let export = SessionExport(
            exportedAt: messageDate,
            model: "m",
            system: "you are helpful",
            usage: TokenUsage(inputTokens: 10, outputTokens: 20, cacheCreationInputTokens: 3, cacheReadInputTokens: 4),
            messages: [message],
            transcript: items,
            lastError: "boom",
            userInfo: ["build": "1"]
        )

        let data = try export.jsonData()
        let decoded = try SessionExport.decode(data)

        #expect(decoded.exportedAt == export.exportedAt)
        #expect(decoded.model == export.model)
        #expect(decoded.system == export.system)
        #expect(decoded.usage == export.usage)
        #expect(decoded.messages == export.messages)
        #expect(decoded.transcript == export.transcript)
        #expect(decoded.lastError == export.lastError)
        #expect(decoded.userInfo == export.userInfo)
    }

    @Test
    func messageWithEveryContentBlockRoundTrips() throws {
        let sample = Message(
            role: .assistant,
            content: [
                .text("prose"),
                .image(ImageContent(mediaType: "image/jpeg", base64Data: "ZZ")),
                .toolCall(ToolCall(
                    use: ToolUse(id: "u", name: "read", input: .object([:])),
                    result: ToolResult(toolUseID: "u", content: "ok", isError: false)
                ))
            ]
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        #expect(decoded == sample)
    }

    @Test
    func conversationItemRoundTripsAcrossEveryKind() throws {
        let cases: [ConversationItem] = [
            ConversationItem(id: .message(UUID()), kind: .user("hi"), timestamp: Date(), duration: nil, latency: nil),
            ConversationItem(id: .streamingAssistant, kind: .assistant("hello"), timestamp: Date(), duration: 1, latency: 2),
            ConversationItem(id: .tool("x"), kind: .tool(name: "read", summary: "reading", result: nil, isError: false), timestamp: Date(), duration: nil, latency: nil),
            ConversationItem(id: .error(1), kind: .error("nope"), timestamp: Date(), duration: nil, latency: nil)
        ]
        for item in cases {
            let data = try JSONEncoder().encode(item)
            let decoded = try JSONDecoder().decode(ConversationItem.self, from: data)
            #expect(decoded == item)
        }
    }
}
