@testable import CollaborationKit
import Foundation
import Testing

/// End-to-end tests for the escape hatch: a user-declared type conforming to
/// ``CollaborationSchemaConvertible`` can be used as a
/// ``@CollaborationTool`` parameter, its schema flows through the tool spec,
/// and JSON input decodes into it at call time.

// MARK: - Fixtures

/// String-backed enum acting as a typed enum parameter.
enum EscapePriority: String, CollaborationSchemaConvertible, Equatable {
    case low
    case medium
    case high

    static var collaborationSchema: JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array([.string("low"), .string("medium"), .string("high")])
        ])
    }
}

/// Struct with a bespoke schema, exercising the object-shaped custom case.
struct EscapePoint: CollaborationSchemaConvertible, Equatable {
    let x: Int
    let y: Int

    static var collaborationSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "x": .object(["type": .string("integer")]),
                "y": .object(["type": .string("integer")])
            ]),
            "required": .array([.string("x"), .string("y")])
        ])
    }
}

@CollaborationTools
final class EscapeStore: @unchecked Sendable {
    private(set) var lastPriority: EscapePriority?
    private(set) var lastPoint: EscapePoint?

    @CollaborationTool("Record a priority.")
    func setPriority(_ p: EscapePriority) -> String {
        lastPriority = p
        return p.rawValue
    }

    @CollaborationTool("Record a point.")
    func setPoint(_ point: EscapePoint) -> String {
        lastPoint = point
        return "\(point.x),\(point.y)"
    }
}

// MARK: - Tests

@Suite("CollaborationSchemaConvertible escape hatch")
struct CollaborationSchemaConvertibleTests {

    // MARK: Schema

    @Test("enum parameter uses the type's collaborationSchema")
    func enumSchemaPassesThrough() {
        let store = EscapeStore()
        let tool = store.collaborationTools.first { $0.name == "setPriority" }!
        #expect(tool.inputSchema == .object([
            "type": .string("object"),
            "properties": .object([
                "p": EscapePriority.collaborationSchema
            ]),
            "required": .array([.string("p")])
        ]))
    }

    @Test("struct parameter uses the type's collaborationSchema")
    func structSchemaPassesThrough() {
        let store = EscapeStore()
        let tool = store.collaborationTools.first { $0.name == "setPoint" }!
        #expect(tool.inputSchema == .object([
            "type": .string("object"),
            "properties": .object([
                "point": EscapePoint.collaborationSchema
            ]),
            "required": .array([.string("point")])
        ]))
    }

    // MARK: Runtime dispatch

    @Test("decodes an enum argument from JSON and forwards it")
    func decodesAndDispatchesEnum() async throws {
        let store = EscapeStore()
        let tool = store.collaborationTools.first { $0.name == "setPriority" }!
        let out = try await tool.call(.object(["p": .string("high")]))
        #expect(out == "high")
        #expect(store.lastPriority == .high)
    }

    @Test("decodes a struct argument from JSON and forwards it")
    func decodesAndDispatchesStruct() async throws {
        let store = EscapeStore()
        let tool = store.collaborationTools.first { $0.name == "setPoint" }!
        let out = try await tool.call(.object(["point": .object([
            "x": .number(3),
            "y": .number(4)
        ])]))
        #expect(out == "3,4")
        #expect(store.lastPoint == EscapePoint(x: 3, y: 4))
    }
}
