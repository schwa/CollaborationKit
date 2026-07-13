import Foundation

/// Escape hatch for using custom types as `@CollaborationTool` parameters.
///
/// Slice 1's built-in schema derivation only handles primitives and their
/// collections (`Bool`, `Int`, `Double`, `Float`, `String`, `Optional<T>`,
/// `Array<T>`, `[String: T]`). Conform a type to
/// ``CollaborationSchemaConvertible`` to teach the macro how to route it —
/// the type must be `Decodable` (so the generated `Input` struct can decode
/// it from the model's JSON) and supply a static JSON Schema fragment.
///
/// ```swift
/// enum Priority: String, CollaborationSchemaConvertible {
///     case low, medium, high
///     static var collaborationSchema: JSONValue {
///         .object([
///             "type": .string("string"),
///             "enum": .array([.string("low"), .string("medium"), .string("high")])
///         ])
///     }
/// }
///
/// @CollaborationTools
/// final class TaskStore {
///     @CollaborationTool("Create a task with a priority.")
///     func create(title: String, priority: Priority) async -> String { ... }
/// }
/// ```
///
/// Related:
/// - RFC 0003 open question 1 (schema fidelity).
/// - Follow-up issues: nested-object handling (#21), typed IDs (#41),
///   built-in derivation for enums/tuples (#24).
public protocol CollaborationSchemaConvertible: Decodable, Sendable {
    /// The JSON Schema fragment describing this type. Sent to the model as
    /// part of the tool spec so it knows how to shape the value.
    static var collaborationSchema: JSONValue { get }
}

/// A raw value type that has a built-in JSON Schema, used by
/// ``CollaborationSchemaConvertible``'s automatic conformance for typed IDs.
///
/// Conforming ``RawValue`` types are ``String``, ``Int``, ``Double``,
/// ``Float``, ``Bool``. A caller-declared `RawRepresentable` id wrapper
/// gets its schema for free.
public protocol CollaborationRawValue: Sendable {
    /// The JSON Schema for values of this raw type.
    static var collaborationRawSchema: JSONValue { get }
}

extension String: CollaborationRawValue {
    public static var collaborationRawSchema: JSONValue {
        .object(["type": .string("string")])
    }
}

extension Int: CollaborationRawValue {
    public static var collaborationRawSchema: JSONValue {
        .object(["type": .string("integer")])
    }
}

extension Double: CollaborationRawValue {
    public static var collaborationRawSchema: JSONValue {
        .object(["type": .string("number")])
    }
}

extension Float: CollaborationRawValue {
    public static var collaborationRawSchema: JSONValue {
        .object(["type": .string("number")])
    }
}

extension Bool: CollaborationRawValue {
    public static var collaborationRawSchema: JSONValue {
        .object(["type": .string("boolean")])
    }
}

/// Default schema for `RawRepresentable` id wrappers.
///
/// Conform a typed id (e.g. `struct NoteID: RawRepresentable, Codable`) to
/// ``CollaborationSchemaConvertible`` and its ``collaborationSchema`` is
/// synthesized from ``RawValue`` — no boilerplate:
///
/// ```swift
/// struct NoteID: RawRepresentable, Codable, CollaborationSchemaConvertible, Hashable {
///     let rawValue: String
/// }
///
/// @CollaborationTool("Delete the note with this id.")
/// func delete(id: NoteID) async throws { ... }
/// ```
extension CollaborationSchemaConvertible
where Self: RawRepresentable, Self.RawValue: CollaborationRawValue {
    public static var collaborationSchema: JSONValue {
        RawValue.collaborationRawSchema
    }
}
