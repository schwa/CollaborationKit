import Foundation

/// Consumes server-sent `data:` payloads and produces ``ProviderStreamEvent``s.
///
/// Provider accumulators conform to this so that ``StreamingTransport`` can drive
/// the SSE loop generically. The transport feeds each non-empty `data:` payload
/// to ``consume(_:)`` and, at end of stream (or when a sentinel is hit), calls
/// ``finish()`` to flush any buffered events.
public protocol ServerSentEventSink {
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
    public var doneSentinel: String? { nil }
    public mutating func finish() -> [ProviderStreamEvent] { [] }
}

/// Drives an SSE `POST` request and translates it into a stream of
/// ``ProviderStreamEvent``s, shared by all streaming providers.
///
/// The transport owns the cross-cutting plumbing every provider needs: wrapping
/// the work in a cancellable `Task`, checking the HTTP status (draining the body
/// into a provider-specific error on failure), and parsing `data:` lines. The
/// per-line semantics live in the provider's ``ServerSentEventSink``.
public enum StreamingTransport {
    /// Runs `request` and streams events parsed by a fresh `sink`.
    ///
    /// - Parameters:
    ///   - request: A factory for the request to send. Run lazily inside the task
    ///     so providers can perform async work (e.g. minting an OAuth token).
    ///   - urlSession: The session used to issue the request.
    ///   - makeSink: Builds the per-call sink that parses payloads.
    ///   - httpError: Maps a non-2xx `(status, body)` into the provider's error.
    ///   - retryPolicy: How to retry transient failures on the initial HTTP
    ///     round-trip. Only applies before the first byte is yielded to the
    ///     consumer — mid-stream failures never retry.
    @preconcurrency
    public static func stream(
        request: @escaping @Sendable () async throws -> URLRequest,
        urlSession: URLSession,
        makeSink: @escaping @Sendable () -> any ServerSentEventSink,
        httpError: @escaping @Sendable (Int, String) -> Error,
        retryPolicy: RetryPolicy = .default
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(
                        request: request,
                        urlSession: urlSession,
                        makeSink: makeSink,
                        httpError: httpError,
                        retryPolicy: retryPolicy,
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

    /// Issues a non-streaming request and decodes the JSON body.
    ///
    /// - Parameters:
    ///   - request: A factory for the request to send. Run lazily so providers
    ///     can perform async work (e.g. minting an OAuth token).
    ///   - urlSession: The session used to issue the request.
    ///   - httpError: Maps a non-2xx `(status, body)` into the provider's error.
    /// - Returns: The decoded ``JSONValue`` of the response body.
    @preconcurrency
    public static func fetchJSON(
        request: @Sendable () async throws -> URLRequest,
        urlSession: URLSession,
        httpError: @Sendable (Int, String) -> Error
    ) async throws -> JSONValue {
        let urlRequest = try await request()
        let (data, response) = try await urlSession.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(bytes: data, encoding: .utf8) ?? ""
            throw httpError(http.statusCode, body)
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    // swiftlint:disable:next function_parameter_count
    private static func run(
        request: @Sendable () async throws -> URLRequest,
        urlSession: URLSession,
        makeSink: @Sendable () -> any ServerSentEventSink,
        httpError: @Sendable (Int, String) -> Error,
        retryPolicy: RetryPolicy,
        into continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation
    ) async throws {
        // Retry the initial HTTP round-trip only. Once we begin iterating
        // `bytes.lines`, we're mid-stream; a failure there is not safely
        // retryable because we may have already yielded events to the
        // consumer that a re-issued request would duplicate.
        let (bytes, statusOKResponse) = try await openStream(
            request: request,
            urlSession: urlSession,
            httpError: httpError,
            retryPolicy: retryPolicy
        )
        _ = statusOKResponse

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

    /// Opens the streaming request, retrying transient failures until a 2xx
    /// response is available or the retry budget is exhausted. Returns the
    /// live byte stream on success; throws the provider's HTTP error on
    /// non-retryable failure.
    private static func openStream(
        request: @Sendable () async throws -> URLRequest,
        urlSession: URLSession,
        httpError: @Sendable (Int, String) -> Error,
        retryPolicy: RetryPolicy
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse?) {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let urlRequest = try await request()
                let (bytes, response) = try await urlSession.bytes(for: urlRequest)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? -1

                if let http, (200..<300).contains(status) {
                    return (bytes, http)
                }

                if attempt < retryPolicy.maxAttempts, RetryReason.isRetryable(status: status) {
                    // Drain the body so the connection can be reused, then
                    // wait for the greater of the computed backoff and any
                    // server-supplied Retry-After.
                    var body = ""
                    for try await line in bytes.lines {
                        body += line + "\n"
                    }
                    _ = body
                    let backoff = retryPolicy.backoff(forAttempt: attempt + 1)
                    let retryAfter = parseRetryAfter(http?.value(forHTTPHeaderField: "Retry-After"))
                    try await retryDelay(max(backoff, retryAfter ?? 0))
                    continue
                }

                // Non-retryable HTTP failure: drain body and throw.
                var body = ""
                for try await line in bytes.lines {
                    body += line + "\n"
                }
                throw httpError(status, body)
            } catch let urlError as URLError {
                if attempt < retryPolicy.maxAttempts, RetryReason.isRetryable(urlError: urlError) {
                    try await retryDelay(retryPolicy.backoff(forAttempt: attempt + 1))
                    continue
                }
                throw urlError
            }
        }
    }
}
