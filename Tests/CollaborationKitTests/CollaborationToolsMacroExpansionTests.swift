#if canImport(CollaborationKitMacros)
import CollaborationKitMacros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

/// Assertions against the *expanded source* the macro produces, complementing
/// the runtime tests in ``CollaborationToolsMacroTests``. Runtime tests catch
/// semantic regressions; these catch codegen-shape regressions the runtime
/// path can't see (e.g. a schema literal that changes structure but still
/// happens to parse equal).
///
/// Note: `assertMacroExpansion` runs its expected string through
/// SwiftSyntax's pretty-printer, so expected sources must match the printer's
/// normalized shape — short accessor braces get expanded to multiple lines,
/// the `@CollaborationTool` peer attribute is stripped from the surrounding
/// source, etc.
// swiftlint:disable:next type_body_length
final class CollaborationToolsMacroExpansionTests: XCTestCase {
    private let macros: [String: any Macro.Type] = [
        "CollaborationTools": CollaborationToolsMacro.self,
        "CollaborationTool": CollaborationToolMacro.self
    ]

    // MARK: - Empty type

    func testEmptyTypeGetsEmptyAccessor() {
        assertMacroExpansion(
            """
            @CollaborationTools
            struct Empty {}
            """,
            expandedSource: """
            struct Empty {

                /// Collaboration tools exposed by this type. Empty because no
                /// members are annotated with `@CollaborationTool`.
                public var collaborationTools: [CollaborationKit.AnyTool] {
                    []
                }
            }
            """,
            macros: macros
        )
    }

    // MARK: - Single method

    func testSingleMethodExpansion() {
        assertMacroExpansion(
            """
            @CollaborationTools
            struct S {
                @CollaborationTool("desc")
                func hi(name: String) -> String { name }
            }
            """,
            expandedSource: #"""
            struct S {
                func hi(name: String) -> String { name }

                private struct __CKTool_hi: CollaborationKit.Tool {
                    struct Input: Swift.Decodable, Swift.Sendable {
                        let name: Swift.String
                    }
                    let __owner: S
                    var name: Swift.String {
                        "hi"
                    }
                    var description: Swift.String {
                        "desc"
                    }
                    var inputSchema: CollaborationKit.JSONValue {
                        .object(["type": .string("object"), "properties": .object(["name": .object(["type": .string("string")])]), "required": .array([.string("name")])])
                    }
                    var requiresApproval: Swift.Bool {
                        false
                    }
                    func call(_ input: Input) async throws -> Swift.String {
                        let __result = __owner.hi(name: input.name)
                        return try CollaborationKit._ckStringify(__result)
                    }
                }

                /// Collaboration tools exposed by this type, one per
                /// `@CollaborationTool`-annotated member.
                public var collaborationTools: [CollaborationKit.AnyTool] {
                    [
                        __CKTool_hi(__owner: self).eraseToAnyTool()
                    ]
                }
            }
            """#,
            macros: macros
        )
    }

    // MARK: - Actor emits `await`

    func testActorMemberIsAwaited() {
        assertMacroExpansion(
            """
            @CollaborationTools
            actor Counter {
                @CollaborationTool("bump")
                func bump() -> Int { 0 }
            }
            """,
            expandedSource: #"""
            actor Counter {
                func bump() -> Int { 0 }

                private struct __CKTool_bump: CollaborationKit.Tool {
                    struct Input: Swift.Decodable, Swift.Sendable {

                    }
                    let __owner: Counter
                    var name: Swift.String {
                        "bump"
                    }
                    var description: Swift.String {
                        "bump"
                    }
                    var inputSchema: CollaborationKit.JSONValue {
                        .object(["type": .string("object"), "properties": .object([:])])
                    }
                    var requiresApproval: Swift.Bool {
                        false
                    }
                    func call(_ input: Input) async throws -> Swift.String {
                        let __result = await __owner.bump()
                        return try CollaborationKit._ckStringify(__result)
                    }
                }

                /// Collaboration tools exposed by this type, one per
                /// `@CollaborationTool`-annotated member.
                public var collaborationTools: [CollaborationKit.AnyTool] {
                    [
                        __CKTool_bump(__owner: self).eraseToAnyTool()
                    ]
                }
            }
            """#,
            macros: macros
        )
    }

    // MARK: - throws propagates

    func testThrowingMemberEmitsTry() {
        assertMacroExpansion(
            """
            @CollaborationTools
            struct S {
                @CollaborationTool("d")
                func f() throws -> Int { 0 }
            }
            """,
            expandedSource: #"""
            struct S {
                func f() throws -> Int { 0 }

                private struct __CKTool_f: CollaborationKit.Tool {
                    struct Input: Swift.Decodable, Swift.Sendable {

                    }
                    let __owner: S
                    var name: Swift.String {
                        "f"
                    }
                    var description: Swift.String {
                        "d"
                    }
                    var inputSchema: CollaborationKit.JSONValue {
                        .object(["type": .string("object"), "properties": .object([:])])
                    }
                    var requiresApproval: Swift.Bool {
                        false
                    }
                    func call(_ input: Input) async throws -> Swift.String {
                        let __result = try __owner.f()
                        return try CollaborationKit._ckStringify(__result)
                    }
                }

                /// Collaboration tools exposed by this type, one per
                /// `@CollaborationTool`-annotated member.
                public var collaborationTools: [CollaborationKit.AnyTool] {
                    [
                        __CKTool_f(__owner: self).eraseToAnyTool()
                    ]
                }
            }
            """#,
            macros: macros
        )
    }

    // MARK: - Void return says "OK"

    func testVoidReturnEmitsOK() {
        assertMacroExpansion(
            """
            @CollaborationTools
            struct S {
                @CollaborationTool("d")
                func f() {}
            }
            """,
            expandedSource: #"""
            struct S {
                func f() {}

                private struct __CKTool_f: CollaborationKit.Tool {
                    struct Input: Swift.Decodable, Swift.Sendable {

                    }
                    let __owner: S
                    var name: Swift.String {
                        "f"
                    }
                    var description: Swift.String {
                        "d"
                    }
                    var inputSchema: CollaborationKit.JSONValue {
                        .object(["type": .string("object"), "properties": .object([:])])
                    }
                    var requiresApproval: Swift.Bool {
                        false
                    }
                    func call(_ input: Input) async throws -> Swift.String {
                        __owner.f()
                        return "OK"
                    }
                }

                /// Collaboration tools exposed by this type, one per
                /// `@CollaborationTool`-annotated member.
                public var collaborationTools: [CollaborationKit.AnyTool] {
                    [
                        __CKTool_f(__owner: self).eraseToAnyTool()
                    ]
                }
            }
            """#,
            macros: macros
        )
    }

    // MARK: - Custom-type parameter routes through the escape hatch

    func testCustomTypeParameterRoutesThroughSchemaHatch() {
        assertMacroExpansion(
            """
            @CollaborationTools
            struct S {
                @CollaborationTool("d")
                func f(p: Priority) {}
            }
            """,
            expandedSource: #"""
            struct S {
                func f(p: Priority) {}

                private struct __CKTool_f: CollaborationKit.Tool {
                    struct Input: Swift.Decodable, Swift.Sendable {
                        let p: Priority
                    }
                    let __owner: S
                    var name: Swift.String {
                        "f"
                    }
                    var description: Swift.String {
                        "d"
                    }
                    var inputSchema: CollaborationKit.JSONValue {
                        .object(["type": .string("object"), "properties": .object(["p": Priority.collaborationSchema]), "required": .array([.string("p")])])
                    }
                    var requiresApproval: Swift.Bool {
                        false
                    }
                    func call(_ input: Input) async throws -> Swift.String {
                        __owner.f(p: input.p)
                        return "OK"
                    }
                }

                /// Collaboration tools exposed by this type, one per
                /// `@CollaborationTool`-annotated member.
                public var collaborationTools: [CollaborationKit.AnyTool] {
                    [
                        __CKTool_f(__owner: self).eraseToAnyTool()
                    ]
                }
            }
            """#,
            macros: macros
        )
    }

    // MARK: - Diagnostic on unsupported metatype parameter

    func testUnsupportedParameterTypeDiagnoses() {
        assertMacroExpansion(
            """
            @CollaborationTools
            struct S {
                @CollaborationTool("d")
                func f(t: Any.Type) {}
            }
            """,
            expandedSource: #"""
            struct S {
                func f(t: Any.Type) {}

                /// Collaboration tools exposed by this type. Empty because no
                /// members are annotated with `@CollaborationTool`.
                public var collaborationTools: [CollaborationKit.AnyTool] {
                    []
                }
            }
            """#,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    Unsupported parameter type 'Any.Type'. Slice 1 supports Bool, Int, Double, Float, String, Optional<T>, Array<T>, and [String: T] where T is one of the same. Workarounds: (1) pass a primitive id (e.g. String) and look up the value inside the method — the recommended pattern for referring to host-owned objects; (2) return types have no such restriction — anything Encodable or CollaborationResultConvertible works today. Follow-ups: #21 (nested @CollaborationTools by id), #24 (schema derivation for enums / tuples / generic wrappers), #25 (CollaborationSchemaConvertible escape hatch), #41 (RawRepresentable typed ids).
                    """,
                    line: 4,
                    column: 15
                )
            ],
            macros: macros
        )
    }
}
#endif
