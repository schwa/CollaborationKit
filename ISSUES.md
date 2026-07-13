# ISSUES.md

File format: <https://github.com/schwa/issues-format>

---

## 1: Add live transport tests with a mock URLProtocol

+++
status: new
priority: high
kind: none
labels: testing
created: 2026-06-23T23:13:55Z
+++

All provider tests are parser-level (StreamAccumulator / OpenAIStreamAccumulator). Nothing exercises AnthropicProvider/OpenAIProvider end-to-end over a real URLSession. Add a MockURLProtocol that feeds canned SSE byte streams through the actual providers to verify: request construction (auth headers, anthropic-beta/user-agent for OAuth, x-api-key vs Bearer), HTTP status handling (non-2xx -> httpError with body), and partial-line SSE buffering. Largest gap: the networking layer is unproven by tests, only manually verified against LM Studio and Anthropic.

---

## 2: Harden SSE parsing against awkward chunk boundaries

+++
status: new
priority: medium
kind: none
labels: bug, testing
created: 2026-06-23T23:14:06Z
+++

Both providers parse the SSE stream via bytes.lines, which assumes each 'data:' payload is a single newline-delimited line. Real SSE can split a JSON payload across reads, use CRLF, or include multi-line data fields. Verify/handle: CRLF line endings, a JSON payload that spans chunk boundaries, and blank-line event separators. Add tests that drive the provider with deliberately split chunks.

---

## 3: Add bounded retry with backoff for transient API failures

+++
status: new
priority: medium
kind: none
labels: enhancement
created: 2026-06-23T23:14:06Z
+++

No retry anywhere. A transient 429 or 5xx (e.g. Anthropic 529 overloaded) kills the whole turn. pi's reference OAuth code retried token exchange on 429/5xx with backoff and honored Retry-After / x-should-retry. Add bounded retry (a few attempts, exponential backoff, respect Retry-After) to: the Anthropic OAuth token exchange/refresh, and the streaming message call for both providers. Must not retry non-idempotent partial streams blindly — only retry before the first byte is yielded.

---

## 4: Honor task cancellation cleanly in LLMSession and providers

+++
status: new
priority: medium
kind: none
labels: enhancement
created: 2026-06-23T23:14:06Z
+++

send() is not easily cancellable mid-turn and the session events stream never finishes (its continuation is never terminated). For any UI, cancelling a turn should stop the in-flight request, stop the tool loop, and let observers know. Wire Task cancellation through the provider streams and the session loop; consider finishing or yielding a terminal event so the events AsyncStream completes.

---

## 5: Preserve partial work when maxIterations is exceeded

+++
status: new
priority: low
kind: none
labels: enhancement
created: 2026-06-23T23:14:14Z
+++

SessionError.maxIterationsExceeded throws out of send() and discards the partial turn (accumulated text, tool calls/results so far are lost to the caller, though history is mutated). Consider returning what happened instead of throwing it away — e.g. include the partial assistant text in the error, or return a result type that distinguishes 'completed' vs 'hit iteration cap'.

---

## 6: Add a turn-complete summary event with total usage and stop reason

+++
status: new
priority: low
kind: none
labels: enhancement
created: 2026-06-23T23:14:14Z
+++

Usage is emitted per model response (SessionEvent.usage), but there is no single turn-level summary: total tokens for the turn plus the stop reason. turnComplete currently carries only the final text. Consider enriching turnComplete (or adding a new event) with aggregated TokenUsage for the turn and the provider stop reason, so callers don't have to sum usage events themselves.

---

## 7: Conversation history compaction with user-defined strategy

+++
status: new
priority: medium
kind: none
created: 2026-06-24T01:06:10Z
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
status: new
priority: low
kind: none
created: 2026-06-24T01:10:57Z
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
status: new
priority: medium
kind: none
created: 2026-06-24T01:10:58Z
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
status: new
priority: medium
kind: feature
created: 2026-07-13T00:40:29Z
+++

See rfcs/0002-collaborationkit-ui.md.

---

## 14: Implement RFC 0003 — Model-Object Tool Macro

+++
status: new
priority: medium
kind: feature
created: 2026-07-13T00:40:29Z
+++

See rfcs/0003-model-object-tool-macro.md.

- `2026-07-13T01:01:38Z`: Slice 1 landed: core `@CollaborationTools` / `@CollaborationTool` macros, primitives + Optional/Array/[String:T], throws/async/actor call-site handling, `CollaborationResultConvertible`. Framework bridges (FoundationModels/SwiftData/AppIntents), `@CollaborationField`, `@CollaborationSchema`, nested-object handling, doc-comment mining, and name prefixing are deferred to later slices.

---

## 15: Consolidate credential storage across targets

+++
status: new
priority: medium
kind: task
created: 2026-07-13T00:55:41Z
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
status: new
priority: medium
kind: feature
depends: 14, 15
created: 2026-07-13T01:02:34Z
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
status: new
priority: medium
kind: feature
depends: 14, 15
created: 2026-07-13T01:02:41Z
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
status: new
priority: medium
kind: feature
depends: 14, 15
created: 2026-07-13T01:02:46Z
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
status: new
priority: low
kind: enhancement
depends: 14
created: 2026-07-13T01:02:51Z
+++

Every @CollaborationTool method has to repeat its description in the attribute argument, even when the method already has a /// doc comment saying the same thing.

Missing per RFC 0003 open question 2:
- If the attribute has no description argument, use the member's /// doc comment as the tool description.
- Explicit attribute string always wins.
- Requires enabling doc-comment trivia access in the macro.

---

## 20: RFC 0003: tool-name prefixing and collision handling across multiple annotated types

+++
status: new
priority: medium
kind: enhancement
depends: 14
created: 2026-07-13T01:02:56Z
+++

Slice 1 uses the bare Swift member name as the tool name. When two @CollaborationTools types both expose e.g. 'create', the model sees two tools with the same name and one wins silently.

Missing per RFC 0003 open question 5:
- Default naming prefixes the tool name with the owning type name (or a shortened form of it).
- Per-attribute override to force a specific tool name.
- Documented guidance for hosts that merge tools from multiple stores.

---

## 21: RFC 0003: nested @CollaborationTools objects as parameters (ID reference vs value)

+++
status: new
priority: low
kind: feature
depends: 14, 15
created: 2026-07-13T01:03:03Z
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
status: new
priority: low
kind: feature
depends: 14
created: 2026-07-13T01:03:09Z
+++

Derived tools frequently have side effects (delete, update, perform an intent). CollaborationKit intentionally leaves approval / gating to the host, but Slice 1 doesn't surface any metadata for a host to key off.

Missing per RFC 0003 open question 6:
- Attribute-level flag (e.g. requiresApproval) on @CollaborationTool.
- SwiftData bridge marks derived mutating tools (create/update/delete) automatically; AppIntents bridge marks intent execution similarly.
- Metadata exposed on AnyTool (or a companion struct) so a host UI can find it without re-inspecting Swift types.

---

## 23: RFC 0003: macro-expansion tests via SwiftSyntaxMacrosTestSupport

+++
status: new
priority: low
kind: task
depends: 14
created: 2026-07-13T01:03:17Z
+++

Slice 1 tests exercise the macro through its runtime output (collaborationTools, call, LLMSession loop). There are no assertions against the actual expanded source, so regressions in codegen shape are only caught indirectly.

Missing per RFC 0003 open question 7:
- Add SwiftSyntaxMacrosTestSupport-based expansion tests for CollaborationToolsMacro covering: empty type, single method, all supported parameter kinds, async/throws/actor call sites, and diagnostic-emitting cases (non-type target, unsupported parameter type).
- Keep the runtime tests too; the two catch different bugs.

---

## 24: RFC 0003: expand built-in schema derivation to enums, tuples, and generic wrappers

+++
status: new
priority: low
kind: enhancement
depends: 14
created: 2026-07-13T01:03:25Z
+++

Slice 1's built-in schema derivation covers primitives, Optional, Array, and [String: T]. Anything else falls through to CollaborationSchemaConvertible (#15) or errors.

RFC 0003 open question 1 asks how far the built-in derivation should go before requiring the escape hatch. Candidates to decide on:
- String-backed enums (map to 'enum' in JSON Schema).
- Enums with associated values.
- Tuples with labels.
- User-declared generic wrappers.

Whichever we support should have expansion tests and a clear line vs. the escape hatch.

---

## 25: RFC 0003: CollaborationSchemaConvertible escape hatch for custom parameter/return types

+++
status: new
priority: medium
kind: feature
depends: 14
created: 2026-07-13T01:02:28Z
updated: 2026-07-13T01:24:08Z
+++

Slice 1 only supports primitives + Optional/Array/[String: T]. Anything else (user structs, enums, tuples, generics) fails macro expansion with 'Unsupported parameter/return type'.

Per RFC 0003 §3 the intended escape hatch is a CollaborationSchemaConvertible protocol: user value types opt in and provide their own JSON Schema fragment, and the macro emits a reference to it rather than trying to derive one.

Missing:
- The CollaborationSchemaConvertible protocol in CollaborationKit.
- Schema-derivation lookup so unknown types check for the conformance before erroring.
- @CollaborationSchema attached macro that emits the conformance (or documents how to write it by hand).

See rfcs/0003-model-object-tool-macro.md, sections 'Supported parameter/return types (initial)' and '3.4 User-sprinkled macros'.

---
