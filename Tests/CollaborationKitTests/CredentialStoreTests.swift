import Foundation
import Testing
@testable import CollaborationKit

/// Tests for the ``CredentialStore`` protocol surface after the shift from
/// fixed-slot methods to a generic key/value API. Covers the extension
/// methods that expose the standard slots (Anthropic API key, OpenAI API
/// key, Claude subscription OAuth) as thin wrappers over
/// ``readCredential(forKey:)`` / ``writeCredential(_:forKey:)`` /
/// ``deleteCredential(forKey:)``, plus custom-key round-trips that prove
/// new backends don't need protocol changes.
@Suite("CredentialStore")
struct CredentialStoreTests {
    // MARK: - InMemory: raw API round-trip

    @Test("read on an empty in-memory store returns notFound")
    func readOnEmptyStoreReturnsNotFound() {
        let store = InMemoryCredentialStore()
        #expect(store.readCredential(forKey: "missing") == .notFound)
    }

    @Test("write then read a custom key round-trips the value")
    func writeThenReadCustomKey() {
        let store = InMemoryCredentialStore()
        _ = store.writeCredential("secret", forKey: "my-backend.token")
        #expect(store.readCredential(forKey: "my-backend.token") == .found("secret"))
    }

    @Test("write with empty string deletes the entry")
    func writeEmptyStringDeletes() {
        let store = InMemoryCredentialStore()
        _ = store.writeCredential("secret", forKey: "k")
        _ = store.writeCredential("", forKey: "k")
        #expect(store.readCredential(forKey: "k") == .notFound)
    }

    @Test("delete removes the entry")
    func deleteRemovesEntry() {
        let store = InMemoryCredentialStore()
        _ = store.writeCredential("secret", forKey: "k")
        _ = store.deleteCredential(forKey: "k")
        #expect(store.readCredential(forKey: "k") == .notFound)
    }

    @Test("delete on a missing key still returns true (success or absence)")
    func deleteMissingKeyReturnsTrue() {
        let store = InMemoryCredentialStore()
        #expect(store.deleteCredential(forKey: "nothing"))
    }

    // MARK: - Standard slot extensions

    @Test("save and read Anthropic API key via the extension methods")
    func anthropicAPIKeyRoundTrip() {
        let store = InMemoryCredentialStore()
        _ = store.saveAnthropicAPIKey("sk-ant-live")
        #expect(store.anthropicAPIKey() == .found("sk-ant-live"))
        // The extension is a plain alias over the raw key, so the raw
        // read must see the same value under the standard key.
        #expect(store.readCredential(forKey: CredentialStoreKey.anthropicAPIKey) == .found("sk-ant-live"))
    }

    @Test("save and read OpenAI API key via the extension methods")
    func openAIAPIKeyRoundTrip() {
        let store = InMemoryCredentialStore()
        _ = store.saveOpenAIAPIKey("sk-openai-live")
        #expect(store.openAIAPIKey() == .found("sk-openai-live"))
    }

    @Test("clear removes the value")
    func clearRemovesValue() {
        let store = InMemoryCredentialStore()
        _ = store.saveAnthropicAPIKey("sk")
        _ = store.clearAnthropicAPIKey()
        #expect(store.anthropicAPIKey() == .notFound)
    }

    @Test("OAuth credentials round-trip via JSON in a plain string slot")
    func oauthCredentialsRoundTrip() {
        let store = InMemoryCredentialStore()
        let creds = OAuthCredentials(
            access: "at",
            refresh: "rt",
            expires: Date(timeIntervalSince1970: 1_000_000)
        )
        #expect(store.saveAnthropicOAuthCredentials(creds))
        #expect(store.anthropicOAuthCredentials() == creds)
    }

    @Test("OAuth credentials return nil when the slot holds invalid JSON")
    func oauthCredentialsReturnNilForInvalidJSON() {
        let store = InMemoryCredentialStore()
        _ = store.writeCredential("not-json", forKey: CredentialStoreKey.anthropicOAuth)
        #expect(store.anthropicOAuthCredentials() == nil)
    }

    // MARK: - Convenience init

    @Test("pre-populating InMemoryCredentialStore stores values under the standard keys")
    func prepopulateInitUsesStandardKeys() {
        let store = InMemoryCredentialStore(
            anthropicAPIKey: "ant",
            openAIAPIKey: "oai"
        )
        #expect(store.readCredential(forKey: CredentialStoreKey.anthropicAPIKey) == .found("ant"))
        #expect(store.readCredential(forKey: CredentialStoreKey.openAIAPIKey) == .found("oai"))
    }

    // MARK: - Custom backend: no protocol change required

    @Test("a custom backend can register a new key without touching CredentialStore")
    func customBackendKeyRoundTrip() {
        let store = InMemoryCredentialStore()
        // Simulate a hypothetical custom backend using its own key.
        let customKey = "custom-backend.session-token"
        _ = store.writeCredential("xyz", forKey: customKey)
        #expect(store.readCredential(forKey: customKey) == .found("xyz"))
        // And it doesn't collide with the standard slots.
        #expect(store.anthropicAPIKey() == .notFound)
    }
}
