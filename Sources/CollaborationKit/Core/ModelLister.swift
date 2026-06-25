import Foundation

/// Metadata about a single model advertised by a provider.
public struct ModelInfo: Sendable, Equatable, Identifiable {
    /// The model identifier to pass to a provider's config (e.g. `gpt-4o`).
    public let id: String
    /// A human-readable display name, when the provider supplies one.
    public let displayName: String?
    /// The owning organization, when the provider supplies one.
    public let ownedBy: String?
    /// The creation date, when the provider supplies one.
    public let created: Date?

    public init(id: String, displayName: String? = nil, ownedBy: String? = nil, created: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.ownedBy = ownedBy
        self.created = created
    }
}

/// A provider that can enumerate the models available to the caller.
///
/// Separate from ``ModelProvider`` so a backend can support running turns
/// without necessarily exposing a model catalog (and vice versa).
public protocol ModelLister: Sendable {
    /// Fetches the list of models the configured credentials can access.
    func listModels() async throws -> [ModelInfo]
}
