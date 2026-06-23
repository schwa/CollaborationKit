@testable import CollaborationKit
import Foundation
import Testing

@Test
func credentialStoreRoundTrips() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("collab-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = CredentialStore(directory: dir)
    #expect(try store.apiKey() == nil)

    try store.save(apiKey: "sk-abc-123")
    #expect(try store.apiKey() == "sk-abc-123")

    let perms = try FileManager.default
        .attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
    #expect(perms?.int16Value == 0o600)

    try store.clear()
    #expect(try store.apiKey() == nil)
}
