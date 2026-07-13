@testable import CollaborationKit
import Foundation
import Testing

// Tests the WireProvider default implementations by driving a fake wire
// through StreamingTransport with a URLProtocol stub.

// MARK: - URLProtocol stub

private final class WireStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodyByPath: [String: (status: Int, body: Data)] = [:]
    static let lock = NSLock()

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let (status, body) = Self.lock.withLock {
            Self.bodyByPath[path] ?? (200, Data())
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

private func wireStubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [WireStubProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - Fake wire

private struct FakeWireError: Error, Equatable {
    let status: Int
    let body: String
}

private struct FakeAccumulator: ServerSentEventSink {
    let doneSentinel: String? = nil
    mutating func consume(_ payload: String) -> [ProviderStreamEvent] {
        [.text(payload)]
    }
}

private struct FakeWire: WireProvider {
    let urlSession: URLSession
    let baseURL: URL

    func makeChatRequest(messages _: [Message], system _: String?, tools _: [ToolSpec]) -> URLRequest {
        URLRequest(url: baseURL.appendingPathComponent("chat"))
    }
    func makeAccumulator() -> any ServerSentEventSink { FakeAccumulator() }
    func httpError(status: Int, body: String) -> Error {
        FakeWireError(status: status, body: body)
    }
    func makeModelsRequest() -> URLRequest? {
        URLRequest(url: baseURL.appendingPathComponent("models"))
    }
    func decodeModels(_ json: JSONValue) -> [ModelInfo] {
        guard case .object(let root) = json, case .array(let data)? = root["data"] else { return [] }
        return data.compactMap { entry in
            guard case .object(let o) = entry, case .string(let id)? = o["id"] else { return nil }
            return ModelInfo(id: id)
        }
    }
}

// MARK: - Tests

@Suite(.serialized)
struct WireProviderTests {
    private let baseURL = URL(string: "https://fakewire.test")!

    private func setStub(_ entries: [String: (Int, Data)]) {
        WireStubProtocol.lock.withLock {
            WireStubProtocol.bodyByPath = entries.mapValues { ($0.0, $0.1) }
        }
    }

    @Test
    func sendDefaultImplRoutesThroughStreamingTransport() async throws {
        setStub(["/chat": (200, Data("data: hello\n".utf8))])
        let wire = FakeWire(urlSession: wireStubSession(), baseURL: baseURL)
        var texts: [String] = []
        for try await event in wire.send(messages: [], system: nil, tools: []) {
            if case .text(let t) = event { texts.append(t) }
        }
        #expect(texts == ["hello"])
    }

    @Test
    func listModelsDefaultImplParsesJSONThroughDecoder() async throws {
        let body = #"{"data":[{"id":"m1"},{"id":"m2"}]}"#
        setStub(["/models": (200, Data(body.utf8))])
        let wire = FakeWire(urlSession: wireStubSession(), baseURL: baseURL)
        let models = try await wire.listModels()
        #expect(models.map(\.id) == ["m1", "m2"])
    }

    @Test
    func listModelsReturnsEmptyWhenRequestIsNil() async throws {
        struct NoCatalogWire: WireProvider {
            let urlSession: URLSession = wireStubSession()
            func makeChatRequest(messages _: [Message], system _: String?, tools _: [ToolSpec]) -> URLRequest {
                URLRequest(url: URL(string: "https://x.test")!)
            }
            func makeAccumulator() -> any ServerSentEventSink { FakeAccumulator() }
            func httpError(status: Int, body: String) -> Error { FakeWireError(status: status, body: body) }
            func makeModelsRequest() -> URLRequest? { nil }
            func decodeModels(_: JSONValue) -> [ModelInfo] { [] }
        }
        let models = try await NoCatalogWire().listModels()
        #expect(models.isEmpty)
    }

    @Test
    func sendRoutesHTTPErrorThroughWireHook() async throws {
        setStub(["/chat": (400, Data("bad".utf8))])
        let wire = FakeWire(
            urlSession: wireStubSession(),
            baseURL: baseURL
        )
        do {
            for try await _ in wire.send(messages: [], system: nil, tools: []) {}
            Issue.record("expected throw")
        } catch let error as FakeWireError {
            #expect(error.status == 400)
            #expect(error.body.contains("bad"))
        }
    }
}
