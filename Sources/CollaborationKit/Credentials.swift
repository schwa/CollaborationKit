import Foundation

/// A simple on-disk credential store for the Anthropic API key.
///
/// Credentials are written to `~/.config/collaborationkit/credentials.json` with
/// `0600` permissions. This is intentionally minimal; hosts wanting Keychain or
/// another secret store can ignore this type and supply ``AnthropicConfig``
/// directly.
public struct CredentialStore: Sendable {
    /// The directory holding the credentials file.
    public let directory: URL
    /// The credentials file itself.
    public let fileURL: URL

    /// Creates a store rooted at the given directory.
    ///
    /// - Parameter directory: The containing directory. Defaults to
    ///   `~/.config/collaborationkit`.
    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("collaborationkit", isDirectory: true)
        self.directory = base
        self.fileURL = base.appendingPathComponent("credentials.json")
    }

    private struct Stored: Codable {
        var apiKey: String?
        var oauth: OAuthCredentials?
    }

    private func load() throws -> Stored {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Stored() }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Stored.self, from: data)
    }

    private func persist(_ stored: Stored) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(stored)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Reads the stored API key, or `nil` if none has been saved.
    public func apiKey() throws -> String? {
        try load().apiKey
    }

    /// Saves the API key, preserving any stored OAuth credentials.
    public func save(apiKey: String) throws {
        var stored = try load()
        stored.apiKey = apiKey
        try persist(stored)
    }

    /// Reads the stored OAuth credentials, or `nil` if none have been saved.
    public func oauthCredentials() throws -> OAuthCredentials? {
        try load().oauth
    }

    /// Saves OAuth credentials, preserving any stored API key.
    public func save(oauth: OAuthCredentials) throws {
        var stored = try load()
        stored.oauth = oauth
        try persist(stored)
    }

    /// Removes any stored credentials.
    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
