@testable import CollaborationKit
@testable import CollaborationKitUI
import Foundation
import Testing

/// Tests for the composer's token-usage readouts (#116).
@Suite("TokenUsageDisplay (#116)")
struct TokenUsageDisplayTests {
    @Test("compact counts abbreviate at thousands and millions")
    func compactCounts() {
        #expect(TokenUsageDisplay.compactCount(0) == "0")
        #expect(TokenUsageDisplay.compactCount(812) == "812")
        #expect(TokenUsageDisplay.compactCount(1_200) == "1.2k")
        #expect(TokenUsageDisplay.compactCount(3_400_000) == "3.4M")
    }

    @Test("no cache readout when caching hasn't engaged")
    func noCacheLabelWithoutCaching() {
        let usage = TokenUsage(inputTokens: 500, outputTokens: 100)
        #expect(TokenUsageDisplay.cacheLabel(for: usage) == nil)
        #expect(TokenUsageDisplay.cacheAccessibilityLabel(for: usage) == nil)
    }

    @Test("cache reads are surfaced on their own")
    func cacheReadsOnly() {
        let usage = TokenUsage(inputTokens: 500, cacheReadInputTokens: 2_500)
        #expect(TokenUsageDisplay.cacheLabel(for: usage) == "2.5k cached")
        #expect(TokenUsageDisplay.cacheAccessibilityLabel(for: usage) == "2500 tokens read from cache")
    }

    @Test("cache writes are surfaced on their own")
    func cacheWritesOnly() {
        let usage = TokenUsage(inputTokens: 500, cacheCreationInputTokens: 900)
        #expect(TokenUsageDisplay.cacheLabel(for: usage) == "900 cache write")
        #expect(TokenUsageDisplay.cacheAccessibilityLabel(for: usage) == "900 tokens written to cache")
    }

    @Test("reads and writes are shown together")
    func cacheReadsAndWrites() {
        let usage = TokenUsage(cacheCreationInputTokens: 900, cacheReadInputTokens: 2_500)
        #expect(TokenUsageDisplay.cacheLabel(for: usage) == "2.5k cached · 900 write")
        #expect(
            TokenUsageDisplay.cacheAccessibilityLabel(for: usage)
                == "2500 tokens read from cache, 900 tokens written to cache"
        )
    }
}
