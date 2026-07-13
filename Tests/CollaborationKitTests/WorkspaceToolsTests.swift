@testable import CollaborationKit
import Foundation
import Testing

/// Behavior tests for ``WorkspaceTools``: a root-scoped filesystem tool
/// suite (read/write/edit/list/search) for issue #79. All fixtures are
/// created under a unique temp directory so tests can run in parallel and
/// never touch real project files.
@Suite("WorkspaceTools")
struct WorkspaceToolsTests {
    // MARK: - Fixtures

    /// Creates a canonicalized temp directory. The `resolvingSymlinksInPath`
    /// dance matters on macOS where `NSTemporaryDirectory` is a `/var/…`
    /// symlink into `/private/var/…`.
    private static func makeWorkspace() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let root = base.appendingPathComponent("workspacetools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return URL(fileURLWithPath: root.path).resolvingSymlinksInPath()
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Tool surface

    @Test("collaborationTools exposes exactly the five workspace tools")
    func exposesFiveTools() throws {
        let root = try Self.makeWorkspace()
        let tools = WorkspaceTools(root: root).collaborationTools
        let names = Set(tools.map(\.name))
        #expect(names == ["readFile", "writeFile", "editFile", "listDirectory", "searchFiles"])
    }

    @Test("writeFile and editFile require approval; the rest do not")
    func approvalMetadata() throws {
        let root = try Self.makeWorkspace()
        let tools = WorkspaceTools(root: root).collaborationTools
        let mutating = Set(tools.filter(\.requiresApproval).map(\.name))
        #expect(mutating == ["writeFile", "editFile"])
    }

    @Test("readOnlyWorkspaceTools drops the mutating tools")
    func readOnlyDropsMutating() throws {
        let root = try Self.makeWorkspace()
        let tools: [any Tool] = .readOnlyWorkspaceTools(root: root)
        let names = Set(tools.map(\.name))
        #expect(names == ["readFile", "listDirectory", "searchFiles"])
    }

    // MARK: - readFile

    @Test("readFile returns UTF-8 contents for a workspace file")
    func readFileReturnsContents() throws {
        let root = try Self.makeWorkspace()
        try Self.write("hello, world", to: root.appendingPathComponent("greeting.txt"))
        let tools = WorkspaceTools(root: root)
        #expect(try tools.readFile(path: "greeting.txt") == "hello, world")
    }

    @Test("readFile truncates and reports when the file exceeds maxReadBytes")
    func readFileTruncatesLarge() throws {
        let root = try Self.makeWorkspace()
        let big = String(repeating: "A", count: 200)
        try Self.write(big, to: root.appendingPathComponent("big.txt"))
        let tools = WorkspaceTools(root: root, maxReadBytes: 50)
        let out = try tools.readFile(path: "big.txt")
        #expect(out.hasPrefix(String(repeating: "A", count: 50)))
        #expect(out.contains("[truncated: file is 200 bytes; showed first 50]"))
    }

    @Test("readFile denies a path outside the workspace root")
    func readFileDeniesEscape() throws {
        let root = try Self.makeWorkspace()
        let tools = WorkspaceTools(root: root)
        #expect(throws: ToolError.self) {
            _ = try tools.readFile(path: "/etc/passwd")
        }
    }

    @Test("readFile denies a `..` escape")
    func readFileDeniesRelativeEscape() throws {
        let root = try Self.makeWorkspace()
        let tools = WorkspaceTools(root: root)
        #expect(throws: ToolError.self) {
            _ = try tools.readFile(path: "../outside.txt")
        }
    }

    // MARK: - writeFile

    @Test("writeFile creates a new file with the given contents")
    func writeFileCreatesFile() throws {
        let root = try Self.makeWorkspace()
        let tools = WorkspaceTools(root: root)
        let result = try tools.writeFile(path: "note.md", content: "hi")
        #expect(result.contains("Wrote 2 characters"))
        let url = root.appendingPathComponent("note.md")
        #expect(try String(contentsOf: url, encoding: .utf8) == "hi")
    }

    @Test("writeFile creates intermediate directories")
    func writeFileCreatesIntermediateDirectories() throws {
        let root = try Self.makeWorkspace()
        let tools = WorkspaceTools(root: root)
        _ = try tools.writeFile(path: "sub/deeper/file.txt", content: "x")
        let url = root.appendingPathComponent("sub/deeper/file.txt")
        #expect(try String(contentsOf: url, encoding: .utf8) == "x")
    }

    @Test("writeFile denies writing outside the workspace")
    func writeFileDeniesEscape() throws {
        let root = try Self.makeWorkspace()
        let tools = WorkspaceTools(root: root)
        #expect(throws: ToolError.self) {
            _ = try tools.writeFile(path: "../escape.txt", content: "bad")
        }
    }

    // MARK: - editFile

    @Test("editFile applies a unique replacement")
    func editFileAppliesUnique() throws {
        let root = try Self.makeWorkspace()
        try Self.write("The quick brown fox", to: root.appendingPathComponent("story.txt"))
        let tools = WorkspaceTools(root: root)
        _ = try tools.editFile(path: "story.txt", oldText: "brown", newText: "red")
        let updated = try String(contentsOf: root.appendingPathComponent("story.txt"), encoding: .utf8)
        #expect(updated == "The quick red fox")
    }

    @Test("editFile rejects an ambiguous match and leaves the file unchanged")
    func editFileRejectsAmbiguous() throws {
        let root = try Self.makeWorkspace()
        try Self.write("foo bar foo baz", to: root.appendingPathComponent("f.txt"))
        let tools = WorkspaceTools(root: root)
        #expect(throws: ToolError.self) {
            _ = try tools.editFile(path: "f.txt", oldText: "foo", newText: "qux")
        }
        let unchanged = try String(contentsOf: root.appendingPathComponent("f.txt"), encoding: .utf8)
        #expect(unchanged == "foo bar foo baz")
    }

    @Test("editFile throws when oldText is not found")
    func editFileNotFound() throws {
        let root = try Self.makeWorkspace()
        try Self.write("hello", to: root.appendingPathComponent("h.txt"))
        let tools = WorkspaceTools(root: root)
        #expect(throws: ToolError.self) {
            _ = try tools.editFile(path: "h.txt", oldText: "missing", newText: "x")
        }
    }

    // MARK: - listDirectory

    @Test("listDirectory lists workspace entries with a trailing slash for directories")
    func listDirectoryMarksDirectories() throws {
        let root = try Self.makeWorkspace()
        try Self.write("a", to: root.appendingPathComponent("alpha.txt"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bravo"),
            withIntermediateDirectories: true
        )
        let tools = WorkspaceTools(root: root)
        let out = try tools.listDirectory(path: "")
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines.contains("alpha.txt"))
        #expect(lines.contains("bravo/"))
    }

    @Test("listDirectory skips hidden entries and common build outputs")
    func listDirectorySkipsHiddenAndBuild() throws {
        let root = try Self.makeWorkspace()
        try Self.write("a", to: root.appendingPathComponent("keep.txt"))
        try Self.write("b", to: root.appendingPathComponent(".hidden"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".build"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("node_modules"),
            withIntermediateDirectories: true
        )
        let tools = WorkspaceTools(root: root)
        let out = try tools.listDirectory(path: "")
        #expect(out.contains("keep.txt"))
        #expect(!out.contains(".hidden"))
        #expect(!out.contains(".build"))
        #expect(!out.contains("node_modules"))
    }

    @Test("listDirectory truncates and reports when the directory is too large")
    func listDirectoryTruncates() throws {
        let root = try Self.makeWorkspace()
        for index in 0..<10 {
            try Self.write("x", to: root.appendingPathComponent("file\(index).txt"))
        }
        let tools = WorkspaceTools(root: root, maxListEntries: 3)
        let out = try tools.listDirectory(path: "")
        #expect(out.contains("[truncated: 10 entries; showed first 3]"))
    }

    @Test("listDirectory on an empty directory reports so")
    func listDirectoryEmpty() throws {
        let root = try Self.makeWorkspace()
        let tools = WorkspaceTools(root: root)
        #expect(try tools.listDirectory(path: "") == "(empty directory)")
    }

    @Test("listDirectory throws for a non-directory path")
    func listDirectoryOnFileThrows() throws {
        let root = try Self.makeWorkspace()
        try Self.write("x", to: root.appendingPathComponent("f.txt"))
        let tools = WorkspaceTools(root: root)
        #expect(throws: ToolError.self) {
            _ = try tools.listDirectory(path: "f.txt")
        }
    }

    // MARK: - searchFiles

    @Test("searchFiles finds substring hits with `path:line: content` formatting")
    func searchFilesFindsHits() throws {
        let root = try Self.makeWorkspace()
        try Self.write("apple\nbanana\ncherry", to: root.appendingPathComponent("fruits.txt"))
        try Self.write("plum\nbanana bread", to: root.appendingPathComponent("more/desserts.txt"))
        let tools = WorkspaceTools(root: root)
        let out = try tools.searchFiles(query: "banana", path: nil)
        #expect(out.contains("fruits.txt:2: banana"))
        #expect(out.contains("more/desserts.txt:2: banana bread"))
    }

    @Test("searchFiles reports (no matches) when nothing hits")
    func searchFilesNoMatches() throws {
        let root = try Self.makeWorkspace()
        try Self.write("apple", to: root.appendingPathComponent("fruits.txt"))
        let tools = WorkspaceTools(root: root)
        #expect(try tools.searchFiles(query: "zzz", path: nil) == "(no matches)")
    }

    @Test("searchFiles truncates at maxSearchResults")
    func searchFilesTruncates() throws {
        let root = try Self.makeWorkspace()
        let manyLines = Array(repeating: "match", count: 20).joined(separator: "\n")
        try Self.write(manyLines, to: root.appendingPathComponent("dup.txt"))
        let tools = WorkspaceTools(root: root, maxSearchResults: 5)
        let out = try tools.searchFiles(query: "match", path: nil)
        #expect(out.contains("[truncated: showed first 5 matches]"))
    }

    @Test("searchFiles skips .build and .git")
    func searchFilesSkipsBuildOutputs() throws {
        let root = try Self.makeWorkspace()
        try Self.write("needle in kept file", to: root.appendingPathComponent("kept.txt"))
        try Self.write("needle in build", to: root.appendingPathComponent(".build/skipped.txt"))
        try Self.write("needle in git", to: root.appendingPathComponent(".git/skipped.txt"))
        let tools = WorkspaceTools(root: root)
        let out = try tools.searchFiles(query: "needle", path: nil)
        #expect(out.contains("kept.txt"))
        #expect(!out.contains(".build"))
        #expect(!out.contains(".git"))
    }

    @Test("searchFiles rejects an empty query")
    func searchFilesRejectsEmptyQuery() throws {
        let root = try Self.makeWorkspace()
        let tools = WorkspaceTools(root: root)
        #expect(throws: ToolError.self) {
            _ = try tools.searchFiles(query: "", path: nil)
        }
    }

    @Test("searchFiles can scope to a subdirectory")
    func searchFilesScopedToSubdir() throws {
        let root = try Self.makeWorkspace()
        try Self.write("needle here", to: root.appendingPathComponent("outer.txt"))
        try Self.write("needle there", to: root.appendingPathComponent("nested/inner.txt"))
        let tools = WorkspaceTools(root: root)
        let out = try tools.searchFiles(query: "needle", path: "nested")
        #expect(out.contains("nested/inner.txt"))
        #expect(!out.contains("outer.txt"))
    }
}
