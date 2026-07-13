@testable import CollaborationKit
import Foundation
import Testing

/// Tests for the requiresApproval metadata on Tool / AnyTool and the
/// `@CollaborationTool("…", requiresApproval:)` argument (#22).

@CollaborationTools
struct ApprovalStore: Sendable {
    @CollaborationTool("Cheap read; no approval needed.")
    func read() -> String { "ok" }

    @CollaborationTool("Destructive; needs approval.", requiresApproval: true)
    func wipe() -> String { "gone" }

    @CollaborationTool("Explicit override wins over prefix.", name: "danger.wipe", requiresApproval: true)
    func alsoWipe() -> String { "also gone" }
}

@Suite("requiresApproval metadata (#22)")
struct RequiresApprovalTests {
    @Test("defaults to false when unspecified")
    func defaultsFalse() {
        let tool = ApprovalStore().collaborationTools.first { $0.name == "read" }
        #expect(tool?.requiresApproval == false)
    }

    @Test("propagates true through the AnyTool wrapper")
    func trueFlowsThroughErasure() {
        let tool = ApprovalStore().collaborationTools.first { $0.name == "wipe" }
        #expect(tool?.requiresApproval == true)
    }

    @Test("combines with explicit name override")
    func combinesWithNameOverride() {
        let tool = ApprovalStore().collaborationTools.first { $0.name == "danger.wipe" }
        #expect(tool?.requiresApproval == true)
    }

    @Test("host can build an approval-required set from a tool list")
    func hostCanBuildRequiredSet() {
        let tools = ApprovalStore().collaborationTools
        let required = Set(tools.filter(\.requiresApproval).map(\.name))
        #expect(required == ["wipe", "danger.wipe"])
    }

    @Test("hand-written Tool without an override defaults to false")
    func handWrittenDefaultsFalse() {
        let erased = BareTool().eraseToAnyTool()
        #expect(erased.requiresApproval == false)
    }
}

/// A minimal hand-written `Tool` with no `requiresApproval` override.
private struct BareTool: Tool {
    struct Input: Decodable, Sendable {}
    var name: String { "bare" }
    var description: String { "" }
    var inputSchema: JSONValue { .object([:]) }
    func call(_: Input) -> String { "" }
}
