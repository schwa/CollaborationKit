@testable import CollaborationKit
import Foundation
import Testing

// End-to-end tests: attach `@CollaborationTools` to a Sendable actor, verify
// the generated `collaborationTools` accessor produces `AnyTool`s with the
// right names, descriptions, schemas, and runtime behaviour.

// MARK: - Fixtures

/// A stateful model object exposing a small mix of tool kinds.
@CollaborationTools
final class NoteStore: @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [String: String] = [:]
    private var order: [String] = []

    init() {}

    @CollaborationTool("List all notes as \"id: title\" lines, oldest first.")
    func list() -> String {
        lock.lock(); defer { lock.unlock() }
        return order.map { "\($0): \(notes[$0] ?? "")" }.joined(separator: "\n")
    }

    @CollaborationTool("Create a new note. Returns the note's id.")
    func create(title: String, body: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let id = "n\(order.count + 1)"
        notes[id] = title + (body.isEmpty ? "" : " — " + body)
        order.append(id)
        return id
    }

    @CollaborationTool("Delete the note with this id. Errors if it doesn't exist.")
    func delete(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard notes.removeValue(forKey: id) != nil else {
            throw ToolError("no note with id \(id)")
        }
        order.removeAll { $0 == id }
    }

    @CollaborationTool("Return the total number of notes.")
    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return notes.count
    }

    // Not exposed — no attribute.
    func housekeeping() {}
}

/// Fixture for doc-comment mining: `@CollaborationTool` with no description
/// argument should fall back to the leading `///` doc comment. An explicit
/// string still wins over the doc comment.
@CollaborationTools
struct DocMined: Sendable {
    /// Return a friendly greeting.
    @CollaborationTool
    func hello() -> String { "hi" }

    /// Summary line only.
    ///
    /// This paragraph and any `- Parameter` blocks must not leak into the
    /// tool description.
    ///
    /// - Parameter name: unused.
    /// - Returns: nothing useful.
    @CollaborationTool
    func onlySummary(name: String) -> String { name }

    /// Doc comment loses to the explicit attribute string.
    @CollaborationTool("Explicit wins.")
    func overridden() -> String { "" }
}

/// Actor variant: exercises the actor-isolation code path (macro must emit
/// `await` when the enclosing type is an actor).
@CollaborationTools
actor Counter {
    private var value: Int = 0

    @CollaborationTool("Increment by a given amount and return the new value.")
    func increment(by amount: Int) -> Int {
        value += amount
        return value
    }

    @CollaborationTool("Read the current value.")
    func read() -> Int { value }
}

/// Exercises all supported parameter kinds: primitives, optionals, arrays,
/// and `[String: T]` dictionaries.
@CollaborationTools
struct TypeCoverage: Sendable {
    @CollaborationTool("All supported types in one method.")
    // swiftlint:disable:next function_parameter_count
    func mix(
        flag: Bool,
        n: Int,
        d: Double,
        s: String,
        maybe: String?,
        list: [Int],
        table: [String: Double]
    ) -> String {
        "\(flag)|\(n)|\(d)|\(s)|\(maybe ?? "nil")|\(list.count)|\(table.count)"
    }
}

// MARK: - Tests

@Suite("CollaborationTools macro")
struct CollaborationToolsMacroTests {
    // MARK: Discovery + accessor

    @Test("exposes exactly the annotated methods")
    func exposesAnnotatedMethods() {
        let store = NoteStore()
        let names = store.collaborationTools.map(\.name).sorted()
        #expect(names == ["count", "create", "delete", "list"])
    }

    @Test("passes through the attribute description")
    func passesDescription() {
        let store = NoteStore()
        let list = store.collaborationTools.first { $0.name == "list" }
        #expect(list?.description == "List all notes as \"id: title\" lines, oldest first.")
    }

    @Test("mines the tool description from the method's /// doc comment")
    func minesDocComment() {
        let mined = DocMined()
        let hello = mined.collaborationTools.first { $0.name == "hello" }
        #expect(hello?.description == "Return a friendly greeting.")
    }

    @Test("doc-comment mining stops at the first blank line or DocC keyword")
    func minesSummaryOnly() {
        let mined = DocMined()
        let summary = mined.collaborationTools.first { $0.name == "onlySummary" }
        #expect(summary?.description == "Summary line only.")
    }

    @Test("explicit description wins over the doc comment")
    func explicitDescriptionWins() {
        let mined = DocMined()
        let overridden = mined.collaborationTools.first { $0.name == "overridden" }
        #expect(overridden?.description == "Explicit wins.")
    }

    // MARK: Schema

    @Test("no-arg tool emits empty properties schema")
    func emptySchema() {
        let store = NoteStore()
        let list = store.collaborationTools.first { $0.name == "list" }!
        #expect(list.inputSchema == .object([
            "type": .string("object"),
            "properties": .object([:])
        ]))
    }

    @Test("two-string schema lists both as required")
    func twoStringSchema() {
        let store = NoteStore()
        let create = store.collaborationTools.first { $0.name == "create" }!
        #expect(create.inputSchema == .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string")]),
                "body": .object(["type": .string("string")])
            ]),
            "required": .array([.string("title"), .string("body")])
        ]))
    }

    @Test("all supported types map to the expected schema")
    func fullSchema() {
        let cov = TypeCoverage()
        let mix = cov.collaborationTools.first { $0.name == "mix" }!
        #expect(mix.inputSchema == .object([
            "type": .string("object"),
            "properties": .object([
                "flag": .object(["type": .string("boolean")]),
                "n": .object(["type": .string("integer")]),
                "d": .object(["type": .string("number")]),
                "s": .object(["type": .string("string")]),
                "maybe": .object(["type": .string("string")]),
                "list": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("integer")])
                ]),
                "table": .object([
                    "type": .string("object"),
                    "additionalProperties": .object(["type": .string("number")])
                ])
            ]),
            // `maybe` is Optional → not required.
            "required": .array([
                .string("flag"),
                .string("n"),
                .string("d"),
                .string("s"),
                .string("list"),
                .string("table")
            ])
        ]))
    }

    // MARK: Runtime call — non-throwing, non-async

    @Test("call forwards args and stringifies the result")
    func callForwardsArgs() async throws {
        let store = NoteStore()
        let create = store.collaborationTools.first { $0.name == "create" }!
        let id = try await create.call(.object([
            "title": .string("Groceries"),
            "body": .string("milk, eggs")
        ]))
        #expect(id == "n1")

        let count = store.collaborationTools.first { $0.name == "count" }!
        let n = try await count.call(.object([:]))
        #expect(n == "1")

        let list = store.collaborationTools.first { $0.name == "list" }!
        let listing = try await list.call(.object([:]))
        #expect(listing == "n1: Groceries — milk, eggs")
    }

    // MARK: Runtime call — throwing

    @Test("thrown ToolError bubbles out of call")
    func throwPropagates() async {
        let store = NoteStore()
        let delete = store.collaborationTools.first { $0.name == "delete" }!
        await #expect(throws: ToolError.self) {
            _ = try await delete.call(.object(["id": .string("nope")]))
        }
    }

    @Test("Void return is stringified as \"OK\"")
    func voidReturnsOK() async throws {
        let store = NoteStore()
        _ = try await store.collaborationTools.first { $0.name == "create" }!
            .call(.object([
                "title": .string("t"),
                "body": .string("b")
            ]))
        let delete = store.collaborationTools.first { $0.name == "delete" }!
        let result = try await delete.call(.object(["id": .string("n1")]))
        #expect(result == "OK")
    }

    // MARK: Actor path

    @Test("actor-isolated methods are called via await")
    func actorCall() async throws {
        let counter = Counter()
        let tools = await counter.collaborationTools
        let inc = tools.first { $0.name == "increment" }!
        let read = tools.first { $0.name == "read" }!

        let r1 = try await inc.call(.object(["amount": .number(3)]))
        #expect(r1 == "3")
        let r2 = try await inc.call(.object(["amount": .number(4)]))
        #expect(r2 == "7")
        let r3 = try await read.call(.object([:]))
        #expect(r3 == "7")
    }

    // MARK: End-to-end via LLMSession

    @Test("session invokes a macro-generated tool")
    func sessionInvokesTool() async throws {
        let store = NoteStore()
        let provider = MacroScriptedProvider([
            [
                .toolUse(ToolUse(
                    id: "u1",
                    name: "create",
                    input: .object(["title": .string("a"), "body": .string("b")])
                )),
                .messageComplete(stopReason: "tool_use")
            ],
            [.text("done"), .messageComplete(stopReason: "end_turn")]
        ])

        let session = LLMSession(
            provider: provider,
            tools: store.collaborationTools
        )
        let reply = try await session.send("please create a note")
        #expect(reply == "done")
        #expect(store.count() == 1)

        // The tool result should be attached to the assistant turn that
        // requested it.
        let history = await session.messages
        let call = history.compactMap(\.toolCalls.first).first
        #expect(call?.result?.content == "n1")
        #expect(call?.result?.isError == false)
    }
}

// MARK: - Scripted provider for the LLMSession smoke test

private actor MacroScriptedProvider: ModelProvider {
    private var scripts: [[ProviderStreamEvent]]
    private var index = 0

    init(_ scripts: [[ProviderStreamEvent]]) {
        self.scripts = scripts
    }

    private func next() -> [ProviderStreamEvent] {
        defer { index += 1 }
        guard index < scripts.count else {
            return [.messageComplete(stopReason: "end_turn")]
        }
        return scripts[index]
    }

    nonisolated func send(
        messages _: [Message],
        system _: String?,
        tools _: [ToolSpec]
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let events = await self.next()
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}
