import Foundation

/// A value that can be returned from a `@CollaborationTool` method and
/// stringified for the model.
///
/// Default conformances are provided for `String`, `LosslessStringConvertible`
/// (via ``_CKLossless``), and any `Encodable` value (via ``_CKJSON``). Users
/// wanting custom formatting can conform their own return types directly.
public protocol CollaborationResultConvertible {
    /// The string sent back to the model as the tool result.
    func collaborationResultString() throws -> String
}

extension String: CollaborationResultConvertible {
    public func collaborationResultString() -> String { self }
}

extension Bool: CollaborationResultConvertible {
    public func collaborationResultString() -> String { description }
}

extension Int: CollaborationResultConvertible {
    public func collaborationResultString() -> String { description }
}

extension Double: CollaborationResultConvertible {
    public func collaborationResultString() -> String { description }
}

extension Float: CollaborationResultConvertible {
    public func collaborationResultString() -> String { description }
}

/// Internal shim used by macro-generated code to convert an arbitrary result
/// into a string.
///
/// Preference order:
///
/// 1. `CollaborationResultConvertible` conformance (users' custom types, plus
///    the built-in primitive conformances above).
/// 2. `Encodable` — serialised as JSON.
///
/// Anything else throws ``CollaborationResultError/noKnownFormatter(_:)``.
/// The previous fallback of `String(describing:)` produced
/// Swift-formatted debug output (`NoteRow(id: "n1", title: "Groceries")`)
/// that models cannot reliably parse; failing fast lets the tool loop report
/// an `is_error` result and the caller conform ``CollaborationResultConvertible``
/// or `Encodable` on the return type.
///
/// A `Void` return is handled by the macro itself (returns `"OK"`).
public func _ckStringify<T>(_ value: T) throws -> String {
    if let convertible = value as? CollaborationResultConvertible {
        return try convertible.collaborationResultString()
    }
    if let encodable = value as? any Encodable {
        return try _ckEncodeJSON(encodable)
    }
    throw CollaborationResultError.noKnownFormatter(String(describing: T.self))
}

/// Overload picked when the return type is statically known to be `Encodable`.
///
/// Preferred over the unconstrained generic version whenever the compiler can
/// prove `T: Encodable` at the call site. That lets us encode without a runtime
/// `as? any Encodable` cast, which is unreliable for generic types like
/// `Array<Element>` when the conformance was defined in a different module
/// (Swift issue: dynamic existential casts on conditionally-conforming generic
/// types can fail across module boundaries).
public func _ckStringify<T: Encodable>(_ value: T) throws -> String {
    if let convertible = value as? CollaborationResultConvertible {
        return try convertible.collaborationResultString()
    }
    return try _ckEncodeJSON(value)
}

/// Errors surfaced when a `@CollaborationTool` return value cannot be
/// stringified for the model.
public enum CollaborationResultError: Error, LocalizedError, Sendable {
    /// The return type conforms to neither ``CollaborationResultConvertible``
    /// nor `Encodable`. The associated string is the offending type name.
    case noKnownFormatter(String)

    public var errorDescription: String? {
        switch self {
        case .noKnownFormatter(let typeName):
            return "Return type '\(typeName)' has no known formatter. Conform it to CollaborationResultConvertible or Encodable so the tool result can be sent to the model."
        }
    }
}

private func _ckEncodeJSON(_ value: any Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(_AnyEncodable(value))
    return String(decoding: data, as: UTF8.self)
}

private struct _AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}
