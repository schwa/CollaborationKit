import Foundation

/// Supplies a valid Claude OAuth access token, refreshing and persisting it as
/// needed.
///
/// Pass ``token`` as the closure for ``AnthropicAuth/oauth(_:)``. On each call it
/// returns the current access token, transparently refreshing via the stored
/// refresh token when the access token has expired and saving the new tokens
/// back to the ``CredentialStore``.
public actor OAuthTokenProvider {
    private var credentials: OAuthCredentials
    private let store: CredentialStore
    private let oauth: AnthropicOAuth

    public init(credentials: OAuthCredentials, store: CredentialStore = CredentialStore(), oauth: AnthropicOAuth = AnthropicOAuth()) {
        self.credentials = credentials
        self.store = store
        self.oauth = oauth
    }

    /// Returns a currently-valid access token, refreshing if necessary.
    public func token() async throws -> String {
        if credentials.isExpired() {
            let refreshed = try await oauth.refresh(credentials)
            credentials = refreshed
            try store.save(oauth: refreshed)
        }
        return credentials.access
    }

    /// A `@Sendable` closure suitable for ``AnthropicAuth/oauth(_:)``.
    nonisolated public var tokenProvider: @Sendable () async throws -> String {
        { try await self.token() }
    }
}
