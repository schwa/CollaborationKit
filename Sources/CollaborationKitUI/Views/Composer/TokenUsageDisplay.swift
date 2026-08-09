import CollaborationKit
import Foundation

/// Formatting helpers for the composer's token-usage readouts.
///
/// Pure and view-free so the number formatting and the "is there anything
/// worth showing?" decisions can be unit tested without a view hierarchy.
enum TokenUsageDisplay {
    /// A short human count: `812`, `1.2k`, `3.4M`.
    static func compactCount(_ value: Int) -> String {
        let n = Double(value)
        if abs(n) >= 1_000_000 {
            return String(format: "%.1fM", n / 1_000_000)
        }
        if abs(n) >= 1_000 {
            return String(format: "%.1fk", n / 1_000)
        }
        return "\(value)"
    }

    /// The cache readout, or `nil` when caching hasn't engaged.
    ///
    /// Cache reads are the number users care about (they're the discount),
    /// so they lead. Cache writes only appear when a provider reports them
    /// separately, which today means Anthropic with prompt caching enabled.
    static func cacheLabel(for usage: TokenUsage) -> String? {
        let read = usage.cacheReadInputTokens
        let written = usage.cacheCreationInputTokens
        switch (read > 0, written > 0) {
        case (false, false):
            return nil

        case (true, false):
            return "\(compactCount(read)) cached"

        case (false, true):
            return "\(compactCount(written)) cache write"

        case (true, true):
            return "\(compactCount(read)) cached · \(compactCount(written)) write"
        }
    }

    /// The spelled-out equivalent of ``cacheLabel(for:)`` for VoiceOver:
    /// exact counts, no abbreviations, no separator glyphs.
    static func cacheAccessibilityLabel(for usage: TokenUsage) -> String? {
        let read = usage.cacheReadInputTokens
        let written = usage.cacheCreationInputTokens
        var parts: [String] = []
        if read > 0 {
            parts.append("\(read) tokens read from cache")
        }
        if written > 0 {
            parts.append("\(written) tokens written to cache")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
