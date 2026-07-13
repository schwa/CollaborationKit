# RFC 0002 — CollaborationKitUI

- **Status:** Draft
- **Author:** @schwa
- **Created:** 2026-07-12
- **Affects:** New target `CollaborationKitUI` in this package.
- **Related:** RFC 0001 (Conversation Structure)

## Summary

Add a new SwiftUI target, `CollaborationKitUI`, that renders a live
`Conversation` (RFC 0001) as a chat-style transcript and provides ready-made
widgets for the credential and OAuth flows the library already supports. The
goal is to let a host app drop a working collaboration UI in with a handful of
lines, without dragging in provider-specific code.

Inspiration and the initial source material come from the equivalent screens
in `../Phosphor` (see `Phosphor/Views/GeneratePanel.swift`,
`Phosphor/Views/SettingsView.swift`, `Phosphor/Support/ConversationStore.swift`,
`Phosphor/Support/ConversationProvider.swift`,
`Phosphor/Support/AnthropicOAuthStore.swift`, and
`Packages/PhosphorSupport/Sources/PhosphorGeneration/Collaboration/ConversationalGenerator.swift`).
Those files are the reference to port from, not a dependency.

## Motivation

- Every host of CollaborationKit re-invents the same UI: message bubbles,
  streaming text, tool-call rows with pending/done/error states, a composer,
  and a scroll-follow behaviour.
- Every host also re-invents credential entry: an API-key field, an OAuth
  paste-code flow, "logged in as…" status, sign-out.
- Phosphor has a mature version of both. Bringing it in-tree (rewritten
  against the neutral `LLMSession` + `Conversation`) makes the library
  batteries-included and gives us a place to iterate on interaction design in
  one repo.

## Design

### Target layout

```
Sources/CollaborationKitUI/
  Transcript/
    TranscriptView.swift        // renders a Conversation
    ExchangeView.swift          // one Exchange (user + entries)
    UserMessageView.swift
    TextResponseView.swift      // streaming + complete states
    ToolTransactionView.swift   // pending/done/error, expandable JSON
    Composer.swift              // input field + send/stop
  Credentials/
    AnthropicCredentialsView.swift   // API key + OAuth in one view
    APIKeyField.swift
    OAuthPasteFlowView.swift    // "open browser → paste code#state"
    CredentialStatusView.swift  // "signed in as …", sign out
  Support/
    ConversationController.swift // ObservableObject wrapping LLMSession
    Theme.swift                  // colors/spacing/fonts, environment
```

Target availability: macOS 14+, iOS 17+ (SwiftUI). No new SPM deps.

### Public surface (sketch)

```swift
// Bind a session + its live conversation to a view.
public struct TranscriptView: View {
    public init(controller: ConversationController)
}

// Owns an LLMSession and a Conversation, exposes @Published state,
// forwards SessionEvents into the Conversation model (RFC 0001).
@MainActor
public final class ConversationController: ObservableObject {
    public init(session: LLMSession)
    @Published public private(set) var conversation: Conversation
    @Published public private(set) var isStreaming: Bool
    public func send(_ text: String, images: [ImageContent] = []) async
    public func cancel()
}

// Credential widgets, provider-agnostic where possible.
public struct AnthropicCredentialsView: View {
    public init(store: CredentialStore = .shared,
                onChange: (() -> Void)? = nil)
}
```

### What to port from Phosphor

- **Transcript layout / streaming behaviour** — the auto-scroll, the
  streaming-cursor affordance, tool-row disclosure, and error styling from
  `GeneratePanel.swift`.
- **Conversation state machine** — the `ConversationStore` /
  `ConversationProvider` split is the same shape RFC 0001 formalises; port the
  update logic, not the types.
- **OAuth paste flow** — the "open browser, paste `code#state`" UI from
  `SettingsView.swift` + `AnthropicOAuthStore.swift`, rewired to call
  `AnthropicOAuth` + `CredentialStore` in this package.
- **API-key entry** — hidden-input field, validation, "test connection" ping.

Port, do not re-export. Nothing Phosphor-specific (Metal editor bits,
shader-tool wiring, `PhosphorGeneration.*`) comes across.

### Theming

Small `Theme` struct with colors, spacing, corner radii, and typography, read
from the environment. Sensible defaults; hosts override per-view or per-tree.
No hard-coded colors in views.

### Non-goals

- No chat persistence UI, no multi-conversation navigation. Hosts pick their
  own storage; the controller just binds one `Conversation` at a time.
- No tool-approval gating UI. That is still the host's concern (per README).
- No provider picker UI. Hosts choose the `ModelProvider`; the credentials
  views are Anthropic-first because that is what the paste OAuth flow is for.
- No iOS-only or macOS-only chrome. Views degrade gracefully on both.

## Open Questions

1. **Model layer.** Does `ConversationController` own the `Conversation`, or
   is `Conversation` already `@Observable` (per RFC 0001 open Q2) and the
   controller just holds the session? Prefer the latter if RFC 0001 lands with
   observable identity.
2. **Text rendering.** Markdown by default? Selectable? Do we ship a
   `TextResponseRenderer` protocol so hosts can swap in a syntax-highlighting
   renderer?
3. **Images in composer.** Paste/drag-drop scope: this RFC or a follow-up?
4. **Tool row content.** Show raw JSON input/output, or a per-tool custom
   view? Consider a `ToolPresenter` registry keyed by tool name.
5. **Errors.** Where do transport / provider errors render in the transcript
   vs a status bar? Tied to RFC 0001 open Q5.
6. **Accessibility.** Roles/labels for the transcript, streaming
   announcements, focus management on the composer.

## Alternatives Considered

- **Keep the UI in Phosphor / each host.** Rejected — the reference
  implementation is worth generalising and every host needs the same pieces.
- **Ship views inside `CollaborationKit` (the core target).** Rejected — Core
  must stay UI-free and SwiftUI-free; that is the whole point of the layer
  split.
- **Depend on a third-party chat-UI package.** Rejected — no external SPM
  deps is a stated constraint of the package.
