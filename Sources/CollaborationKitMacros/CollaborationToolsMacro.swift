import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

public enum CollaborationToolsMacro: MemberMacro {
    public static func expansion(
        of attribute: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let ownerInfo = try enclosingTypeInfo(from: declaration, context: context)
        let prefix = prefixArgument(from: attribute)

        let tools = annotatedMethods(in: declaration, context: context, prefix: prefix)

        // Emit even when empty, so the accessor exists and the user's site
        // compiles predictably.
        var decls: [DeclSyntax] = []

        for tool in tools {
            decls.append(contentsOf: toolStructDecls(
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
        let isMainActor = hasMainActorAttribute(declaration.attributes)
        if let cls = declaration.as(ClassDeclSyntax.self) {
            return OwnerInfo(name: cls.name.text, isActor: isMainActor)
        }
        if let str = declaration.as(StructDeclSyntax.self) {
            return OwnerInfo(name: str.name.text, isActor: isMainActor)
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

    /// Detects `@MainActor` (or a qualified spelling like `Swift.MainActor`)
    /// among the attributes on the enclosing type.
    private static func hasMainActorAttribute(_ attributes: AttributeListSyntax) -> Bool {
        for attr in attributes {
            guard let a = attr.as(AttributeSyntax.self) else { continue }
            let name = a.attributeName.trimmedDescription
            if name == "MainActor" || name.hasSuffix(".MainActor") { return true }
        }
        return false
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

    /// Decodes the parameter list of one annotated method, or throws
    /// ``MacroFailure/diagnosed`` after diagnosing when any parameter type
    /// is unsupported.
    private static func decodedParameters(
        of signature: FunctionSignatureSyntax,
        context: some MacroExpansionContext
    ) throws -> [DecodedParameter] {
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
            } catch {
                hadUnsupported = true
            }
        }
        if hadUnsupported { throw MacroFailure.diagnosed }
        return parameters
    }

    private static func annotatedMethods(
        in declaration: some DeclGroupSyntax,
        context: some MacroExpansionContext,
        prefix: String?
    ) -> [DecodedTool] {
        var results: [DecodedTool] = []

        for member in declaration.memberBlock.members {
            guard let fn = member.decl.as(FunctionDeclSyntax.self) else { continue }
            guard let (attr, attrDescription) = collaborationToolAttribute(on: fn) else { continue }

            // Explicit attribute string wins. Otherwise, mine the method's
            // `///` doc comment. If neither exists, diagnose.
            let description: String
            if let attrDescription {
                description = attrDescription
            } else if let mined = docCommentSummary(of: fn) {
                description = mined
            } else {
                context.diagnose(Diagnostic(
                    node: Syntax(attr),
                    message: MacroDiagnostic.missingDescription
                ))
                continue
            }

            let signature = fn.signature

            guard let parameters = try? decodedParameters(of: signature, context: context) else { continue }

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

    /// Locates the `@CollaborationTool` attribute on `fn`, and extracts the
    /// literal description passed as its first (unlabeled) positional
    /// argument, if any. Returns `nil` when the attribute isn't present.
    /// Returns `(attr, nil)` when the attribute is present but no positional
    /// description literal was supplied — caller falls back to doc-comment
    /// mining.
    private static func collaborationToolAttribute(
        on fn: FunctionDeclSyntax
    ) -> (AttributeSyntax, String?)? {
        for attr in fn.attributes {
            guard let a = attr.as(AttributeSyntax.self) else { continue }
            let name = a.attributeName.trimmedDescription
            guard name == "CollaborationTool" || name.hasSuffix(".CollaborationTool") else {
                continue
            }
            // `@CollaborationTool` (no parens) or `@CollaborationTool(name: ...)`
            // both leave the description unset.
            guard case .argumentList(let args) = a.arguments,
                  let first = args.first,
                  first.label == nil,
                  let literal = first.expression.as(StringLiteralExprSyntax.self),
                  let value = literal.representedLiteralValue else {
                return (a, nil)
            }
            return (a, value)
        }
        return nil
    }

    /// Extracts a plain-text summary from `fn`'s leading `///` or `/** */`
    /// doc comments. Stops at the first blank doc-comment line or DocC
    /// keyword line (`- Parameter`, `- Returns:`, etc.), so parameter and
    /// return docs don't leak into the tool description.
    private static func docCommentSummary(of fn: FunctionDeclSyntax) -> String? {
        let rawLines = docCommentLines(from: fn.leadingTrivia)

        return summarize(rawLines)
    }

    /// Reduces `trivia` to a flat list of doc-comment lines. A non-doc,
    /// non-whitespace trivia piece resets the run so only the doc comment
    /// immediately attached to the decl contributes.
    private static func docCommentLines(from trivia: Trivia) -> [String] {
        var lines: [String] = []
        for piece in trivia {
            if let line = docLineCommentBody(piece) {
                lines.append(line)
            } else if case .docBlockComment = piece {
                lines.append(contentsOf: docBlockCommentLines(piece))
            } else if isIgnorableTrivia(piece) {
                continue
            } else {
                lines.removeAll()
            }
        }
        return lines
    }

    private static func docLineCommentBody(_ piece: TriviaPiece) -> String? {
        guard case .docLineComment(let text) = piece else { return nil }
        var body = Substring(text)
        if body.hasPrefix("///") { body = body.dropFirst(3) }
        if body.first == " " { body = body.dropFirst() }
        return String(body)
    }

    private static func docBlockCommentLines(_ piece: TriviaPiece) -> [String] {
        guard case .docBlockComment(let text) = piece else { return [] }
        var body = Substring(text)
        if body.hasPrefix("/**") { body = body.dropFirst(3) }
        if body.hasSuffix("*/") { body = body.dropLast(2) }
        return body.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var l = String(line).trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("*") { l.removeFirst() }
            return l.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func isIgnorableTrivia(_ piece: TriviaPiece) -> Bool {
        switch piece {
        case .newlines, .spaces, .tabs, .carriageReturns, .carriageReturnLineFeeds:
            return true

        default:
            return false
        }
    }

    private static func summarize(_ rawLines: [String]) -> String? {
        let stopPrefixes = [
            "- Parameter", "- Parameters", "- Returns:", "- Throws:",
            "- Note:", "- Important:", "- Warning:", "# ", "## "
        ]
        var summary: [String] = []
        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if stopPrefixes.contains(where: { trimmed.hasPrefix($0) }) { break }
            summary.append(trimmed)
        }

        let joined = summary.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
    }
}

// MARK: - Diagnostics

enum MacroFailure: Error {
    case diagnosed
}

struct MacroDiagnostic: DiagnosticMessage {
    static let notAType = Self(
        message: "@CollaborationTools can only be attached to a class, struct, or actor.",
        diagnosticID: MessageID(domain: "CollaborationKitMacros", id: "notAType"),
        severity: .error
    )

    static let missingDescription = Self(
        message: "@CollaborationTool needs a description — pass one as the first argument, or add a `///` doc comment above the method.",
        diagnosticID: MessageID(domain: "CollaborationKitMacros", id: "missingDescription"),
        severity: .error
    )

    static func unsupportedType(_ description: String) -> Self {
        Self(
            message: description,
            diagnosticID: MessageID(domain: "CollaborationKitMacros", id: "unsupportedType"),
            severity: .error
        )
    }

    /// A tailored diagnostic for an unsupported parameter type, pointing at
    /// the concrete workarounds available today and the follow-up work that
    /// will eventually cover it.
    static func unsupportedInputType(_ typeName: String) -> Self {
        let message = """
        Unsupported parameter type '\(typeName)'. \
        Slice 1 supports Bool, Int, Double, Float, String, Optional<T>, Array<T>, and [String: T] where T is one of the same. \
        Workarounds: \
        (1) pass a primitive id (e.g. String) and look up the value inside the method — the recommended pattern for referring to host-owned objects; \
        (2) return types have no such restriction — anything Encodable or CollaborationResultConvertible works today. \
        Follow-ups: #21 (nested @CollaborationTools by id), #24 (schema derivation for enums / tuples / generic wrappers), #25 (CollaborationSchemaConvertible escape hatch), #41 (RawRepresentable typed ids).
        """
        return Self(
            message: message,
            diagnosticID: MessageID(domain: "CollaborationKitMacros", id: "unsupportedInputType"),
            severity: .error
        )
    }

    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity
}
