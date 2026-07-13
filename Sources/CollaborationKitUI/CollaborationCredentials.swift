import CollaborationKit
import Foundation
import Observation
import SwiftUI

/// Observable wrapper around a ``CredentialStore`` plus the currently
/// selected ``Backend``.
///
/// Inject this into the SwiftUI environment; the credential views and any
/// host UI that shows "signed in?" state read it directly. The store
/// remains the source of truth — this type caches the derived flags and
/// re-reads them on ``refresh()`` after any mutation.
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
@preconcurrency
@Observable
@MainActor
public final class CollaborationCredentials {
    /// The store credentials are read from and written to.
    ///
    /// Defaults to a ``KeychainCredentialStore``, but any ``CredentialStore``
    /// works — tests use ``InMemoryCredentialStore``, and hosts can plug in
    /// their own persistence.
    public let store: any CredentialStore

    /// The backends this credentials model knows about — the source of truth
    /// for pickers, model persistence keys, and provider construction.
    public let backends: [Backend]

    /// The provider the host wants to talk to. Persisted in `UserDefaults`
    /// under the key passed to ``init(store:backends:initialBackend:defaultsKey:)``
    /// when non-`nil`.
    public var backend: Backend {
        didSet {
            if let key = defaultsKey, oldValue.id != backend.id {
                UserDefaults.standard.set(backend.id, forKey: key)
            }
            refresh()
        }
    }

    /// Whether credentials are stored for the current ``backend``.
    public private(set) var hasCredentials: Bool

    /// The model identifier the user picked for the current backend, or the
    /// backend's default when nothing has been persisted yet. Stored (not
    /// computed) so Observation fires on change.
    public private(set) var selectedModel: String

    /// The last non-`.notFound` failure reason for the current backend, if
    /// any. Set when a Keychain read for the active slot returned `.failed`,
    /// so the UI can distinguish "no key" from "couldn't read it right now".
    public private(set) var readFailure: OSStatus?

    private let defaultsKey: String?

    /// Creates a credentials model.
    ///
    /// - Parameters:
    ///   - store: The credential store credentials are read from and written
    ///     to. Defaults to a ``KeychainCredentialStore``.
    ///   - backends: The backends the host wants to expose. Defaults to
    ///     ``Backend/allBuiltin``.
    ///   - initialBackend: The backend to select before ``UserDefaults`` is
    ///     consulted. Must be present in `backends`; falls back to the first
    ///     entry otherwise.
    ///   - defaultsKey: When non-`nil`, the selected backend id is persisted
    ///     to `UserDefaults` under this key and restored on init.
    public init(
        store: any CredentialStore = KeychainCredentialStore(),
        backends: [Backend] = Backend.allBuiltin,
        initialBackend: Backend? = nil,
        defaultsKey: String? = "collaborationkit.backend"
    ) {
        precondition(!backends.isEmpty, "CollaborationCredentials requires at least one backend.")
        self.store = store
        self.backends = backends
        self.defaultsKey = defaultsKey

        let restoredID = defaultsKey.flatMap { UserDefaults.standard.string(forKey: $0) }
        let restored = restoredID.flatMap { id in backends.first { $0.id == id } }
        let backend = restored ?? initialBackend ?? backends[0]

        self.backend = backend
        self.hasCredentials = false
        self.selectedModel = UserDefaults.standard
            .string(forKey: backend.modelDefaultsKey) ?? backend.defaultModel
        self.readFailure = nil
        refresh()
    }

    /// Re-reads credential state for the current backend. Call after any
    /// mutation (save/clear/login/logout) — the built-in views already do.
    public func refresh() {
        readFailure = nil
        hasCredentials = backend.hasCredentials(store)
        selectedModel = UserDefaults.standard
            .string(forKey: backend.modelDefaultsKey) ?? backend.defaultModel
    }

    /// Builds a ``ModelProvider`` for the current backend and model choice.
    ///
    /// Uses ``selectedModel`` (the persisted user choice, or the backend
    /// default) when `model` is `nil`.
    public func makeProvider(
        model: String? = nil,
        maxTokens: Int = 4_096,
        baseURL: URL? = nil
    ) throws -> any ModelProvider {
        let effectiveBaseURL = baseURL ?? persistedBaseURL(for: backend)
        return try backend.makeProvider(store, model ?? selectedModel, maxTokens, effectiveBaseURL)
    }

    // MARK: - Base URL persistence

    /// Returns the persisted base-URL override for `backend`, or `nil` when
    /// none has been set (or the stored string doesn't parse).
    public func baseURL(for backend: Backend? = nil) -> URL? {
        persistedBaseURL(for: backend ?? self.backend)
    }

    /// Persists a base-URL override for `backend` (defaults to the current
    /// backend). Passing `nil` clears the override.
    public func setBaseURL(_ url: URL?, for backend: Backend? = nil) {
        let target = backend ?? self.backend
        let key = target.baseURLDefaultsKey
        if let url {
            UserDefaults.standard.set(url.absoluteString, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func persistedBaseURL(for backend: Backend) -> URL? {
        guard let string = UserDefaults.standard.string(forKey: backend.baseURLDefaultsKey),
              !string.isEmpty else { return nil }
        return URL(string: string)
    }

    // MARK: - Model selection persistence

    /// Persists a model choice for the given backend (defaults to the current
    /// backend). Setting an empty string reverts to the backend default.
    public func selectModel(_ modelID: String, for backend: Backend? = nil) {
        let target = backend ?? self.backend
        let key = target.modelDefaultsKey
        if modelID.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(modelID, forKey: key)
        }
        if target.id == self.backend.id {
            selectedModel = modelID.isEmpty ? self.backend.defaultModel : modelID
        }
    }

    /// Fetches the models available for the current backend by asking the
    /// underlying ``ModelProvider`` for a catalog (via ``ModelLister``).
    ///
    /// Returns an empty array when the provider doesn't expose a catalog.
    public func listAvailableModels() async throws -> [ModelInfo] {
        let provider = try makeProvider()
        guard let lister = provider as? ModelLister else { return [] }
        return try await lister.listModels()
    }
}
