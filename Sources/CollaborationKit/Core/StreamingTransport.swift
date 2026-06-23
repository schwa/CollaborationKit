import Foundation

/// Consumes server-sent `data:` payloads and produces ``ProviderStreamEvent``s.
///
/// Provider accumulators conform to this so that ``StreamingTransport`` can drive
/// the SSE loop generically. The transport feeds each non-empty `data:` payload
/// to ``consume(_:)`` and, at end of stream (or when a sentinel is hit), calls
/// ``finish()`` to flush any buffered events.
protocol ServerSentEventSink {
    /// The payload that terminates the stream, if the API sends one (e.g. OpenAI's
    /// `[DONE]`). When the transport sees this payload it stops reading and flushes
    /// via ``finish()`` instead of passing it to ``consume(_:)``. `nil` if the API
    /// has no such sentinel (e.g. Anthropic, which ends the byte stream).
    var doneSentinel: String? { get }

    /// Processes one `data:` payload, returning any completed events.
    mutating func consume(_ payload: String) throws -> [ProviderStreamEvent]

    /// Flushes any buffered events at end of stream. Sinks that emit incrementally
    /// return an empty array.
    mutating func finish() -> [ProviderStreamEvent]
}

extension ServerSentEventSink {
    var doneSentinel: String? { nil }
    mutating func finish() -> [ProviderStreamEvent] { [] }
}

/// Drives an SSE `POST` request and translates it into a stream of
/// ``ProviderStreamEvent``s, shared by all streaming providers.
///
/// The transport owns the cross-cutting plumbing every provider needs: wrapping
/// the work in a cancellable `Task`, checking the HTTP status (draining the body
/// into a provider-specific error on failure), and parsing `data:` lines. The
/// per-line semantics live in the provider's ``ServerSentEventSink``.
enum StreamingTransport {
    /// Runs `request` and streams events parsed by a fresh `sink`.
    ///
    /// - Parameters:
    ///   - request: A factory for the request to send. Run lazily inside the task
    ///     so providers can perform async work (e.g. minting an OAuth token).
    ///   - urlSession: The session used to issue the request.
    ///   - makeSink: Builds the per-call sink that parses payloads.
    ///   - httpError: Maps a non-2xx `(status, body)` into the provider's error.
    static func stream(
        request: @escaping @Sendable () async throws -> URLRequest,
        urlSession: URLSession,
        makeSink: @escaping @Sendable () -> ServerSentEventSink,
        httpError: @escaping @Sendable (Int, String) -> Error
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(
                        request: request,
                        urlSession: urlSession,
                        makeSink: makeSink,
                        httpError: httpError,
                        into: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(
        request: @Sendable () async throws -> URLRequest,
        urlSession: URLSession,
        makeSink: @Sendable () -> ServerSentEventSink,
        httpError: @Sendable (Int, String) -> Error,
        into continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation
    ) async throws {
        let urlRequest = try await request()
        let (bytes, response) = try await urlSession.bytes(for: urlRequest)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines {
                body += line + "\n"
            }
            throw httpError(http.statusCode, body)
        }

        var sink = makeSink()
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else {
                continue
            }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty else {
                continue
            }
            if let sentinel = sink.doneSentinel, payload == sentinel {
                for event in sink.finish() {
                    continuation.yield(event)
                }
                return
            }
            for event in try sink.consume(payload) {
                continuation.yield(event)
            }
        }
        // Sinks with a sentinel flush only when that sentinel arrives; if the
        // stream ends without it, nothing is flushed (matching the original
        // provider behavior). Sentinel-less sinks flush at end of stream.
        if sink.doneSentinel == nil {
            for event in sink.finish() {
                continuation.yield(event)
            }
        }
    }
}
