@testable import CollaborationKit
import Foundation
import Testing

/// Unit tests for the ``PathPolicy`` allowlist helper (#32).
struct PathPolicyTests {

    // MARK: - Fixtures

    /// Creates a fresh temp directory and returns its canonical URL. The
    /// dance through `resolvingSymlinksInPath` matters on macOS, where
    /// `NSTemporaryDirectory` returns a `/var/…` path that symlinks into
    /// `/private/var/…`.
    private static func makeTempRoot() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let root = base.appendingPathComponent("pathpolicy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return URL(fileURLWithPath: root.path).resolvingSymlinksInPath()
    }

    // MARK: - Basic containment

    @Test
    func fileInsideRootAllowed() throws {
        let root = try Self.makeTempRoot()
        let policy = PathPolicy(allowedRoots: [root])
        try policy.check(root.appendingPathComponent("hello.txt"))
    }

    @Test
    func fileOutsideRootDenied() throws {
        let root = try Self.makeTempRoot()
        let policy = PathPolicy(allowedRoots: [root])
        let outside = URL(fileURLWithPath: "/etc/passwd")
        #expect(!policy.allows(outside))
        #expect(throws: PathPolicyError.self) { try policy.check(outside) }
    }

    @Test
    func siblingWithMatchingPrefixIsDenied() throws {
        let root = try Self.makeTempRoot()
        let policy = PathPolicy(allowedRoots: [root])
        // `<root>ish/inside.txt` shares the leading textual prefix but is
        // NOT under `<root>`. Path-component comparison must catch this.
        let sibling = URL(fileURLWithPath: root.path + "ish").appendingPathComponent("inside.txt")
        #expect(!policy.allows(sibling))
    }

    // MARK: - Symlink escape

    @Test
    func symlinkEscapeDeniedByDefault() throws {
        let root = try Self.makeTempRoot()
        // Create a symlink inside `root` that points outside `root`.
        let outsideTarget = try Self.makeTempRoot()
        let escape = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outsideTarget)

        let policy = PathPolicy(allowedRoots: [root])
        #expect(!policy.allows(escape))
    }

    @Test
    func symlinkEscapeAllowedWhenOptedIn() throws {
        let root = try Self.makeTempRoot()
        let outsideTarget = try Self.makeTempRoot()
        let escape = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outsideTarget)

        let policy = PathPolicy(allowedRoots: [root], allowsSymlinkEscape: true)
        // With escape allowed, the pre-resolution absolute path stays inside
        // `root` and the check passes.
        #expect(policy.allows(escape))
    }

    // MARK: - Resolve()

    @Test
    func resolveRelativeToFirstRoot() throws {
        let root = try Self.makeTempRoot()
        let policy = PathPolicy(allowedRoots: [root])
        let url = try policy.resolve("subdir/hello.txt")
        #expect(url.path.hasPrefix(root.path))
        #expect(url.lastPathComponent == "hello.txt")
    }

    @Test
    func resolveRejectsAbsolutePathOutsideRoots() throws {
        let root = try Self.makeTempRoot()
        let policy = PathPolicy(allowedRoots: [root])
        #expect(throws: PathPolicyError.self) {
            _ = try policy.resolve("/etc/passwd")
        }
    }

    @Test
    func resolveThrowsWhenNoRootsConfigured() {
        let policy = PathPolicy(allowedRoots: [])
        #expect(throws: PathPolicyError.self) {
            _ = try policy.resolve("anything.txt")
        }
    }

    @Test
    func dotDotEscapeIsCaught() throws {
        let root = try Self.makeTempRoot()
        let policy = PathPolicy(allowedRoots: [root])
        // `subdir/../../escape.txt` resolves outside `root`.
        #expect(throws: PathPolicyError.self) {
            _ = try policy.resolve("subdir/../../escape.txt")
        }
    }
}
