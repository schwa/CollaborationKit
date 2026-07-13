import Foundation

/// Turns a type's `@CollaborationTool`-annotated members into a set of
/// ``AnyTool`` values.
///
/// Attaching this macro to a class, struct, or actor generates:
///
/// - A nested `Tool` conformer per annotated member, whose `Input` reflects the
///   member's parameter list and whose `inputSchema` is derived from parameter
///   types.
/// - A `collaborationTools: [AnyTool]` property on the enclosing type that
///   returns one erased tool per annotated member.
///
/// Slice 1 restrictions:
///
/// - The enclosing type must be `Sendable` (or an `actor`).
/// - Parameter types must be one of: `Bool`, `Int`, `Double`, `Float`,
///   `String`, `Optional<T>`, `Array<T>`, `Dictionary<String, T>` where `T`
///   is one of the same, **or** a type conforming to
///   ``CollaborationSchemaConvertible``.
/// - Return types have no such restriction — anything `Encodable` or
///   ``CollaborationResultConvertible`` works.
///
/// ## Nested-object rule
///
/// Split by whether the object has host-side identity:
///
/// - **Referent objects** (a row in a store, a model record, a document):
///   pass an **id** (primitive or ``CollaborationSchemaConvertible`` id
///   wrapper). The tool body looks the value up.
/// - **Value objects** (a point, a range, an options blob): inline via a
///   type conforming to ``CollaborationSchemaConvertible``.
///
/// Decide by asking: does this thing have host-side identity that outlives
/// the call? Yes → id. No → inline. See RFC 0003 for the reasoning.
///
/// See RFC 0003.
@attached(member, names: named(collaborationTools), arbitrary)
public macro CollaborationTools() = #externalMacro(
    module: "CollaborationKitMacros",
    type: "CollaborationToolsMacro"
)

/// Marks a method as a collaboration tool.
///
/// The `description` argument becomes the tool description shown to the model.
/// The tool's name defaults to the Swift method name.
///
/// Must be used inside a type annotated with ``CollaborationTools()``.
@attached(peer)
public macro CollaborationTool(_ description: String) = #externalMacro(
    module: "CollaborationKitMacros",
    type: "CollaborationToolMacro"
)
