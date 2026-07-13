import SwiftSyntax

/// A structural description of a Swift type sufficient to emit both a JSON
/// Schema fragment and a Swift type expression usable in the generated
/// `Input` struct.
enum ParamType {
    case bool
    case int
    case double
    case float
    case string
    indirect case optional(ParamType)
    indirect case array(ParamType)
    indirect case stringDictionary(ParamType)
    /// A user-declared type routed through
    /// ``CollaborationSchemaConvertible``. The associated string is the
    /// user's spelling of the type (used verbatim as both the Swift type and
    /// the source of the runtime schema lookup).
    case custom(String)

    /// The Swift source spelling to use inside the generated `Input` struct.
    var swiftTypeSource: String {
        switch self {
        case .bool: return "Swift.Bool"
        case .int: return "Swift.Int"
        case .double: return "Swift.Double"
        case .float: return "Swift.Float"
        case .string: return "Swift.String"
        case .optional(let inner): return "\(inner.swiftTypeSource)?"
        case .array(let inner): return "[\(inner.swiftTypeSource)]"
        case .stringDictionary(let inner): return "[Swift.String: \(inner.swiftTypeSource)]"
        case .custom(let name): return name
        }
    }

    /// A JSON Schema fragment (as a Swift source expression building a
    /// `CollaborationKit.JSONValue`) describing this type.
    ///
    /// Wraps `Optional` transparently — required-ness is tracked separately at
    /// the parameter level.
    func jsonSchemaSource() -> String {
        switch self {
        case .bool:
            return #".object(["type": .string("boolean")])"#
        case .int:
            return #".object(["type": .string("integer")])"#
        case .double, .float:
            return #".object(["type": .string("number")])"#
        case .string:
            return #".object(["type": .string("string")])"#
        case .optional(let inner):
            return inner.jsonSchemaSource()
        case .array(let inner):
            return #".object(["type": .string("array"), "items": \#(inner.jsonSchemaSource())])"#
        case .stringDictionary(let inner):
            return #".object(["type": .string("object"), "additionalProperties": \#(inner.jsonSchemaSource())])"#
        case .custom(let name):
            // Runtime lookup: the type supplies its own schema via
            // `CollaborationSchemaConvertible`. If the type doesn't conform,
            // the generated code fails to compile at the call site — the
            // exact error the user needs to see.
            return "\(name).collaborationSchema"
        }
    }

    var isOptional: Bool {
        if case .optional = self { return true }
        return false
    }
}

enum SchemaDerivationError: Error, CustomStringConvertible {
    case unsupportedType(String)

    /// The offending type name, for constructing tailored diagnostics.
    var typeName: String {
        switch self {
        case .unsupportedType(let name):
            return name
        }
    }

    var description: String {
        switch self {
        case .unsupportedType(let name):
            return "Unsupported parameter/return type: \(name). Slice 1 supports Bool, Int, Double, Float, String, Optional, Array, and [String: T] where T is one of the same."
        }
    }
}

/// Parses a `TypeSyntax` into a ``ParamType``. Throws
/// ``SchemaDerivationError`` for anything unsupported in Slice 1.
func parseParamType(_ type: TypeSyntax) throws -> ParamType {
    // Optional<T>, T?
    if let opt = type.as(OptionalTypeSyntax.self) {
        return .optional(try parseParamType(opt.wrappedType))
    }
    if let impl = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
        return .optional(try parseParamType(impl.wrappedType))
    }

    // [T]
    if let arr = type.as(ArrayTypeSyntax.self) {
        return .array(try parseParamType(arr.element))
    }

    // [K: V]
    if let dict = type.as(DictionaryTypeSyntax.self) {
        let key = try parseParamType(dict.key)
        guard case .string = key else {
            throw SchemaDerivationError.unsupportedType(type.trimmedDescription)
        }
        return .stringDictionary(try parseParamType(dict.value))
    }

    // Identifier — including generic forms like Optional<T>, Array<T>,
    // Dictionary<String, T>.
    if let ident = type.as(IdentifierTypeSyntax.self) {
        let name = ident.name.text
        if let generics = ident.genericArgumentClause {
            let args = generics.arguments.map(\.argument).compactMap { TypeSyntax($0) }
            switch name {
            case "Optional":
                guard args.count == 1 else {
                    throw SchemaDerivationError.unsupportedType(type.trimmedDescription)
                }
                return .optional(try parseParamType(args[0]))
            case "Array":
                guard args.count == 1 else {
                    throw SchemaDerivationError.unsupportedType(type.trimmedDescription)
                }
                return .array(try parseParamType(args[0]))
            case "Dictionary":
                guard args.count == 2 else {
                    throw SchemaDerivationError.unsupportedType(type.trimmedDescription)
                }
                let key = try parseParamType(args[0])
                guard case .string = key else {
                    throw SchemaDerivationError.unsupportedType(type.trimmedDescription)
                }
                return .stringDictionary(try parseParamType(args[1]))
            default:
                break
            }
        }

        switch name {
        case "Bool", "Swift.Bool": return .bool
        case "Int", "Swift.Int": return .int
        case "Double", "Swift.Double": return .double
        case "Float", "Swift.Float": return .float
        case "String", "Swift.String": return .string
        default:
            // Escape hatch (#25): assume the user's type conforms to
            // CollaborationSchemaConvertible. If it doesn't, the generated
            // Tool struct fails to compile at `<Type>.collaborationSchema`
            // — exactly the error message the user needs to see.
            return .custom(type.trimmedDescription)
        }
    }

    // Nested / dotted names like `Note.ID` — treat as an opaque custom type
    // and route through the CollaborationSchemaConvertible escape hatch.
    if type.is(MemberTypeSyntax.self) {
        return .custom(type.trimmedDescription)
    }

    // Metatypes, function types, existentials, etc.: still unsupported.
    throw SchemaDerivationError.unsupportedType(type.trimmedDescription)
}

/// One decoded parameter, ready to be lowered into an `Input` field and
/// forwarded at the call site.
struct DecodedParameter {
    /// External (argument) label as seen at the call site.
    let externalLabel: String?
    /// The identifier used for the `Input` struct field and forwarding.
    let inputFieldName: String
    let type: ParamType
}

/// One `@CollaborationTool`-annotated method, decomposed for lowering.
struct DecodedTool {
    let methodName: String
    let toolName: String
    let description: String
    let parameters: [DecodedParameter]
    let isAsync: Bool
    let isThrows: Bool
    /// Return type text (`nil` for `Void`).
    let returnTypeText: String?
}
