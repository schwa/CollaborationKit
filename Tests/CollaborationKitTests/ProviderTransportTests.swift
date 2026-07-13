@testable import CollaborationKit
import Foundation
import Testing

// Live-transport tests for `AnthropicProvider` and `OpenAIProvider`. These
// exercise real request construction (auth headers, URL, method) and the
// HTTP error path by driving the providers through `StreamingTransport` with
// a URLProtocol stub, without hitting the network.
//
// Wire-format encoding of the request body is covered by
// `AnthropicWireTests` / `OpenAITests`; here we care about the plumbing that
// only exists on the provider types themselves.

// MARK: - Capturing URLProtocol

/// A URLProtocol that records the outgoing request and serves a canned
/// status + SSE body. Tests inspect ``ProviderCaptureProtocol/last`` to
/// assert what the provider actually sent.
private final class ProviderCaptureProtocol: URLProtocol, @unchecked Sendable {
    struct Captured {
        var url: URL?
        var method: String?
        var headers: [String: String]
    }

    nonisolated(unsafe) static var responseStatus: Int = 200
    nonisolated(unsafe) static var responseBody: Data = Data()
    nonisolated(unsafe) static var last: Captured?
    static let lock = NSLock()

    static func reset(status: Int = 200, body: Data = Data()) {
        lock.withLock {
            responseStatus = status
            responseBody = body
            last = nil
        }
    }

    static func snapshot() -> Captured? {
        lock.withLock { last }
    }

    // swiftlint:disable:next non_overridable_class_declaration
    override class func canInit(with _: URLRequest) -> Bool { true }
    // swiftlint:disable:next non_overridable_class_declaration
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let captured = Captured(
            url: request.url,
            method: request.httpMethod,
            headers: request.allHTTPHeaderFields ?? [:]
        )
        let (status, body): (Int, Data) = Self.lock.withLock {
            Self.last = captured
            return (Self.responseStatus, Self.responseBody)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func captureSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ProviderCaptureProtocol.self]
    return URLSession(configuration: config)
}

private func drain(_ stream: AsyncThrowingStream<ProviderStreamEvent, Error>) async throws {
    for try await _ in stream {}
}

// A minimal SSE body that both providers' accumulators can consume without
// yielding anything interesting — enough to let the transport finish cleanly.
private let emptyAnthropicSSE = Data("""
event: message_stop
data: {"type":"message_stop"}

""".utf8)

private let emptyOpenAISSE = Data("""
data: [DONE]

""".utf8)

// Header names are compared case-insensitively because URLSession may
// normalize some canonical headers (e.g. `User-Agent`) before handing the
// request off to the URLProtocol.
private extension ProviderCaptureProtocol.Captured {
    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

// MARK: - Provider transport tests
//
// A single serialized suite: `ProviderCaptureProtocol` uses shared class-level
// state, so parallel suites would race on `reset` / `snapshot`.

@Suite(.serialized)
struct ProviderTransportTests {
    // MARK: Anthropic

    private func anthropicProvider(auth: AnthropicAuth) -> AnthropicProvider {
        AnthropicProvider(
            config: AnthropicConfig(auth: auth, model: "claude-test", maxTokens: 128),
            urlSession: captureSession(),
            retryPolicy: .none
        )
    }

    @Test
    func apiKeyAuthSendsXAPIKeyAndNoBearer() async throws {
        ProviderCaptureProtocol.reset(body: emptyAnthropicSSE)
        let provider = anthropicProvider(auth: .apiKey("test-key-123"))

        try await drain(provider.send(messages: [], system: nil, tools: []))

        let captured = try #require(ProviderCaptureProtocol.snapshot())
        #expect(captured.method == "POST")
        #expect(captured.url?.path == "/v1/messages")
        #expect(captured.header("x-api-key") == "test-key-123")
        #expect(captured.header("anthropic-version") != nil)
        #expect(captured.header("Content-Type") == "application/json")
        // OAuth-only headers must not appear on API-key requests.
        #expect(captured.header("Authorization") == nil)
        #expect(captured.header("anthropic-beta") == nil)
        #expect(captured.header("x-app") == nil)
    }

    @Test
    func oauthAuthSendsBearerAndClaudeCodeIdentityHeaders() async throws {
        ProviderCaptureProtocol.reset(body: emptyAnthropicSSE)
        let provider = anthropicProvider(auth: .oauth { "oauth-access-token" })

        try await drain(provider.send(messages: [], system: nil, tools: []))

        let captured = try #require(ProviderCaptureProtocol.snapshot())
        #expect(captured.header("Authorization") == "Bearer oauth-access-token")
        #expect(captured.header("anthropic-beta") == ClaudeCodeIdentity.betas)
        #expect(captured.header("user-agent") == ClaudeCodeIdentity.userAgent)
        #expect(captured.header("x-app") == ClaudeCodeIdentity.app)
        #expect(captured.header("anthropic-dangerous-direct-browser-access") == "true")
        // OAuth never sets x-api-key.
        #expect(captured.header("x-api-key") == nil)
    }

    @Test
    func nonSuccessResponseThrowsAnthropicHTTPError() async throws {
        ProviderCaptureProtocol.reset(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))
        let provider = anthropicProvider(auth: .apiKey("bad"))

        do {
            try await drain(provider.send(messages: [], system: nil, tools: []))
            Issue.record("expected AnthropicError.httpError")
        } catch let AnthropicError.httpError(status, body) {
            #expect(status == 401)
            #expect(body.contains("unauthorized"))
        }
    }

    @Test
    func anthropicModelsRequestUsesApiKeyAndGET() async throws {
        let body = Data(#"{"data":[{"id":"claude-a"},{"id":"claude-b"}]}"#.utf8)
        ProviderCaptureProtocol.reset(body: body)
        let provider = anthropicProvider(auth: .apiKey("k"))

        let models = try await provider.listModels()

        let captured = try #require(ProviderCaptureProtocol.snapshot())
        #expect(captured.method == "GET")
        #expect(captured.url?.path == "/v1/models")
        #expect(captured.header("x-api-key") == "k")
        #expect(models.map(\.id) == ["claude-a", "claude-b"])
    }

    // MARK: OpenAI

    private func openAIProvider(apiKey: String = "sk-test") -> OpenAIProvider {
        OpenAIProvider(
            config: OpenAIConfig(apiKey: apiKey, model: "gpt-test", maxTokens: 128),
            urlSession: captureSession(),
            retryPolicy: .none
        )
    }

    @Test
    func openAIChatRequestUsesBearerAndJSONContentType() async throws {
        ProviderCaptureProtocol.reset(body: emptyOpenAISSE)
        let provider = openAIProvider(apiKey: "sk-abc")

        try await drain(provider.send(messages: [], system: nil, tools: []))

        let captured = try #require(ProviderCaptureProtocol.snapshot())
        #expect(captured.method == "POST")
        #expect(captured.url?.path == "/v1/chat/completions")
        #expect(captured.header("Authorization") == "Bearer sk-abc")
        #expect(captured.header("Content-Type") == "application/json")
    }

    @Test
    func openAINonSuccessResponseThrowsHTTPError() async throws {
        ProviderCaptureProtocol.reset(status: 500, body: Data(#"{"error":"boom"}"#.utf8))
        let provider = openAIProvider()

        do {
            try await drain(provider.send(messages: [], system: nil, tools: []))
            Issue.record("expected OpenAIError.httpError")
        } catch let OpenAIError.httpError(status, body) {
            #expect(status == 500)
            #expect(body.contains("boom"))
        }
    }

    @Test
    func openAIModelsRequestUsesBearerAndGET() async throws {
        let body = Data(#"{"data":[{"id":"m-1"},{"id":"m-2"}]}"#.utf8)
        ProviderCaptureProtocol.reset(body: body)
        let provider = openAIProvider(apiKey: "sk-list")

        let models = try await provider.listModels()

        let captured = try #require(ProviderCaptureProtocol.snapshot())
        #expect(captured.method == "GET")
        #expect(captured.url?.path == "/v1/models")
        #expect(captured.header("Authorization") == "Bearer sk-list")
        #expect(models.map(\.id) == ["m-1", "m-2"])
    }
}
