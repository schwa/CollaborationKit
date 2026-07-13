import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

public enum CollaborationToolsMacro: MemberMacro {
    public static func expansion(
        of attribute: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let ownerInfo = try enclosingTypeInfo(from: declaration, context: context)
        let prefix = prefixArgument(from: attribute)

        let tools = try annotatedMethods(in: declaration, context: context, prefix: prefix)

        // Emit even when empty — the accessor should exist so the user's site
        // compiles predictably.
        var decls: [DeclSyntax] = []

        for tool in tools {
            decls.append(contentsOf: try toolStructDecls(
                for: tool,
                ownerTypeName: ownerInfo.name,
                ownerIsActor: ownerInfo.isActor
            ))
        }

        decls.append(collaborationToolsAccessor(for: tools))

        return decls
    }

    // MARK: - Enclosing type

    private struct OwnerInfo {
        let name: String
        let isActor: Bool
    }

    private static func enclosingTypeInfo(
        from declaration: some DeclGroupSyntax,
        context: some MacroExpansionContext
    ) throws -> OwnerInfo {
        if let cls = declaration.as(ClassDeclSyntax.self) {
            return OwnerInfo(name: cls.name.text, isActor: false)
        }
        if let str = declaration.as(StructDeclSyntax.self) {
            return OwnerInfo(name: str.name.text, isActor: false)
        }
        if let act = declaration.as(ActorDeclSyntax.self) {
            return OwnerInfo(name: act.name.text, isActor: true)
        }
        context.diagnose(Diagnostic(
            node: Syntax(declaration),
            message: MacroDiagnostic.notAType
        ))
        throw MacroFailure.diagnosed
    }

    // MARK: - Attribute arguments

    /// Extracts the `prefix:` argument from `@CollaborationTools(prefix: "…")`,
    /// or `nil` when the caller passed no prefix (or an empty string).
    private static func prefixArgument(from attribute: AttributeSyntax) -> String? {
        guard case .argumentList(let args) = attribute.arguments else { return nil }
        for arg in args where arg.label?.text == "prefix" {
            if let literal = arg.expression.as(StringLiteralExprSyntax.self),
               let value = literal.representedLiteralValue,
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Extracts the `name:` argument from `@CollaborationTool("…", name: "…")`,
    /// or `nil` when the caller passed no explicit name.
    private static func nameArgument(from attribute: AttributeSyntax) -> String? {
        guard case .argumentList(let args) = attribute.arguments else { return nil }
        for arg in args where arg.label?.text == "name" {
            if let literal = arg.expression.as(StringLiteralExprSyntax.self),
               let value = literal.representedLiteralValue,
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Extracts the `requiresApproval:` boolean argument from
    /// `@CollaborationTool("…", requiresApproval: true)`, or `false` when
    /// omitted.
    private static func requiresApprovalArgument(from attribute: AttributeSyntax) -> Bool {
        guard case .argumentList(let args) = attribute.arguments else { return false }
        for arg in args where arg.label?.text == "requiresApproval" {
            if let literal = arg.expression.as(BooleanLiteralExprSyntax.self) {
                return literal.literal.text == "true"
            }
        }
        return false
    }

    // MARK: - Discovery

    private static func annotatedMethods(
        in declaration: some DeclGroupSyntax,
        context: some MacroExpansionContext,
        prefix: String?
    ) throws -> [DecodedTool] {
        var results: [DecodedTool] = []

        for member in declaration.memberBlock.members {
            guard let fn = member.decl.as(FunctionDeclSyntax.self) else { continue }
            guard let (attr, description) = collaborationToolAttribute(on: fn) else { continue }

            let signature = fn.signature

            var parameters: [DecodedParameter] = []
            var hadUnsupported = false
            for param in signature.parameterClause.parameters {
                do {
                    let type = try parseParamType(param.type)
                    let external: String? = {
                        let text = param.firstName.text
                        return text == "_" ? nil : text
                    }()
                    let fieldName: String = {
                        if let second = param.secondName?.text {
                            return second
                        }
                        return param.firstName.text
                    }()
                    parameters.append(DecodedParameter(
                        externalLabel: external,
                        inputFieldName: fieldName,
                        type: type
                    ))
                } catch let error as SchemaDerivationError {
                    context.diagnose(Diagnostic(
                        node: Syntax(param.type),
                        message: MacroDiagnostic.unsupportedInputType(error.typeName)
                    ))
                    hadUnsupported = true
                }
            }
            if hadUnsupported { continue }

            let effects = signature.effectSpecifiers
            let isAsync = effects?.asyncSpecifier != nil
            let isThrows = effects?.throwsClause != nil

            let returnText: String?
            if let ret = signature.returnClause?.type {
                let trimmed = ret.trimmedDescription
                returnText = (trimmed == "Void" || trimmed == "()") ? nil : trimmed
            } else {
                returnText = nil
            }

            // Explicit `name:` on the per-method attribute wins outright.
            // Otherwise: if the enclosing type declared a `prefix:`, join it
            // to the method name with an underscore. Bare Swift method name
            // is the fallback.
            let toolName: String = {
                if let override = nameArgument(from: attr) { return override }
                if let prefix { return "\(prefix)_\(fn.name.text)" }
                return fn.name.text
            }()

            results.append(DecodedTool(
                methodName: fn.name.text,
                toolName: toolName,
                description: description,
                parameters: parameters,
                isAsync: isAsync,
                isThrows: isThrows,
                returnTypeText: returnText,
                requiresApproval: requiresApprovalArgument(from: attr)
            ))
        }

        return results
    }

    private static func collaborationToolAttribute(
        on fn: FunctionDeclSyntax
    ) -> (AttributeSyntax, String)? {
        for attr in fn.attributes {
            guard let a = attr.as(AttributeSyntax.self) else { continue }
            let name = a.attributeName.trimmedDescription
            guard name == "CollaborationTool" || name.hasSuffix(".CollaborationTool") else {
                continue
            }
            guard case .argumentList(let args) = a.arguments,
                  let first = args.first,
                  let literal = first.expression.as(StringLiteralExprSyntax.self),
                  let value = literal.representedLiteralValue else {
                continue
            }
            return (a, value)
        }
        return nil
    }

    // MARK: - Codegen: tool struct

    private static func toolStructDecls(
        for tool: DecodedTool,
        ownerTypeName: String,
        ownerIsActor: Bool
    ) throws -> [DeclSyntax] {
        let structName = "__CKTool_\(tool.methodName)"

        // Input struct body
        let inputFields = tool.parameters
            .map { "        let \($0.inputFieldName): \($0.type.swiftTypeSource)" }
            .joined(separator: "\n")

        // JSON schema
        let schemaSource = jsonSchemaSource(for: tool.parameters)

        // Forwarding call
        let callArgs = tool.parameters.map { p -> String in
            if let external = p.externalLabel {
                return "\(external): input.\(p.inputFieldName)"
            } else {
                return "input.\(p.inputFieldName)"
            }
        }.joined(separator: ", ")

        let needsAwait = tool.isAsync || ownerIsActor
        let effectPrefix: String = {
            switch (tool.isThrows, needsAwait) {
            case (true, true): return "try await "
            case (true, false): return "try "
            case (false, true): return "await "
            case (false, false): return ""
            }
        }()

        let callExpr = "\(effectPrefix)__owner.\(tool.methodName)(\(callArgs))"

        let bodyStmts: String
        if tool.returnTypeText == nil {
            bodyStmts = """
                    \(callExpr)
                    return "OK"
            """
        } else {
            bodyStmts = """
                    let __result = \(callExpr)
                    return try CollaborationKit._ckStringify(__result)
            """
        }

        let descriptionLiteral = swiftStringLiteral(tool.description)
        let toolNameLiteral = swiftStringLiteral(tool.toolName)
        let approvalLiteral = tool.requiresApproval ? "true" : "false"

        let decl: DeclSyntax = """
        private struct \(raw: structName): CollaborationKit.Tool {
            struct Input: Swift.Decodable, Swift.Sendable {
        \(raw: inputFields)
            }
            let __owner: \(raw: ownerTypeName)
            var name: Swift.String { \(raw: toolNameLiteral) }
            var description: Swift.String { \(raw: descriptionLiteral) }
            var inputSchema: CollaborationKit.JSONValue { \(raw: schemaSource) }
            var requiresApproval: Swift.Bool { \(raw: approvalLiteral) }
            func call(_ input: Input) async throws -> Swift.String {
        \(raw: bodyStmts)
            }
        }
        """
        return [decl]
    }

    // MARK: - Codegen: accessor

    private static func collaborationToolsAccessor(for tools: [DecodedTool]) -> DeclSyntax {
        if tools.isEmpty {
            return """
            /// Collaboration tools exposed by this type. Empty because no
            /// members are annotated with `@CollaborationTool`.
            public var collaborationTools: [CollaborationKit.AnyTool] { [] }
            """
        }

        let items = tools.map { tool in
            "__CKTool_\(tool.methodName)(__owner: self).eraseToAnyTool()"
        }.joined(separator: ",\n            ")

        return """
        /// Collaboration tools exposed by this type, one per
        /// `@CollaborationTool`-annotated member.
        public var collaborationTools: [CollaborationKit.AnyTool] {
            [
                \(raw: items)
            ]
        }
        """
    }

    // MARK: - JSON schema for parameter list

    private static func jsonSchemaSource(for params: [DecodedParameter]) -> String {
        if params.isEmpty {
            return #".object(["type": .string("object"), "properties": .object([:])])"#
        }

        let propEntries = params.map { p in
            let key = swiftStringLiteral(p.externalLabel ?? p.inputFieldName)
            return "\(key): \(p.type.jsonSchemaSource())"
        }.joined(separator: ", ")

        let required = params.compactMap { p -> String? in
            guard !p.type.isOptional else { return nil }
            return swiftStringLiteral(p.externalLabel ?? p.inputFieldName)
        }

        if required.isEmpty {
            return #".object(["type": .string("object"), "properties": .object([\#(propEntries)])])"#
        }

        let requiredList = required.map { ".string(\($0))" }.joined(separator: ", ")
        return #".object(["type": .string("object"), "properties": .object([\#(propEntries)]), "required": .array([\#(requiredList)])])"#
    }

    // MARK: - Helpers

    private static func swiftStringLiteral(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u{%04x}", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

// MARK: - Diagnostics

enum MacroFailure: Error {
    case diagnosed
}

struct MacroDiagnostic: DiagnosticMessage {
    static let notAType = MacroDiagnostic(
        message: "@CollaborationTools can only be attached to a class, struct, or actor.",
        diagnosticID: MessageID(domain: "CollaborationKitMacros", id: "notAType"),
        severity: .error
    )

    static func unsupportedType(_ description: String) -> MacroDiagnostic {
        MacroDiagnostic(
            message: description,
            diagnosticID: MessageID(domain: "CollaborationKitMacros", id: "unsupportedType"),
            severity: .error
        )
    }

    /// A tailored diagnostic for an unsupported parameter type, pointing at
    /// the concrete workarounds available today and the follow-up work that
    /// will eventually cover it.
    static func unsupportedInputType(_ typeName: String) -> MacroDiagnostic {
        let message = """
        Unsupported parameter type '\(typeName)'. \
        Slice 1 supports Bool, Int, Double, Float, String, Optional<T>, Array<T>, and [String: T] where T is one of the same. \
        Workarounds: \
        (1) pass a primitive id (e.g. String) and look up the value inside the method — the recommended pattern for referring to host-owned objects; \
        (2) return types have no such restriction — anything Encodable or CollaborationResultConvertible works today. \
        Follow-ups: #21 (nested @CollaborationTools by id), #24 (schema derivation for enums / tuples / generic wrappers), #25 (CollaborationSchemaConvertible escape hatch), #41 (RawRepresentable typed ids).
        """
        return MacroDiagnostic(
            message: message,
            diagnosticID: MessageID(domain: "CollaborationKitMacros", id: "unsupportedInputType"),
            severity: .error
        )
    }

    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity
}
