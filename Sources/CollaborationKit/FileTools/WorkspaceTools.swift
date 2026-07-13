import Foundation

/// A workspace-rooted tool suite covering the common filesystem operations
/// an agent needs when collaborating inside a project directory: reading,
/// writing, editing, listing, and searching text files.
///
/// Every path the model supplies is resolved relative to ``root`` and
/// checked against a ``PathPolicy`` before the operation runs, so the tools
/// never touch anything outside the workspace.
///
/// The whole suite is opt-in: hosts include it by adding
/// ``Swift/Array/workspaceTools(root:maxReadBytes:maxListEntries:maxSearchResults:allowsSymlinkEscape:)``
/// (or constructing this type directly) to the tools passed to
/// ``LLMSession``. ``writeFile(path:content:)`` and
/// ``editFile(path:oldText:newText:)`` set ``Tool/requiresApproval`` to
/// `true` so hosts route mutating calls through the session's approval
/// closure. A read-only surface is available as
/// ``Swift/Array/readOnlyWorkspaceTools(root:maxReadBytes:maxListEntries:maxSearchResults:allowsSymlinkEscape:)``.
///
/// Defaults chosen for a small-to-medium local project:
///
/// - `maxReadBytes = 512 KiB` — a single read is trimmed to this many bytes;
///   the tool reports a truncation notice when it happens so the model
///   knows it didn't see the whole file.
/// - `maxListEntries = 500` — a directory listing rarely exceeds this
///   without pointing at the wrong directory.
/// - `maxSearchResults = 100` — one screen's worth of hits.
///
/// The tools operate on UTF-8 text. Non-text files surface a ``ToolError``
/// rather than binary garbage. Search is a plain, case-sensitive substring
/// scan across UTF-8 text files inside the workspace; hidden entries
/// (leading `.`) and common build outputs (`.build`, `node_modules`,
/// `.git`, `.jj`, `DerivedData`) are skipped.
@CollaborationTools
public struct WorkspaceTools: Sendable {
    /// The workspace root every path is resolved against.
    public let root: URL
    /// The path policy that gates every model-supplied path.
    public let policy: PathPolicy
    /// Maximum bytes returned from a single ``readFile(path:)`` call.
    public let maxReadBytes: Int
    /// Maximum entries returned from a single ``listDirectory(path:)`` call.
    public let maxListEntries: Int
    /// Maximum hits returned from a single ``searchFiles(query:path:)`` call.
    public let maxSearchResults: Int

    /// Creates a workspace-rooted tool suite.
    ///
    /// - Parameters:
    ///   - root: The directory the tools may read from and write to.
    ///   - maxReadBytes: Cap on a single read. Default 512 KiB.
    ///   - maxListEntries: Cap on a single directory listing. Default 500.
    ///   - maxSearchResults: Cap on a single search. Default 100.
    ///   - allowsSymlinkEscape: Passed through to ``PathPolicy``. Default
    ///     `false` — symlinks that point outside ``root`` are denied.
    public init(
        root: URL,
        maxReadBytes: Int = 512 * 1024,
        maxListEntries: Int = 500,
        maxSearchResults: Int = 100,
        allowsSymlinkEscape: Bool = false
    ) {
        self.root = root
        self.policy = PathPolicy(allowedRoots: [root], allowsSymlinkEscape: allowsSymlinkEscape)
        self.maxReadBytes = maxReadBytes
        self.maxListEntries = maxListEntries
        self.maxSearchResults = maxSearchResults
    }

    // MARK: - Tools

    /// Read a UTF-8 text file inside the workspace. Paths are resolved
    /// relative to the workspace root. Large files are truncated and the
    /// tool reports the truncation.
    @CollaborationTool
    public func readFile(path: String) throws -> String {
        let url = try resolve(path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ToolError("Failed to read '\(path)': \(error.localizedDescription)")
        }
        var truncated = false
        let slice: Data
        if data.count > maxReadBytes {
            slice = data.prefix(maxReadBytes)
            truncated = true
        } else {
            slice = data
        }
        guard let text = String(data: slice, encoding: .utf8) else {
            throw ToolError("'\(path)' is not valid UTF-8 text.")
        }
        if truncated {
            return text + "\n\n[truncated: file is \(data.count) bytes; showed first \(maxReadBytes)]"
        }
        return text
    }

    /// Overwrite a UTF-8 text file inside the workspace with the given
    /// contents. Intermediate directories are created as needed. Provide
    /// the complete new file contents.
    @CollaborationTool(requiresApproval: true)
    public func writeFile(path: String, content: String) throws -> String {
        let url = try resolve(path)
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ToolError("Failed to write '\(path)': \(error.localizedDescription)")
        }
        return "Wrote \(content.count) characters to \(path)."
    }

    /// Replace an exact, unique span of text in a file inside the workspace.
    /// `oldText` must match exactly once; include enough surrounding context
    /// to make it unique. Use ``writeFile(path:content:)`` for new files.
    @CollaborationTool(requiresApproval: true)
    public func editFile(path: String, oldText: String, newText: String) throws -> String {
        let url = try resolve(path)
        let current: String
        do {
            current = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ToolError("Failed to read '\(path)': \(error.localizedDescription)")
        }

        let occurrences = current.components(separatedBy: oldText).count - 1
        switch occurrences {
        case 0:
            throw ToolError("`oldText` was not found in '\(path)'.")

        case 1:
            let updated = current.replacingOccurrences(of: oldText, with: newText)
            do {
                try updated.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw ToolError("Failed to write '\(path)': \(error.localizedDescription)")
            }
            return "Edit applied to \(path)."

        default:
            throw ToolError(
                "`oldText` matched \(occurrences) times in '\(path)'; it must be unique. Add surrounding context."
            )
        }
    }

    /// List entries in a workspace directory. Pass an empty string or "."
    /// to list the workspace root. Directories are marked with a trailing
    /// "/". Hidden entries and common build outputs are skipped.
    @CollaborationTool
    public func listDirectory(path: String) throws -> String {
        let target = path.isEmpty ? root : try resolve(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError("'\(path)' is not a directory.")
        }
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ToolError("Failed to list '\(path)': \(error.localizedDescription)")
        }
        let filtered = contents.filter { !Self.skippedDirectoryNames.contains($0.lastPathComponent) }
        let sorted = filtered.sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
        let clipped = sorted.prefix(maxListEntries)
        var lines: [String] = []
        for url in clipped {
            let dir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            lines.append(url.lastPathComponent + (dir ? "/" : ""))
        }
        if sorted.count > maxListEntries {
            lines.append("[truncated: \(sorted.count) entries; showed first \(maxListEntries)]")
        }
        return lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n")
    }

    /// Case-sensitive substring search across UTF-8 text files inside the
    /// workspace. Pass an empty `path` (or omit it) to search the whole
    /// workspace. Returns `path:line: content` hits, one per line.
    @CollaborationTool
    public func searchFiles(query: String, path: String? = nil) throws -> String {
        guard !query.isEmpty else {
            throw ToolError("`query` must not be empty.")
        }
        let searchRoot: URL
        if let path, !path.isEmpty {
            searchRoot = try resolve(path)
        } else {
            searchRoot = root
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: searchRoot.path, isDirectory: &isDir) else {
            throw ToolError("Search root '\(path ?? "")' does not exist.")
        }

        var hits: [String] = []
        hits.reserveCapacity(maxSearchResults)
        var truncated = false

        let files: [URL]
        if isDir.boolValue {
            files = Self.enumerateFiles(at: searchRoot)
        } else {
            files = [searchRoot]
        }

        outer: for url in files {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let relative = Self.relativePath(of: url, root: root)
            var lineNumber = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                lineNumber += 1
                if line.contains(query) {
                    hits.append("\(relative):\(lineNumber): \(line)")
                    if hits.count >= maxSearchResults {
                        truncated = true
                        break outer
                    }
                }
            }
        }

        if hits.isEmpty {
            return "(no matches)"
        }
        if truncated {
            hits.append("[truncated: showed first \(maxSearchResults) matches]")
        }
        return hits.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Directory names skipped by listings and searches. Hidden entries
    /// (leading `.`) are skipped as well via `.skipsHiddenFiles`.
    private static let skippedDirectoryNames: Set<String> = [
        ".build",
        ".git",
        ".jj",
        ".svn",
        "DerivedData",
        "node_modules",
        ".venv",
        "venv",
        "__pycache__",
        ".next",
        "dist",
        "build"
    ]

    /// Resolve a model-supplied path relative to the workspace root and
    /// verify it is inside the allowed root.
    private func resolve(_ path: String) throws -> URL {
        do {
            return try policy.resolve(path.isEmpty ? "." : path)
        } catch let error as PathPolicyError {
            throw ToolError(error.errorDescription ?? "Path denied: \(error.url.path)")
        } catch {
            throw ToolError("Failed to resolve '\(path)': \(error.localizedDescription)")
        }
    }

    /// Recursively enumerate regular files under `root`, skipping the
    /// pruned directory names above and any hidden entries.
    private static func enumerateFiles(at root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if skippedDirectoryNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    /// Relative path from `root` to `url`, or the absolute path if the URL
    /// doesn't sit under `root` (shouldn't happen after policy checks, but
    /// guarded for defensive output formatting).
    private static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.resolvingSymlinksInPath().path
        let urlPath = url.resolvingSymlinksInPath().path
        if urlPath.hasPrefix(rootPath + "/") {
            return String(urlPath.dropFirst(rootPath.count + 1))
        }
        if urlPath == rootPath {
            return "."
        }
        return urlPath
    }
}

extension Array where Element == any Tool {
    /// The full workspace tool suite (read, write, edit, list, search).
    ///
    /// Write and edit set ``Tool/requiresApproval`` to `true` so hosts can
    /// route mutating calls through the session's approval closure. See
    /// ``WorkspaceTools`` for parameter details.
    public static func workspaceTools(
        root: URL,
        maxReadBytes: Int = 512 * 1024,
        maxListEntries: Int = 500,
        maxSearchResults: Int = 100,
        allowsSymlinkEscape: Bool = false
    ) -> [any Tool] {
        WorkspaceTools(
            root: root,
            maxReadBytes: maxReadBytes,
            maxListEntries: maxListEntries,
            maxSearchResults: maxSearchResults,
            allowsSymlinkEscape: allowsSymlinkEscape
        ).collaborationTools
    }

    /// The read-only slice of the workspace tool suite (read, list,
    /// search). Equivalent to ``workspaceTools(root:maxReadBytes:maxListEntries:maxSearchResults:allowsSymlinkEscape:)``
    /// filtered to tools that don't require approval.
    public static func readOnlyWorkspaceTools(
        root: URL,
        maxReadBytes: Int = 512 * 1024,
        maxListEntries: Int = 500,
        maxSearchResults: Int = 100,
        allowsSymlinkEscape: Bool = false
    ) -> [any Tool] {
        workspaceTools(
            root: root,
            maxReadBytes: maxReadBytes,
            maxListEntries: maxListEntries,
            maxSearchResults: maxSearchResults,
            allowsSymlinkEscape: allowsSymlinkEscape
        ).filter { !$0.requiresApproval }
    }
}
