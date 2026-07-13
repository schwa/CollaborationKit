@testable import CollaborationKit
@testable import CollaborationKitUI
import Foundation
import Testing

struct BackendTests {

    // MARK: - Built-in values

    @Test
    func builtinBackendsHaveDistinctIDs() {
        let ids = Backend.allBuiltin.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test
    func modelDefaultsKeyMirrorsID() {
        #expect(Backend.claudeSubscription.modelDefaultsKey == "collaborationkit.model.claudeSubscription")
        #expect(Backend.openAI.modelDefaultsKey == "collaborationkit.model.openAI")
    }

    // MARK: - Model filters

    @Test
    func claudeFilterKeepsClaudeAndDropsDatedSnapshots() {
        let filter = Backend.claudePrefixFilter
        #expect(filter("claude-sonnet-4-5"))
        #expect(filter("claude-opus-4-8"))
        #expect(!filter("gpt-4o"))
        #expect(!filter("claude-sonnet-4-5-2025-12-11"))
    }

    @Test
    func openAIFilterKeepsChatAndDropsAudioImageEmbeddings() {
        let filter = Backend.openAIChatFilter
        #expect(filter("gpt-4o"))
        #expect(filter("chatgpt-4o-latest"))
        #expect(filter("o1-mini"))
        #expect(filter("o3-mini"))
        #expect(!filter("gpt-4o-audio-preview"))
        #expect(!filter("text-embedding-3-small"))
        #expect(!filter("dall-e-3"))
        #expect(!filter("whisper-1"))
        #expect(!filter("gpt-4o-2025-12-11"))
    }

    // MARK: - Custom backend registration

    @Test
    func customBackendWorksAsExpected() {
        let custom = Backend(
            id: "test.mock",
            displayName: "Test Mock",
            defaultModel: "mock-1",
            hasCredentials: { _ in true },
            makeProvider: { _, _, _ in throw MockError.notImplemented },
            modelFilter: { $0.hasPrefix("mock-") }
        )
        #expect(custom.modelDefaultsKey == "collaborationkit.model.test.mock")
        #expect(custom.modelFilter("mock-1"))
        #expect(!custom.modelFilter("gpt-4o"))
    }

    // MARK: - hasCredentials against an in-memory store

    @Test
    func anthropicAPIBackendReportsCredentialsWhenKeyStored() {
        let store = InMemoryCredentialStore(anthropicAPIKey: "sk-ant-test")
        #expect(Backend.anthropicAPI.hasCredentials(store))
        #expect(!Backend.openAI.hasCredentials(store))
        #expect(!Backend.claudeSubscription.hasCredentials(store))
    }

    @Test
    func openAIBackendReportsCredentialsWhenKeyStored() {
        let store = InMemoryCredentialStore(openAIAPIKey: "sk-openai-test")
        #expect(Backend.openAI.hasCredentials(store))
        #expect(!Backend.anthropicAPI.hasCredentials(store))
    }

    @Test
    func claudeSubscriptionBackendReportsCredentialsWhenOAuthStored() {
        let creds = OAuthCredentials(
            access: "at",
            refresh: "rt",
            expires: Date().addingTimeInterval(3_600)
        )
        let store = InMemoryCredentialStore(anthropicOAuth: creds)
        #expect(Backend.claudeSubscription.hasCredentials(store))
    }

    @Test
    func emptyStoreReportsNoCredentialsForAnyBackend() {
        let store = InMemoryCredentialStore()
        for backend in Backend.allBuiltin {
            #expect(!backend.hasCredentials(store), "\(backend.id) should not report credentials on an empty store")
        }
    }

    // MARK: - makeProvider surfaces missingCredentials

    @Test
    func makeProviderThrowsMissingCredentialsForEmptyStore() {
        let store = InMemoryCredentialStore()
        for backend in Backend.allBuiltin {
            #expect(throws: CollaborationCredentialsError.self) {
                _ = try backend.makeProvider(store, backend.defaultModel, 1_024)
            }
        }
    }

    @Test
    func makeProviderBuildsForAnthropicAPIWithStoredKey() throws {
        let store = InMemoryCredentialStore(anthropicAPIKey: "sk-ant-test")
        _ = try Backend.anthropicAPI.makeProvider(store, Backend.anthropicAPI.defaultModel, 1_024)
    }

    // MARK: - Error carries backend metadata

    @Test
    func missingCredentialsErrorNamesTheBackend() {
        let error = CollaborationCredentialsError.missingCredentials(id: "x", displayName: "Custom")
        #expect(error.localizedDescription.contains("Custom"))
    }

    private enum MockError: Error { case notImplemented }
}
