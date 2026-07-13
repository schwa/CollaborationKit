import SwiftUI
import CollaborationKit

/// A `Section` that logs the user in to a Claude subscription via the paste
/// OAuth flow, or logs them out if already signed in.
///
/// Reads and writes credentials through the ``CollaborationCredentials`` in the
/// environment. Drop it inside any `Form` — it renders as a single section.
///
/// ```swift
/// Form {
///     AnthropicOAuthSection()
/// }
/// .formStyle(.grouped)
/// .environment(credentials)
/// ```
///
/// > Important: The Claude subscription OAuth flow uses the Claude Code OAuth
/// > client. It is unofficial, may violate Anthropic's terms, and may break
/// > without notice.
public struct AnthropicOAuthSection: View {
    @Environment(CollaborationCredentials.self) private var credentials

    @State private var isLoggedIn: Bool = false
    @State private var loginRequest: AnthropicOAuth.LoginRequest?
    @State private var pastedCode: String = ""
    @State private var errorMessage: String?
    @State private var isCompleting: Bool = false

    private let oauth = AnthropicOAuth()

    public init() {}

    public var body: some View {
        Section {
            if isLoggedIn {
                loggedInRow
            } else if let request = loginRequest {
                pasteFlow(for: request)
            } else {
                Button {
                    beginLogin()
                } label: {
                    Label("Log In with Claude Subscription", systemImage: "person.badge.key")
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        } header: {
            Text("Claude Subscription")
        } footer: {
            Text("Log in with a Claude subscription instead of a billed API key. Unofficial (uses the Claude Code OAuth client) and may break without notice. Tokens are refreshed automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: syncLoginState)
    }

    // MARK: - Subviews

    private var loggedInRow: some View {
        HStack {
            Label("Signed in with a Claude subscription", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Spacer()
            Button("Log Out", role: .destructive) {
                credentials.store.clearAnthropicOAuthCredentials()
                credentials.refresh()
                syncLoginState()
                clearPasteState()
            }
        }
    }

    @ViewBuilder
    private func pasteFlow(for request: AnthropicOAuth.LoginRequest) -> some View {
        Text("A browser window opened. After approving, paste the `code#state` value shown back here.")
            .font(.callout)
            .foregroundStyle(.secondary)

        TextField("Paste code#state", text: $pastedCode)
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)
            .onSubmit { complete(request) }

        HStack {
            Button("Complete Login") { complete(request) }
                .keyboardShortcut(.defaultAction)
                .disabled(pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCompleting)

            Button("Cancel", role: .cancel) {
                clearPasteState()
            }

            if isCompleting {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
    }

    // MARK: - Actions

    private func beginLogin() {
        errorMessage = nil
        let request = oauth.beginLogin()
        loginRequest = request
        pastedCode = ""
        BrowserOpener.open(request.authorizeURL)
    }

    private func complete(_ request: AnthropicOAuth.LoginRequest) {
        let trimmed = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        isCompleting = true

        Task {
            do {
                let creds = try await oauth.completeLogin(input: trimmed, request: request)
                credentials.store.saveAnthropicOAuthCredentials(creds)
                credentials.refresh()
                syncLoginState()
                clearPasteState()
                isCompleting = false
            } catch {
                errorMessage = "Login failed: \(error.localizedDescription)"
                isCompleting = false
            }
        }
    }

    private func syncLoginState() {
        isLoggedIn = credentials.store.anthropicOAuthCredentials() != nil
    }

    private func clearPasteState() {
        loginRequest = nil
        pastedCode = ""
    }
}
