# CollaborationKit

A Swift package for building apps that collaborate with an LLM through tools.

You drive a provider-agnostic session, the model calls tools you register, and
you observe everything — streaming text, tool calls, and token usage — through
a live `AsyncStream`. Ships with Anthropic and OpenAI-compatible backends and a
read/write/edit tool set for collaborating on a document (a file on disk or an
in-memory string).

- **Swift 6**, strict concurrency, `Sendable` throughout.
- **macOS 14+ / iOS 17+**.
- **URLSession + async/await**, no external SPM dependencies in the core
  library. (`collab-cli` uses `swift-argument-parser`; the macro target uses
  `swift-syntax`.)
- **MIT licensed.**

## Features

- **Provider-agnostic sessions.** `LLMSession` is an actor that owns the
  conversation, registered tools, and the tool-use loop.
- **Two backends included.**
  - `AnthropicProvider` — Claude via a billed API key **or** a Claude
    subscription (OAuth).
  - `OpenAIProvider` — the OpenAI API and any OpenAI-compatible server: LM
    Studio, Ollama, [antirez/ds4](https://github.com/antirez/ds4), gateways.
  - Add more by implementing one protocol.
- **Typed tools.** Conform to `Tool` with a `Decodable` input and a
  hand-written JSON Schema, or use the `@CollaborationTools` /
  `@CollaborationTool` macros.
- **File tools built in.** `read`, `write`, and `edit` against a
  `TextDocument` (file or in-memory).
- **Live event stream.** Streaming text deltas, tool calls, tool results, and
  usage — all through `session.events`.
- **Tool-vs-harness error split.** Tool errors are reported back to the model
  so it can adapt; transport / decoding / loop errors throw out to you.
- **Token usage reporting.** Per-turn `input`/`output` counts, plus a
  cumulative total on the session.
- **`collab-cli` executable** for quick file collaboration from the terminal.
- **`CollaborationKitUI`** — optional SwiftUI transcript, composer, settings,
  and a Keychain-backed credential store.

## Installation

Add CollaborationKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/schwa/CollaborationKit", from: "0.1.0")
]
```

Then depend on the products you need:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "CollaborationKit", package: "CollaborationKit"),
        .product(name: "CollaborationKitUI", package: "CollaborationKit") // optional
    ]
)
```

## Quick start

```swift
import CollaborationKit

let doc = InMemoryDocument("Hello, world.\n")

let provider = AnthropicProvider(
    config: AnthropicConfig(apiKey: myKey)   // model defaults to claude-sonnet-4-5
)

let session = LLMSession(
    provider: provider,
    system: "You are collaborating with the user on a document.",
    tools: .fileTools(for: doc)
)

// Observe tool calls, streaming text, and usage live.
Task {
    for await event in session.events {
        switch event {
        case .textDelta(let chunk): print(chunk, terminator: "")
        case .toolCall(let use):    print("\n[tool] \(use.name)")
        case .usage(let usage):     print("\n[usage] in: \(usage.inputTokens) out: \(usage.outputTokens)")
        default: break
        }
    }
}

let reply = try await session.send("Rewrite this as a haiku.")
print("\n\(reply)")
print(doc.contents)
print("Session total: \(await session.totalUsage.totalTokens) tokens")
```

### Other backends

```swift
// OpenAI-compatible: LM Studio, Ollama, antirez/ds4, or the OpenAI API.
let local = OpenAIProvider(config: .lmStudio(model: "qwen2.5-coder-7b-instruct"))

let ds4 = OpenAIProvider(config: OpenAIConfig(
    apiKey: "unused",
    model: "deepseek-v4-flash",
    baseURL: URL(string: "http://localhost:8080")!
))

// Claude via a subscription (OAuth) instead of a billed key.
let claude = AnthropicProvider(config: AnthropicConfig(auth: .oauth {
    // Return a currently-valid access token.
    // Refresh via AnthropicOAuth if expired.
    try await currentAccessToken()
}))
```

## Custom tools

Conform to `Tool` with a `Decodable` input and a JSON Schema:

```swift
struct UppercaseTool: Tool {
    struct Input: Decodable, Sendable { let text: String }

    var name: String { "uppercase" }
    var description: String { "Uppercase a string." }
    var inputSchema: JSONValue {
        .object([
            "type": "object",
            "properties": .object([
                "text": .object(["type": "string"])
            ]),
            "required": .array(["text"])
        ])
    }

    func call(_ input: Input) async throws -> String {
        input.text.uppercased()
    }
}

let session = LLMSession(provider: provider, tools: [UppercaseTool().eraseToAnyTool()])
```

Or use the macros to skip the boilerplate:

```swift
@CollaborationTools
struct MyTools {
    @CollaborationTool("Uppercase a string.")
    func uppercase(text: String) -> String { text.uppercased() }
}
```

## `collab-cli`

The `collab-cli` executable wraps the library for quick file collaboration:

```sh
# Store your Anthropic API key. Prompts with hidden input, or pass --api-key.
collab-cli login

# Log in with a Claude subscription (OAuth, paste flow, no local server).
collab-cli login --oauth

# Collaborate on a file. Created if it doesn't exist.
collab-cli chat notes.md
collab-cli chat draft.txt --model claude-sonnet-4-5 --max-tokens 8192

# Use a local LM Studio model.
collab-cli chat notes.md --provider lmstudio --model qwen2.5-coder-7b-instruct

# Any OpenAI-compatible server.
collab-cli chat notes.md --provider openai --model gpt-4o --base-url https://api.openai.com
collab-cli chat notes.md --provider openai --model deepseek-v4-flash --base-url http://localhost:8080
```

`chat --provider anthropic` uses stored OAuth credentials if present, otherwise
the stored API key. OAuth tokens are refreshed automatically. Per-response
token usage is printed as `[usage] in: N out: M`.

Tool calling with local models requires a model the server reports as
tool-capable; quality varies. Claude via `anthropic` is the most reliable.

## Providers

| Provider     | Endpoint                     | Auth                      | CLI login             |
|--------------|------------------------------|---------------------------|-----------------------|
| `anthropic`  | `/v1/messages`               | API key or subscription   | `login` / `--oauth`   |
| `openai`     | `/v1/chat/completions`       | API key                   | `login` (real OpenAI) |
| `lmstudio`   | `/v1/chat/completions`       | none                      | not needed            |

> **OAuth caveat:** subscription login uses the Claude Code OAuth client and is
> unofficial. It may violate Anthropic's terms and may break without notice.

## Concepts

### Documents

`TextDocument` abstracts the editable backing. Use `FileDocument(url:)` for a
file on disk or `InMemoryDocument(_:)` for a string. The `edit` tool performs
an exact, unique string replacement.

### Errors

- **Tool errors** — throw `ToolError` (or any error) from a handler. The
  session reports it back to the model as an error result so it can adapt and
  retry.
- **Harness errors** — transport, decoding, unknown-loop failures, and
  `SessionError.maxIterationsExceeded` throw out of `send(_:)` to you.

### Token usage

Providers that report usage emit a `SessionEvent.usage(TokenUsage)` per
response. `LLMSession.totalUsage` accumulates across the session. This is
per-turn accounting, **not** the model's remaining context window — the
endpoints don't return the window size. Local servers that omit usage report
zeros.

### Authentication

`AnthropicConfig` takes an `auth`: `.apiKey(String)` (sent as `x-api-key`) or
`.oauth(...)` (a Claude subscription token sent as `Authorization: Bearer`).
`AnthropicOAuth` performs a PKCE login with manual code paste (no local
server). Core ships no credential persistence — bring your own store, or use
`CollaborationKitUI.KeychainCredentialStore` (Keychain-backed, one slot each
for Anthropic API key, Anthropic OAuth, and OpenAI API key). `collab-cli`
keeps its credentials in UserDefaults.

### History

`LLMSession.messages` exposes the conversation read-only; serialize it
yourself if you want to persist. The package does no persistence and no
tool-approval gating — those are the host application's concern.

## Examples

- [`Examples/CollaborationDemo`](Examples/CollaborationDemo) — a SwiftUI demo
  app using `CollaborationKitUI`.

## Contributing

Contributions welcome! Please open an issue before starting significant work
so we can discuss the direction.

### Layout

```
Sources/CollaborationKit/
  Core/        Message, JSONValue, TokenUsage, Tool (+AnyTool), SessionEvent,
               ModelProvider, LLMSession, Retry  — provider-agnostic
  Anthropic/   AnthropicConfig (+AnthropicAuth), AnthropicWire,
               AnthropicProvider (+StreamAccumulator), AnthropicOAuth
  OpenAI/      OpenAIConfig, OpenAIWire,
               OpenAIProvider (+OpenAIStreamAccumulator)
  FileTools/   TextDocument (+FileDocument/InMemoryDocument), read/write/edit,
               PathPolicy
  Macros/      @CollaborationTools, @CollaborationTool,
               CollaborationResultConvertible, CollaborationSchemaConvertible
Sources/CollaborationKitUI/
  Keychain/    KeychainCredentialStore, KeychainReadResult
  Views/, Transcript/, Support/, Composer/
Sources/collab-cli/
  Collab, Login, Chat, CLICredentialStore (UserDefaults)
Tests/CollaborationKitTests/
```

### Design rules

- **Layers stay clean.** Nothing in `Core/` may import or know about a
  specific provider. Each provider lives in its own folder and implements only
  `ModelProvider`, translating its wire protocol into a neutral
  `AsyncThrowingStream<ProviderStreamEvent>`. The session translates those
  into `SessionEvent` on the live stream.
- **Typed tools, not JSON.** Tools declare a `Decodable & Sendable` `Input`
  and a hand-written `inputSchema: JSONValue`. Do not auto-derive schemas
  from `Codable`.
- **Error split (load-bearing).** Tool handlers throw → the session converts
  to an `is_error` tool result fed back to the model. Harness/transport/
  decoding failures and `SessionError` throw out of `send(_:)` to the caller.
- **Sendable everywhere.** Strict concurrency is on; keep new types
  `Sendable`.
- **Token usage is per-turn, not context-window.** Never fabricate counts;
  providers that omit usage contribute zero.

### Adding a provider

New folder under `Sources/CollaborationKit/`, implement `ModelProvider` only.
Translate the wire protocol into `ProviderStreamEvent`, reassemble streamed
tool-call argument fragments, and emit `.usage` if the API reports it. Add
accumulator tests with raw payloads. `Core/` must stay provider-agnostic.

### Testing

Run the suite with `swift test`. Tests must not hit the network — use the
scripted provider for session behavior and the stream-accumulator tests for
provider/SSE parsing. Add a test when you add a tool, session behavior, or
provider parsing.

## License

MIT. See [LICENSE](LICENSE).
