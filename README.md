# CollaborationKit

Swift package for building apps that collaborate with an LLM through tools.

Provider-agnostic sessions, typed tools, streaming events, and read/write/edit
tools for a document (a file or an in-memory string).

Swift 6, macOS 14+ / iOS 17+. URLSession + async/await. MIT.

## Features

- `LLMSession`: an actor that owns the conversation, the tools, and the
  tool-use loop.
- Providers:
  - `AnthropicProvider`: Claude via API key or subscription (OAuth).
  - `OpenAIProvider`: OpenAI and any compatible server (LM Studio, Ollama,
    [antirez/ds4](https://github.com/antirez/ds4)).
  - Roll your own by implementing `ModelProvider`.
- Typed tools via the `Tool` protocol (`Decodable` input, JSON Schema), or the
  `@CollaborationTools` / `@CollaborationTool` macros.
- File tools: `read`, `write`, `edit` against a `TextDocument`.
- Live event stream: text deltas, tool calls, tool results, usage.
- Tool errors go back to the model. Transport and decoding errors throw to
  you. The two never get confused.
- Token usage, per turn and cumulative.
- `collab-cli`: file collaboration from the terminal.
- `CollaborationKitUI`: SwiftUI transcript, composer, and a Keychain-backed
  key store.

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/schwa/CollaborationKit", from: "0.1.0")
]
```

## Quick Start

```swift
import CollaborationKit

let doc = InMemoryDocument("Hello, world.\n")
let provider = AnthropicProvider(config: AnthropicConfig(apiKey: myKey))
let session = LLMSession(
    provider: provider,
    system: "You are collaborating with the user on a document.",
    tools: .fileTools(for: doc)
)

Task {
    for await event in session.events {
        if case .textDelta(let chunk) = event { print(chunk, terminator: "") }
    }
}

let reply = try await session.send("Rewrite this as a haiku.")
```

Other backends:

```swift
let local = OpenAIProvider(config: .lmStudio(model: "qwen2.5-coder-7b-instruct"))
let claude = AnthropicProvider(config: AnthropicConfig(auth: .oauth {
    try await currentAccessToken()
}))
```

## `collab-cli`

```sh
collab-cli login                        # store API key
collab-cli login --oauth                # Claude subscription
collab-cli chat notes.md                # collaborate on a file
collab-cli chat notes.md --provider lmstudio --model qwen2.5-coder-7b-instruct
```

| Provider    | Endpoint                | Auth                    |
|-------------|-------------------------|-------------------------|
| `anthropic` | `/v1/messages`          | API key or subscription |
| `openai`    | `/v1/chat/completions`  | API key                 |
| `lmstudio`  | `/v1/chat/completions`  | none                    |

> OAuth caveat: subscription login uses the Claude Code OAuth client and is
> unofficial. It may violate Anthropic's terms and may break without notice.

## Examples

- [`Examples/CollaborationDemo`](Examples/CollaborationDemo) — SwiftUI demo
  using `CollaborationKitUI`.

## Contributing

Open an issue before starting significant work. Run `swift test`; tests must
not hit the network. A few design rules worth knowing before you patch things:
`Core/` stays provider-agnostic, tools are typed rather than raw JSON, tool
errors go back to the model, and harness errors throw out to the caller.

## License

MIT. See [LICENSE](LICENSE).
