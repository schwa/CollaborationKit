import Foundation

/// A ``ModelProvider`` that talks to an HTTP + Server-Sent-Events chat
/// completion endpoint.
///
/// Conformers describe the wire-specific bits: how a chat request is built,
/// how streaming events are accumulated, how a non-2xx response becomes an
/// error, and (optionally) how the model catalog is fetched. In return they
/// get ``ModelProvider/send(messages:system:tools:)`` and
/// ``ModelLister/listModels()`` implementations for free — one boundary,
/// one transport, one retry policy.
///
/// See ``AnthropicProvider`` and ``OpenAIProvider`` for concrete conformers.
public protocol WireProvider: ModelProvider, ModelLister {
    /// The `URLSession` used to issue requests. Both `send` and `listModels`
    /// route through this session.
    var urlSession: URLSession { get }

    /// Retry policy applied to the initial HTTP round-trip. Only applies
    /// before the first byte reaches the consumer.
    var retryPolicy: RetryPolicy { get }

    /// Builds the HTTP request that opens a streaming chat completion.
    /// Awaited inside the transport's Task so implementations can perform
    /// async work (e.g. minting an OAuth access token).
    func makeChatRequest(
        messages: [Message],
        system: String?,
        tools: [ToolSpec]
    ) async throws -> URLRequest

    /// Fresh accumulator for one stream. Returns a value-type sink because
    /// the transport calls `mutating` methods on it internally.
    func makeAccumulator() -> any ServerSentEventSink

    /// Maps a non-2xx (status, body) into the provider's error type.
    func httpError(status: Int, body: String) -> Error

    /// Builds the HTTP request for the model catalog, or returns `nil` to
    /// disable model listing (e.g. providers without a `/v1/models` route).
    func makeModelsRequest() async throws -> URLRequest?

    /// Decodes a model list response body into ``ModelInfo`` values.
    func decodeModels(_ json: JSONValue) -> [ModelInfo]
}

extension WireProvider {
    public var retryPolicy: RetryPolicy { .default }

    public func send(
        messages: [Message],
        system: String?,
        tools: [ToolSpec]
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        StreamingTransport.stream(
            request: { try await self.makeChatRequest(messages: messages, system: system, tools: tools) },
            urlSession: urlSession,
            makeSink: { self.makeAccumulator() },
            httpError: { status, body in self.httpError(status: status, body: body) },
            retryPolicy: retryPolicy
        )
    }

    public func listModels() async throws -> [ModelInfo] {
        guard let request = try await makeModelsRequest() else { return [] }
        let json = try await StreamingTransport.fetchJSON(
            request: { request },
            urlSession: urlSession,
            httpError: { status, body in self.httpError(status: status, body: body) } // swiftlint:disable:this trailing_closure
        )
        return decodeModels(json)
    }
}
