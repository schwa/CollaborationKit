import Foundation

/// Bounded exponential-backoff retry policy for transient API failures.
///
/// Applied to Anthropic's OAuth token exchange and the initial HTTP round-trip
/// of streaming provider calls (before any bytes are yielded to consumers, so
/// a mid-turn partial stream is never blindly re-issued).
public struct RetryPolicy: Sendable, Equatable {
    /// Maximum number of attempts, including the first one.
    public var maxAttempts: Int
    /// Delay before the second attempt in seconds. Doubled for each subsequent
    /// attempt, up to ``maxDelay``.
    public var baseDelay: TimeInterval
    /// Cap on the computed backoff delay.
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int, baseDelay: TimeInterval, maxDelay: TimeInterval) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// A sensible default: 3 attempts, 0.5s → 1s → 2s (capped at 8s).
    public static let `default` = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, maxDelay: 8)

    /// Disables retry entirely (1 attempt only).
    public static let none = RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0)

    /// Backoff for the given attempt number (1-indexed). Attempt 1 is the
    /// initial call and returns `0`; subsequent attempts get exponential
    /// delay capped at ``maxDelay``.
    public func backoff(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        let delay = baseDelay * pow(2.0, Double(attempt - 2))
        return min(delay, maxDelay)
    }
}

/// Reasons the transport considers a failure transient enough to retry.
///
/// The provider decides — retries live at the call site, not in this file.
/// This enum names the cases so classifiers stay consistent across providers.
enum RetryReason: Sendable, Equatable {
    /// A non-2xx HTTP status that the API is likely to recover from.
    /// Standard set: 408, 425, 429, 500, 502, 503, 504, plus Anthropic's 529.
    case retryableStatus(Int)
    /// A URLError transport failure (network dropped, DNS, connection lost).
    case transportFailure

    /// Whether a status code should be considered transient / retryable.
    static func isRetryable(status: Int) -> Bool {
        switch status {
        case 408, 425, 429, 500, 502, 503, 504, 529: return true
        default: return false
        }
    }

    /// Whether a `URLError` is one that generally clears on retry (network
    /// blips) rather than a hard misconfiguration.
    static func isRetryable(urlError: URLError) -> Bool {
        switch urlError.code {
        case .timedOut,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .cannotFindHost,
             .resourceUnavailable,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}

/// Parses a `Retry-After` header value (seconds or an HTTP-date), returning
/// the delay in seconds if present and parseable.
func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if let seconds = TimeInterval(trimmed) {
        return max(0, seconds)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    if let date = formatter.date(from: trimmed) {
        return max(0, date.timeIntervalSince(now))
    }
    return nil
}

/// Sleeps for `delay` seconds, honoring Task cancellation. `delay <= 0`
/// returns immediately without a suspension.
func retryDelay(_ delay: TimeInterval) async throws {
    guard delay > 0 else { return }
    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
}
