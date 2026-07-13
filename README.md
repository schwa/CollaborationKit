# CollaborationKit

Swift package for building apps that collaborate with an LLM through tools.
Annotate methods on your model with a macro and the model can call them.
Add the SwiftUI chat view and you have an assistant panel.

## Features

### `CollaborationKit`

- `LLMSession`: an actor that runs the tool-use loop.
- `@CollaborationTools` / `@CollaborationTool` macros. Annotate methods on
  your model and the JSON Schema is derived from the parameter list.
- Providers:
  - `AnthropicProvider`: Claude via API key or subscription (OAuth).
  - `OpenAIProvider`: OpenAI and any compatible server (LM Studio, Ollama,
    [antirez/ds4](https://github.com/antirez/ds4)).
  - Roll your own by implementing `ModelProvider`.
- Live event stream for text deltas, tool activity, and token usage.
- Tool errors go back to the model. Transport and decoding errors throw to
  you.

### `CollaborationKitUI`

- `CollaborationChatView`: transcript + composer, drop into any SwiftUI
  hierarchy.
- `ConversationStore`: observable transcript state driven by an
  `LLMSession`.
- `CollaborationSettingsView`: everything needed to sign in and pick a
  model.
- `CollaborationCredentials`: observable credentials wrapper for the
  environment; builds a `ModelProvider` on demand.
- `KeychainCredentialStore`: Keychain-backed storage for API keys and OAuth
  tokens.

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/schwa/CollaborationKit", from: "0.1.0")
]
```

Products: `CollaborationKit` (core) and `CollaborationKitUI` (SwiftUI).

## Creating Tools via macros

Annotate a class (or actor, or struct) with `@CollaborationTools`, then mark
methods with `@CollaborationTool`. The macro derives a JSON Schema from the
parameter list and exposes a `collaborationTools: [any Tool]` property. Tool
descriptions come from the method's `///` doc comment, or from an explicit
string passed to `@CollaborationTool` if you want to override it.

```swift
import CollaborationKit

@MainActor
@Observable
@CollaborationTools
final class Notes {
    var items: [Note] = []

    /// List every note, oldest first.
    @CollaborationTool
    func list() async -> [Note] { /* ... */ }

    /// Create a note. Returns the new note's id.
    @CollaborationTool
    func create(title: String, body: String) async -> String { /* ... */ }

    /// Delete the note with the given id.
    @CollaborationTool(requiresApproval: true)
    func delete(id: String) async throws { /* ... */ }
}
```

Doc-comment mining uses the first paragraph — up to the first blank line or
DocC keyword (`- Parameter`, `- Returns:`, etc.) — so parameter and return
docs stay out of the tool description.

Parameters may be primitives, `Optional`, `Array`, `Dictionary<String, T>`,
or any type conforming to `CollaborationSchemaConvertible`.
`requiresApproval: true` routes the call through the session's approval
closure before it runs.

Hand the tools to a session:

```swift
let notes = Notes()
let session = LLMSession(
    provider: AnthropicProvider(config: .init(apiKey: myKey)),
    system: "You help the user manage notes.",
    tools: notes.collaborationTools
)

let reply = try await session.send("Add a note titled 'Groceries'.")
```

If you're building a custom UI or a headless tool, subscribe to
`session.events` to watch the model work as it goes. SwiftUI hosts using
`ConversationStore` / `CollaborationChatView` skip this; the store consumes
the events for you.

```swift
for await event in await session.events {
    switch event {
    case .textDelta(let chunk): print(chunk, terminator: "")
    case .toolCall(let call): print("\n→ \(call.name)")
    case .usage(let u): print("\ntokens: \(u.totalTokens)")
    default: break
    }
}
```

## SwiftUI

`CollaborationKitUI` gives you the chat surface and a settings pane backed
by the Keychain. Wire it into an app:

```swift
import SwiftUI
import CollaborationKit
import CollaborationKitUI

@main
struct MyApp: App {
    @State private var credentials = CollaborationCredentials(
        store: KeychainCredentialStore(service: "com.example.MyApp")
    )

    var body: some Scene {
        WindowGroup {
            ContentView().environment(credentials)
        }
        #if os(macOS)
        Settings {
            CollaborationSettingsView().environment(credentials)
        }
        #endif
    }
}
```

`CollaborationSettingsView` handles sign-in and model selection. Writes go
straight to the Keychain.

In your view, build a session from the credentials and put
`CollaborationChatView` wherever you want the assistant to live:

```swift
struct ContentView: View {
    @Environment(CollaborationCredentials.self) private var credentials
    @State private var notes = Notes()
    @State private var store: ConversationStore?

    var body: some View {
        NotesList(notes: notes)
            .inspector(isPresented: .constant(true)) {
                if let store {
                    CollaborationChatView(store: store)
                }
            }
            .task(id: credentials.hasCredentials) {
                guard credentials.hasCredentials else { store = nil; return }
                let provider = try? credentials.makeProvider()
                guard let provider else { return }
                let session = LLMSession(
                    provider: provider,
                    system: "You help the user manage notes.",
                    tools: notes.collaborationTools
                )
                store = ConversationStore(session: session)
            }
    }
}
```

`ConversationStore` owns the transcript. `CollaborationChatView` renders it
above a composer (with optional image attachments), and shows a "Sign in"
placeholder when credentials are missing.

## FAQ

### Why is my `@CollaborationTool` method in an extension ignored?

`@CollaborationTool` must be declared in the same type body as the
`@CollaborationTools` attribute. Methods annotated in an `extension` are
silently skipped: Swift attached-member macros only see the primary
declaration's member block, not extensions, so the macro cannot discover
them. Move the method into the primary declaration.

## Demo app

[`Examples/CollaborationDemo`](Examples/CollaborationDemo) is a small
SwiftUI notes app wired up end to end. The notes store uses
`@CollaborationTools`, the chat lives in an inspector, and Settings hosts
`CollaborationSettingsView` so you can switch between Claude (API key or
subscription) and any OpenAI-compatible backend. Open the Xcode project
inside that folder and run.

## Providers

| Provider              | Auth                                     |
|-----------------------|------------------------------------------|
| Anthropic (API key)   | `AnthropicProvider(config: .init(apiKey:))` |
| Claude Subscription   | `AnthropicProvider(config: .init(auth: .oauth { … }))` |
| OpenAI                | `OpenAIProvider(config: .init(apiKey:model:))` |
| LM Studio / Ollama    | `OpenAIProvider(config: .lmStudio(model:))` |

> OAuth caveat: subscription login uses the Claude Code OAuth client and is
> unofficial. It may violate Anthropic's terms and may break without notice.

## License

MIT. See [LICENSE](LICENSE).
