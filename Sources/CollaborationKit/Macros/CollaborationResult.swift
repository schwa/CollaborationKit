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
/// 3. Fallback to `String(describing:)`.
///
/// A `Void` return is handled by the macro itself (returns `"OK"`).
public func _ckStringify<T>(_ value: T) throws -> String {
    if let convertible = value as? CollaborationResultConvertible {
        return try convertible.collaborationResultString()
    }
    if let encodable = value as? any Encodable {
        return try _ckEncodeJSON(encodable)
    }
    return String(describing: value)
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
