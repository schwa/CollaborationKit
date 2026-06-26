import Foundation

/// An error raised by the session harness itself, distinct from tool failures.
///
/// Tool failures are fed back to the model as error results; harness errors
/// throw out of ``LLMSession/send(_:)`` to the caller.
public enum SessionError: Error, Sendable {
    /// The model referenced a tool name that is not registered.
    case unknownTool(String)

    /// The tool loop exceeded ``LLMSession/maxIterations`` without completing.
    case maxIterationsExceeded(Int)
}

/// A provider-agnostic conversation that runs an agentic tool-use loop.
///
/// A session owns the conversation history, the registered tools, and the loop
/// that round-trips between the model and tool execution. Drive it with
/// ``send(_:)`` for the final text, and observe live activity via ``events``.
///
/// Sessions are actors; their history is mutated only on the actor.
public actor LLMSession {
    private let provider: ModelProvider
    private let system: String?
    private let tools: [String: AnyTool]
    private let toolSpecs: [ToolSpec]

    /// The maximum number of model/tool round-trips per ``send(_:)`` call.
    public let maxIterations: Int

    private var history: [Message] = []

    private let eventContinuation: AsyncStream<SessionEvent>.Continuation
    /// A stream of events describing turn progress: text, tool calls, results.
    nonisolated public let events: AsyncStream<SessionEvent>

    /// Creates a session.
    ///
    /// - Parameters:
    ///   - provider: The backend used to run model turns.
    ///   - system: An optional system prompt.
    ///   - tools: The tools the model may invoke. Names must be unique.
    ///   - maxIterations: A cap on model/tool round-trips per turn.
    public init(
        provider: ModelProvider,
        system: String? = nil,
        tools: [AnyTool] = [],
        maxIterations: Int = 32
    ) {
        self.provider = provider
        self.system = system
        self.tools = Dictionary(tools.map { ($0.name, $0) }) { _, new in new }
        self.toolSpecs = tools.map { ToolSpec(name: $0.name, description: $0.description, inputSchema: $0.inputSchema) }
        self.maxIterations = maxIterations

        var continuation: AsyncStream<SessionEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    /// The conversation so far, read-only. Serialize this if you need to persist.
    public var messages: [Message] {
        history
    }

    /// Truncates the conversation history to the first `count` messages,
    /// discarding everything after.
    ///
    /// Use this to "roll back" the model's memory to an earlier point: the next
    /// ``send(_:)`` continues as if the discarded turns never happened. `count`
    /// is clamped to the current history length, so values larger than
    /// ``messages``.count leave the history unchanged and negative values clear
    /// it.
    ///
    /// - Parameter count: The number of leading messages to keep.
    public func truncateHistory(keeping count: Int) {
        let clamped = max(0, min(count, history.count))
        history.removeLast(history.count - clamped)
    }

    private var accumulatedUsage = TokenUsage()

    /// Cumulative token usage across all turns in this session.
    ///
    /// Providers that do not report usage contribute zero. This is per-session
    /// accounting, not the model's remaining context window.
    public var totalUsage: TokenUsage {
        accumulatedUsage
    }

    /// Sends a user message and runs the tool loop until the model stops.
    ///
    /// - Parameter text: The user's message.
    /// - Returns: The model's final assistant text for the turn.
    /// - Throws: ``SessionError`` or any provider/transport error. Tool failures
    ///   are not thrown; they are fed back to the model as error results.
    public func send(_ text: String) async throws -> String {
        try await send(text: text)
    }

    /// Sends a user message with optional image attachments and runs the tool
    /// loop until the model stops.
    ///
    /// - Parameters:
    ///   - text: The user's message.
    ///   - images: Image attachments to include alongside the text.
    /// - Returns: The model's final assistant text for the turn.
    /// - Throws: ``SessionError`` or any provider/transport error. Tool failures
    ///   are not thrown; they are fed back to the model as error results.
    public func send(text: String, images: [ImageContent] = []) async throws -> String {
        history.append(images.isEmpty ? .user(text) : .user(text: text, images: images))
        return try await runLoop()
    }

    private func runLoop() async throws -> String {
        var lastText = ""

        for _ in 0..<maxIterations {
            var assistantBlocks: [ContentBlock] = []
            var turnText = ""
            var pendingToolUses: [ToolUse] = []

            let stream = provider.send(messages: history, system: system, tools: toolSpecs)
            for try await event in stream {
                switch event {
                case .textDelta(let chunk):
                    eventContinuation.yield(.textDelta(chunk))

                case .text(let block):
                    turnText += block
                    assistantBlocks.append(.text(block))
                    eventContinuation.yield(.text(block))

                case .toolUse(let use):
                    assistantBlocks.append(.toolUse(use))
                    pendingToolUses.append(use)
                    eventContinuation.yield(.toolCall(use))

                case .usage(let usage):
                    accumulatedUsage += usage
                    eventContinuation.yield(.usage(usage))

                case .messageComplete:
                    break
                }
            }

            history.append(Message(role: .assistant, content: assistantBlocks))
            lastText = turnText

            guard !pendingToolUses.isEmpty else {
                eventContinuation.yield(.turnComplete(text: lastText))
                return lastText
            }

            var resultBlocks: [ContentBlock] = []
            for use in pendingToolUses {
                let result = await execute(use)
                resultBlocks.append(.toolResult(result))
                eventContinuation.yield(.toolResult(result))
            }
            history.append(Message(role: .user, content: resultBlocks))
        }

        throw SessionError.maxIterationsExceeded(maxIterations)
    }

    private func execute(_ use: ToolUse) async -> ToolResult {
        guard let tool = tools[use.name] else {
            return ToolResult(
                toolUseID: use.id,
                content: "Unknown tool: \(use.name)",
                isError: true
            )
        }
        do {
            let output = try await tool.call(use.input)
            return ToolResult(toolUseID: use.id, content: output)
        } catch let error as ToolError {
            return ToolResult(toolUseID: use.id, content: error.message, isError: true)
        } catch {
            return ToolResult(toolUseID: use.id, content: "\(error)", isError: true)
        }
    }
}
