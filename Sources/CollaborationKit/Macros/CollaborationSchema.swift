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
