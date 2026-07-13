@testable import CollaborationKit
@testable import CollaborationKitUI
import Foundation
import Testing

/// Unit tests for the session debug-export UI plumbing added in #72.
/// The SwiftUI-side wiring (environment/focused-value publication,
/// `.fileExporter` presentation) is exercised end-to-end from the demo
/// app; these tests cover the pieces that don't need a view hierarchy.
@MainActor
struct SessionDebugExportUITests {
    @Test
    func timestampedFilenameIsFilesystemSafeAndJSONExtensioned() {
        let name = SessionDebugExportModifier.timestampedFilename()
        // Prefix + `.json` suffix, no colons, no spaces, no forward slashes.
        #expect(name.hasPrefix("collaboration-debug-"))
        #expect(name.hasSuffix(".json"))
        let banned: Set<Character> = [":", " ", "/", "\\"]
        #expect(!name.contains { banned.contains($0) })
    }

    @Test
    func exportDebugLogActionInvokesItsHandler() {
        // A tiny counter to observe the handler firing. `ExportDebugLogAction`
        // captures a MainActor closure so the state read here is race-free.
        final class Counter: @unchecked Sendable {
            var value = 0
        }
        let counter = Counter()
        let action = ExportDebugLogAction { @MainActor in
            counter.value += 1
        }
        action()
        action()
        #expect(counter.value == 2)
    }
}
