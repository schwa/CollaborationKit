import Foundation

/// The outcome of reading a value from the Keychain.
///
/// Distinguishes a genuinely missing item (`.notFound`) from a transient or
/// permission-related failure (`.failed`). Callers that collapse both into
/// `nil` risk treating a Keychain that isn't currently readable (e.g. right
/// after login, `errSecInteractionNotAllowed`) as an unset credential — the
/// user then sees a "no key" state that clears the field on the next save.
public enum KeychainReadResult: Equatable, Sendable {
    /// The item exists and its UTF-8 value was decoded successfully.
    case found(String)

    /// No item exists for the requested account.
    case notFound

    /// The Keychain returned an error other than "not found".
    ///
    /// The associated `OSStatus` is the raw code from `SecItemCopyMatching`.
    /// Use `KeychainReadResult.message(for:)` for a human-readable summary.
    case failed(OSStatus)

    /// Convenience: the string value, or `nil` for `.notFound` / `.failed`.
    ///
    /// Prefer switching on the case when you need to distinguish "no key" from
    /// "couldn't read the key right now".
    public var value: String? {
        if case .found(let value) = self { return value }
        return nil
    }

    /// A short human-readable description for a `.failed` status.
    public static func message(for status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "unknown Keychain error (status \(status))"
    }
}
