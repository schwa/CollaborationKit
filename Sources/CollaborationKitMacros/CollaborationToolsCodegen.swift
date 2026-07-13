import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - Codegen

extension CollaborationToolsMacro {
    // MARK: - Tool struct

    static func toolStructDecls(
        for tool: DecodedTool,
        ownerTypeName: String,
        ownerIsActor: Bool
    ) -> [DeclSyntax] {
        let structName = "__CKTool_\(tool.methodName)"

        let inputFields = tool.parameters
            .map { "        let \($0.inputFieldName): \($0.type.swiftTypeSource)" }
            .joined(separator: "\n")

        let schemaSource = jsonSchemaSource(for: tool.parameters)

        let descriptionLiteral = swiftStringLiteral(tool.description)
        let toolNameLiteral = swiftStringLiteral(tool.toolName)
        let approvalLiteral = tool.requiresApproval ? "true" : "false"
        let bodyStmts = callBody(for: tool, ownerIsActor: ownerIsActor)

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

    /// The generated `call(_:)` body: invoke the owner's method with the
    /// right effect keywords, then stringify the result.
    private static func callBody(for tool: DecodedTool, ownerIsActor: Bool) -> String {
        let callArgList = tool.parameters.map { p -> String in
            if let external = p.externalLabel {
                return "\(external): input.\(p.inputFieldName)"
            }
            return "input.\(p.inputFieldName)"
        }
        let callArgs = callArgList.joined(separator: ", ")

        let needsAwait = tool.isAsync || ownerIsActor
        let effectPrefix: String = {
            switch (tool.isThrows, needsAwait) {
            case (true, true):
                return "try await "

            case (true, false):
                return "try "

            case (false, true):
                return "await "

            case (false, false):
                return ""
            }
        }()

        let callExpr = "\(effectPrefix)__owner.\(tool.methodName)(\(callArgs))"

        let lines: [String]
        if tool.returnTypeText == nil {
            lines = [callExpr, #"return "OK""#]
        } else {
            lines = [
                "let __result = \(callExpr)",
                "return try CollaborationKit._ckStringify(__result)"
            ]
        }
        return lines.map { "        " + $0 }.joined(separator: "\n")
    }

    // MARK: - Accessor

    static func collaborationToolsAccessor(for tools: [DecodedTool]) -> DeclSyntax {
        if tools.isEmpty {
            return """
            /// Collaboration tools exposed by this type. Empty because no
            /// members are annotated with `@CollaborationTool`.
            public var collaborationTools: [any CollaborationKit.Tool] { [] }
            """
        }

        let itemList = tools.map { tool in
            "__CKTool_\(tool.methodName)(__owner: self)"
        }
        let items = itemList.joined(separator: ",\n            ")

        return """
        /// Collaboration tools exposed by this type, one per
        /// `@CollaborationTool`-annotated member.
        public var collaborationTools: [any CollaborationKit.Tool] {
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

        let propEntryList = params.map { p in
            let key = swiftStringLiteral(p.externalLabel ?? p.inputFieldName)
            return "\(key): \(p.type.jsonSchemaSource())"
        }
        let propEntries = propEntryList.joined(separator: ", ")

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
            case "\\":
                out += "\\\\"

            case "\"":
                out += "\\\""

            case "\n":
                out += "\\n"

            case "\r":
                out += "\\r"

            case "\t":
                out += "\\t"

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
