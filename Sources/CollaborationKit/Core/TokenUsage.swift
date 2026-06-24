import Foundation

/// Token counts reported by a provider for a model response.
///
/// Values are best-effort: providers report what they can, and some local
/// servers omit usage entirely (in which case counts are zero). Counts describe
/// a single turn unless accumulated, e.g. via ``LLMSession/totalUsage``.
public struct TokenUsage: Sendable, Equatable {
    /// Tokens in the request (the prompt and conversation so far).
    public var inputTokens: Int
    /// Tokens generated in the response.
    public var outputTokens: Int
    /// Tokens written to the prompt cache this turn (Anthropic only; billed at a
    /// premium). Zero when caching is unused or unreported.
    public var cacheCreationInputTokens: Int
    /// Tokens read from the prompt cache this turn (Anthropic only; billed at a
    /// discount). Zero when caching is unused or unreported.
    public var cacheReadInputTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0,
        cacheReadInputTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    /// The sum of input and output tokens.
    public var totalTokens: Int {
        inputTokens + outputTokens
    }

    /// Adds two usages component-wise.
    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationInputTokens: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens,
            cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens
        )
    }

    /// Accumulates `other` into this value.
    public static func += (lhs: inout Self, rhs: Self) {
        lhs = lhs + rhs
    }
}
