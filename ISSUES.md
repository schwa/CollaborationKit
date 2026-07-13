# ISSUES.md

File format: <https://github.com/schwa/issues-format>

---

## 1: Add live transport tests with a mock URLProtocol

+++
status: open
priority: medium
kind: task
labels: testing, effort:m
created: 2026-06-23T23:13:55Z
updated: 2026-07-13T01:54:13Z
+++

All provider tests are parser-level (StreamAccumulator / OpenAIStreamAccumulator). Nothing exercises AnthropicProvider/OpenAIProvider end-to-end over a real URLSession. Add a MockURLProtocol that feeds canned SSE byte streams through the actual providers to verify: request construction (auth headers, anthropic-beta/user-agent for OAuth, x-api-key vs Bearer), HTTP status handling (non-2xx -> httpError with body), and partial-line SSE buffering. Largest gap: the networking layer is unproven by tests, only manually verified against LM Studio and Anthropic.

---

## 2: Harden SSE parsing against awkward chunk boundaries

+++
status: open
priority: medium
kind: bug
labels: bug, testing, effort:s
created: 2026-06-23T23:14:06Z
updated: 2026-07-13T01:49:39Z
+++

Both providers parse the SSE stream via bytes.lines, which assumes each 'data:' payload is a single newline-delimited line. Real SSE can split a JSON payload across reads, use CRLF, or include multi-line data fields. Verify/handle: CRLF line endings, a JSON payload that spans chunk boundaries, and blank-line event separators. Add tests that drive the provider with deliberately split chunks.

---

## 3: Add bounded retry with backoff for transient API failures

+++
status: open
priority: medium
kind: enhancement
labels: enhancement, effort:m
created: 2026-06-23T23:14:06Z
updated: 2026-07-13T01:49:39Z
+++

No retry anywhere. A transient 429 or 5xx (e.g. Anthropic 529 overloaded) kills the whole turn. pi's reference OAuth code retried token exchange on 429/5xx with backoff and honored Retry-After / x-should-retry. Add bounded retry (a few attempts, exponential backoff, respect Retry-After) to: the Anthropic OAuth token exchange/refresh, and the streaming message call for both providers. Must not retry non-idempotent partial streams blindly — only retry before the first byte is yielded.

---

## 4: Honor task cancellation cleanly in LLMSession and providers

+++
status: open
priority: medium
kind: enhancement
labels: enhancement, effort:m
created: 2026-06-23T23:14:06Z
updated: 2026-07-13T01:49:39Z
+++

send() is not easily cancellable mid-turn and the session events stream never finishes (its continuation is never terminated). For any UI, cancelling a turn should stop the in-flight request, stop the tool loop, and let observers know. Wire Task cancellation through the provider streams and the session loop; consider finishing or yielding a terminal event so the events AsyncStream completes.

---

## 5: Preserve partial work when maxIterations is exceeded

+++
status: open
priority: low
kind: enhancement
labels: enhancement, effort:s
created: 2026-06-23T23:14:14Z
updated: 2026-07-13T01:49:39Z
+++

SessionError.maxIterationsExceeded throws out of send() and discards the partial turn (accumulated text, tool calls/results so far are lost to the caller, though history is mutated). Consider returning what happened instead of throwing it away — e.g. include the partial assistant text in the error, or return a result type that distinguishes 'completed' vs 'hit iteration cap'.

---

## 6: Add a turn-complete summary event with total usage and stop reason

+++
status: open
priority: low
kind: enhancement
labels: enhancement, effort:s
created: 2026-06-23T23:14:14Z
updated: 2026-07-13T01:49:39Z
+++

Usage is emitted per model response (SessionEvent.usage), but there is no single turn-level summary: total tokens for the turn plus the stop reason. turnComplete currently carries only the final text. Consider enriching turnComplete (or adding a new event) with aggregated TokenUsage for the turn and the provider stop reason, so callers don't have to sum usage events themselves.

---

## 7: Conversation history compaction with user-defined strategy

+++
status: open
priority: medium
kind: feature
labels: effort:l
created: 2026-06-24T01:06:10Z
updated: 2026-07-13T01:49:39Z
+++

LLMSession.history grows unbounded and is sent in full every turn; there is no compaction, truncation, or summarization, so long sessions will eventually exceed the provider's context window.

Add a compaction mechanism to LLMSession:

- A pluggable, user-defined compaction strategy (a protocol / closure) the host can supply when creating a session.
- A sensible default strategy that is useful out of the box (e.g. summarize or drop older turns while preserving the system prompt and recent context; must keep tool_use/tool_result pairing intact).
- Compaction runs against the session's history and must preserve message validity (assistant tool_use blocks always matched by following tool_result blocks).
- Keep Core/ provider-agnostic; strategy operates on [Message].
- Token usage is per-turn only and does not report remaining context window, so triggering should be strategy-controlled (e.g. by message count / accumulated tokens), not by querying the model's window.

Acceptance:
- Strategy protocol + default strategy implemented.
- Session invokes compaction at the appropriate point in the turn loop.
- Tests with ScriptedProvider covering: default strategy compacts as expected, custom strategy is honored, tool_use/tool_result pairing preserved.

---

## 8: Extract shared SSE/HTTP streaming transport for providers

+++
status: closed
priority: medium
kind: none
created: 2026-06-24T01:10:57Z
updated: 2026-06-24T01:26:58Z
closed: 2026-06-24T01:26:58Z
+++

AnthropicProvider and OpenAIProvider duplicate byte-identical streaming transport plumbing:

- The send(...) wrapper that builds an AsyncThrowingStream around a Task, finishes on success, finishes(throwing:) on error, and cancels the task on termination.
- The stream(...) method: urlSession.bytes(for:), non-2xx status check that drains the body into an error, then the SSE 'data:' line loop (strip prefix, trim, skip empty) feeding an accumulator.

Only the request-building and the accumulator differ between providers; the transport is copy-pasted and currently has no direct test coverage.

Proposal: extract a deep, shallow-interface SSE/HTTP transport module that owns the Task/stream wrapper, status handling, error-body draining, and 'data:' line parsing. Providers supply a URLRequest factory and an accumulator-like sink; the transport drives the loop.

Constraints:
- Keep Core/ provider-agnostic; transport can live in Core/ or a shared internal location but must not import Anthropic/OpenAI specifics.
- Preserve each provider's accumulator semantics (Anthropic emits on content_block_stop; OpenAI emits on [DONE] via finish()). The [DONE] sentinel handling differs and must be expressible.
- Preserve error types (AnthropicError.httpError / OpenAIError.httpError with status + drained body).

Test impact:
- Add boundary tests for the transport with a stubbed URLSession / byte stream (status codes, error-body draining, data: line parsing, sentinel handling).
- Existing StreamAccumulator / OpenAIStreamAccumulator tests stay unchanged.

Acceptance:

- `2026-06-24T01:10:57Z`: Shared transport implemented; both providers use it; no behavior change.
- `2026-06-24T01:10:57Z`: Transport boundary tests added; full suite green (no network).
- `2026-06-24T01:26:58Z`: Implemented shared StreamingTransport + ServerSentEventSink; both providers delegate to it. Behavior-preserving (no public API change). Added 7 boundary tests; suite 30 green.

---

## 9: Consolidate neutral-message wire encoding ownership

+++
status: open
priority: low
kind: task
labels: effort:m
created: 2026-06-24T01:10:57Z
updated: 2026-07-13T01:49:39Z
+++

Message -> wire encoding knowledge is split across AnthropicWire, OpenAIWire, and the provider request builders:

- AnthropicWire encodes the neutral Message/ContentBlock model into Anthropic's structured blocks and owns the OAuth identity-block rule.
- OpenAIWire flattens the same neutral model into tool_calls + per-result role:'tool' messages.
- Both are free enums of static functions rather than deep modules; encoding concerns leak between the wire enum and the provider's makeRequest.

Proposal: give each provider a clearly-owned, deep wire-encoding module with a small interface (neutral messages/tools/system in -> request body out), so the encoding concept is co-located and the provider transport/request code does not re-handle message shape.

Constraints:
- Preserve Anthropic OAuth specifics: identity block prepended first as structured system blocks; non-OAuth uses plain string system. (Load-bearing per AGENTS.md.)
- Preserve OpenAI flattening: assistant tool_use -> tool_calls; each tool_result -> its own role:'tool' message; one neutral message can expand to several wire messages.
- Core/ stays provider-agnostic.

Test impact:
- OpenAITests already covers wire flattening; keep it.
- Lower payoff than the transport extraction; mainly improves cohesion and discoverability.

Acceptance:
- Wire encoding consolidated per provider behind a small interface; no behavior change; suite green.

Note: lower priority — cohesion/readability win, not a correctness or testability gap.

---

## 10: Decompose LLMSession.runLoop responsibilities (turn loop / event fan-out / tool dispatch)

+++
status: open
priority: medium
kind: task
labels: effort:m
created: 2026-06-24T01:10:58Z
updated: 2026-07-13T01:49:39Z
+++

LLMSession.runLoop mixes three responsibilities in one method:

1. Driving the model/tool round-trip loop and mutating history.
2. Fanning provider ProviderStreamEvents out into SessionEvents on the events continuation.
3. Dispatching tools (execute) and accumulating TokenUsage.

Consequences:
- The loop is entangled with the AsyncStream continuation and the live provider call, so it is hard to test in isolation; SessionTests can only exercise it end-to-end via ScriptedProvider.
- The planned compaction strategy (issue #CollaborationKit#7) has no clean extension point in the loop.

Proposal: separate the turn-loop core from the event-emission and tool-dispatch concerns so the loop can be reasoned about and tested at a boundary (history transcript + tool dispatcher in -> events + updated history out), with compaction as a clean hook.

Constraints:
- Preserve the error split (ToolError/any error -> is_error tool result fed back; SessionError/transport -> thrown out of send). Load-bearing per AGENTS.md.
- Preserve public behavior of send(_:) and the events stream ordering (textDelta/text/toolCall/toolResult/usage/turnComplete).
- Keep LLMSession an actor; history remains read-only-exposed via messages.
- Coordinate with #CollaborationKit#7 (compaction) — this refactor should make that hook natural.

Test impact:
- Existing ScriptedProvider end-to-end tests remain.
- Add boundary tests for the decomposed turn loop / tool dispatch independent of the streaming machinery.

Acceptance:
- runLoop decomposed; behavior and event ordering unchanged; compaction has a clear insertion point; suite green.

Riskier than the transport extraction (touches session behavior) but strategically aligned with #CollaborationKit#7.

---

## 11: Support image (multimodal) input in messages

+++
status: closed
priority: low
kind: none
created: 2026-06-24T02:38:08Z
updated: 2026-06-25T03:28:46Z
closed: 2026-06-25T03:28:46Z
+++

The content model is text-only: ContentBlock has only .text/.toolUse/.toolResult, and ToolResult.content is a String. Neither provider can send images even though Anthropic and OpenAI both support image input natively.

Add multimodal image input as an additive extension that respects the existing layering (Core/ stays provider-agnostic).

Scope:
- Core/: add an image content representation (e.g. ContentBlock.image(ImageContent)) carrying base64 data + media type (and/or a URL variant). Decide whether images are also allowed in ToolResult content.
- AnthropicWire: encode as an 'image' block (source: { type: base64, media_type, data }).
- OpenAIWire: encode as 'image_url' parts within the user message content array; the flattening logic must handle multi-part user content.
- Convenience: a Message.user(text:images:) helper.
- Optional: collab-cli CLI plumbing to attach image files to a turn.

Constraints:
- Keep Core/ provider-agnostic; no Anthropic/OpenAI specifics leak in.
- Preserve OpenAI wire flattening (assistant tool_use -> tool_calls; tool_result -> role:'tool'); extend it to multi-part content rather than breaking it.
- Sendable everywhere.

Test impact:
- Add wire-encoding tests for both providers covering an image-bearing user message (Anthropic image block shape; OpenAI image_url multi-part shape).
- No network; encoding-only tests.

Acceptance:
- ContentBlock supports images; both wire encoders emit correct shapes; helper added; suite green.
- Output-only models (image generation) are out of scope; this is input only.

---

## 12: Support disabling parallel tool calls in the OpenAI provider

+++
status: closed
priority: medium
kind: enhancement
labels: openai, tools
created: 2026-06-25T00:09:19Z
updated: 2026-06-25T00:12:09Z
closed: 2026-06-25T00:12:09Z
+++

The OpenAI provider (Sources/CollaborationKit/OpenAI) always lets the server decide on parallel tool calls. gpt-4o issues multiple tool calls in a single turn, which breaks agentic edit loops: in a real session it emitted writeConfiguration AND a blind 'edit' in the same turn, so the edit's oldText didn't match the (not-yet-updated) source. It recovered via read -> edit, but the parallel/blind call is wasteful and fragile.

Ask:
- Add a 'parallelToolCalls: Bool' option to OpenAIConfig (default true to preserve current behavior, or expose so callers can turn it off for agentic flows).
- Emit 'parallel_tool_calls' in the /v1/chat/completions request body (OpenAIWire) when set, so callers can send 'parallel_tool_calls': false.

Context: surfaced while wiring OpenAI into Phosphor's shader-generation tool loop. Anthropic serializes tool calls and works perfectly; OpenAI needs parallel calls disabled to behave the same in an edit/read/compile loop.

---

## 13: Implement RFC 0002 — CollaborationKitUI

+++
status: closed
priority: medium
kind: feature
created: 2026-07-13T00:40:29Z
updated: 2026-07-13T01:28:24Z
closed: 2026-07-13T01:28:24Z
+++

See rfcs/0002-collaborationkit-ui.md.

- `2026-07-13T01:28:24Z`: Core landed as of 2026-07-12: auth flow (KeychainCredentialStore, CollaborationCredentials, Settings view, OAuth paste flow, API key sections), transcript model (ConversationStore + ConversationItem, Phosphor-ported), transcript/composer/chat views, demo wired end-to-end. Remaining work per the RFC tracked in #26 (rollback), #27 (theme), #28 (iOS), #29 (tool presenters), #30 (accessibility). RFC 0002 marked Implemented.

---

## 14: Implement RFC 0003 — Model-Object Tool Macro

+++
status: open
priority: medium
kind: feature
labels: effort:xl
created: 2026-07-13T00:40:29Z
updated: 2026-07-13T01:49:52Z
+++

See rfcs/0003-model-object-tool-macro.md.

- `2026-07-13T01:01:38Z`: Slice 1 landed: core `@CollaborationTools` / `@CollaborationTool` macros, primitives + Optional/Array/[String:T], throws/async/actor call-site handling, `CollaborationResultConvertible`. Framework bridges (FoundationModels/SwiftData/AppIntents), `@CollaborationField`, `@CollaborationSchema`, nested-object handling, doc-comment mining, and name prefixing are deferred to later slices.

---

## 15: Consolidate credential storage across targets

+++
status: open
priority: high
kind: task
labels: effort:m
created: 2026-07-13T00:55:41Z
updated: 2026-07-13T01:54:05Z
+++

Credential-related types now live in three places with overlapping responsibilities:

- CollaborationKit/Credentials.swift — file-based `CredentialStore` (API key + OAuth JSON at ~/.config/collaborationkit/credentials.json).
- CollaborationKit/Anthropic/OAuthTokenProvider.swift — actor that refreshes and persists back to the file-based `CredentialStore`.
- CollaborationKitUI/Keychain/KeychainCredentialStore.swift — Keychain-backed store with slots for Anthropic API key, Anthropic OAuth, OpenAI API key, plus its own self-refreshing token-provider closure.
- CollaborationKitUI/CollaborationBackend.swift — `hasCredentials(for:)` / `makeProvider(for:)` on the Keychain store only; the file store has no equivalent.
- collab-cli/Login.swift — writes exclusively to the file store.

Result: two independent sources of truth (file vs Keychain), duplicated refresh logic (`OAuthTokenProvider` actor vs. the closure returned by `KeychainCredentialStore.anthropicOAuthTokenProvider`), OpenAI slot only in the Keychain store, and the CLI vs the UI can never see each other's credentials.

Design work: pick one of

1. Common `CredentialStorage` protocol in Core with file + Keychain conformers, one `OAuthTokenProvider` that talks to it, `hasCredentials`/`makeProvider` defined once.
2. Deprecate the file-based store; the Keychain becomes the default and the CLI moves to it (option: continue writing the JSON file as a portable export for headless / CI use).
3. Keep both but formalize the split: file store is CLI-only, Keychain store is app-only, share nothing but `OAuthCredentials`.

Related: RFC 0002 (CollaborationKitUI).

---

## 16: RFC 0003: FoundationModels bridge for @Generable types and cross-backend tool reuse

+++
status: open
priority: medium
kind: feature
labels: effort:l
depends: 14, 15
created: 2026-07-13T01:02:34Z
updated: 2026-07-13T01:49:52Z
+++

Slice 1 has no awareness of FoundationModels. A @Generable value used as a tool parameter or return type is rejected as an unsupported type; there is no way to reuse the schema FoundationModels already generates.

Missing per RFC 0003 §3.1:
- Recognise @Generable types in the macro's parameter/return handling and reuse their generated schema.
- A companion macro (or utility) that exposes a FoundationModels session's own tools through the CollaborationKit Tool surface, so an app can share one toolbox across backends.
- OS-version gating in the bridge module.

Depends on the CollaborationSchemaConvertible / schema-lookup mechanism from #15.

---

## 17: RFC 0003: SwiftData bridge synthesizes CRUD tools for @Model types

+++
status: open
priority: medium
kind: feature
labels: effort:l
depends: 14, 15
created: 2026-07-13T01:02:41Z
updated: 2026-07-13T01:49:52Z
+++

Slice 1 does not know about SwiftData @Model types. Annotating a @Model with @CollaborationTools does nothing useful — the user still has to hand-write list/fetch/create/update/delete tools.

Missing per RFC 0003 §3.2:
- Derived CRUD tools (list, fetch(id:), create, update(id:, ...), delete(id:)) for a @Model type.
- @CollaborationField(.readOnly | .hidden | .writable) per property to control the derived surface.
- Predicate parameter → declarative filter schema (not full Predicate DSL).
- A collaborationTools(in: ModelContext) accessor variant, since these tools need a ModelContext.
- Hand-written @CollaborationTool methods on the same @Model override the derived tool of the same name.
- OS-version gating in the bridge module.

---

## 18: RFC 0003: AppIntents bridge exposes AppIntent.perform() as a tool

+++
status: open
priority: medium
kind: feature
labels: effort:l
depends: 14, 15
created: 2026-07-13T01:02:46Z
updated: 2026-07-13T01:49:52Z
+++

Slice 1 does not know about AppIntent. A type conforming to AppIntent isn't recognised by the macro; parameters declared with @Parameter are ignored.

Missing per RFC 0003 §3.3:
- Recognise AppIntent-conforming types and expose perform() as a tool.
- Derive tool parameters from @Parameter metadata (title, description, default value, options).
- Parameter summaries / localised titles feed the tool description.
- IntentResult flows through CollaborationResultConvertible (dialog text → tool result string; opened content → structured result).
- In-process invocation only — no need to route through the system.
- OS-version gating in the bridge module.

---

## 19: RFC 0003: doc-comment mining feeds tool descriptions

+++
status: open
priority: low
kind: enhancement
labels: effort:s
depends: 14
created: 2026-07-13T01:02:51Z
updated: 2026-07-13T01:49:52Z
+++

Every @CollaborationTool method has to repeat its description in the attribute argument, even when the method already has a /// doc comment saying the same thing.

Missing per RFC 0003 open question 2:
- If the attribute has no description argument, use the member's /// doc comment as the tool description.
- Explicit attribute string always wins.
- Requires enabling doc-comment trivia access in the macro.

---

## 20: RFC 0003: tool-name prefixing and collision handling across multiple annotated types

+++
status: open
priority: medium
kind: enhancement
labels: effort:s
depends: 14
created: 2026-07-13T01:02:56Z
updated: 2026-07-13T01:49:52Z
+++

Slice 1 uses the bare Swift member name as the tool name. When two @CollaborationTools types both expose e.g. 'create', the model sees two tools with the same name and one wins silently.

Missing per RFC 0003 open question 5:
- Default naming prefixes the tool name with the owning type name (or a shortened form of it).
- Per-attribute override to force a specific tool name.
- Documented guidance for hosts that merge tools from multiple stores.

---

## 21: RFC 0003: nested @CollaborationTools objects as parameters (ID reference vs value)

+++
status: open
priority: high
kind: feature
labels: effort:m
depends: 14, 15
created: 2026-07-13T01:03:03Z
updated: 2026-07-13T01:53:09Z
+++

There is no defined behaviour when a @CollaborationTool method takes a value of another @CollaborationTools-annotated type as a parameter, or returns one. Right now such a parameter fails schema derivation.

Missing per RFC 0003 open question 3:
- Decide and document: nested types are passed by ID, not by inlined value.
- Macro emits a schema referencing the ID type; the tool body dereferences on entry.
- What 'ID type' means for a given store is user-declared, likely via a small protocol.
- Test that the model sees a stable ID schema and not the full nested object.

---

## 22: RFC 0003: expose per-tool metadata (e.g. requiresApproval) for host-side gating

+++
status: open
priority: low
kind: feature
labels: effort:s
depends: 14
created: 2026-07-13T01:03:09Z
updated: 2026-07-13T01:49:52Z
+++

Derived tools frequently have side effects (delete, update, perform an intent). CollaborationKit intentionally leaves approval / gating to the host, but Slice 1 doesn't surface any metadata for a host to key off.

Missing per RFC 0003 open question 6:
- Attribute-level flag (e.g. requiresApproval) on @CollaborationTool.
- SwiftData bridge marks derived mutating tools (create/update/delete) automatically; AppIntents bridge marks intent execution similarly.
- Metadata exposed on AnyTool (or a companion struct) so a host UI can find it without re-inspecting Swift types.

---

## 23: RFC 0003: macro-expansion tests via SwiftSyntaxMacrosTestSupport

+++
status: open
priority: high
kind: task
labels: effort:m
depends: 14
created: 2026-07-13T01:03:17Z
updated: 2026-07-13T01:53:09Z
+++

Slice 1 tests exercise the macro through its runtime output (collaborationTools, call, LLMSession loop). There are no assertions against the actual expanded source, so regressions in codegen shape are only caught indirectly.

Missing per RFC 0003 open question 7:
- Add SwiftSyntaxMacrosTestSupport-based expansion tests for CollaborationToolsMacro covering: empty type, single method, all supported parameter kinds, async/throws/actor call sites, and diagnostic-emitting cases (non-type target, unsupported parameter type).
- Keep the runtime tests too; the two catch different bugs.

---

## 24: RFC 0003: expand built-in schema derivation to enums, tuples, and generic wrappers

+++
status: open
priority: high
kind: enhancement
labels: effort:m
depends: 14
created: 2026-07-13T01:03:25Z
updated: 2026-07-13T01:53:09Z
+++

Slice 1's built-in schema derivation covers primitives, Optional, Array, and [String: T]. Anything else falls through to CollaborationSchemaConvertible (#15) or errors.

RFC 0003 open question 1 asks how far the built-in derivation should go before requiring the escape hatch. Candidates to decide on:
- String-backed enums (map to 'enum' in JSON Schema).
- Enums with associated values.
- Tuples with labels.
- User-declared generic wrappers.

Whichever we support should have expansion tests and a clear line vs. the escape hatch.

- `2026-07-13T02:01:07Z`: Punt from autonomous run: this is a design decision, not an implementation task. The issue itself asks 'candidates to decide on' — string/int-backed enums, associated-value enums, labeled tuples, user-declared generic wrappers. Without knowing the target type's conformances at macro-expansion time (SwiftSyntax can't resolve conformances), the only safe path is either (a) a per-type annotation the user spells, or (b) route everything through CollaborationSchemaConvertible (#25). Recommend: land #25 first (explicit escape hatch), then reconsider what to bake in built-in. Meanwhile #41 covers RawRepresentable typed ids as its own targeted slice. Needs product call before implementation.

---

## 25: RFC 0003: CollaborationSchemaConvertible escape hatch for custom parameter/return types

+++
status: closed
priority: high
kind: feature
labels: effort:m
depends: 14
created: 2026-07-13T01:02:28Z
updated: 2026-07-13T02:03:11Z
closed: 2026-07-13T02:03:11Z
+++

Slice 1 only supports primitives + Optional/Array/[String: T]. Anything else (user structs, enums, tuples, generics) fails macro expansion with 'Unsupported parameter/return type'.

Per RFC 0003 §3 the intended escape hatch is a CollaborationSchemaConvertible protocol: user value types opt in and provide their own JSON Schema fragment, and the macro emits a reference to it rather than trying to derive one.

Missing:
- The CollaborationSchemaConvertible protocol in CollaborationKit.
- Schema-derivation lookup so unknown types check for the conformance before erroring.
- @CollaborationSchema attached macro that emits the conformance (or documents how to write it by hand).

See rfcs/0003-model-object-tool-macro.md, sections 'Supported parameter/return types (initial)' and '3.4 User-sprinkled macros'.

- `2026-07-13T02:03:11Z`: Landed. Added `public protocol CollaborationSchemaConvertible: Decodable, Sendable` requiring `static var collaborationSchema: JSONValue { get }`. The macro now routes any unknown identifier type as `ParamType.custom(name)` and emits `<Type>.collaborationSchema` for the runtime schema lookup — if the user's type doesn't conform, the generated code fails to compile at the .collaborationSchema access with a targeted error. Works uniformly under Optional, Array, and [String: T]. Added 4 end-to-end tests (string-backed enum + custom struct) exercising both schema flow and JSON decode dispatch.

---

## 26: CollaborationKitUI: rollback/snapshot support

+++
status: open
priority: medium
kind: feature
labels: effort:l
created: 2026-07-13T01:28:00Z
updated: 2026-07-13T01:49:58Z
+++

Phosphor's ConversationStore lets a user roll back the session to just before a prior user prompt: it snapshots host state (in Phosphor's case, the shader source) alongside the pre-turn history depth, then restores both on demand and truncates the LLMSession history.

Not ported in the initial CollaborationKitUI transcript because the snapshot payload is host-specific. Design a generic API:

- Generic `RollbackSnapshot<Context>` (Context: Sendable) attached to each user prompt row.
- Host closure captures Context at send time and applies it on rollback.
- ConversationStore.rollBack(to:) truncates messages (and calls LLMSession.truncateHistory), invokes the apply closure, drops error overlays.
- ConversationRowView exposes a 'Roll Back to Here' affordance on user rows when snapshots are available.

Related: RFC 0002, #13.

---

## 27: CollaborationKitUI: Theme type with environment plumbing

+++
status: open
priority: low
kind: feature
labels: effort:m
created: 2026-07-13T01:28:00Z
updated: 2026-07-13T01:49:58Z
+++

RFC 0002 calls for a small Theme struct (colors, spacing, corner radii, typography) read from the environment, with hosts overriding per-view or per-tree. Currently ConversationRowView and ComposerView hard-code accent/secondary/red colors and 10/12/16pt spacing.

Design:
- `CollaborationTheme` struct with named tokens (accent, userBubble, assistantBubble, errorTint, spacing, cornerRadius, prose/monospaced fonts).
- `EnvironmentValues.collaborationTheme` + `.collaborationTheme(_:)` modifier.
- Replace hard-coded values in all built-in views.

Related: RFC 0002, #13.

---

## 28: CollaborationKitUI: iOS platform support

+++
status: open
priority: medium
kind: feature
labels: effort:m
created: 2026-07-13T01:28:00Z
updated: 2026-07-13T01:49:58Z
+++

Package currently declares only macOS 14. RFC 0002 calls for macOS 14+ AND iOS 17+.

Work:
- Add `.iOS(.v17)` to Package.swift platforms.
- Verify BrowserOpener path uses UIApplication.open (already guarded).
- Guard `SettingsLink` in CollaborationChatView / missing-credentials placeholder.
- Verify AttachmentThumbnailsView / Attachment (UIImage path already present).
- collab-cli executable target: audit stdio usage (getpass etc.) or exclude from iOS builds.
- Add an iOS destination to the demo app scheme and smoke-test.

Related: RFC 0002, #13.

---

## 29: CollaborationKitUI: tool-presenter registry for custom row content

+++
status: open
priority: low
kind: feature
labels: effort:m
created: 2026-07-13T01:28:00Z
updated: 2026-07-13T01:49:58Z
+++

Right now ConversationRowView renders every tool call the same way: icon + summary line + optional monospaced result. Rich hosts want per-tool custom content (e.g. Phosphor's compileShader row showing diagnostics inline, a diff view for edit results, an image preview for an image-gen tool).

Design a `ToolPresenter` protocol (or view builder closure) registered by tool name, consulted by ConversationRowView. Default presenter matches today's rendering. Registry lives on the store or in the environment; unknown tools fall through to the default.

Related: RFC 0002, #13.

---

## 30: CollaborationKitUI: accessibility pass

+++
status: open
priority: medium
kind: task
labels: effort:m
created: 2026-07-13T01:28:00Z
updated: 2026-07-13T01:49:58Z
+++

RFC 0002 open question 6: roles/labels for the transcript, streaming announcements, focus management on the composer.

Concretely:
- Transcript rows: accessibilityLabel per row kind (user prompt, assistant reply, tool call name+state, error).
- Streaming announcements: post an accessibility notification when a new item appears or a turn completes (VoiceOver rotor).
- Composer: sensible focus order; explicit labels on Attach/Send/Stop buttons; announce token label changes as polite updates.
- ContentUnavailableViews: audit systemImage roles.
- Dynamic Type: verify at accessibility sizes.

Related: RFC 0002, #13.

---

## 31: Tool approval

+++
status: open
priority: medium
kind: feature
labels: effort:m
created: 2026-07-13T01:34:27Z
updated: 2026-07-13T01:49:58Z
+++

Add a mechanism for the host to approve (or deny) tool invocations before they run. Related to #22 (per-tool metadata like requiresApproval).

- `2026-07-13T01:50:12Z`: Related to #32 (path approval for built-in file tools) and #22 (per-tool requiresApproval metadata): #22 surfaces the flag, #31 defines the host-side hook that consumes it, #32 is a concrete built-in application of the same hook for filesystem paths.

---

## 32: Path approval

+++
status: open
priority: medium
kind: feature
labels: effort:m
created: 2026-07-13T01:34:27Z
updated: 2026-07-13T01:49:58Z
+++

Add a mechanism for the host to approve (or deny) filesystem path access by built-in file tools (read/write/edit).

- `2026-07-13T01:50:12Z`: Related to #31 (general tool-approval mechanism). Filesystem-path gating for read/write/edit is arguably a specialization: consider implementing it as a built-in participant in whatever host-approval hook #31 lands.

---

## 33: Copy progress/stop button from Phosphor to CollaborationKitUI

+++
status: closed
priority: medium
kind: task
created: 2026-07-13T01:36:39Z
updated: 2026-07-13T01:45:54Z
closed: 2026-07-13T01:45:54Z
+++

Port the progress/stop button UI component from the Phosphor project into the CollaborationKitUI target. Used to indicate an in-flight LLM turn and let the user cancel it.

- `2026-07-13T01:45:54Z`: Ported from Phosphor as `StopButton` (public) in Sources/CollaborationKitUI/Views/Composer/. Wired into ComposerView; replaces the plain bordered Stop button when a turn is running.

---

## 34: CollaborationKitUI: model picker per backend

+++
status: open
priority: medium
kind: feature
labels: effort:m
created: 2026-07-13T01:40:35Z
updated: 2026-07-13T01:49:58Z
+++

Phosphor's Settings has a ModelPickerSection that fetches the available models for the selected backend (via ModelLister), filters to chat/tool-capable ids, sorts them, and persists the user's selection. CollaborationKitUI currently only knows CollaborationBackend.defaultModel.

Design:
- ModelPickerSection view usable inside CollaborationSettingsView (or standalone).
- Fetches via the ModelLister protocol against the currently-configured backend.
- Filters obvious non-chat models (embeddings, audio, image, moderation, dated snapshots) with a customizable predicate.
- Persists selection to UserDefaults under a caller-supplied key (defaults to "collaborationkit.model.<backend>").
- CollaborationCredentials.makeProvider(model:) already accepts an override; add a resolved-selection accessor so hosts don't reinvent it.
- Graceful fallback when the fetch fails or credentials are missing.

Blocks: any Phosphor migration onto CollaborationKitUI.
Related: RFC 0002, #13, #28.

---

## 35: CollaborationKitUI: session debug export (JSON)

+++
status: open
priority: medium
kind: feature
labels: effort:m
created: 2026-07-13T01:40:35Z
updated: 2026-07-13T01:49:58Z
+++

Phosphor's ConversationExport bundles a full session snapshot (raw transcript, system prompt, model id, cumulative usage, last error, tool calls/results, and any host-specific state like current shader source) into a Codable JSON export, then hands it to .fileExporter.

Design:
- Codable SessionExport value covering: exportedAt, model id, system prompt, TokenUsage, lastError, [Message], and the projected [ConversationItem] transcript with per-row timing.
- ConversationStore.buildExport() async that gathers the LLMSession's authoritative messages/usage plus the projected items.
- FileDocument (or Transferable) conformance for .fileExporter usage.
- Extension point for hosts to attach domain payload (e.g. Phosphor's currentSource) via a generic parameter or a userInfo dictionary.

Blocks: any Phosphor migration onto CollaborationKitUI.
Related: RFC 0002, #13.

---

## 36: CollaborationKitUI: image drop destination on the transcript

+++
status: open
priority: low
kind: feature
labels: effort:s
created: 2026-07-13T01:40:35Z
updated: 2026-07-13T01:49:58Z
+++

Phosphor's transcript accepts image file drops (URLs) directly onto the scroll area and routes them into the pending composer attachments. CollaborationKitUI's TranscriptView has no dropDestination — users must go through the paperclip importer.

Design:
- TranscriptView gains a dropDestination(for: URL.self) that funnels dropped files into the ComposerView's attachment list.
- ComposerView exposes a way to receive attachments programmatically (init/binding or a small controller).
- Handle security-scoped URL access.

Blocks: parity with Phosphor's drag-drop experience.
Related: RFC 0002, #13.

---

## 37: CollaborationKitUI: menu-command / focused-scene-value hooks

+++
status: open
priority: low
kind: feature
labels: effort:s
created: 2026-07-13T01:40:35Z
updated: 2026-07-13T01:49:58Z
+++

Phosphor exposes actions (export debug info, stop generation, roll back) to the app menu via focusedSceneValue with typed FocusedValueKey values, so the File / Edit menus can trigger them contextually.

Design:
- Public FocusedValueKey types for the actions CollaborationKitUI can drive: exportSession, stopGeneration, rollBack (once rollback lands).
- A small Actions value type surfaced by CollaborationChatView / TranscriptView / ComposerView via focusedSceneValue.
- Documented pattern for hosts to add CommandMenu items that consume them.

Related: RFC 0002, #13, #26 (rollback), and the export issue above.

---

## 38: CollaborationKitUI: glowing multicolor prompt border (opt-in)

+++
status: closed
priority: low
kind: feature
created: 2026-07-13T01:40:36Z
updated: 2026-07-13T01:45:54Z
closed: 2026-07-13T01:45:54Z
+++

Phosphor's composer sports a distinctive multicolor glowing border on the prompt field that brightens on focus. It's decorative and Phosphor-only today; ComposerView uses a plain 1pt accent border.

Design:
- ViewModifier (glowingPromptBorder(cornerRadius:active:)) shipped with CollaborationKitUI.
- Opt-in per host \u2014 the default border stays plain so we don't foist chrome on everyone.
- ComposerView gains an initializer parameter (borderStyle: .plain | .glow) or exposes the modifier for hosts to apply.

Related: RFC 0002, #13, #27 (theme).

- `2026-07-13T01:45:54Z`: Ported from Phosphor as `GlowingPromptBorder` (public ViewModifier) + `.glowingPromptBorder(cornerRadius:active:)` extension. Exposed via `ComposerBorderStyle.glow` on ComposerView / CollaborationChatView; default remains `.plain`. Demo uses `.glow` to show it off.

---

## 39: RFC 0003: replace `String(describing:)` fallback in `_ckStringify`

+++
status: closed
priority: high
kind: enhancement
labels: effort:s
created: 2026-07-13T01:43:27Z
updated: 2026-07-13T01:59:35Z
closed: 2026-07-13T01:59:35Z
+++

Today `_ckStringify` (Sources/CollaborationKit/Macros/CollaborationResult.swift) handles a return type in this order:

1. `CollaborationResultConvertible` conformance
2. `Encodable` (JSON encoded)
3. `String(describing:)` fallback

The third branch is a footgun: a struct that conforms to neither ends up sent to the model as `NoteRow(id: "n1", title: "Groceries")` — not JSON, not obviously human-readable, and the model then has to guess how to parse it. Silent bad behavior.

Options:

- **Runtime error.** Throw a clear `ToolError("Return type \(T.self) needs Encodable or CollaborationResultConvertible")`; the session converts it to an `is_error` tool result and the model learns. Cheap, obvious, but every-turn cost.
- **`Mirror` fallback.** Reflect the value into a synthetic JSON object (properties → keys). Better than `String(describing:)` but slow, doesn't handle collections/enums with associated values cleanly, and effectively hides the missing conformance.
- **Macro-time check.** Have `@CollaborationTool` inspect the return type and emit a compile-time diagnostic ("Return type X does not conform to Encodable or CollaborationResultConvertible; conform one of them."). Best DX but SwiftSyntax can't check conformances directly — only surface-level heuristics.

Recommendation: land the runtime error first (safe, immediate), consider the `Mirror` fallback as an opt-in for prototyping, and pursue a macro-time diagnostic when we can.

Related: RFC 0003, #14, #25.

- `2026-07-13T01:59:35Z`: Fixed: `_ckStringify` now throws `CollaborationResultError.noKnownFormatter(String)` when a return type conforms to neither CollaborationResultConvertible nor Encodable, instead of falling back to `String(describing:)` which produced Swift-formatted debug output the model couldn't parse. The error names the offending type so the developer can immediately see what to conform. LLMSession will convert the throw into an is_error tool result and the model can adapt. Added 6 regression tests in CollaborationResultTests.

---

## 40: RFC 0003: improve unsupported-input-type macro diagnostic

+++
status: closed
priority: high
kind: enhancement
labels: effort:s
created: 2026-07-13T01:43:27Z
updated: 2026-07-13T02:00:33Z
closed: 2026-07-13T02:00:33Z
+++

Today `SchemaDerivationError.unsupportedType` (Sources/CollaborationKitMacros/SchemaDerivation.swift) surfaces as:

    Unsupported parameter/return type: NoteRow. Slice 1 supports Bool, Int, Double, Float, String, Optional, Array, and [String: T] where T is one of the same.

Actionable improvements:

- Once #25 (CollaborationSchemaConvertible escape hatch) lands, mention it in the diagnostic message.
- For struct/class parameter types, suggest the ID-pattern ("Pass a String id and look up the value inside the method — see #21").
- Emit a FixIt suggesting the primitive workaround when the offending type is a Codable value type (best-effort — SwiftSyntax can only see the declared type, not conformances).
- Point at the RFC section that documents supported types.

Related: RFC 0003, #14, #21, #25.

- `2026-07-13T02:00:33Z`: Diagnostic message rewritten to point at concrete workarounds available today (primitive-id pattern; Encodable-return works) and the follow-ups that will eventually cover richer types (#21, #24, #25, #41). SchemaDerivationError gained a `typeName` accessor so the macro can construct tailored messages without parsing the description string. Not covered by a unit test yet — diagnostic testing needs SwiftSyntaxMacrosTestSupport, tracked in #23.

---

## 41: RFC 0003: support typed ID wrappers (RawRepresentable) as tool parameters

+++
status: open
priority: high
kind: feature
labels: effort:m
created: 2026-07-13T01:52:23Z
updated: 2026-07-13T01:57:53Z
+++

The demo's DemoNotes today has:

    func list() async -> String
    func create(title: String, body: String) async -> String
    func delete(id: String) async throws

These would idiomatically be:

    func list() async -> [Note]        // or [Note.ID]
    func create(...) async -> Note.ID
    func delete(id: Note.ID) async throws

**Return side** — already works: `[Note]` conforming to `Codable` runs through `_ckStringify`'s Encodable path and produces JSON the model can parse. A typed `struct NoteID: RawRepresentable, Codable` returns as a JSON string. No macro change needed; the demo just doesn't use it.

**Input side** — blocked by slice 1's primitives-only restriction. `Note.ID` (a `RawRepresentable` wrapper around `String` or `Int`) fails schema derivation with `unsupportedType`. This is the most common Swift pattern for tagged identifiers, and the current workaround (accept `String` everywhere, stringly-typed) forces every host to lose type safety at exactly the boundary where the model touches the domain.

Design:

- Recognise `T: RawRepresentable where T.RawValue: Codable` (or the primitive set slice 1 supports) as a parameter type.
- Derive the JSON Schema from `RawValue`; decode by constructing `T(rawValue: decodedRaw)` and failing if `nil`.
- Symmetric coverage for enums with raw values (`enum Priority: String, Codable`) — same pattern, likely folded into schema derivation for enums (#24).

Update the demo to use `Note.ID` on `create` / `delete` and `[Note]` on `list` once inputs land.

Related: RFC 0003, #14, #24 (enums/tuples/generics), #25 (custom escape hatch).

---

## 42: Increase test coverage

+++
status: new
priority: medium
kind: task
created: 2026-07-13T02:02:44Z
+++

Test coverage across CollaborationKit is insufficient. Audit current coverage, identify uncovered code paths (especially in core sync/collaboration logic), and add tests to reach an acceptable coverage level.

---

## 43: SwiftUI review

+++
status: new
priority: medium
kind: task
created: 2026-07-13T02:02:45Z
+++

Review SwiftUI code in CollaborationKit and Examples for correctness, modern API usage, and adherence to house rules. Areas to check include view identity, state ownership, ForEach usage, environment values, animations, and use of soft-deprecated APIs.

---

## 44: Swift concurrency review

+++
status: new
priority: medium
kind: task
created: 2026-07-13T02:02:45Z
+++

Review Swift concurrency usage across CollaborationKit for correctness and modern API usage. Look for actor isolation issues, Sendable violations, task lifetime bugs, unstructured Task usage, MainActor misuse, and other async/await pitfalls.

---
