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
/// - Parameter and return types must be one of: `Bool`, `Int`, `Double`,
///   `Float`, `String`, `Optional<T>`, `Array<T>`, or
///   `Dictionary<String, T>` where `T` is one of the same.
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
