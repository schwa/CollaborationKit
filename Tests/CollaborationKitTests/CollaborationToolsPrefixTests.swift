@testable import CollaborationKit
import Foundation
import Testing

// Tests for tool-name prefixing (`@CollaborationTools(prefix: …)`) and
// per-tool name overrides (`@CollaborationTool("…", name: "…")`) — the
// collision-handling knobs added by #20.

// MARK: - Fixtures

@CollaborationTools
struct PrefixDefault: Sendable {
    @CollaborationTool("Do a thing.")
    func doIt() -> Int { 1 }
}

@CollaborationTools(prefix: "Notes")
struct PrefixApplied: Sendable {
    @CollaborationTool("Create a note.")
    func create() -> Int { 1 }

    @CollaborationTool("List notes.")
    func list() -> Int { 2 }
}

@CollaborationTools(prefix: "Tasks")
struct PrefixWithOverride: Sendable {
    @CollaborationTool("Create a task.")
    func create() -> Int { 1 }

    // The explicit name wins over the type prefix.
    @CollaborationTool("Delete a task by id.", name: "tasks.delete")
    func delete() -> Int { 2 }
}

@CollaborationTools
struct EmptyPrefixIsNil: Sendable {
    // Emulates a caller who passed an empty string; treated the same as
    // omitting the prefix.
    @CollaborationTool("Ping.")
    func ping() -> Int { 1 }
}

// MARK: - Tests

@Suite("Tool-name prefixing / override (#20)")
struct CollaborationToolsPrefixTests {
    @Test("without prefix, the tool name is the Swift method name")
    func defaultsToBareMethodName() {
        let names = PrefixDefault().collaborationTools.map(\.name).sorted()
        #expect(names == ["doIt"])
    }

    @Test("prefix: joins each method name with an underscore")
    func prefixJoinsWithUnderscore() {
        let names = PrefixApplied().collaborationTools.map(\.name).sorted()
        #expect(names == ["Notes_create", "Notes_list"])
    }

    @Test("per-attribute name: overrides both the method name and the prefix")
    func explicitNameOverridesPrefix() {
        let names = PrefixWithOverride().collaborationTools.map(\.name).sorted()
        // `create` still picks up the prefix; `delete` uses the explicit
        // "tasks.delete" and ignores the type-level prefix entirely.
        #expect(names == ["Tasks_create", "tasks.delete"])
    }
}
