# CollaborationKit

A small Swift package for collaborating with an LLM through tools. You drive a
provider-agnostic session; the model can call tools you register; you observe
everything via a live event stream.

Ships with Anthropic and OpenAI-compatible backends and a read/write/edit tool
set for collaborating on a document (a file on disk or an in-memory string).

- **Provider layer** — `ModelProvider` abstracts the backend.
  - `AnthropicProvider` — Claude, via a billed API key **or** a Claude
    subscription (OAuth).
  - `OpenAIProvider` — the OpenAI API and any OpenAI-compatible server: LM
    Studio, Ollama, [antirez/ds4](https://github.com/antirez/ds4), gateways.
  - More can be added by implementing one protocol.
- **Session layer** — `LLMSession` (an actor) owns the conversation, registered
  tools, and the agentic tool-use loop. Emits a live event stream and tracks
  cumulative token usage.
- **Tools layer** — `Tool` (typed, `Decodable` input) + `AnyTool` eraser. File
  tools (`read`/`write`/`edit`) ship built-in.

Features: streaming text, typed tools, tool-vs-harness error split, token usage
reporting, subscription OAuth, and a `collab` CLI.

URLSession + async/await. Swift 6, macOS 14+. The library has no external
SPM dependencies (CryptoKit, a system framework, is used for OAuth PKCE); the
`collab` CLI uses swift-argument-parser.

## CLI

The `collab` executable wraps the library for quick file collaboration.

```sh
# Store your Anthropic API key (~/.config/collaborationkit/credentials.json, 0600).
# Prompts with hidden input, or pass --api-key.
collab login

# Or log in with a Claude subscription via OAuth (paste flow, no local server).
# Opens a browser; paste back the code#state shown after approving.
collab login --oauth

# Collaborate on a file. Created if it doesn't exist. read/write/edit tools
# operate on this path. Type messages; 'exit' to quit.
collab chat notes.md
collab chat draft.txt --model claude-sonnet-4-5 --max-tokens 8192

# Use a local LM Studio model (no login needed; LM Studio ignores the key).
# --model is the identifier of the model loaded in LM Studio.
collab chat notes.md --provider lmstudio --model qwen2.5-coder-7b-instruct

# Any OpenAI-compatible server (OpenAI, Ollama, antirez/ds4, gateways).
collab chat notes.md --provider openai --model gpt-4o --base-url https://api.openai.com
collab chat notes.md --provider openai --model deepseek-v4-flash --base-url http://localhost:8080
```

The CLI prints per-response token usage as `[usage] in: N  out: M`.

Tool calling with local models requires a model the server reports as
tool-capable; quality varies. Claude via `anthropic` is the most reliable.

`chat --provider anthropic` uses stored OAuth credentials if present, otherwise
the stored API key. OAuth tokens are refreshed automatically.

| Provider     | Endpoint                     | Auth                      | Login        |
|--------------|------------------------------|---------------------------|--------------|
| `anthropic`  | `/v1/messages`               | API key or subscription   | `login` / `--oauth` |
| `openai`     | `/v1/chat/completions`       | API key (ignored locally) | `login` (real OpenAI) |
| `lmstudio`   | `/v1/chat/completions`       | none                      | not needed   |

> **OAuth caveat:** subscription login uses the Claude Code OAuth client and is
> unofficial. It may violate Anthropic's terms and may break without notice.

## Example

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

### Backends

```swift
// OpenAI-compatible: LM Studio, Ollama, antirez/ds4, or the OpenAI API.
let local = OpenAIProvider(config: .lmStudio(model: "qwen2.5-coder-7b-instruct"))
let ds4 = OpenAIProvider(config: OpenAIConfig(
    apiKey: "unused",
    model: "deepseek-v4-flash",
    baseURL: URL(string: "http://localhost:8080")!
))

// Claude via a subscription (OAuth) instead of a billed key.
let creds = try CredentialStore().oauthCredentials()!   // after `collab login --oauth`
let tokens = OAuthTokenProvider(credentials: creds)      // refreshes automatically
let claude = AnthropicProvider(config: AnthropicConfig(auth: .oauth(tokens.tokenProvider)))
```

## Concepts

### Tools

Conform to `Tool` with a `Decodable` input and a hand-written JSON Schema:

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

### Errors

- **Tool errors** — throw `ToolError` (or any error) from a handler. The session
  reports it back to the model as an error result so it can adapt and retry.
- **Harness errors** — transport, decoding, unknown-loop failures, and
  `SessionError.maxIterationsExceeded` throw out of `send(_:)` to you.

### Documents

`TextDocument` abstracts the editable backing. Use `FileDocument(url:)` for a file
on disk or `InMemoryDocument(_:)` for a string. The `edit` tool performs an exact,
unique string replacement.

### Token usage

Providers that report usage emit a `SessionEvent.usage(TokenUsage)` per response
(input/output token counts). `LLMSession.totalUsage` accumulates across the
session. This is per-turn accounting, **not** the model's remaining context
window — the endpoints don't return the window size. Local servers that omit
usage report zeros.

### Authentication

`AnthropicConfig` takes an `auth`: `.apiKey(String)` (sent as `x-api-key`) or
`.oauth(...)` (a Claude subscription token sent as `Authorization: Bearer`).
`AnthropicOAuth` performs a PKCE login with manual code paste (no local server);
`OAuthTokenProvider` refreshes and persists tokens. `CredentialStore` holds an
API key and/or OAuth credentials at `~/.config/collaborationkit/credentials.json`
(`0600`).

> **OAuth caveat:** subscription login uses the Claude Code OAuth client and is
> unofficial. It may violate Anthropic's terms and may break without notice.

## History

`LLMSession.messages` exposes the conversation read-only; serialize it yourself if
you want to persist. The package does no persistence and no tool-approval gating —
those are the host application's concern.

## Contributing

### Layout

```
Sources/CollaborationKit/
  Core/        Message, JSONValue, TokenUsage, Tool (+AnyTool), SessionEvent,
               ModelProvider, LLMSession  — provider-agnostic
  Anthropic/   AnthropicConfig (+AnthropicAuth), AnthropicWire,
               AnthropicProvider (+StreamAccumulator), AnthropicOAuth,
               OAuthTokenProvider
  OpenAI/      OpenAIConfig, OpenAIWire,
               OpenAIProvider (+OpenAIStreamAccumulator) — OpenAI/LM Studio/ds4
  FileTools/   TextDocument (+FileDocument/InMemoryDocument), read/write/edit
  Credentials.swift   on-disk API key + OAuth store
Sources/collab/        Collab (entry), Login (+--oauth), Chat (--provider/--base-url)
Tests/CollaborationKitTests/
```

### Design rules

- **Layers stay clean.** Nothing in `Core/` may import or know about a specific
  provider. Each provider lives in its own folder and implements only
  `ModelProvider`, translating its wire protocol into a neutral
  `AsyncThrowingStream<ProviderStreamEvent>`. The session translates those into
  `SessionEvent` on the live stream.
- **Typed tools, not JSON.** Tools declare a `Decodable & Sendable` `Input` and a
  hand-written `inputSchema: JSONValue`. Do not auto-derive schemas from `Codable`.
- **Error split (load-bearing).** Tool handlers throw → the session converts to an
  `is_error` tool result fed back to the model. Harness/transport/decoding
  failures and `SessionError` throw out of `send(_:)` to the caller. Keep this
  distinction intact.
- **Sendable everywhere.** Strict concurrency is on; keep new types `Sendable`.
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
