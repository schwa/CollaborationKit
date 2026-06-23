@testable import CollaborationKit
import Foundation
import Testing

// MARK: - URLProtocol stub

/// A `URLProtocol` that replays a status code and body carried per-request in
/// headers, so transport tests never hit the network and never share mutable
/// global state across parallel tests.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    // swiftlint:disable:next non_overridable_class_declaration
    override class func canInit(with _: URLRequest) -> Bool { true }
    // swiftlint:disable:next non_overridable_class_declaration
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status = Int(request.value(forHTTPHeaderField: "X-Stub-Status") ?? "200") ?? 200
        let bodyB64 = request.value(forHTTPHeaderField: "X-Stub-Body") ?? ""
        let body = Data(base64Encoded: bodyB64) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

private func request(status: Int, body: String) -> URLRequest {
    var request = URLRequest(url: URL(string: "https://example.test/stream")!)
    request.setValue("\(status)", forHTTPHeaderField: "X-Stub-Status")
    request.setValue(Data(body.utf8).base64EncodedString(), forHTTPHeaderField: "X-Stub-Body")
    return request
}

private enum StubError: Error, Equatable {
    case http(Int, String)
}

private func collect(_ stream: AsyncThrowingStream<ProviderStreamEvent, Error>) async throws -> [ProviderStreamEvent] {
    var events: [ProviderStreamEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

// MARK: - Sinks

/// Emits one `.text` per `data:` line; no sentinel, flushes a marker on finish.
private struct LineEchoSink: ServerSentEventSink {
    mutating func consume(_ payload: String) -> [ProviderStreamEvent] {
        [.text(payload)]
    }
    mutating func finish() -> [ProviderStreamEvent] {
        [.text("FINISHED")]
    }
}

/// Buffers payloads and emits them only on the `[DONE]` sentinel via finish().
private struct SentinelSink: ServerSentEventSink {
    let doneSentinel: String? = "[DONE]"
    private var buffer: [String] = []
    mutating func consume(_ payload: String) -> [ProviderStreamEvent] {
        buffer.append(payload)
        return []
    }
    mutating func finish() -> [ProviderStreamEvent] {
        buffer.map { .text($0) }
    }
}

private struct ThrowingSink: ServerSentEventSink {
    mutating func consume(_ payload: String) throws -> [ProviderStreamEvent] {
        throw StubError.http(0, payload)
    }
}

// MARK: - Tests

@Test
func transportParsesDataLinesAndSkipsOthers() async throws {
    let body = """
    : comment line
    data: one

    event: ignored
    data:two
    data:    three

    """
    let session = stubbedSession()
    let stream = StreamingTransport.stream(
        request: { request(status: 200, body: body) },
        urlSession: session,
        makeSink: { LineEchoSink() },
        httpError: { status, body in StubError.http(status, body) }
    )
    let events = try await collect(stream)
    let texts = events.compactMap { event -> String? in
        if case .text(let t) = event { return t }
        return nil
    }
    // Leading/trailing whitespace trimmed; non-data lines skipped; finish() flushed.
    #expect(texts == ["one", "two", "three", "FINISHED"])
}

@Test
func transportSkipsEmptyDataPayloads() async throws {
    let body = "data:\ndata:   \ndata: real\n"
    let session = stubbedSession()
    let stream = StreamingTransport.stream(
        request: { request(status: 200, body: body) },
        urlSession: session,
        makeSink: { LineEchoSink() },
        httpError: { status, body in StubError.http(status, body) }
    )
    let events = try await collect(stream)
    let texts = events.compactMap { event -> String? in
        if case .text(let t) = event { return t }
        return nil
    }
    #expect(texts == ["real", "FINISHED"])
}

@Test
func transportStopsAtSentinelAndFlushes() async throws {
    let body = """
    data: a
    data: b
    data: [DONE]
    data: c

    """
    let session = stubbedSession()
    let stream = StreamingTransport.stream(
        request: { request(status: 200, body: body) },
        urlSession: session,
        makeSink: { SentinelSink() },
        httpError: { status, body in StubError.http(status, body) }
    )
    let events = try await collect(stream)
    let texts = events.compactMap { event -> String? in
        if case .text(let t) = event { return t }
        return nil
    }
    // Flushes a and b on sentinel; c after the sentinel is never read.
    #expect(texts == ["a", "b"])
}

@Test
func sentinelSinkDoesNotFlushWhenStreamEndsWithoutSentinel() async throws {
    let body = "data: a\ndata: b\n"
    let session = stubbedSession()
    let stream = StreamingTransport.stream(
        request: { request(status: 200, body: body) },
        urlSession: session,
        makeSink: { SentinelSink() },
        httpError: { status, body in StubError.http(status, body) }
    )
    let events = try await collect(stream)
    // No sentinel arrived, so nothing is flushed (matches provider behavior).
    #expect(events.isEmpty)
}

@Test
func transportThrowsProviderErrorWithDrainedBodyOnNon2xx() async throws {
    let session = stubbedSession()
    let body = "data: ignored\nrate limited\n"
    do {
        _ = try await collect(StreamingTransport.stream(
            request: { request(status: 429, body: body) },
            urlSession: session,
            makeSink: { LineEchoSink() },
            httpError: { status, body in StubError.http(status, body) }
        ))
        Issue.record("expected throw")
    } catch let StubError.http(status, body) {
        #expect(status == 429)
        #expect(body.contains("data: ignored"))
        #expect(body.contains("rate limited"))
    }
}

@Test
func transportPropagatesSinkErrors() async throws {
    let session = stubbedSession()
    let stream = StreamingTransport.stream(
        request: { request(status: 200, body: "data: boom\n") },
        urlSession: session,
        makeSink: { ThrowingSink() },
        httpError: { status, body in StubError.http(status, body) }
    )
    await #expect(throws: StubError.self) {
        _ = try await collect(stream)
    }
}

@Test
func transportPropagatesRequestFactoryErrors() async throws {
    let session = stubbedSession()
    let stream = StreamingTransport.stream(
        request: { throw StubError.http(-1, "request failed") },
        urlSession: session,
        makeSink: { LineEchoSink() },
        httpError: { status, body in StubError.http(status, body) }
    )
    await #expect(throws: StubError.self) {
        _ = try await collect(stream)
    }
}
