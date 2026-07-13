import Foundation

/// An allowlist of filesystem locations tools may read from or write to.
///
/// The built-in ``FileTools`` accept a single ``TextDocument`` at
/// construction, so their filesystem reach is already bounded to what the
/// caller passed in. Hosts building **their own**
/// path-parameterized tools (e.g. "list files in this directory", "open a
/// project file by name") use ``PathPolicy`` to gate every path the model
/// supplies against a set of pre-approved roots.
///
/// ```swift
/// let policy = PathPolicy(allowedRoots: [projectRoot])
///
/// struct OpenFileTool: Tool {
///     let policy: PathPolicy
///     struct Input: Decodable, Sendable { let path: String }
///     var name: String { "openFile" }
///     var description: String { "Open a file inside the project." }
///     var inputSchema: JSONValue { ... }
///     func call(_ input: Input) throws -> String {
///         let url = try policy.resolve(input.path)
///         return try String(contentsOf: url, encoding: .utf8)
///     }
/// }
/// ```
///
/// Related to ``ToolApprovalDecision`` on ``LLMSession``: use the approval
/// hook for *whole-call* gating (rate limiting, user confirmation prompts) and
/// `PathPolicy` for *per-argument* filesystem-scope gating.
public struct PathPolicy: Sendable {
    /// The canonicalized directories tools may resolve paths inside.
    ///
    /// The initializer canonicalizes each root (resolving symlinks and `..`)
    /// so containment checks compare like against like.
    public let allowedRoots: [URL]

    /// Whether to allow paths that resolve, through symlinks, to a location
    /// outside ``allowedRoots``. Default: `false` — symlink escapes are denied.
    ///
    /// The check runs against the fully-resolved absolute path, so a symlink
    /// inside an allowed root that points outside is caught.
    public let allowsSymlinkEscape: Bool

    /// Creates a policy.
    ///
    /// - Parameters:
    ///   - allowedRoots: The directories that constrain reachable paths. Empty
    ///     means "deny everything".
    ///   - allowsSymlinkEscape: Whether symlinks may point outside
    ///     ``allowedRoots``. Default `false`.
    public init(allowedRoots: [URL], allowsSymlinkEscape: Bool = false) {
        self.allowedRoots = allowedRoots.map(Self.canonicalize)
        self.allowsSymlinkEscape = allowsSymlinkEscape
    }

    /// Whether `url` (or a caller-supplied path) resolves inside an allowed
    /// root.
    ///
    /// Convenience for `try? check(...)` when the caller only needs the
    /// yes/no answer.
    public func allows(_ url: URL) -> Bool {
        (try? check(url)) != nil
    }

    /// Throws ``PathPolicyError`` if `url` doesn't resolve inside an allowed
    /// root under the current ``allowsSymlinkEscape`` setting.
    public func check(_ url: URL) throws {
        let resolved = allowsSymlinkEscape
            ? Self.absolute(url)
            : Self.canonicalize(url)
        for root in allowedRoots where Self.contains(root: root, resolved: resolved) {
            return
        }
        let roots = allowedRoots.map(\.path).joined(separator: ", ")
        throw PathPolicyError(
            url: url,
            reason: "Path is not inside any allowed root (\(roots))."
        )
    }

    /// Resolves a model-supplied string path against the first allowed root
    /// as a base, verifies the result is inside an allowed root, and returns
    /// it as an absolute `URL`.
    ///
    /// Relative paths are resolved against `allowedRoots.first`. Absolute
    /// paths (starting with `/`) are used as-is before the containment check.
    ///
    /// - Throws: ``PathPolicyError`` if there are no allowed roots, or the
    ///   resolved path is outside them.
    public func resolve(_ path: String) throws -> URL {
        guard let base = allowedRoots.first else {
            throw PathPolicyError(
                url: URL(fileURLWithPath: path),
                reason: "PathPolicy has no allowed roots configured."
            )
        }
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            url = base.appendingPathComponent(path)
        }
        try check(url)
        return url
    }

    // MARK: - Helpers

    /// The canonicalized (symlinks resolved) absolute path of `url`.
    private static func canonicalize(_ url: URL) -> URL {
        // resolvingSymlinksInPath drops trailing "/" and resolves ".." /
        // "." components as well as symlinks. Falling through to
        // standardizedFileURL as a safety net if the item doesn't exist yet.
        URL(fileURLWithPath: url.path).resolvingSymlinksInPath()
    }

    /// The absolute path without symlink resolution (still standardizes `..`).
    private static func absolute(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path).standardizedFileURL
    }

    /// Whether `resolved` sits at or under `root`. Path-component comparison
    /// so `/a/b` isn't considered inside `/a/bar`.
    private static func contains(root: URL, resolved: URL) -> Bool {
        let rootComponents = root.pathComponents
        let resolvedComponents = resolved.pathComponents
        guard rootComponents.count <= resolvedComponents.count else { return false }
        return Array(resolvedComponents.prefix(rootComponents.count)) == rootComponents
    }
}

/// A failure surfaced by ``PathPolicy`` when a path isn't inside an allowed
/// root.
public struct PathPolicyError: Error, LocalizedError, Sendable {
    /// The offending URL as the caller supplied it (pre-canonicalization).
    public let url: URL
    /// Human-readable reason.
    public let reason: String

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }

    public var errorDescription: String? {
        "PathPolicy denied '\(url.path)': \(reason)"
    }
}
