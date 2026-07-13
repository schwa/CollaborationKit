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

        // Round-trip: encode then decode; verify the shape.
        let data = try export.jsonData()
        let decoded = try SessionExport.decode(data)

        #expect(decoded.model == "test-model")
        #expect(decoded.userInfo == ["build": "42"])
        #expect(decoded.messages.isEmpty)
        #expect(decoded.transcript.isEmpty)
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
        // Sanity checks on the encoded shape.
        #expect(json.contains("\"exportedAt\""))
        #expect(json.contains("\"messages\""))
        #expect(json.contains("\"transcript\""))
        #expect(json.contains("\"model\" : \"abc\""))
        #expect(json.contains("\"usage\""))
    }
}
