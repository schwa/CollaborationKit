import Foundation

/// A streamed event produced by a ``ModelProvider`` during a single model call.
///
/// Providers translate their wire protocol into this neutral stream, which the
/// session consumes to build messages and emit ``SessionEvent`` values.
public enum ProviderStreamEvent: Sendable {
    /// An incremental chunk of assistant text.
    case textDelta(String)

    /// A completed text block.
    case text(String)

    /// A completed tool-use request from the model.
    case toolUse(ToolUse)

    /// Token usage reported for this response. May arrive at any point; providers
    /// that omit usage never emit it.
    case usage(TokenUsage)

    /// The model finished its response. `stopReason` is provider-specific.
    case messageComplete(stopReason: String?)
}

/// The tool metadata a provider needs to advertise tools to a model.
public struct ToolSpec: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// A pluggable backend that can run a model turn given a conversation and tools.
///
/// Implementations talk to a specific provider (e.g. Anthropic). The session is
/// written entirely against this protocol and is provider-agnostic.
public protocol ModelProvider: Sendable {
    /// Runs a single model call, streaming results.
    ///
    /// - Parameters:
    ///   - messages: The full conversation so far.
    ///   - system: An optional system prompt.
    ///   - tools: The tools to advertise to the model.
    /// - Returns: An async stream of provider events for this one model response.
    func send(
        messages: [Message],
        system: String?,
        tools: [ToolSpec]
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error>
}
