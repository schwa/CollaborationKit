import Foundation
import Observation
import SwiftUI
import CollaborationKit

/// Observable wrapper around a ``KeychainCredentialStore`` plus the currently
/// selected ``CollaborationBackend``.
///
/// Inject this into the SwiftUI environment; the credential views and any host
/// UI that shows "signed in?" state read it directly. The Keychain remains the
/// source of truth — this type caches the derived flags and re-reads them on
/// ``refresh()`` after any mutation.
///
/// ```swift
/// @main
/// struct MyApp: App {
///     @State private var credentials = CollaborationCredentials()
///     var body: some Scene {
///         WindowGroup { ContentView().environment(credentials) }
///         Settings { CollaborationSettingsView() }
///     }
/// }
/// ```
@Observable
@MainActor
public final class CollaborationCredentials {
    /// The store credentials are read from and written to.
    public let store: KeychainCredentialStore

    /// The provider the host wants to talk to. Persisted in `UserDefaults`
    /// under the key passed to ``init(store:defaultsKey:)`` when non-`nil`.
    public var backend: CollaborationBackend {
        didSet {
            if let key = defaultsKey, oldValue != backend {
                UserDefaults.standard.set(backend.rawValue, forKey: key)
            }
            refresh()
        }
    }

    /// Whether credentials are stored for the current ``backend``.
    ///
    /// Recomputed on ``refresh()`` — the SwiftUI views call refresh after
    /// every save/clear/login/logout so observers update immediately.
    public private(set) var hasCredentials: Bool

    /// The last non-`.notFound` failure reason for the current backend, if
    /// any. Set when a Keychain read for the active slot returned `.failed`,
    /// so the UI can distinguish "no key" from "couldn't read it right now".
    public private(set) var readFailure: OSStatus?

    private let defaultsKey: String?

    /// Creates a credentials model.
    ///
    /// - Parameters:
    ///   - store: The Keychain store to read from and write to. Defaults to a
    ///     store using the default service string.
    ///   - initialBackend: The backend to select before ``UserDefaults`` (if
    ///     any) is consulted.
    ///   - defaultsKey: When non-`nil`, the selected backend is persisted to
    ///     `UserDefaults` under this key and restored on init.
    public init(
        store: KeychainCredentialStore = KeychainCredentialStore(),
        initialBackend: CollaborationBackend = .claudeSubscription,
        defaultsKey: String? = "collaborationkit.backend"
    ) {
        self.store = store
        self.defaultsKey = defaultsKey
        let restored = defaultsKey
            .flatMap { UserDefaults.standard.string(forKey: $0) }
            .flatMap(CollaborationBackend.init(rawValue:))
        self.backend = restored ?? initialBackend
        self.hasCredentials = false
        self.readFailure = nil
        refresh()
    }

    /// Re-reads credential state for the current backend. Call after any
    /// mutation (save/clear/login/logout) — the built-in views already do.
    public func refresh() {
        readFailure = nil
        switch backend {
        case .claudeSubscription:
            hasCredentials = store.anthropicOAuthCredentials() != nil

        case .anthropicAPI:
            hasCredentials = evaluate(store.anthropicAPIKey())

        case .openAI:
            hasCredentials = evaluate(store.openAIAPIKey())
        }
    }

    /// Builds a ``ModelProvider`` for the current backend and model choice.
    ///
    /// Convenience wrapper around
    /// ``KeychainCredentialStore/makeProvider(for:model:maxTokens:)``. Uses
    /// ``selectedModel`` (the persisted user choice, or the backend default)
    /// when `model` is `nil`.
    public func makeProvider(model: String? = nil, maxTokens: Int = 4_096) throws -> any ModelProvider {
        try store.makeProvider(for: backend, model: model ?? selectedModel, maxTokens: maxTokens)
    }

    // MARK: - Model selection persistence

    /// The model identifier the user picked for the current backend, or the
    /// backend's default when nothing has been persisted yet.
    public var selectedModel: String {
        UserDefaults.standard.string(forKey: modelDefaultsKey(for: backend)) ?? backend.defaultModel
    }

    /// Persists a model choice for the given backend (defaults to the current
    /// backend). Setting an empty string reverts to the backend default.
    public func selectModel(_ modelID: String, for backend: CollaborationBackend? = nil) {
        let target = backend ?? self.backend
        let key = modelDefaultsKey(for: target)
        if modelID.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(modelID, forKey: key)
        }
    }

    /// Fetches the models available for the current backend by asking the
    /// underlying ``ModelProvider`` for a catalog (via ``ModelLister``).
    ///
    /// Returns an empty array when the provider doesn't expose a catalog.
    /// Throws a ``CollaborationCredentialsError`` when credentials are
    /// missing or unreadable, or whatever error the provider surfaces.
    public func listAvailableModels() async throws -> [ModelInfo] {
        let provider = try makeProvider()
        guard let lister = provider as? ModelLister else { return [] }
        return try await lister.listModels()
    }

    /// UserDefaults key for the persisted model id of a backend.
    public func modelDefaultsKey(for backend: CollaborationBackend) -> String {
        "collaborationkit.model.\(backend.rawValue)"
    }

    private func evaluate(_ result: KeychainReadResult) -> Bool {
        switch result {
        case .found(let value):
            return !value.isEmpty

        case .notFound:
            return false

        case .failed(let status):
            readFailure = status
            return false
        }
    }
}
