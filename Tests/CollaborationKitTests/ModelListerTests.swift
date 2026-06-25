@testable import CollaborationKit
import Foundation
import Testing

/// A `URLProtocol` that serves a status + JSON body keyed by request host, so
/// parallel tests never share mutable state.
private final class FixedJSONProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var registry: [String: (Int, String)] = [:]

    static func register(host: String, status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        registry[host] = (status, body)
    }

    private static func entry(for host: String) -> (Int, String) {
        lock.lock(); defer { lock.unlock() }
        return registry[host] ?? (200, "{}")
    }

    // swiftlint:disable:next non_overridable_class_declaration
    override class func canInit(with _: URLRequest) -> Bool { true }
    // swiftlint:disable:next non_overridable_class_declaration
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let (status, body) = Self.entry(for: host)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func fixedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FixedJSONProtocol.self]
    return URLSession(configuration: config)
}

private func fixedBaseURL(_ host: String, status: Int, body: String) -> URL {
    FixedJSONProtocol.register(host: host, status: status, body: body)
    return URL(string: "https://\(host)")!
}

@Test
func openAIListsModels() async throws {
    let body = """
    {"object":"list","data":[
      {"id":"gpt-4o","object":"model","created":1715300000,"owned_by":"openai"},
      {"id":"gpt-3.5-turbo","object":"model","owned_by":"system"}
    ]}
    """
    let baseURL = fixedBaseURL("openai-list.test", status: 200, body: body)
    let provider = OpenAIProvider(
        config: OpenAIConfig(apiKey: "k", model: "gpt-4o", baseURL: baseURL),
        urlSession: fixedSession()
    )
    let models = try await provider.listModels()
    #expect(models.map(\.id) == ["gpt-4o", "gpt-3.5-turbo"])
    #expect(models[0].ownedBy == "openai")
    #expect(models[0].created == Date(timeIntervalSince1970: 1_715_300_000))
    #expect(models[1].created == nil)
}

@Test
func openAIListModelsThrowsOnHTTPError() async throws {
    let baseURL = fixedBaseURL("openai-err.test", status: 401, body: #"{"error":{"message":"bad key"}}"#)
    let provider = OpenAIProvider(
        config: OpenAIConfig(apiKey: "bad", model: "gpt-4o", baseURL: baseURL),
        urlSession: fixedSession()
    )
    await #expect(throws: OpenAIError.self) {
        _ = try await provider.listModels()
    }
}

@Test
func anthropicListsModels() async throws {
    let body = """
    {"data":[
      {"type":"model","id":"claude-3-5-sonnet-20241022","display_name":"Claude 3.5 Sonnet","created_at":"2024-10-22T00:00:00Z"}
    ],"has_more":false}
    """
    let baseURL = fixedBaseURL("anthropic-list.test", status: 200, body: body)
    let provider = AnthropicProvider(
        config: AnthropicConfig(apiKey: "k", model: "claude-3-5-sonnet-20241022", baseURL: baseURL),
        urlSession: fixedSession()
    )
    let models = try await provider.listModels()
    #expect(models.count == 1)
    #expect(models[0].id == "claude-3-5-sonnet-20241022")
    #expect(models[0].displayName == "Claude 3.5 Sonnet")
    #expect(models[0].created == ISO8601DateFormatter().date(from: "2024-10-22T00:00:00Z"))
}
