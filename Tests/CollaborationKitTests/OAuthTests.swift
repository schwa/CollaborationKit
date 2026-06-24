@testable import CollaborationKit
import Foundation
import Testing

@Test
func parsesCodeHashState() {
    let parsed = AnthropicOAuth.parseAuthInput("abc123#xyz789")
    #expect(parsed == AnthropicOAuth.ParsedAuthInput(code: "abc123", state: "xyz789"))
}

@Test
func parsesFullCallbackURL() {
    let parsed = AnthropicOAuth.parseAuthInput(
        "https://platform.claude.com/oauth/code/callback?code=abc123&state=xyz789"
    )
    #expect(parsed == AnthropicOAuth.ParsedAuthInput(code: "abc123", state: "xyz789"))
}

@Test
func rejectsGarbageInput() {
    #expect(AnthropicOAuth.parseAuthInput("not a code") == nil)
    #expect(AnthropicOAuth.parseAuthInput("") == nil)
}

@Test
func beginLoginProducesAuthorizeURLWithPKCE() {
    let request = AnthropicOAuth().beginLogin()
    let url = request.authorizeURL
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

    #expect(url.host == "claude.ai")
    #expect(items["code_challenge_method"] == "S256")
    #expect(items["response_type"] == "code")
    #expect(items["state"] == request.state)
    #expect((items["code_challenge"] ?? "")?.isEmpty == false)
    #expect(!request.verifier.isEmpty)
    // base64url: no padding or URL-unsafe characters.
    #expect(!request.verifier.contains("="))
    #expect(!request.verifier.contains("+"))
    #expect(!request.verifier.contains("/"))
}

@Test
func oauthCredentialsExpiry() {
    let past = OAuthCredentials(access: "a", refresh: "r", expires: Date(timeIntervalSinceNow: -10))
    let future = OAuthCredentials(access: "a", refresh: "r", expires: Date(timeIntervalSinceNow: 1_000))
    #expect(past.isExpired())
    #expect(!future.isExpired())
}

@Test
func oauthRequestBodyPrependsIdentityBlock() {
    let body = AnthropicWire.requestBody(
        model: "m", maxTokens: 10, system: "Be helpful.", messages: [], tools: [], oauth: true
    )
    guard case .object(let root) = body,
          case .array(let blocks)? = root["system"],
          case .object(let first) = blocks.first,
          case .string(let text)? = first["text"] else {
        Issue.record("expected structured system blocks")
        return
    }
    #expect(text == AnthropicWire.claudeCodeIdentity)
    #expect(blocks.count == 2)
}

@Test
func apiKeyRequestBodyUsesStringSystem() {
    let body = AnthropicWire.requestBody(
        model: "m", maxTokens: 10, system: "Be helpful.", messages: [], tools: [], oauth: false
    )
    guard case .object(let root) = body else {
        Issue.record("expected object")
        return
    }
    #expect(root["system"] == .string("Be helpful."))
}

@Test
func cacheControlMarksSystemAsStructuredBlock() {
    let body = AnthropicWire.requestBody(
        model: "m",
        maxTokens: 10,
        system: "Be helpful.",
        messages: [],
        tools: [],
        oauth: false,
        cacheControl: true
    )
    guard case .object(let root) = body,
          case .array(let blocks)? = root["system"],
          case .object(let block) = blocks.last else {
        Issue.record("expected structured system blocks")
        return
    }
    #expect(block["cache_control"] == .object(["type": .string("ephemeral")]))
}

@Test
func cacheControlMarksLastToolOnly() {
    let tool = { (name: String) in
        ToolSpec(name: name, description: "d", inputSchema: .object([:]))
    }
    let body = AnthropicWire.requestBody(
        model: "m",
        maxTokens: 10,
        system: nil,
        messages: [],
        tools: [tool("a"), tool("b")],
        oauth: false,
        cacheControl: true
    )
    guard case .object(let root) = body,
          case .array(let tools)? = root["tools"],
          case .object(let first) = tools.first,
          case .object(let last) = tools.last else {
        Issue.record("expected tools array")
        return
    }
    #expect(first["cache_control"] == nil)
    #expect(last["cache_control"] == .object(["type": .string("ephemeral")]))
}

@Test
func credentialStoreKeepsApiKeyAndOAuthSeparately() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("collab-oauth-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = CredentialStore(directory: dir)

    try store.save(apiKey: "sk-key")
    let creds = OAuthCredentials(access: "sk-ant-oat-x", refresh: "r", expires: Date(timeIntervalSinceNow: 3_600))
    try store.save(oauth: creds)

    // Saving OAuth must not clobber the API key, and vice versa.
    #expect(try store.apiKey() == "sk-key")
    #expect(try store.oauthCredentials() == creds)
}
