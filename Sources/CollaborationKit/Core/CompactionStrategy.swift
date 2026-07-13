import Foundation

/// A strategy that trims or transforms a session's conversation history
/// before it is sent to the provider.
///
/// The session invokes ``compact(history:usage:)`` at the top of every model
/// round-trip, so a strategy can react to the current message count or
/// accumulated usage and decide whether to shrink the history. Returning the
/// input unchanged means "no compaction this time".
///
/// ## Preserving message validity
///
/// The domain shape keeps each tool call together with its result inside a
/// single assistant message (see ``ContentBlock/toolCall(_:)``), so the
/// wire-format pairing between `tool_use` and `tool_result` cannot be broken
/// by dropping a whole message.
///
/// The provider wire protocols do, however, require a valid message
/// sequence (typically strict user/assistant alternation with all assistant
/// messages between two user messages belonging to the same turn). The
/// built-in ``KeepRecentCompactionStrategy`` groups messages into turns and
/// trims whole turns to preserve that shape; custom strategies must do the
/// same or they will break the next provider call.
public protocol CompactionStrategy: Sendable {
    /// Returns a possibly-compacted history to replace the session's
    /// current history. Return the input unchanged to skip compaction.
    ///
    /// - Parameters:
    ///   - history: The session's current message history.
    ///   - usage: Cumulative token usage across the session so far.
    /// - Returns: The new history. Must be provider-valid (whole turns only;
    ///   see the protocol overview).
    func compact(history: [Message], usage: TokenUsage) async -> [Message]
}

// MARK: - No-op

/// The default compaction strategy: never compacts. Preserves the pre-#7
/// behavior for callers that don't opt into compaction.
public struct NoCompactionStrategy: CompactionStrategy {
    public init() {}
    public func compact(history: [Message], usage _: TokenUsage) async -> [Message] {
        history
    }
}

// MARK: - Keep-recent

/// A drop-oldest-turns strategy that keeps the most recent `keepLastTurns`
/// user/assistant turns intact, optionally pinning the first user message
/// as long-lived "task setup" context.
///
/// A *turn* is one user message plus every assistant message that follows
/// it up to the next user message — this matches how the session appends
/// messages, and it means dropping whole turns preserves the alternating
/// shape the providers expect.
public struct KeepRecentCompactionStrategy: CompactionStrategy {
    /// The number of trailing turns to keep. Must be at least one.
    public let keepLastTurns: Int

    /// When `true`, the first user message in the history is always kept
    /// (in addition to the trailing turns) so downstream turns can still
    /// see the original task framing.
    public let keepFirstUserMessage: Bool

    /// Minimum message count before compaction runs. Useful to avoid
    /// churning the history on short conversations. Defaults to the same
    /// number of messages the strategy would leave behind after a trim,
    /// so compaction is a no-op until it would actually shorten anything.
    public let minMessagesBeforeCompacting: Int

    public init(
        keepLastTurns: Int,
        keepFirstUserMessage: Bool = false,
        minMessagesBeforeCompacting: Int? = nil
    ) {
        precondition(keepLastTurns >= 1, "keepLastTurns must be >= 1")
        self.keepLastTurns = keepLastTurns
        self.keepFirstUserMessage = keepFirstUserMessage
        // Rough lower bound: at least `keepLastTurns * 2` messages before
        // there's anything worth dropping.
        self.minMessagesBeforeCompacting = minMessagesBeforeCompacting ?? (keepLastTurns * 2)
    }

    public func compact(history: [Message], usage _: TokenUsage) async -> [Message] {
        guard history.count > minMessagesBeforeCompacting else { return history }

        let turns = Self.groupIntoTurns(history)
        guard turns.count > keepLastTurns else { return history }

        let trailing = Array(turns.suffix(keepLastTurns).joined())

        // Pin the very first user message if requested — the "task setup"
        // prompt often anchors the whole conversation for the model, and
        // dropping it silently changes the model's understanding.
        if keepFirstUserMessage,
           let firstUser = history.first(where: { $0.role == .user }),
           !trailing.contains(where: { $0.id == firstUser.id })
        {
            return [firstUser] + trailing
        }

        return trailing
    }

    /// Splits a message history into turn groups. A turn begins at each
    /// user message and includes every immediately-following assistant
    /// message. Messages that appear before the first user message (rare,
    /// but not impossible) form a leading group of their own so they
    /// aren't silently discarded by the split.
    static func groupIntoTurns(_ history: [Message]) -> [[Message]] {
        var turns: [[Message]] = []
        var current: [Message] = []
        for message in history {
            if message.role == .user && !current.isEmpty {
                turns.append(current)
                current = [message]
            } else {
                current.append(message)
            }
        }
        if !current.isEmpty {
            turns.append(current)
        }
        return turns
    }
}
