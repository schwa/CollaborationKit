import ArgumentParser
import CollaborationKit
import Foundation

enum ProviderKind: String, ExpressibleByArgument, CaseIterable {
    case anthropic
    case openai
    case lmstudio
}

/// Tracks per-turn timing across the send call and the event-stream task.
///
/// The event task records when the first token arrives; the send loop reads the
/// totals once the turn completes. Actor isolation keeps the two tasks in sync.
private actor TurnTimer {
    private var start: ContinuousClock.Instant?
    private var firstToken: ContinuousClock.Instant?
    private(set) var outputTokens = 0

    /// Resets the timer at the start of a turn.
    func begin(at instant: ContinuousClock.Instant) {
        start = instant
        firstToken = nil
        outputTokens = 0
    }

    /// Records the arrival of the first streamed token; later calls are ignored.
    func noteFirstToken() {
        guard firstToken == nil else { return }
        firstToken = .now
    }

    func addOutputTokens(_ count: Int) {
        outputTokens += count
    }

    /// Time from the start of the turn to the first streamed token, if any arrived.
    var firstTokenDelay: Duration? {
        guard let start, let firstToken else { return nil }
        return start.duration(to: firstToken)
    }
}

private extension Duration {
    /// The duration as fractional seconds.
    var seconds: Double {
        let (secs, attos) = components
        return Double(secs) + Double(attos) / 1e18
    }
}

struct Chat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Collaborate with an LLM on a file. Read/write/edit tools operate on the given path."
    )

    @Argument(help: "Path to the file to collaborate on. Created if it doesn't exist.")
    var path: String

    @Option(name: .long, help: "Backend: anthropic, openai, or lmstudio.")
    var provider: ProviderKind = .anthropic

    @Option(name: .long, help: "Model identifier. Defaults to a Claude model for anthropic.")
    var model: String?

    @Option(name: .long, help: "Override the API base URL (e.g. http://localhost:1234 for LM Studio).")
    var baseURL: String?

    @Option(name: .long, help: "Max tokens per response.")
    var maxTokens: Int = 4_096

    func run() async throws {
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: url.path) {
            try "".write(to: url, atomically: true, encoding: .utf8)
            print("Created \(url.path)")
        }

        let document = FileDocument(url: url)
        let modelProvider = try makeProvider()
        let session = LLMSession(
            provider: modelProvider,
            system: """
            You are collaborating with the user on the file at \(url.path). \
            Use the read, write, and edit tools to inspect and modify it. \
            Read the file before editing when you need its current contents.
            """,
            tools: .fileTools(for: document)
        )

        let timer = TurnTimer()
        printEvents(from: session, timer: timer)

        print("Collaborating on \(url.path). Type a message, or 'exit' to quit.\n")
        while true {
            print("> ", terminator: "")
            guard let line = readLine(strippingNewline: true) else { break }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed == "exit" || trimmed == "quit" { break }

            do {
                let start = ContinuousClock.now
                await timer.begin(at: start)
                _ = try await session.send(trimmed)
                let elapsed = start.duration(to: .now)
                let firstToken = await timer.firstTokenDelay
                let tokens = await timer.outputTokens
                printTiming(elapsed: elapsed, firstToken: firstToken, outputTokens: tokens)
                print("\n")
            } catch {
                FileHandle.standardError.write(Data("\nError: \(error)\n".utf8))
            }
        }
    }

    /// Builds the configured provider, sourcing credentials as needed.
    private func makeProvider() throws -> ModelProvider {
        switch provider {
        case .anthropic:
            let store = CredentialStore()
            let auth: AnthropicAuth
            if let oauth = try store.oauthCredentials() {
                let provider = OAuthTokenProvider(credentials: oauth, store: store)
                auth = .oauth(provider.tokenProvider)
            } else if let apiKey = try store.apiKey() {
                auth = .apiKey(apiKey)
            } else {
                throw ValidationError("No credentials found. Run `collab login` or `collab login --oauth` first.")
            }
            var config = AnthropicConfig(
                auth: auth,
                model: model ?? "claude-sonnet-4-5",
                maxTokens: maxTokens
            )
            if let baseURL { config.baseURL = try parseURL(baseURL) }
            return AnthropicProvider(config: config)

        case .openai:
            let apiKey = try requireStoredKey()
            guard let model else {
                throw ValidationError("--model is required for the openai provider.")
            }
            var config = OpenAIConfig(apiKey: apiKey, model: model, maxTokens: maxTokens)
            if let baseURL { config.baseURL = try parseURL(baseURL) }
            return OpenAIProvider(config: config)

        case .lmstudio:
            guard let model else {
                throw ValidationError("--model is required for the lmstudio provider (the model loaded in LM Studio).")
            }
            let serverURL = try baseURL.map(parseURL) ?? URL(string: "http://localhost:1234")!
            // LM Studio ignores the API key; no login required.
            let config = OpenAIConfig.lmStudio(model: model, baseURL: serverURL, maxTokens: maxTokens)
            return OpenAIProvider(config: config)
        }
    }

    private func requireStoredKey() throws -> String {
        guard let apiKey = try CredentialStore().apiKey() else {
            throw ValidationError("No API key found. Run `collab login` first.")
        }
        return apiKey
    }

    private func parseURL(_ string: String) throws -> URL {
        guard let url = URL(string: string) else {
            throw ValidationError("Invalid base URL: \(string)")
        }
        return url
    }

    /// Streams session events to stdout: assistant text live, tool activity tagged.
    private func printEvents(from session: LLMSession, timer: TurnTimer) {
        Task {
            for await event in session.events {
                switch event {
                case .textDelta(let chunk):
                    await timer.noteFirstToken()
                    print(chunk, terminator: "")
                    fflush(stdout)

                case .toolCall(let use):
                    print("\n  [\(use.name)] \(summarize(use.input))")

                case .toolResult(let result):
                    if result.isError {
                        print("  [error] \(result.content)")
                    }

                case .usage(let usage):
                    await timer.addOutputTokens(usage.outputTokens)
                    print("\n  [usage] in: \(usage.inputTokens)  out: \(usage.outputTokens)")

                case .text, .turnComplete:
                    break
                }
            }
        }
    }

    /// Prints per-turn timing: total wall time, time-to-first-token, and output tokens/sec.
    private func printTiming(elapsed: Duration, firstToken: Duration?, outputTokens: Int) {
        let seconds = elapsed.seconds
        var line = "  [timing] total: \(format(seconds))s"
        if let firstToken {
            line += "  ttft: \(format(firstToken.seconds))s"
        }
        if outputTokens > 0, seconds > 0 {
            line += "  out: \(format(Double(outputTokens) / seconds)) tok/s"
        }
        print("\n\(line)")
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func summarize(_ input: JSONValue) -> String {
        guard case .object(let object) = input, !object.isEmpty else { return "" }
        return object.keys.sorted().joined(separator: ", ")
    }
}
