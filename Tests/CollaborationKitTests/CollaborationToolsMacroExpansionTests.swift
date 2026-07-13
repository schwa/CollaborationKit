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
// swiftlint:disable:next type_body_length
    private let macros: [String: any Macro.Type] = [
// swiftlint:disable:next type_body_length
        "CollaborationTools": CollaborationToolsMacro.self,
// swiftlint:disable:next type_body_length
        "CollaborationTool": CollaborationToolMacro.self
// swiftlint:disable:next type_body_length
    ]
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
    // MARK: - Empty type
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
    func testEmptyTypeGetsEmptyAccessor() {
// swiftlint:disable:next type_body_length
        assertMacroExpansion(
// swiftlint:disable:next type_body_length
            """
// swiftlint:disable:next type_body_length
            @CollaborationTools
// swiftlint:disable:next type_body_length
            struct Empty {}
// swiftlint:disable:next type_body_length
            """,
// swiftlint:disable:next type_body_length
            expandedSource: """
// swiftlint:disable:next type_body_length
            struct Empty {
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
                /// Collaboration tools exposed by this type. Empty because no
// swiftlint:disable:next type_body_length
                /// members are annotated with `@CollaborationTool`.
// swiftlint:disable:next type_body_length
                public var collaborationTools: [CollaborationKit.AnyTool] {
// swiftlint:disable:next type_body_length
                    []
// swiftlint:disable:next type_body_length
                }
// swiftlint:disable:next type_body_length
            }
// swiftlint:disable:next type_body_length
            """,
// swiftlint:disable:next type_body_length
            macros: macros
// swiftlint:disable:next type_body_length
        )
// swiftlint:disable:next type_body_length
    }
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
    // MARK: - Single method
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
    func testSingleMethodExpansion() {
// swiftlint:disable:next type_body_length
        assertMacroExpansion(
// swiftlint:disable:next type_body_length
            """
// swiftlint:disable:next type_body_length
            @CollaborationTools
// swiftlint:disable:next type_body_length
            struct S {
// swiftlint:disable:next type_body_length
                @CollaborationTool("desc")
// swiftlint:disable:next type_body_length
                func hi(name: String) -> String { name }
// swiftlint:disable:next type_body_length
            }
// swiftlint:disable:next type_body_length
            """,
// swiftlint:disable:next type_body_length
            expandedSource: #"""
// swiftlint:disable:next type_body_length
            struct S {
// swiftlint:disable:next type_body_length
                func hi(name: String) -> String { name }
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
                private struct __CKTool_hi: CollaborationKit.Tool {
// swiftlint:disable:next type_body_length
                    struct Input: Swift.Decodable, Swift.Sendable {
// swiftlint:disable:next type_body_length
                        let name: Swift.String
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    let __owner: S
// swiftlint:disable:next type_body_length
                    var name: Swift.String {
// swiftlint:disable:next type_body_length
                        "hi"
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    var description: Swift.String {
// swiftlint:disable:next type_body_length
                        "desc"
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    var inputSchema: CollaborationKit.JSONValue {
// swiftlint:disable:next type_body_length
                        .object(["type": .string("object"), "properties": .object(["name": .object(["type": .string("string")])]), "required": .array([.string("name")])])
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    var requiresApproval: Swift.Bool {
// swiftlint:disable:next type_body_length
                        false
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    func call(_ input: Input) async throws -> Swift.String {
// swiftlint:disable:next type_body_length
                        let __result = __owner.hi(name: input.name)
// swiftlint:disable:next type_body_length
                        return try CollaborationKit._ckStringify(__result)
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                }
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
                /// Collaboration tools exposed by this type, one per
// swiftlint:disable:next type_body_length
                /// `@CollaborationTool`-annotated member.
// swiftlint:disable:next type_body_length
                public var collaborationTools: [CollaborationKit.AnyTool] {
// swiftlint:disable:next type_body_length
                    [
// swiftlint:disable:next type_body_length
                        __CKTool_hi(__owner: self).eraseToAnyTool()
// swiftlint:disable:next type_body_length
                    ]
// swiftlint:disable:next type_body_length
                }
// swiftlint:disable:next type_body_length
            }
// swiftlint:disable:next type_body_length
            """#,
// swiftlint:disable:next type_body_length
            macros: macros
// swiftlint:disable:next type_body_length
        )
// swiftlint:disable:next type_body_length
    }
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
    // MARK: - Actor emits `await`
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
    func testActorMemberIsAwaited() {
// swiftlint:disable:next type_body_length
        assertMacroExpansion(
// swiftlint:disable:next type_body_length
            """
// swiftlint:disable:next type_body_length
            @CollaborationTools
// swiftlint:disable:next type_body_length
            actor Counter {
// swiftlint:disable:next type_body_length
                @CollaborationTool("bump")
// swiftlint:disable:next type_body_length
                func bump() -> Int { 0 }
// swiftlint:disable:next type_body_length
            }
// swiftlint:disable:next type_body_length
            """,
// swiftlint:disable:next type_body_length
            expandedSource: #"""
// swiftlint:disable:next type_body_length
            actor Counter {
// swiftlint:disable:next type_body_length
                func bump() -> Int { 0 }
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
                private struct __CKTool_bump: CollaborationKit.Tool {
// swiftlint:disable:next type_body_length
                    struct Input: Swift.Decodable, Swift.Sendable {
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    let __owner: Counter
// swiftlint:disable:next type_body_length
                    var name: Swift.String {
// swiftlint:disable:next type_body_length
                        "bump"
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    var description: Swift.String {
// swiftlint:disable:next type_body_length
                        "bump"
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    var inputSchema: CollaborationKit.JSONValue {
// swiftlint:disable:next type_body_length
                        .object(["type": .string("object"), "properties": .object([:])])
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    var requiresApproval: Swift.Bool {
// swiftlint:disable:next type_body_length
                        false
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    func call(_ input: Input) async throws -> Swift.String {
// swiftlint:disable:next type_body_length
                        let __result = await __owner.bump()
// swiftlint:disable:next type_body_length
                        return try CollaborationKit._ckStringify(__result)
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                }
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
                /// Collaboration tools exposed by this type, one per
// swiftlint:disable:next type_body_length
                /// `@CollaborationTool`-annotated member.
// swiftlint:disable:next type_body_length
                public var collaborationTools: [CollaborationKit.AnyTool] {
// swiftlint:disable:next type_body_length
                    [
// swiftlint:disable:next type_body_length
                        __CKTool_bump(__owner: self).eraseToAnyTool()
// swiftlint:disable:next type_body_length
                    ]
// swiftlint:disable:next type_body_length
                }
// swiftlint:disable:next type_body_length
            }
// swiftlint:disable:next type_body_length
            """#,
// swiftlint:disable:next type_body_length
            macros: macros
// swiftlint:disable:next type_body_length
        )
// swiftlint:disable:next type_body_length
    }
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
    // MARK: - throws propagates
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
    func testThrowingMemberEmitsTry() {
// swiftlint:disable:next type_body_length
        assertMacroExpansion(
// swiftlint:disable:next type_body_length
            """
// swiftlint:disable:next type_body_length
            @CollaborationTools
// swiftlint:disable:next type_body_length
            struct S {
// swiftlint:disable:next type_body_length
                @CollaborationTool("d")
// swiftlint:disable:next type_body_length
                func f() throws -> Int { 0 }
// swiftlint:disable:next type_body_length
            }
// swiftlint:disable:next type_body_length
            """,
// swiftlint:disable:next type_body_length
            expandedSource: #"""
// swiftlint:disable:next type_body_length
            struct S {
// swiftlint:disable:next type_body_length
                func f() throws -> Int { 0 }
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
                private struct __CKTool_f: CollaborationKit.Tool {
// swiftlint:disable:next type_body_length
                    struct Input: Swift.Decodable, Swift.Sendable {
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    let __owner: S
// swiftlint:disable:next type_body_length
                    var name: Swift.String {
// swiftlint:disable:next type_body_length
                        "f"
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    var description: Swift.String {
// swiftlint:disable:next type_body_length
                        "d"
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    var inputSchema: CollaborationKit.JSONValue {
// swiftlint:disable:next type_body_length
                        .object(["type": .string("object"), "properties": .object([:])])
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    var requiresApproval: Swift.Bool {
// swiftlint:disable:next type_body_length
                        false
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    func call(_ input: Input) async throws -> Swift.String {
// swiftlint:disable:next type_body_length
                        let __result = try __owner.f()
// swiftlint:disable:next type_body_length
                        return try CollaborationKit._ckStringify(__result)
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                }
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
                /// Collaboration tools exposed by this type, one per
// swiftlint:disable:next type_body_length
                /// `@CollaborationTool`-annotated member.
// swiftlint:disable:next type_body_length
                public var collaborationTools: [CollaborationKit.AnyTool] {
// swiftlint:disable:next type_body_length
                    [
// swiftlint:disable:next type_body_length
                        __CKTool_f(__owner: self).eraseToAnyTool()
// swiftlint:disable:next type_body_length
                    ]
// swiftlint:disable:next type_body_length
                }
// swiftlint:disable:next type_body_length
            }
// swiftlint:disable:next type_body_length
            """#,
// swiftlint:disable:next type_body_length
            macros: macros
// swiftlint:disable:next type_body_length
        )
// swiftlint:disable:next type_body_length
    }
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
    // MARK: - Void return says "OK"
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
    func testVoidReturnEmitsOK() {
// swiftlint:disable:next type_body_length
        assertMacroExpansion(
// swiftlint:disable:next type_body_length
            """
// swiftlint:disable:next type_body_length
            @CollaborationTools
// swiftlint:disable:next type_body_length
            struct S {
// swiftlint:disable:next type_body_length
                @CollaborationTool("d")
// swiftlint:disable:next type_body_length
                func f() {}
// swiftlint:disable:next type_body_length
            }
// swiftlint:disable:next type_body_length
            """,
// swiftlint:disable:next type_body_length
            expandedSource: #"""
// swiftlint:disable:next type_body_length
            struct S {
// swiftlint:disable:next type_body_length
                func f() {}
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
                private struct __CKTool_f: CollaborationKit.Tool {
// swiftlint:disable:next type_body_length
                    struct Input: Swift.Decodable, Swift.Sendable {
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    let __owner: S
// swiftlint:disable:next type_body_length
                    var name: Swift.String {
// swiftlint:disable:next type_body_length
                        "f"
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    var description: Swift.String {
// swiftlint:disable:next type_body_length
                        "d"
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    var inputSchema: CollaborationKit.JSONValue {
// swiftlint:disable:next type_body_length
                        .object(["type": .string("object"), "properties": .object([:])])
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    var requiresApproval: Swift.Bool {
// swiftlint:disable:next type_body_length
                        false
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    func call(_ input: Input) async throws -> Swift.String {
// swiftlint:disable:next type_body_length
                        __owner.f()
// swiftlint:disable:next type_body_length
                        return "OK"
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                }
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
                /// Collaboration tools exposed by this type, one per
// swiftlint:disable:next type_body_length
                /// `@CollaborationTool`-annotated member.
// swiftlint:disable:next type_body_length
                public var collaborationTools: [CollaborationKit.AnyTool] {
// swiftlint:disable:next type_body_length
                    [
// swiftlint:disable:next type_body_length
                        __CKTool_f(__owner: self).eraseToAnyTool()
// swiftlint:disable:next type_body_length
                    ]
// swiftlint:disable:next type_body_length
                }
// swiftlint:disable:next type_body_length
            }
// swiftlint:disable:next type_body_length
            """#,
// swiftlint:disable:next type_body_length
            macros: macros
// swiftlint:disable:next type_body_length
        )
// swiftlint:disable:next type_body_length
    }
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
    // MARK: - Custom-type parameter routes through the escape hatch
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
    func testCustomTypeParameterRoutesThroughSchemaHatch() {
// swiftlint:disable:next type_body_length
        assertMacroExpansion(
// swiftlint:disable:next type_body_length
            """
// swiftlint:disable:next type_body_length
            @CollaborationTools
// swiftlint:disable:next type_body_length
            struct S {
// swiftlint:disable:next type_body_length
                @CollaborationTool("d")
// swiftlint:disable:next type_body_length
                func f(p: Priority) {}
// swiftlint:disable:next type_body_length
            }
// swiftlint:disable:next type_body_length
            """,
// swiftlint:disable:next type_body_length
            expandedSource: #"""
// swiftlint:disable:next type_body_length
            struct S {
// swiftlint:disable:next type_body_length
                func f(p: Priority) {}
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
                private struct __CKTool_f: CollaborationKit.Tool {
// swiftlint:disable:next type_body_length
                    struct Input: Swift.Decodable, Swift.Sendable {
// swiftlint:disable:next type_body_length
                        let p: Priority
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    let __owner: S
// swiftlint:disable:next type_body_length
                    var name: Swift.String {
// swiftlint:disable:next type_body_length
                        "f"
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    var description: Swift.String {
// swiftlint:disable:next type_body_length
                        "d"
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    var inputSchema: CollaborationKit.JSONValue {
// swiftlint:disable:next type_body_length
                        .object(["type": .string("object"), "properties": .object(["p": Priority.collaborationSchema]), "required": .array([.string("p")])])
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    var requiresApproval: Swift.Bool {
// swiftlint:disable:next type_body_length
                        false
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                    func call(_ input: Input) async throws -> Swift.String {
// swiftlint:disable:next type_body_length
                        __owner.f(p: input.p)
// swiftlint:disable:next type_body_length
                        return "OK"
// swiftlint:disable:next type_body_length
                    }
// swiftlint:disable:next type_body_length
                }
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
                /// Collaboration tools exposed by this type, one per
// swiftlint:disable:next type_body_length
                /// `@CollaborationTool`-annotated member.
// swiftlint:disable:next type_body_length
                public var collaborationTools: [CollaborationKit.AnyTool] {
// swiftlint:disable:next type_body_length
                    [
// swiftlint:disable:next type_body_length
                        __CKTool_f(__owner: self).eraseToAnyTool()
// swiftlint:disable:next type_body_length
                    ]
// swiftlint:disable:next type_body_length
                }
// swiftlint:disable:next type_body_length
            }
// swiftlint:disable:next type_body_length
            """#,
// swiftlint:disable:next type_body_length
            macros: macros
// swiftlint:disable:next type_body_length
        )
// swiftlint:disable:next type_body_length
    }
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
    // MARK: - Diagnostic on unsupported metatype parameter
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
    func testUnsupportedParameterTypeDiagnoses() {
// swiftlint:disable:next type_body_length
        assertMacroExpansion(
// swiftlint:disable:next type_body_length
            """
// swiftlint:disable:next type_body_length
            @CollaborationTools
// swiftlint:disable:next type_body_length
            struct S {
// swiftlint:disable:next type_body_length
                @CollaborationTool("d")
// swiftlint:disable:next type_body_length
                func f(t: Any.Type) {}
// swiftlint:disable:next type_body_length
            }
// swiftlint:disable:next type_body_length
            """,
// swiftlint:disable:next type_body_length
            expandedSource: #"""
// swiftlint:disable:next type_body_length
            struct S {
// swiftlint:disable:next type_body_length
                func f(t: Any.Type) {}
// swiftlint:disable:next type_body_length

// swiftlint:disable:next type_body_length
                /// Collaboration tools exposed by this type. Empty because no
// swiftlint:disable:next type_body_length
                /// members are annotated with `@CollaborationTool`.
// swiftlint:disable:next type_body_length
                public var collaborationTools: [CollaborationKit.AnyTool] {
// swiftlint:disable:next type_body_length
                    []
// swiftlint:disable:next type_body_length
                }
// swiftlint:disable:next type_body_length
            }
// swiftlint:disable:next type_body_length
            """#,
// swiftlint:disable:next type_body_length
            diagnostics: [
// swiftlint:disable:next type_body_length
                DiagnosticSpec(
// swiftlint:disable:next type_body_length
                    message: """
// swiftlint:disable:next type_body_length
                    Unsupported parameter type 'Any.Type'. Slice 1 supports Bool, Int, Double, Float, String, Optional<T>, Array<T>, and [String: T] where T is one of the same. Workarounds: (1) pass a primitive id (e.g. String) and look up the value inside the method — the recommended pattern for referring to host-owned objects; (2) return types have no such restriction — anything Encodable or CollaborationResultConvertible works today. Follow-ups: #21 (nested @CollaborationTools by id), #24 (schema derivation for enums / tuples / generic wrappers), #25 (CollaborationSchemaConvertible escape hatch), #41 (RawRepresentable typed ids).
// swiftlint:disable:next type_body_length
                    """,
// swiftlint:disable:next type_body_length
                    line: 4,
// swiftlint:disable:next type_body_length
                    column: 15
// swiftlint:disable:next type_body_length
                )
// swiftlint:disable:next type_body_length
            ],
// swiftlint:disable:next type_body_length
            macros: macros
// swiftlint:disable:next type_body_length
        )
// swiftlint:disable:next type_body_length
    }
// swiftlint:disable:next type_body_length
}
// swiftlint:disable:next type_body_length
#endif
// swiftlint:disable:next type_body_length
