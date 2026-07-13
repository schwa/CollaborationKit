# CollaborationKit

Swift package for building apps that collaborate with an LLM through tools.
Annotate methods on your model with a macro and the model can call them. Drop
the SwiftUI chat view into your app and you have an assistant panel.

Swift 6, macOS 14+ / iOS 17+. URLSession + async/await. MIT.

## Features

- `LLMSession`: an actor that owns the conversation, the tools, and the
  tool-use loop.
- `@CollaborationTools` / `@CollaborationTool` macros — annotate methods on
  your model, get typed tools with derived JSON Schema for free.
- Providers:
  - `AnthropicProvider`: Claude via API key or subscription (OAuth).
  - `OpenAIProvider`: OpenAI and any compatible server (LM Studio, Ollama,
    [antirez/ds4](https://github.com/antirez/ds4)).
  - Roll your own by implementing `ModelProvider`.
- Live event stream: text deltas, tool calls, tool results, usage.
- Tool errors go back to the model. Transport and decoding errors throw to
  you. The two never get confused.
- `CollaborationKitUI`: SwiftUI chat view, composer, settings, and a
  Keychain-backed credential store.

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
parameter list and exposes a `collaborationTools: [AnyTool]` property.

```swift
import CollaborationKit

@MainActor
@Observable
@CollaborationTools
final class Notes {
    var items: [Note] = []

    @CollaborationTool("List every note, oldest first.")
    func list() async -> [Note] { /* ... */ }

    @CollaborationTool("Create a note. Returns the new note's id.")
    func create(title: String, body: String) async -> String { /* ... */ }

    @CollaborationTool("Delete the note with the given id.", requiresApproval: true)
    func delete(id: String) async throws { /* ... */ }
}
```

Parameters may be primitives, `Optional`, `Array`, `Dictionary<String, T>`,
or any type conforming to `CollaborationSchemaConvertible`, `requiresApproval: true` routes the call through the
session's approval closure before it runs.

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
`session.events` to stream text deltas, tool calls, and usage as they happen.
SwiftUI hosts using `ConversationStore` / `CollaborationChatView` don't need
this — the store consumes the events for you.

```swift
for await event in session.events {
    switch event {
    case .textDelta(let chunk): print(chunk, terminator: "")
    case .toolCall(let call): print("\n→ \(call.name)")
    case .usage(let u): print("\ntokens: \(u.total)")
    default: break
    }
}
```

## SwiftUI

`CollaborationKitUI` gives you the chat surface, a Settings pane, and a
Keychain-backed credentials store. Drop it into an app:

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

`CollaborationSettingsView` handles provider selection, API keys, Claude
subscription OAuth, and model pickers — writes go straight to the Keychain.

In your view, build a session from the credentials and drop
`CollaborationChatView` wherever you want the assistant to live (an
`.inspector`, a sheet, a side panel):

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

## Demo app

[`Examples/CollaborationDemo`](Examples/CollaborationDemo) is a small
SwiftUI notes app wired up end to end: `@CollaborationTools` on the notes
store, `CollaborationChatView` in an inspector, `CollaborationSettingsView`
in the Settings scene, Keychain credentials, and switching between Claude
(API key or subscription) and OpenAI-compatible backends. Open the Xcode
project inside that folder and run.

## Providers

| Provider              | Auth                                     |
|-----------------------|------------------------------------------|
| Anthropic (API key)   | `AnthropicProvider(config: .init(apiKey:))` |
| Claude Subscription   | `AnthropicProvider(config: .init(auth: .oauth { … }))` |
| OpenAI                | `OpenAIProvider(config: .init(apiKey:))` |
| LM Studio / Ollama    | `OpenAIProvider(config: .lmStudio(model:))` |

> OAuth caveat: subscription login uses the Claude Code OAuth client and is
> unofficial. It may violate Anthropic's terms and may break without notice.

## Contributing

Open an issue before starting significant work. Run `swift test`; tests must
not hit the network. Design rules worth knowing: `Core/` stays
provider-agnostic, tools are typed rather than raw JSON, tool errors go back
to the model, and harness errors throw out to the caller.

## License

MIT. See [LICENSE](LICENSE).
