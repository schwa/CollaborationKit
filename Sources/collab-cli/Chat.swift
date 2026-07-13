#if os(macOS)

import ArgumentParser
import CollaborationKit
import Foundation

enum ProviderKind: String, ExpressibleByArgument, CaseIterable {
    case anthropic
    case openai
    case lmstudio
    case ollama
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

    @Option(name: .long, help: "Backend: anthropic, openai, lmstudio, or ollama.")
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
    ///
    /// Delegates every case to a shared ``Backend`` factory so credential
    /// lookup and provider construction stay in one place.
    private func makeProvider() throws -> ModelProvider {
        let baseURL = try baseURL.map(parseURL)
        switch provider {
        case .anthropic:
            let store = CLICredentialStore()
            // Prefer the OAuth backend when subscription credentials are
            // stored; fall back to the API-key backend otherwise. Mirrors
            // the priority the pre-Backend hand-rolled path used.
            let backend: Backend = store.oauthCredentials() != nil
                ? .claudeSubscription
                : .anthropicAPI
            guard backend.hasCredentials(store) else {
                throw ValidationError("No credentials found. Run `collab-cli login` or `collab-cli login --oauth` first.")
            }
            return try backend.makeProvider(store, model ?? backend.defaultModel, maxTokens, baseURL)

        case .openai:
            guard let model else {
                throw ValidationError("--model is required for the openai provider.")
            }
            // OpenAI credentials for the CLI are stored under the Anthropic
            // slot today (see CLICredentialStore + Login), so route the
            // stored API key into the OpenAI backend by hand.
            let apiKey = try requireStoredKey()
            let store = InMemoryCredentialStore(openAIAPIKey: apiKey)
            return try Backend.openAI.makeProvider(store, model, maxTokens, baseURL)

        case .lmstudio:
            guard let model else {
                throw ValidationError("--model is required for the lmstudio provider (the model loaded in LM Studio).")
            }
            // No credentials required; the store is unused.
            let backend = Backend.lmStudio()
            return try backend.makeProvider(InMemoryCredentialStore(), model, maxTokens, baseURL)

        case .ollama:
            guard let model else {
                throw ValidationError("--model is required for the ollama provider (e.g. llama3.2).")
            }
            let backend = Backend.ollama()
            return try backend.makeProvider(InMemoryCredentialStore(), model, maxTokens, baseURL)
        }
    }

    private func requireStoredKey() throws -> String {
        guard let apiKey = CLICredentialStore().apiKey() else {
            throw ValidationError("No API key found. Run `collab-cli login` first.")
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

                case .text, .turnComplete, .historyChanged:
                    break

                case .turnCancelled:
                    print("\n  [stopped]")
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

#endif
