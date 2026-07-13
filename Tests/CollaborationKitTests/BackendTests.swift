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
    func localFilterKeepsChatAndDropsEmbeddingsAudioImage() {
        let filter = Backend.localChatFilter
        #expect(filter("llama3.2"))
        #expect(filter("qwen2.5-coder:14b"))
        #expect(filter("mistral-nemo"))
        #expect(!filter("nomic-embed-text"))
        #expect(!filter("whisper-large"))
        #expect(!filter("stable-diffusion-image"))
    }

    // MARK: - Local backends

    @Test
    func lmStudioBackendReportsCredentialsWithoutStore() {
        let backend = Backend.lmStudio()
        #expect(backend.id == "lmStudio")
        #expect(backend.hasCredentials(InMemoryCredentialStore()))
    }

    @Test
    func lmStudioMakeProviderIgnoresEmptyStore() throws {
        let backend = Backend.lmStudio()
        _ = try backend.makeProvider(InMemoryCredentialStore(), backend.defaultModel, 1_024, nil)
    }

    @Test
    func ollamaBackendReportsCredentialsWithoutStore() {
        let backend = Backend.ollama()
        #expect(backend.id == "ollama")
        #expect(backend.hasCredentials(InMemoryCredentialStore()))
    }

    @Test
    func ollamaMakeProviderIgnoresEmptyStore() throws {
        let backend = Backend.ollama()
        _ = try backend.makeProvider(InMemoryCredentialStore(), backend.defaultModel, 1_024, nil)
    }

    @Test
    func localBackendsAreNotIncludedInAllBuiltin() {
        let ids = Set(Backend.allBuiltin.map(\.id))
        #expect(!ids.contains("lmStudio"))
        #expect(!ids.contains("ollama"))
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
            makeProvider: { _, _, _, _ in throw MockError.notImplemented },
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
        // Local backends don't require credentials; skip them here.
        let credentialed = Backend.allBuiltin.filter { $0.id != "lmStudio" && $0.id != "ollama" }
        for backend in credentialed {
            #expect(throws: CollaborationCredentialsError.self) {
                _ = try backend.makeProvider(store, backend.defaultModel, 1_024, nil)
            }
        }
    }

    @Test
    func makeProviderBuildsForAnthropicAPIWithStoredKey() throws {
        let store = InMemoryCredentialStore(anthropicAPIKey: "sk-ant-test")
        _ = try Backend.anthropicAPI.makeProvider(store, Backend.anthropicAPI.defaultModel, 1_024, nil)
    }

    // MARK: - OpenAI factory

    @Test
    func openAIFactoryMatchesStaticValueByDefault() {
        let factory = Backend.openAI()
        #expect(factory.id == Backend.openAI.id)
        #expect(factory.displayName == Backend.openAI.displayName)
        #expect(factory.defaultModel == Backend.openAI.defaultModel)
    }

    @Test
    func openAIFactoryBuildsProviderWithStoredKey() throws {
        let store = InMemoryCredentialStore(openAIAPIKey: "sk-openai-test")
        let backend = Backend.openAI(parallelToolCalls: false)
        _ = try backend.makeProvider(store, backend.defaultModel, 1_024, nil)
    }

    // MARK: - Base URL persistence

    @Test
    func baseURLDefaultsKeyMirrorsID() {
        #expect(Backend.lmStudio().baseURLDefaultsKey == "collaborationkit.baseURL.lmStudio")
        #expect(Backend.ollama().baseURLDefaultsKey == "collaborationkit.baseURL.ollama")
    }

    @MainActor
    @Test
    func credentialsPersistAndClearBaseURLOverride() {
        let defaults = UserDefaults.standard
        let backend = Backend.lmStudio()
        defaults.removeObject(forKey: backend.baseURLDefaultsKey)
        defer { defaults.removeObject(forKey: backend.baseURLDefaultsKey) }

        let credentials = CollaborationCredentials(
            store: InMemoryCredentialStore(),
            backends: [backend],
            initialBackend: backend,
            defaultsKey: nil
        )

        #expect(credentials.baseURL() == nil)
        let override = URL(string: "http://192.168.1.42:1234")!
        credentials.setBaseURL(override)
        #expect(credentials.baseURL() == override)

        credentials.setBaseURL(nil)
        #expect(credentials.baseURL() == nil)
    }

    // MARK: - Error carries backend metadata

    @Test
    func missingCredentialsErrorNamesTheBackend() {
        let error = CollaborationCredentialsError.missingCredentials(id: "x", displayName: "Custom")
        #expect(error.localizedDescription.contains("Custom"))
    }

    private enum MockError: Error { case notImplemented }
}
