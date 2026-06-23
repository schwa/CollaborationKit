import ArgumentParser
import CollaborationKit
import Foundation

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Store credentials for `collab chat` (API key or Claude subscription OAuth)."
    )

    @Flag(name: .long, help: "Log in with a Claude subscription via OAuth (paste flow).")
    var oauth = false

    @Option(name: .long, help: "The API key. If omitted, you'll be prompted (input hidden).")
    var apiKey: String?

    func run() async throws {
        let store = CredentialStore()
        if oauth {
            try await runOAuth(store: store)
            return
        }
        let key = try apiKey ?? promptForKey()
        guard !key.isEmpty else {
            throw ValidationError("No API key provided.")
        }
        try store.save(apiKey: key)
        print("Saved credentials to \(store.fileURL.path)")
    }

    private func runOAuth(store: CredentialStore) async throws {
        let flow = AnthropicOAuth()
        let request = flow.beginLogin()

        print("""
        Claude subscription login (OAuth). Open this URL in your browser:

        \(request.authorizeURL.absoluteString)

        Approve access, then copy the code shown (the `code#state` value, or the
        full callback URL) and paste it below.
        """)
        print()

        // Best-effort: open the browser automatically on macOS.
        _ = try? openInBrowser(request.authorizeURL)

        print("Paste code#state or callback URL: ", terminator: "")
        guard let input = readLine(strippingNewline: true), !input.isEmpty else {
            throw ValidationError("No code provided.")
        }

        let credentials = try await flow.completeLogin(input: input, request: request)
        try store.save(oauth: credentials)
        print("Saved OAuth credentials to \(store.fileURL.path)")
    }

    private func openInBrowser(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try process.run()
    }

    /// Reads the key with echo disabled when a TTY is present, falling back to a
    /// plain read when input is piped.
    private func promptForKey() -> String {
        if isatty(STDIN_FILENO) != 0, let secret = String(validatingCString: getpass("Anthropic API key: ")) {
            return secret.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
