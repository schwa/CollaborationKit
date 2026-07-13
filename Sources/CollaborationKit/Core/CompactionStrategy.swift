import Foundation

/// A strategy that trims or transforms a session's conversation history
/// before it is sent to the provider.
///
/// The session invokes ``compact(history:usage:)`` at the top of every model
/// round-trip, so a strategy can react to the accumulated token usage and
/// decide whether to shrink the history. Returning the input unchanged
/// means "no compaction this time".
///
/// ## Token counts, not message counts
///
/// Compaction decisions must be driven by provider-reported token usage,
/// never by message count. Message count is a poor proxy for context-window
/// pressure — a handful of long tool_result blocks can blow the window
/// while many short turns stay well within it. Custom strategies should
/// derive their trigger from ``TokenUsage/inputTokens`` (or an equivalent
/// token source) rather than counting messages.
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

    /// Reports how close the session is to triggering compaction.
    ///
    /// Hosts render this as a "tokens used / budget" chip or progress bar.
    /// Returning `nil` (the default) tells the UI there is no meaningful
    /// budget to show — either the strategy never compacts, or it does not
    /// have a fixed token threshold.
    ///
    /// - Parameter usage: Cumulative token usage across the session so far.
    /// - Returns: The current token count and the strategy's trigger
    ///   threshold, or `nil` if no threshold applies.
    func compactionProgress(usage: TokenUsage) -> CompactionProgress?
}

extension CompactionStrategy {
    public func compactionProgress(usage _: TokenUsage) -> CompactionProgress? {
        nil
    }
}

// MARK: - Progress

/// A snapshot of how close a session is to a compaction event.
///
/// Produced by ``CompactionStrategy/compactionProgress(usage:)``. `current`
/// is the strategy's live measurement (typically ``TokenUsage/inputTokens``)
/// and `limit` is the value at which it will start compacting.
public struct CompactionProgress: Sendable, Equatable {
    /// The current measurement (typically cumulative input tokens).
    public var current: Int

    /// The strategy's trigger threshold.
    public var limit: Int

    public init(current: Int, limit: Int) {
        self.current = current
        self.limit = limit
    }

    /// `current / limit` clamped to `0...1`. `0` when `limit` is non-positive.
    public var fraction: Double {
        guard limit > 0 else { return 0 }
        return min(1, max(0, Double(current) / Double(limit)))
    }
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
///
/// ## Triggering
///
/// Compaction runs once the session's cumulative input tokens
/// (``TokenUsage/inputTokens``, reported by the provider across all
/// completed turns) reach or exceed ``triggerAtTokens``. If there are only
/// ``keepLastTurns`` or fewer turns in the history there is nothing to
/// trim, so compaction is a no-op regardless of the token count.
public struct KeepRecentCompactionStrategy: CompactionStrategy {
    /// The number of trailing turns to keep. Must be at least one.
    public let keepLastTurns: Int

    /// When `true`, the first user message in the history is always kept
    /// (in addition to the trailing turns) so downstream turns can still
    /// see the original task framing.
    public let keepFirstUserMessage: Bool

    /// Compaction runs once the session's cumulative input tokens (as
    /// reported by the provider across all completed turns) reach or
    /// exceed this value.
    ///
    /// Pick a threshold that leaves enough headroom for the next round-
    /// trip below the model's context window — e.g. 70–80% of the window.
    public let triggerAtTokens: Int

    public init(
        keepLastTurns: Int,
        keepFirstUserMessage: Bool = false,
        triggerAtTokens: Int
    ) {
        precondition(keepLastTurns >= 1, "keepLastTurns must be >= 1")
        precondition(triggerAtTokens > 0, "triggerAtTokens must be > 0")
        self.keepLastTurns = keepLastTurns
        self.keepFirstUserMessage = keepFirstUserMessage
        self.triggerAtTokens = triggerAtTokens
    }

    public func compact(history: [Message], usage: TokenUsage) async -> [Message] {
        guard usage.inputTokens >= triggerAtTokens else { return history }

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

    public func compactionProgress(usage: TokenUsage) -> CompactionProgress? {
        CompactionProgress(current: usage.inputTokens, limit: triggerAtTokens)
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
