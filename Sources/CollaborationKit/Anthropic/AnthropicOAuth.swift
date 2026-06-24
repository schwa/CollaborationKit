import CryptoKit
import Foundation

/// OAuth tokens for Claude subscription access, obtained via the Claude Code
/// OAuth flow.
///
/// > Important: This uses the Claude Code OAuth client. It authorizes API access
/// > against a Claude subscription rather than a billed API key. It is
/// > unofficial, may violate Anthropic's terms, and may break without notice.
public struct OAuthCredentials: Codable, Sendable, Equatable {
    /// The bearer access token (begins with `sk-ant-oat`).
    public var access: String
    /// The refresh token, used to obtain a new access token.
    public var refresh: String
    /// The absolute expiry time of the access token.
    public var expires: Date

    public init(access: String, refresh: String, expires: Date) {
        self.access = access
        self.refresh = refresh
        self.expires = expires
    }

    /// Whether the access token is expired (or within a small safety margin).
    public func isExpired(now: Date = Date()) -> Bool {
        expires <= now
    }
}

/// An error raised during the OAuth login or refresh flow.
public enum OAuthError: Error, Sendable {
    case parseFailure(String)
    case stateMismatch
    case tokenExchangeFailed(status: Int, body: String)
    case malformedTokenResponse
}

/// The Claude Code OAuth flow, using out-of-band manual code entry.
///
/// No local server is started. The caller opens ``authorizeURL(challenge:state:)``
/// in a browser, the user approves, and pastes back the resulting `code#state`
/// (or full callback URL), which is exchanged for tokens.
public struct AnthropicOAuth: Sendable {
    // Claude Code OAuth client parameters.
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let authorizeURLBase = "https://claude.ai/oauth/authorize"
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    private static let scopes = [
        "org:create_api_key",
        "user:profile",
        "user:inference",
        "user:sessions:claude_code",
        "user:mcp_servers",
        "user:file_upload"
    ].joined(separator: " ")

    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    /// A PKCE verifier/challenge pair plus the opaque state for one login.
    public struct LoginRequest: Sendable {
        public let verifier: String
        public let state: String
        /// The URL the user should open in their browser to authorize.
        public let authorizeURL: URL
    }

    /// Begins a login: generates PKCE + state and the browser authorize URL.
    public func beginLogin() -> LoginRequest {
        let verifier = Self.makeVerifier()
        let challenge = Self.challenge(for: verifier)
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return LoginRequest(verifier: verifier, state: state, authorizeURL: Self.authorizeURL(challenge: challenge, state: state))
    }

    /// Completes a login by exchanging the pasted code for tokens.
    ///
    /// - Parameters:
    ///   - input: The pasted `code#state`, or the full callback URL.
    ///   - request: The ``LoginRequest`` returned by ``beginLogin()``.
    /// - Returns: The obtained ``OAuthCredentials``.
    public func completeLogin(input: String, request: LoginRequest) async throws -> OAuthCredentials {
        guard let parsed = Self.parseAuthInput(input) else {
            throw OAuthError.parseFailure(input)
        }
        guard parsed.state == request.state else {
            throw OAuthError.stateMismatch
        }
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": parsed.code,
            "state": parsed.state,
            "redirect_uri": Self.redirectURI,
            "code_verifier": request.verifier
        ]
        return try await exchange(body: body)
    }

    /// Refreshes an access token using its refresh token.
    public func refresh(_ credentials: OAuthCredentials) async throws -> OAuthCredentials {
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": credentials.refresh
        ]
        return try await exchange(body: body, fallbackRefresh: credentials.refresh)
    }

    // MARK: - Token exchange

    private func exchange(body: [String: String], fallbackRefresh: String? = nil) async throws -> OAuthCredentials {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OAuthError.tokenExchangeFailed(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String,
              let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue else {
            throw OAuthError.malformedTokenResponse
        }
        let refresh = (object["refresh_token"] as? String) ?? fallbackRefresh ?? ""
        // Expire five minutes early to avoid edge-of-expiry failures.
        let expires = Date().addingTimeInterval(expiresIn - 5 * 60)
        return OAuthCredentials(access: access, refresh: refresh, expires: expires)
    }

    // MARK: - URL building & parsing

    private static func authorizeURL(challenge: String, state: String) -> URL {
        var components = URLComponents(string: authorizeURLBase)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url!
    }

    struct ParsedAuthInput: Equatable {
        let code: String
        let state: String
    }

    static func parseAuthInput(_ input: String) -> ParsedAuthInput? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // A full callback URL with query parameters.
        if let components = URLComponents(string: text),
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
           let state = components.queryItems?.first(where: { $0.name == "state" })?.value {
            return ParsedAuthInput(code: code, state: state)
        }

        // The `code#state` form shown on the OOB page.
        let hashParts = text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        if hashParts.count == 2, !hashParts[0].isEmpty, !hashParts[1].isEmpty {
            return ParsedAuthInput(code: String(hashParts[0]), state: String(hashParts[1]))
        }

        return nil
    }

    // MARK: - PKCE

    private static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return base64URL(Data(bytes))
    }

    private static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
