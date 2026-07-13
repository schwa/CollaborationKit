@testable import CollaborationKit
import Testing

/// Behavior tests for the ``FileTools`` read/write/edit methods, which the
/// `@CollaborationTools` macro also exposes as three tool schemas. Testing
/// the plain methods gives full coverage of the substantive logic (uniqueness
/// counting, error mapping) without going through the JSON layer.
///
/// Uses ``InMemoryDocument`` so tests don't touch the filesystem.
@Suite("FileTools")
struct FileToolsTests {
    // MARK: - read

    @Test("read returns the current document contents")
    func readReturnsContents() throws {
        let doc = InMemoryDocument("hello, world")
        let tools = FileTools(document: doc)
        #expect(try tools.read() == "hello, world")
    }

    @Test("read on an empty document returns the empty string")
    func readOnEmptyDocumentReturnsEmpty() throws {
        let doc = InMemoryDocument("")
        let tools = FileTools(document: doc)
        #expect(try tools.read().isEmpty)
    }

    @Test("read surfaces a ToolError when the document read throws")
    func readSurfacesToolErrorOnFailure() {
        let doc = FailingDocument()
        let tools = FileTools(document: doc)
        #expect(throws: ToolError.self) {
            _ = try tools.read()
        }
    }

    // MARK: - write

    @Test("write replaces the full contents and reports the character count")
    func writeReplacesContents() throws {
        let doc = InMemoryDocument("old contents")
        let tools = FileTools(document: doc)
        let result = try tools.write(content: "brand new text")
        #expect(doc.contents == "brand new text")
        #expect(result == "Wrote 14 characters.")
    }

    @Test("write of empty string clears the document")
    func writeEmptyStringClearsDocument() throws {
        let doc = InMemoryDocument("populated")
        let tools = FileTools(document: doc)
        _ = try tools.write(content: "")
        #expect(doc.contents.isEmpty)
    }

    @Test("write surfaces a ToolError when the underlying write fails")
    func writeSurfacesToolErrorOnFailure() {
        let doc = FailingDocument()
        let tools = FileTools(document: doc)
        #expect(throws: ToolError.self) {
            _ = try tools.write(content: "anything")
        }
    }

    // MARK: - edit

    @Test("edit applies a unique match and updates the document")
    func editAppliesUniqueMatch() throws {
        let doc = InMemoryDocument("The quick brown fox")
        let tools = FileTools(document: doc)
        let result = try tools.edit(oldText: "brown", newText: "red")
        #expect(doc.contents == "The quick red fox")
        #expect(result == "Edit applied.")
    }

    @Test("edit throws when the oldText is not found")
    func editThrowsWhenNotFound() throws {
        let doc = InMemoryDocument("hello")
        let tools = FileTools(document: doc)
        #expect(throws: ToolError.self) {
            _ = try tools.edit(oldText: "missing", newText: "x")
        }
        // Document must be unchanged.
        #expect(doc.contents == "hello")
    }

    @Test("edit rejects an ambiguous match and reports the count")
    func editRejectsAmbiguousMatch() throws {
        let doc = InMemoryDocument("foo bar foo baz foo")
        let tools = FileTools(document: doc)
        do {
            _ = try tools.edit(oldText: "foo", newText: "qux")
            Issue.record("Expected an ambiguous-match error, but edit succeeded.")
        } catch let error as ToolError {
            #expect(error.message.contains("3 times"))
        }
        // Document must be unchanged.
        #expect(doc.contents == "foo bar foo baz foo")
    }

    @Test("edit with newText same as oldText is a no-op success on a unique match")
    func editIdempotentReplacementSucceeds() throws {
        let doc = InMemoryDocument("unique-token here")
        let tools = FileTools(document: doc)
        _ = try tools.edit(oldText: "unique-token", newText: "unique-token")
        #expect(doc.contents == "unique-token here")
    }

    // MARK: - collaborationTools surface

    @Test("collaborationTools exposes exactly read, write, and edit")
    func collaborationToolsExposesThreeTools() {
        let tools = FileTools(document: InMemoryDocument(""))
        let names = tools.collaborationTools.map(\.name).sorted()
        #expect(names == ["edit", "read", "write"])
    }
}

// MARK: - Helpers

/// A ``TextDocument`` whose read and write both throw. Used to prove the
/// tools convert underlying errors into ``ToolError`` values.
private struct FailingDocument: TextDocument {
    enum Failure: Error { case boom }
    func read() throws -> String { throw Failure.boom }
    func write(_: String) throws { throw Failure.boom }
}
