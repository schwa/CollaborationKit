@testable import CollaborationKit
import Foundation
import Testing

/// Unit tests for the retry policy + Retry-After parsing. Behaviour on the
/// wire (transport / OAuth) is exercised in the transport-specific suites.
struct RetryTests {
    // MARK: RetryPolicy.backoff

    @Test
    func backoffZeroForFirstAttempt() {
        let policy = RetryPolicy.default
        #expect(policy.backoff(forAttempt: 1) == 0)
    }

    @Test
    func backoffExponentialUpToCap() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 0.5, maxDelay: 8)
        #expect(policy.backoff(forAttempt: 2) == 0.5)
        #expect(policy.backoff(forAttempt: 3) == 1.0)
        #expect(policy.backoff(forAttempt: 4) == 2.0)
        #expect(policy.backoff(forAttempt: 5) == 4.0)
    }

    @Test
    func backoffCapsAtMaxDelay() {
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: 1, maxDelay: 3)
        #expect(policy.backoff(forAttempt: 6) == 3)
        #expect(policy.backoff(forAttempt: 100) == 3)
    }

    // MARK: RetryReason classification

    @Test
    func retryableStatusCodesIncludeStandardTransientErrors() {
        for status in [408, 425, 429, 500, 502, 503, 504, 529] {
            #expect(RetryReason.isRetryable(status: status), "expected \(status) retryable")
        }
    }

    @Test
    func nonTransientStatusesAreNotRetryable() {
        for status in [400, 401, 403, 404, 501] {
            #expect(!RetryReason.isRetryable(status: status), "expected \(status) not retryable")
        }
    }

    // MARK: Retry-After parsing

    @Test
    func retryAfterSecondsFormatParses() {
        #expect(parseRetryAfter("5") == 5)
        #expect(parseRetryAfter("  12  ") == 12)
        #expect(parseRetryAfter("0") == 0)
    }

    @Test
    func retryAfterHTTPDateParsesToRelativeDelay() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 60 seconds after `now`.
        let future = now.addingTimeInterval(60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: future)

        let delay = parseRetryAfter(header, now: now)
        #expect(delay != nil)
        // Allow one second of drift for formatter/round-trip.
        #expect(abs((delay ?? 0) - 60) < 1)
    }

    @Test
    func retryAfterMissingOrGarbageIsNil() {
        #expect(parseRetryAfter(nil) == nil)
        #expect(parseRetryAfter("nonsense") == nil)
    }

    @Test
    func retryAfterPastDateClampsToZero() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let past = now.addingTimeInterval(-3_600)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        #expect(parseRetryAfter(formatter.string(from: past), now: now) == 0)
    }
}
